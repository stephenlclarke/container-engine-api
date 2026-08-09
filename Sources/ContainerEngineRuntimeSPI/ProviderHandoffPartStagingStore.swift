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

public enum ProviderHandoffPartStagingStoreError:
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
        case write
    }

    case duplicateRecord
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
        case .duplicateRecord:
            "provider handoff part staging record conflicts with an existing identity"
        case .integrityMismatch:
            "provider handoff part staging store integrity check failed"
        case .invalidEncoding:
            "provider handoff part staging store encoding is invalid"
        case .invalidMetadata:
            "provider handoff part staging store metadata is unsafe"
        case let .ioFailure(operation, code):
            "provider handoff part staging store \(operation.rawValue) failed with errno \(code)"
        case .notFound:
            "provider handoff part staging record does not exist"
        case .revisionOverflow:
            "provider handoff part staging store revision cannot advance beyond UInt64.max"
        case let .revisionMismatch(expected, actual):
            "provider handoff part staging revision mismatch: expected \(expected), found \(actual)"
        case .stateTooLarge:
            "provider handoff part staging store exceeds its 32 MiB bound"
        }
    }
}

/// Durable compare-and-swap storage for common per-part import progress.
///
/// Payload bytes and controller-private effects stay outside this store. The
/// collection contains only immutable descriptor identity, normalized ranges,
/// verification evidence, a protected receipt digest, and bounded failure
/// class.
public struct ProviderHandoffPartStagingStore: Sendable {
    public static let stateFileName = "provider-handoff-part-staging.json"
    public static let lockFileName = "provider-handoff-part-staging.lock"
    public static let maximumPayloadBytes = 32 * 1024 * 1024

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    @discardableResult
    public func declare(
        _ proposed: ProviderHandoffPartStagingRecordV1
    ) throws -> ProviderHandoffPartStagingRecordV1 {
        try ProviderHandoffPartStagingStateMachine.validate(proposed)
        guard proposed.state == .declared, proposed.stagingRevision == 1 else {
            throw ProviderHandoffPartStagingStoreError.invalidEncoding
        }
        return try withLock {
            var state = try loadOrEmptyUnlocked()
            if let existing = state.records.first(where: {
                $0.tokenID == proposed.tokenID
                    && $0.manifestID == proposed.manifestID
                    && $0.partKind == proposed.partKind
            }) {
                do {
                    try ProviderHandoffPartStagingStateMachine
                        .validateImmutableIdentity(
                            existing,
                            matches: proposed
                        )
                } catch {
                    throw ProviderHandoffPartStagingStoreError.duplicateRecord
                }
                return existing
            }
            state.records.append(proposed)
            state.records.sort(by: Self.recordLess)
            guard state.storeRevision < UInt64.max else {
                throw ProviderHandoffPartStagingStoreError.revisionOverflow
            }
            state.storeRevision += 1
            try writeUnlocked(state)
            return proposed
        }
    }

    public func load(
        tokenID: String,
        manifestID: String,
        partKind: ProviderHandoffPartKindV1
    ) throws -> ProviderHandoffPartStagingRecordV1 {
        try withLock {
            let state = try loadOrEmptyUnlocked()
            guard
                let record = state.records.first(where: {
                    $0.tokenID == tokenID
                        && $0.manifestID == manifestID
                        && $0.partKind == partKind
                })
            else {
                throw ProviderHandoffPartStagingStoreError.notFound
            }
            return record
        }
    }

    public func records() throws -> [ProviderHandoffPartStagingRecordV1] {
        try withLock { try loadOrEmptyUnlocked().records }
    }

    @discardableResult
    public func update(
        tokenID: String,
        manifestID: String,
        partKind: ProviderHandoffPartKindV1,
        expectedStagingRevision: UInt64,
        _ mutation: (inout ProviderHandoffPartStagingRecordV1) throws -> Void
    ) throws -> ProviderHandoffPartStagingRecordV1 {
        try withLock {
            var state = try loadOrEmptyUnlocked()
            guard
                let index = state.records.firstIndex(where: {
                    $0.tokenID == tokenID
                        && $0.manifestID == manifestID
                        && $0.partKind == partKind
                })
            else {
                throw ProviderHandoffPartStagingStoreError.notFound
            }
            let before = state.records[index]
            guard before.stagingRevision == expectedStagingRevision else {
                throw ProviderHandoffPartStagingStoreError.revisionMismatch(
                    expected: expectedStagingRevision,
                    actual: before.stagingRevision
                )
            }
            guard
                expectedStagingRevision < UInt64.max,
                state.storeRevision < UInt64.max
            else {
                throw ProviderHandoffPartStagingStoreError.revisionOverflow
            }
            try mutation(&state.records[index])
            let after = state.records[index]
            try ProviderHandoffPartStagingStateMachine.validateImmutableIdentity(
                after,
                matches: before
            )
            try ProviderHandoffPartStagingStateMachine.validate(after)
            if after == before {
                return after
            }
            guard
                after.stagingRevision == expectedStagingRevision + 1
            else {
                throw ProviderHandoffPartStagingStoreError.revisionMismatch(
                    expected: expectedStagingRevision + 1,
                    actual: after.stagingRevision
                )
            }
            state.storeRevision += 1
            try writeUnlocked(state)
            return after
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
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffPartStagingStoreError.ioFailure(
                .createLock,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        try validateFile(descriptor, maximumSize: 0)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ProviderHandoffPartStagingStoreError.ioFailure(.lock, errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func loadOrEmptyUnlocked() throws -> StoreState {
        do {
            return try loadUnlocked()
        } catch ProviderHandoffPartStagingStoreError.notFound {
            return StoreState(schemaVersion: 1, storeRevision: 0, records: [])
        }
    }

    private func loadUnlocked() throws -> StoreState {
        let descriptor = Darwin.open(
            stateURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw ProviderHandoffPartStagingStoreError.notFound
            }
            throw ProviderHandoffPartStagingStoreError.ioFailure(.openState, errno)
        }
        defer { Darwin.close(descriptor) }
        let status = try validateFile(
            descriptor,
            maximumSize: Self.maximumPayloadBytes * 2
        )
        let encoded = try readAll(descriptor, count: Int(status.st_size))
        let decoder = JSONDecoder()
        let envelope: StoreEnvelope
        do {
            envelope = try decoder.decode(StoreEnvelope.self, from: encoded)
        } catch {
            throw ProviderHandoffPartStagingStoreError.invalidEncoding
        }
        guard
            envelope.schemaVersion == 1,
            envelope.payload.count <= Self.maximumPayloadBytes,
            ProviderHandoffDigest.sha256(envelope.payload)
            == envelope.payloadDigestSHA256
        else {
            throw ProviderHandoffPartStagingStoreError.integrityMismatch
        }
        let state: StoreState
        do {
            state = try decoder.decode(StoreState.self, from: envelope.payload)
        } catch {
            throw ProviderHandoffPartStagingStoreError.invalidEncoding
        }
        try Self.validate(state)
        return state
    }

    private func writeUnlocked(_ state: StoreState) throws {
        try Self.validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(state)
        guard payload.count <= Self.maximumPayloadBytes else {
            throw ProviderHandoffPartStagingStoreError.stateTooLarge
        }
        let envelope = StoreEnvelope(
            schemaVersion: 1,
            payload: payload,
            payloadDigestSHA256: ProviderHandoffDigest.sha256(payload)
        )
        let encoded = try encoder.encode(envelope)
        let temporaryURL = root.appendingPathComponent(
            ".provider-handoff-part-staging.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffPartStagingStoreError.ioFailure(
                .createTemporary,
                errno
            )
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        _ = try validateFile(descriptor, maximumSize: 0)
        try writeAll(encoded, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProviderHandoffPartStagingStoreError.ioFailure(
                .synchronize,
                errno
            )
        }
        guard Darwin.rename(temporaryURL.path, stateURL.path) == 0 else {
            throw ProviderHandoffPartStagingStoreError.ioFailure(.publish, errno)
        }
        published = true
        let directory = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw ProviderHandoffPartStagingStoreError.ioFailure(
                .openDirectory,
                errno
            )
        }
        defer { Darwin.close(directory) }
        guard Darwin.fsync(directory) == 0 else {
            throw ProviderHandoffPartStagingStoreError.ioFailure(
                .synchronize,
                errno
            )
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
            throw ProviderHandoffPartStagingStoreError.ioFailure(
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
            throw ProviderHandoffPartStagingStoreError.invalidMetadata
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
            throw ProviderHandoffPartStagingStoreError.invalidMetadata
        }
        return status
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> Data {
        guard count >= 0 else {
            throw ProviderHandoffPartStagingStoreError.invalidMetadata
        }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let result = Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    count - offset
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw ProviderHandoffPartStagingStoreError.ioFailure(
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
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw ProviderHandoffPartStagingStoreError.ioFailure(
                        .write,
                        errno
                    )
                }
                offset += result
            }
        }
    }

    private static func validate(_ state: StoreState) throws {
        guard
            state.schemaVersion == 1,
            state.records == state.records.sorted(by: recordLess)
        else {
            throw ProviderHandoffPartStagingStoreError.invalidEncoding
        }
        for (index, record) in state.records.enumerated() {
            try ProviderHandoffPartStagingStateMachine.validate(record)
            guard
                !state.records[..<index].contains(where: {
                    sameIdentity($0, record)
                })
            else {
                throw ProviderHandoffPartStagingStoreError.duplicateRecord
            }
        }
    }

    private static func sameIdentity(
        _ lhs: ProviderHandoffPartStagingRecordV1,
        _ rhs: ProviderHandoffPartStagingRecordV1
    ) -> Bool {
        lhs.tokenID == rhs.tokenID
            && lhs.manifestID == rhs.manifestID
            && lhs.partKind == rhs.partKind
    }

    private static func recordLess(
        _ lhs: ProviderHandoffPartStagingRecordV1,
        _ rhs: ProviderHandoffPartStagingRecordV1
    ) -> Bool {
        if lhs.tokenID != rhs.tokenID {
            return lhs.tokenID.utf8.lexicographicallyPrecedes(rhs.tokenID.utf8)
        }
        if lhs.manifestID != rhs.manifestID {
            return lhs.manifestID.utf8.lexicographicallyPrecedes(rhs.manifestID.utf8)
        }
        return lhs.partKind.rawValue.utf8.lexicographicallyPrecedes(
            rhs.partKind.rawValue.utf8
        )
    }
}

private struct StoreState: Codable {
    var schemaVersion: UInt32
    var storeRevision: UInt64
    var records: [ProviderHandoffPartStagingRecordV1]
}

private struct StoreEnvelope: Codable {
    var schemaVersion: UInt32
    var payload: Data
    var payloadDigestSHA256: String
}
