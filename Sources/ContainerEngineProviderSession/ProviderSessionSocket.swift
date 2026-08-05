//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import Darwin
import Foundation

final class ProviderSessionSocket: @unchecked Sendable {
    static let maximumFrameBytes = 48 * 1024 * 1024
    static let maximumBufferedBodyBytes = 128 * 1024 * 1024
    static let maximumBufferedRequestBodyBytes = 1024 * 1024 * 1024
    private static let peerIdentityCache =
        ProviderSessionPeerIdentityCache(capacity: 32)

    private let descriptor: Int32
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var isClosed = false

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        guard
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit {
        close()
    }

    func readFrame() async throws -> ProviderSessionFrame {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let frame = try readLock.withLock {
                        var lengthBytes = [UInt8](repeating: 0, count: 4)
                        try readExactly(into: &lengthBytes)
                        let length = lengthBytes.reduce(UInt32(0)) { value, byte in
                            (value << 8) | UInt32(byte)
                        }
                        guard length > 0, length <= Self.maximumFrameBytes else {
                            throw ContainerEngineProviderSessionError.frameTooLarge(Int(length))
                        }
                        var payload = [UInt8](repeating: 0, count: Int(length))
                        try readExactly(into: &payload)
                        do {
                            return try JSONDecoder().decode(
                                ProviderSessionFrame.self,
                                from: Data(payload)
                            )
                        } catch let error as ContainerEngineProviderSessionError {
                            throw error
                        } catch {
                            throw ContainerEngineProviderSessionError.invalidFrame(
                                String(describing: error)
                            )
                        }
                    }
                    continuation.resume(returning: frame)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func writeFrame(_ frame: ProviderSessionFrame) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try writeLock.withLock {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                        let payload = try encoder.encode(frame)
                        guard payload.count <= Self.maximumFrameBytes else {
                            throw ContainerEngineProviderSessionError.frameTooLarge(payload.count)
                        }
                        var length = UInt32(payload.count).bigEndian
                        try withUnsafeBytes(of: &length) { bytes in
                            try writeAll(bytes)
                        }
                        try payload.withUnsafeBytes { bytes in
                            try writeAll(bytes)
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        closeLock.withLock {
            guard !isClosed else {
                return
            }
            isClosed = true
            _ = shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    func peerCodeIdentity() throws -> ProviderHandoffCodeIdentityV1 {
        var peerPID: pid_t = 0
        var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard
            getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &peerPID,
                &peerPIDLength
            ) == 0,
            peerPID > 0,
            peerPIDLength == socklen_t(MemoryLayout<pid_t>.size)
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var peerToken = audit_token_t()
        var peerTokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard
            getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERTOKEN,
                &peerToken,
                &peerTokenLength
            ) == 0,
            peerTokenLength == socklen_t(MemoryLayout<audit_token_t>.size)
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let peerAuditToken = withUnsafeBytes(of: &peerToken) { Data($0) }
        var path = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(
            peerPID,
            &path,
            UInt32(path.count)
        )
        guard count > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var processInformation = proc_bsdinfo()
        let processInformationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard
            proc_pidinfo(
                peerPID,
                PROC_PIDTBSDINFO,
                0,
                &processInformation,
                processInformationSize
            ) == processInformationSize,
            processInformation.pbi_pid == UInt32(peerPID)
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let executableURL = URL(
            fileURLWithFileSystemRepresentation: path,
            isDirectory: false,
            relativeTo: nil
        )
        let executablePath = executableURL.path
        let key = ProviderSessionPeerProcessKey(
            processIdentifier: peerPID,
            peerAuditToken: peerAuditToken,
            startTimeSeconds: processInformation.pbi_start_tvsec,
            startTimeMicroseconds: processInformation.pbi_start_tvusec,
            executablePath: executablePath
        )
        return try Self.peerIdentityCache.identity(for: key) {
            try ProviderHandoffCodeIdentity.load(at: executableURL)
        }
    }

    private func readExactly(into bytes: inout [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remaining
                )
            }
            if result == 0 {
                throw ContainerEngineProviderSessionError.connectionClosed
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += result
        }
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += result
        }
    }
}

struct ProviderSessionPeerProcessKey: Hashable, Sendable {
    var processIdentifier: pid_t
    var peerAuditToken: Data
    var startTimeSeconds: UInt64
    var startTimeMicroseconds: UInt64
    var executablePath: String
}

final class ProviderSessionPeerIdentityCache: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var identities: [
        ProviderSessionPeerProcessKey: ProviderHandoffCodeIdentityV1
    ] = [:]
    private var insertionOrder: [ProviderSessionPeerProcessKey] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func identity(
        for key: ProviderSessionPeerProcessKey,
        load: () throws -> ProviderHandoffCodeIdentityV1
    ) throws -> ProviderHandoffCodeIdentityV1 {
        try lock.withLock {
            if let identity = identities[key] {
                return identity
            }
            let identity = try load()
            if identities.count == capacity, let oldest = insertionOrder.first {
                identities.removeValue(forKey: oldest)
                insertionOrder.removeFirst()
            }
            identities[key] = identity
            insertionOrder.append(key)
            return identity
        }
    }
}

enum ProviderSessionUnixSocket {
    private nonisolated(unsafe) static var processLockPaths = Set<String>()
    private static let processLock = NSLock()

    struct Listener {
        var descriptor: Int32
        var lockDescriptor: Int32
        var lockPath: String
        var device: dev_t
        var inode: ino_t
    }

    static func connect(path: String) throws -> ProviderSessionSocket {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = try makeAddress(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return try ProviderSessionSocket(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func listen(path: String) throws -> Listener {
        try prepareParent(path: path)
        let lockPath = path + ".lock"
        let lockDescriptor = try acquireLock(path: lockPath)
        do {
            try prepare(path: path)
        } catch {
            releaseLock(lockDescriptor, path: lockPath)
            throw error
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            releaseLock(lockDescriptor, path: lockPath)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = try makeAddress(path: path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0, Darwin.listen(descriptor, 128) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var status = stat()
            guard
                lstat(path, &status) == 0,
                status.st_uid == getuid(),
                status.st_mode & S_IFMT == S_IFSOCK
            else {
                throw ContainerEngineProviderSessionError.unsafeSocketPath(path)
            }
            return Listener(
                descriptor: descriptor,
                lockDescriptor: lockDescriptor,
                lockPath: lockPath,
                device: status.st_dev,
                inode: status.st_ino
            )
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: path)
            releaseLock(lockDescriptor, path: lockPath)
            throw error
        }
    }

    static func close(_ listener: Listener, path: String) {
        _ = Darwin.shutdown(listener.descriptor, SHUT_RDWR)
        Darwin.close(listener.descriptor)
        var status = stat()
        if lstat(path, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFSOCK,
            status.st_dev == listener.device,
            status.st_ino == listener.inode
        {
            try? FileManager.default.removeItem(atPath: path)
        }
        releaseLock(listener.lockDescriptor, path: listener.lockPath)
    }

    static func makeAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard
            path.hasPrefix("/"),
            !path.utf8.contains(0),
            bytes.count + 1 <= capacity
        else {
            throw ContainerEngineProviderSessionError.invalidSocketPath(path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { target in
                target.initialize(repeating: 0, count: capacity)
                for index in bytes.indices {
                    target[index] = bytes[index]
                }
            }
        }
        return address
    }

    private static func prepare(path: String) throws {
        _ = try makeAddress(path: path)
        try prepareParent(path: path)
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK else {
                throw ContainerEngineProviderSessionError.unsafeSocketPath(path)
            }
            try FileManager.default.removeItem(atPath: path)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func prepareParent(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var parentStatus = stat()
        guard
            lstat(parent.path, &parentStatus) == 0,
            parentStatus.st_uid == getuid(),
            parentStatus.st_mode & S_IFMT == S_IFDIR,
            parentStatus.st_mode & (S_IRWXG | S_IRWXO) == 0
        else {
            throw ContainerEngineProviderSessionError.unsafeSocketDirectory(parent.path)
        }
    }

    private static func acquireLock(path: String) throws -> Int32 {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let reserved = processLock.withLock {
            processLockPaths.insert(standardizedPath).inserted
        }
        guard reserved else {
            throw ContainerEngineProviderSessionError.unsafeSocketPath(path)
        }
        let descriptor = open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            releaseProcessLock(path: standardizedPath)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var status = stat()
        guard
            fstat(descriptor, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_mode & (S_IRWXG | S_IRWXO) == 0,
            status.st_nlink == 1,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            Darwin.close(descriptor)
            releaseProcessLock(path: standardizedPath)
            throw ContainerEngineProviderSessionError.unsafeSocketPath(path)
        }
        return descriptor
    }

    private static func releaseLock(_ descriptor: Int32, path: String) {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        releaseProcessLock(
            path: URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }

    private static func releaseProcessLock(path: String) {
        _ = processLock.withLock {
            processLockPaths.remove(path)
        }
    }
}
