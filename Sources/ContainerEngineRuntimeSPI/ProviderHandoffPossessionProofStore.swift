//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Darwin
import Foundation

public enum ProviderHandoffPossessionProofStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public enum Operation: String, Equatable, Sendable {
        case createDirectory
        case createLock
        case createTemporary
        case list
        case lock
        case openDirectory
        case openProof
        case publish
        case read
        case synchronize
        case write
    }

    case conflictingProof
    case invalidEncoding
    case invalidMetadata
    case ioFailure(Operation, Int32)
    case notFound
    case proofTooLarge

    public var description: String {
        switch self {
        case .conflictingProof:
            "provider handoff destination possession proof conflicts with an existing token/key receipt"
        case .invalidEncoding:
            "provider handoff destination possession proof encoding is invalid"
        case .invalidMetadata:
            "provider handoff destination possession proof metadata is unsafe"
        case .ioFailure(let operation, let code):
            "provider handoff destination possession proof store \(operation.rawValue) failed with errno \(code)"
        case .notFound:
            "provider handoff destination possession proof was not found"
        case .proofTooLarge:
            "provider handoff destination possession proof exceeds its 128 KiB bound"
        }
    }
}

/// Durable, signature-verifiable destination receipt for each successful
/// X25519 possession challenge. The receipt is published before the response,
/// so a lost response or process crash can replay the identical signed proof.
public struct ProviderHandoffPossessionProofStore: Sendable {
    public static let maximumProofBytes = 128 * 1024
    public static let lockFileName = "provider-handoff-possession-proofs.lock"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    @discardableResult
    public func store(
        _ proof: ProviderHandoffDestinationKeyPossessionProofV1
    ) throws -> String {
        let encoded =
            try ProviderHandoffProviderKeyControlCodec
            .encodePossessionProof(proof)
        guard encoded.count <= Self.maximumProofBytes else {
            throw ProviderHandoffPossessionProofStoreError.proofTooLarge
        }
        let digest =
            try ProviderHandoffProjections
            .destinationPossessionProofRecordDigest(proof)
        return try withLock {
            for existingDigest in try proofDigestsUnlocked() {
                let existing = try loadUnlocked(existingDigest)
                guard
                    existing.tokenID == proof.tokenID,
                    existing.manifestID == proof.manifestID,
                    existing.destinationKeyPurpose
                        == proof.destinationKeyPurpose,
                    existing.destinationKeyID == proof.destinationKeyID
                else {
                    continue
                }
                guard existing == proof, existingDigest == digest else {
                    throw ProviderHandoffPossessionProofStoreError
                        .conflictingProof
                }
                return digest
            }
            let destination = proofURL(digest)
            let temporary = root.appendingPathComponent(
                ".possession-proof.\(UUID().uuidString.lowercased()).tmp"
            )
            let descriptor = Darwin.open(
                temporary.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw ProviderHandoffPossessionProofStoreError.ioFailure(
                    .createTemporary,
                    errno
                )
            }
            var published = false
            defer {
                Darwin.close(descriptor)
                if !published {
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
            _ = try validateFile(descriptor, maximumSize: 0)
            try writeAll(encoded, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw ProviderHandoffPossessionProofStoreError.ioFailure(
                    .synchronize,
                    errno
                )
            }
            guard
                Darwin.renamex_np(
                    temporary.path,
                    destination.path,
                    UInt32(RENAME_EXCL)
                ) == 0
            else {
                if errno == EEXIST,
                    try loadUnlocked(digest) == proof
                {
                    return digest
                }
                throw ProviderHandoffPossessionProofStoreError.ioFailure(
                    .publish,
                    errno
                )
            }
            published = true
            try synchronizeRoot()
            return digest
        }
    }

    public func load(
        _ proofRecordDigestSHA256: String
    ) throws -> ProviderHandoffDestinationKeyPossessionProofV1 {
        try withLock { try loadUnlocked(proofRecordDigestSHA256) }
    }

    private var lockURL: URL {
        root.appendingPathComponent(Self.lockFileName)
    }

    private func proofURL(_ digest: String) -> URL {
        root.appendingPathComponent("\(digest).json")
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try prepareRoot()
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffPossessionProofStoreError.ioFailure(
                .createLock,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        _ = try validateFile(descriptor, maximumSize: 0)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ProviderHandoffPossessionProofStoreError.ioFailure(.lock, errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func loadUnlocked(
        _ digest: String
    ) throws -> ProviderHandoffDestinationKeyPossessionProofV1 {
        guard (try? ProviderHandoffDigest.parseSHA256(digest)) != nil else {
            throw ProviderHandoffPossessionProofStoreError.invalidEncoding
        }
        let descriptor = Darwin.open(
            proofURL(digest).path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw ProviderHandoffPossessionProofStoreError.notFound
            }
            throw ProviderHandoffPossessionProofStoreError.ioFailure(
                .openProof,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        let status = try validateFile(
            descriptor,
            maximumSize: Self.maximumProofBytes
        )
        let encoded = try readAll(descriptor, count: Int(status.st_size))
        let proof: ProviderHandoffDestinationKeyPossessionProofV1
        do {
            proof =
                try ProviderHandoffProviderKeyControlCodec
                .decodePossessionProof(encoded)
        } catch {
            throw ProviderHandoffPossessionProofStoreError.invalidEncoding
        }
        guard
            try ProviderHandoffProjections
                .destinationPossessionProofRecordDigest(proof) == digest
        else {
            throw ProviderHandoffPossessionProofStoreError.invalidEncoding
        }
        return proof
    }

    private func proofDigestsUnlocked() throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: root.path
            )
        } catch {
            throw ProviderHandoffPossessionProofStoreError.ioFailure(
                .list,
                errno
            )
        }
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let digest = String(name.dropLast(5))
            guard (try? ProviderHandoffDigest.parseSHA256(digest)) != nil else {
                return nil
            }
            return digest
        }.sorted()
    }

    private func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProviderHandoffPossessionProofStoreError.ioFailure(
                .createDirectory,
                errno
            )
        }
        var status = stat()
        guard
            Darwin.lstat(root.path, &status) == 0,
            status.st_uid == Darwin.getuid(),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_mode & (S_IRWXG | S_IRWXO) == 0,
            status.st_nlink >= 2
        else {
            throw ProviderHandoffPossessionProofStoreError.invalidMetadata
        }
    }

    @discardableResult
    private func validateFile(
        _ descriptor: Int32,
        maximumSize: Int
    ) throws -> stat {
        var status = stat()
        guard
            Darwin.fstat(descriptor, &status) == 0,
            status.st_uid == Darwin.getuid(),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_mode & (S_IRWXG | S_IRWXO) == 0,
            status.st_nlink == 1,
            status.st_size >= 0,
            maximumSize == 0 || status.st_size <= maximumSize
        else {
            throw ProviderHandoffPossessionProofStoreError.invalidMetadata
        }
        return status
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let result = Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw ProviderHandoffPossessionProofStoreError.ioFailure(
                        .read,
                        errno
                    )
                }
                offset += result
            }
        }
        return data
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < data.count {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw ProviderHandoffPossessionProofStoreError.ioFailure(
                        .write,
                        errno
                    )
                }
                offset += result
            }
        }
    }

    private func synchronizeRoot() throws {
        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffPossessionProofStoreError.ioFailure(
                .openDirectory,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProviderHandoffPossessionProofStoreError.ioFailure(
                .synchronize,
                errno
            )
        }
    }
}
