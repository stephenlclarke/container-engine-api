//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Darwin
import Foundation

public enum ProviderHandoffGatewayStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public enum Operation: String, Equatable, Sendable {
        case createDirectory
        case createLock
        case createTemporary
        case lock
        case openDirectory
        case openState
        case publish
        case read
        case synchronize
        case unlock
        case write
    }

    case integrityMismatch
    case invalidEncoding
    case invalidMetadata
    case ioFailure(Operation, Int32)
    case notFound
    case revisionOverflow
    case revisionMismatch(expected: UInt64, actual: UInt64)
    case stateTooLarge

    public var description: String {
        switch self {
        case .integrityMismatch:
            "provider handoff gateway state integrity check failed"
        case .invalidEncoding:
            "provider handoff gateway state encoding is invalid"
        case .invalidMetadata:
            "provider handoff gateway state metadata is unsafe"
        case .ioFailure(let operation, let code):
            "provider handoff gateway store \(operation.rawValue) failed with errno \(code)"
        case .notFound:
            "provider handoff gateway state does not exist"
        case .revisionOverflow:
            "provider handoff gateway store revision cannot advance beyond UInt64.max"
        case .revisionMismatch(let expected, let actual):
            "provider handoff gateway store revision mismatch: expected \(expected), found \(actual)"
        case .stateTooLarge:
            "provider handoff gateway state exceeds its 32 MiB bound"
        }
    }
}

/// Inode-safe atomic persistence for the gateway's one authority decision state.
///
/// The separately locked state file contains an authenticated envelope around a
/// sorted-key JSON projection. Cryptographic handoff records inside that state
/// continue to use deterministic CBOR; JSON is only the private durable store
/// representation and is never signed or transported.
public struct ProviderHandoffGatewayStore: Sendable {
    public static let stateFileName = "provider-handoff-state.json"
    public static let lockFileName = "provider-handoff-state.lock"
    public static let maximumPayloadBytes = 32 * 1024 * 1024

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func load() throws -> ProviderHandoffGatewayStateV1 {
        try withLock {
            try loadUnlocked()
        }
    }

    public func loadOrCreate(
        initial: @autoclosure () throws -> ProviderHandoffGatewayStateV1
    ) throws -> ProviderHandoffGatewayStateV1 {
        try withLock {
            do {
                return try loadUnlocked()
            } catch ProviderHandoffGatewayStoreError.notFound {
                let state = try initial()
                try ProviderHandoffGatewayStateMachine.validate(state)
                try writeUnlocked(state)
                return state
            }
        }
    }

    /// Applies one already-closed state-machine mutation under the store lock.
    ///
    /// A successful mutation must increment `storeRevision` exactly once. This
    /// prevents a caller from persisting an unversioned or multi-step decision.
    public func update(
        expectedStoreRevision: UInt64,
        _ mutation: (inout ProviderHandoffGatewayStateV1) throws -> Void
    ) throws -> ProviderHandoffGatewayStateV1 {
        try withLock {
            var state = try loadUnlocked()
            guard state.storeRevision == expectedStoreRevision else {
                throw ProviderHandoffGatewayStoreError.revisionMismatch(
                    expected: expectedStoreRevision,
                    actual: state.storeRevision
                )
            }
            guard expectedStoreRevision < UInt64.max else {
                throw ProviderHandoffGatewayStoreError.revisionOverflow
            }
            try mutation(&state)
            guard state.storeRevision == expectedStoreRevision + 1 else {
                throw ProviderHandoffGatewayStoreError.revisionMismatch(
                    expected: expectedStoreRevision + 1,
                    actual: state.storeRevision
                )
            }
            try ProviderHandoffGatewayStateMachine.validate(state)
            try writeUnlocked(state)
            return state
        }
    }

    private var stateURL: URL {
        root.appendingPathComponent(Self.stateFileName, isDirectory: false)
    }

    private var lockURL: URL {
        root.appendingPathComponent(Self.lockFileName, isDirectory: false)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try prepareRoot()
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffGatewayStoreError.ioFailure(.createLock, errno)
        }
        defer { close(descriptor) }
        try validateFile(descriptor, maximumSize: 0)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ProviderHandoffGatewayStoreError.ioFailure(.lock, errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func loadUnlocked() throws -> ProviderHandoffGatewayStateV1 {
        let descriptor = open(stateURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw ProviderHandoffGatewayStoreError.notFound
            }
            throw ProviderHandoffGatewayStoreError.ioFailure(.openState, errno)
        }
        defer { close(descriptor) }
        let status = try validateFile(
            descriptor,
            maximumSize: Self.maximumPayloadBytes * 2
        )
        let encoded = try readAll(descriptor, count: Int(status.st_size))
        let decoder = JSONDecoder()
        let envelope: StateEnvelope
        do {
            envelope = try decoder.decode(StateEnvelope.self, from: encoded)
        } catch {
            throw ProviderHandoffGatewayStoreError.invalidEncoding
        }
        guard
            envelope.schemaVersion == 1,
            envelope.payload.count <= Self.maximumPayloadBytes,
            ProviderHandoffDigest.sha256(envelope.payload)
                == envelope.payloadDigestSHA256
        else {
            throw ProviderHandoffGatewayStoreError.integrityMismatch
        }
        let state: ProviderHandoffGatewayStateV1
        do {
            state = try decoder.decode(
                ProviderHandoffGatewayStateV1.self,
                from: envelope.payload
            )
        } catch {
            throw ProviderHandoffGatewayStoreError.invalidEncoding
        }
        try ProviderHandoffGatewayStateMachine.validate(state)
        return state
    }

    private func writeUnlocked(_ state: ProviderHandoffGatewayStateV1) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(state)
        guard payload.count <= Self.maximumPayloadBytes else {
            throw ProviderHandoffGatewayStoreError.stateTooLarge
        }
        let envelope = StateEnvelope(
            schemaVersion: 1,
            payload: payload,
            payloadDigestSHA256: ProviderHandoffDigest.sha256(payload)
        )
        let encoded = try encoder.encode(envelope)
        let temporaryURL = root.appendingPathComponent(
            ".provider-handoff-state.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffGatewayStoreError.ioFailure(
                .createTemporary,
                errno
            )
        }
        var published = false
        defer {
            close(descriptor)
            if !published {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        _ = try validateFile(descriptor, maximumSize: 0)
        try writeAll(encoded, descriptor: descriptor)
        guard fsync(descriptor) == 0 else {
            throw ProviderHandoffGatewayStoreError.ioFailure(.synchronize, errno)
        }
        guard rename(temporaryURL.path, stateURL.path) == 0 else {
            throw ProviderHandoffGatewayStoreError.ioFailure(.publish, errno)
        }
        published = true
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else {
            throw ProviderHandoffGatewayStoreError.ioFailure(.openDirectory, errno)
        }
        defer { close(directory) }
        guard fsync(directory) == 0 else {
            throw ProviderHandoffGatewayStoreError.ioFailure(.synchronize, errno)
        }
    }

    private func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProviderHandoffGatewayStoreError.ioFailure(
                .createDirectory,
                errno
            )
        }
        var status = stat()
        guard
            lstat(root.path, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_mode & (S_IRWXG | S_IRWXO) == 0,
            status.st_nlink >= 2
        else {
            throw ProviderHandoffGatewayStoreError.invalidMetadata
        }
    }

    @discardableResult
    private func validateFile(
        _ descriptor: Int32,
        maximumSize: Int
    ) throws -> stat {
        var status = stat()
        guard
            fstat(descriptor, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_mode & (S_IRWXG | S_IRWXO) == 0,
            status.st_nlink == 1,
            status.st_size >= 0,
            maximumSize == 0 || status.st_size <= maximumSize
        else {
            throw ProviderHandoffGatewayStoreError.invalidMetadata
        }
        return status
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> Data {
        guard count >= 0 else {
            throw ProviderHandoffGatewayStoreError.invalidMetadata
        }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            while offset < count {
                let result = Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw ProviderHandoffGatewayStoreError.ioFailure(.read, errno)
                }
                offset += result
            }
        }
        return data
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw ProviderHandoffGatewayStoreError.ioFailure(.write, errno)
                }
                offset += result
            }
        }
    }
}

private struct StateEnvelope: Codable {
    var schemaVersion: UInt32
    var payload: Data
    var payloadDigestSHA256: String
}
