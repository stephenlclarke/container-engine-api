//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//===----------------------------------------------------------------------===//

import CryptoKit
import Darwin
import Foundation

public enum ProviderHandoffBundleObjectStateV1:
    String,
    Codable,
    Equatable,
    Sendable
{
    case receiving
    case verified
}

public struct ProviderHandoffBundleObjectRecordV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var bundleObjectID: String
    public var transportByteLength: UInt64
    public var transportDigestSHA256: String
    public var receivedByteCount: UInt64
    public var pendingChunkOffset: UInt64?
    public var pendingChunkByteLength: UInt64?
    public var pendingChunkDigestSHA256: String?
    public var objectRevision: UInt64
    public var state: ProviderHandoffBundleObjectStateV1

    public init(
        bundleObjectID: String,
        transportByteLength: UInt64,
        transportDigestSHA256: String,
        receivedByteCount: UInt64 = 0,
        pendingChunkOffset: UInt64? = nil,
        pendingChunkByteLength: UInt64? = nil,
        pendingChunkDigestSHA256: String? = nil,
        objectRevision: UInt64 = 1,
        state: ProviderHandoffBundleObjectStateV1 = .receiving
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bundleObjectID = bundleObjectID
        self.transportByteLength = transportByteLength
        self.transportDigestSHA256 = transportDigestSHA256
        self.receivedByteCount = receivedByteCount
        self.pendingChunkOffset = pendingChunkOffset
        self.pendingChunkByteLength = pendingChunkByteLength
        self.pendingChunkDigestSHA256 = pendingChunkDigestSHA256
        self.objectRevision = objectRevision
        self.state = state
    }
}

public enum ProviderHandoffBundleObjectStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public enum Operation: String, Equatable, Sendable {
        case createDirectory
        case createFile
        case lock
        case map
        case openDirectory
        case openFile
        case publish
        case read
        case remove
        case synchronize
        case write
    }

    case boundsExceeded
    case conflictingChunk
    case identityMismatch
    case integrityMismatch
    case invalidEncoding
    case invalidMetadata
    case invalidRecord
    case ioFailure(Operation, Int32)
    case notFound
    case revisionOverflow
    case revisionMismatch(expected: UInt64, actual: UInt64)
    case transportIncomplete

    public var description: String {
        switch self {
        case .boundsExceeded:
            "provider handoff bundle object exceeds a platform or chunk bound"
        case .conflictingChunk:
            "provider handoff bundle object chunk conflicts with durable bytes"
        case .identityMismatch:
            "provider handoff bundle object identity changed"
        case .integrityMismatch:
            "provider handoff bundle object integrity check failed"
        case .invalidEncoding:
            "provider handoff bundle object metadata encoding is invalid"
        case .invalidMetadata:
            "provider handoff bundle object filesystem metadata is unsafe"
        case .invalidRecord:
            "provider handoff bundle object record is invalid"
        case .ioFailure(let operation, let code):
            "provider handoff bundle object \(operation.rawValue) failed with errno \(code)"
        case .notFound:
            "provider handoff bundle object does not exist"
        case .revisionOverflow:
            "provider handoff bundle object revision cannot advance beyond UInt64.max"
        case .revisionMismatch(let expected, let actual):
            "provider handoff bundle object revision mismatch: expected \(expected), found \(actual)"
        case .transportIncomplete:
            "provider handoff bundle object transport is incomplete"
        }
    }
}

/// Durable content-addressed transport storage for provider-handoff packages.
///
/// Chunks are appended in order, but any fully durable prior chunk may be
/// replayed byte-for-byte. Each append synchronizes object bytes before its
/// authenticated receipt. Final verification streams SHA-256 from the file and
/// atomically publishes an immutable object, so package size is not bounded by
/// process memory or the provider-session control-frame limit.
public struct ProviderHandoffBundleObjectStore: Sendable {
    public static let maximumChunkBytes = 4 * 1024 * 1024

    private static let metadataMagic = Data("CHOBJM1".utf8)
    private static let metadataSchemaVersion: UInt32 = 1
    private static let maximumMetadataBytes = 64 * 1024
    private static let authenticationDomain = Data(
        "container.provider-handoff.bundle-object-metadata.v1\0".utf8
    )
    private static let keyByteCount = 32
    private static let lockFileName = ".bundle-object.lock"
    private static let keyFileName = ".bundle-object.key"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    @discardableResult
    public func declare(
        bundleObjectID: String,
        transportByteLength: UInt64,
        transportDigestSHA256: String
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        let proposed = ProviderHandoffBundleObjectRecordV1(
            bundleObjectID: bundleObjectID,
            transportByteLength: transportByteLength,
            transportDigestSHA256: transportDigestSHA256
        )
        try Self.validate(proposed)
        return try withStore { descriptor, key in
            if let existing = try loadIfPresent(
                proposed.bundleObjectID,
                rootDescriptor: descriptor,
                keyData: key
            ) {
                guard Self.sameIdentity(existing, proposed) else {
                    throw ProviderHandoffBundleObjectStoreError.identityMismatch
                }
                try validateBackingFile(existing, rootDescriptor: descriptor)
                return existing
            }
            let partial = Self.partialFileName(proposed.bundleObjectID)
            let objectDescriptor = try Self.openNewFile(
                rootDescriptor: descriptor,
                name: partial
            )
            guard Darwin.fsync(objectDescriptor) == 0 else {
                let code = errno
                Darwin.close(objectDescriptor)
                throw ProviderHandoffBundleObjectStoreError.ioFailure(
                    .synchronize,
                    code
                )
            }
            Darwin.close(objectDescriptor)
            do {
                try persist(
                    proposed,
                    rootDescriptor: descriptor,
                    keyData: key
                )
                try Self.synchronizeDirectory(descriptor)
                return proposed
            } catch {
                _ = Self.unlink(
                    rootDescriptor: descriptor,
                    name: partial
                )
                throw error
            }
        }
    }

    public func load(
        bundleObjectID: String
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        try withStore { descriptor, key in
            guard
                let record = try loadIfPresent(
                    bundleObjectID,
                    rootDescriptor: descriptor,
                    keyData: key
                )
            else {
                throw ProviderHandoffBundleObjectStoreError.notFound
            }
            try validateBackingFile(record, rootDescriptor: descriptor)
            return record
        }
    }

    @discardableResult
    public func append(
        bundleObjectID: String,
        offset: UInt64,
        bytes: Data,
        expectedObjectRevision: UInt64
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        guard !bytes.isEmpty, bytes.count <= Self.maximumChunkBytes else {
            throw ProviderHandoffBundleObjectStoreError.boundsExceeded
        }
        return try withStore { descriptor, key in
            guard
                var record = try loadIfPresent(
                    bundleObjectID,
                    rootDescriptor: descriptor,
                    keyData: key
                )
            else {
                throw ProviderHandoffBundleObjectStoreError.notFound
            }
            guard record.objectRevision == expectedObjectRevision else {
                throw ProviderHandoffBundleObjectStoreError.revisionMismatch(
                    expected: expectedObjectRevision,
                    actual: record.objectRevision
                )
            }
            guard record.state == .receiving else {
                throw ProviderHandoffBundleObjectStoreError.invalidRecord
            }
            let (upperBound, overflow) = offset.addingReportingOverflow(
                UInt64(bytes.count)
            )
            guard !overflow, upperBound <= record.transportByteLength else {
                throw ProviderHandoffBundleObjectStoreError.boundsExceeded
            }
            let objectDescriptor = try Self.openManagedFile(
                rootDescriptor: descriptor,
                name: Self.partialFileName(record.bundleObjectID),
                flags: O_RDWR,
                operation: .openFile
            )
            defer { Darwin.close(objectDescriptor) }
            if offset < record.receivedByteCount {
                guard upperBound <= record.receivedByteCount else {
                    throw ProviderHandoffBundleObjectStoreError.conflictingChunk
                }
                let existing = try Self.readExactly(
                    descriptor: objectDescriptor,
                    offset: offset,
                    count: bytes.count
                )
                guard existing == bytes else {
                    throw ProviderHandoffBundleObjectStoreError.conflictingChunk
                }
                return record
            }
            guard
                offset == record.receivedByteCount,
                record.objectRevision < UInt64.max
            else {
                if record.objectRevision == UInt64.max {
                    throw ProviderHandoffBundleObjectStoreError.revisionOverflow
                }
                throw ProviderHandoffBundleObjectStoreError.conflictingChunk
            }
            let chunkDigest = ProviderHandoffDigest.sha256(bytes)
            if let pendingOffset = record.pendingChunkOffset,
                let pendingLength = record.pendingChunkByteLength,
                let pendingDigest = record.pendingChunkDigestSHA256
            {
                guard
                    pendingOffset == offset,
                    pendingLength == UInt64(bytes.count),
                    pendingDigest == chunkDigest
                else {
                    throw ProviderHandoffBundleObjectStoreError.conflictingChunk
                }
            } else {
                guard
                    record.pendingChunkOffset == nil,
                    record.pendingChunkByteLength == nil,
                    record.pendingChunkDigestSHA256 == nil
                else {
                    throw ProviderHandoffBundleObjectStoreError.invalidRecord
                }
                record.pendingChunkOffset = offset
                record.pendingChunkByteLength = UInt64(bytes.count)
                record.pendingChunkDigestSHA256 = chunkDigest
                try persist(record, rootDescriptor: descriptor, keyData: key)
            }
            try Self.writeAll(
                bytes,
                descriptor: objectDescriptor,
                offset: offset
            )
            guard Darwin.fsync(objectDescriptor) == 0 else {
                throw ProviderHandoffBundleObjectStoreError.ioFailure(
                    .synchronize,
                    errno
                )
            }
            record.receivedByteCount = upperBound
            record.pendingChunkOffset = nil
            record.pendingChunkByteLength = nil
            record.pendingChunkDigestSHA256 = nil
            record.objectRevision += 1
            try persist(record, rootDescriptor: descriptor, keyData: key)
            return record
        }
    }

    @discardableResult
    public func verify(
        bundleObjectID: String,
        expectedObjectRevision: UInt64
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        try withStore { descriptor, key in
            guard
                var record = try loadIfPresent(
                    bundleObjectID,
                    rootDescriptor: descriptor,
                    keyData: key
                )
            else {
                throw ProviderHandoffBundleObjectStoreError.notFound
            }
            guard record.objectRevision == expectedObjectRevision else {
                throw ProviderHandoffBundleObjectStoreError.revisionMismatch(
                    expected: expectedObjectRevision,
                    actual: record.objectRevision
                )
            }
            if record.state == .verified {
                try verifyFile(record, rootDescriptor: descriptor)
                return record
            }
            guard
                record.receivedByteCount == record.transportByteLength,
                record.pendingChunkOffset == nil,
                record.pendingChunkByteLength == nil,
                record.pendingChunkDigestSHA256 == nil,
                record.objectRevision < UInt64.max
            else {
                if record.objectRevision == UInt64.max {
                    throw ProviderHandoffBundleObjectStoreError.revisionOverflow
                }
                throw ProviderHandoffBundleObjectStoreError.transportIncomplete
            }
            let partialName = Self.partialFileName(record.bundleObjectID)
            let verifiedName = Self.verifiedFileName(record.bundleObjectID)
            let sourceName: String
            if Self.exists(
                rootDescriptor: descriptor,
                name: verifiedName
            ) {
                sourceName = verifiedName
            } else {
                sourceName = partialName
            }
            try verifyFile(
                record,
                rootDescriptor: descriptor,
                fileName: sourceName
            )
            if sourceName == partialName {
                let completedDescriptor = try Self.openManagedFile(
                    rootDescriptor: descriptor,
                    name: partialName,
                    flags: O_RDONLY,
                    operation: .openFile
                )
                defer { Darwin.close(completedDescriptor) }
                guard
                    Darwin.fchmod(completedDescriptor, mode_t(0o400)) == 0,
                    Darwin.fsync(completedDescriptor) == 0
                else {
                    throw ProviderHandoffBundleObjectStoreError.ioFailure(
                        .synchronize,
                        errno
                    )
                }
                guard
                    partialName.withCString({ source in
                        verifiedName.withCString { destination in
                            Darwin.renameat(
                                descriptor,
                                source,
                                descriptor,
                                destination
                            )
                        }
                    }) == 0
                else {
                    throw ProviderHandoffBundleObjectStoreError.ioFailure(
                        .publish,
                        errno
                    )
                }
                try Self.synchronizeDirectory(descriptor)
            }
            record.state = .verified
            record.objectRevision += 1
            try persist(record, rootDescriptor: descriptor, keyData: key)
            return record
        }
    }

    public func readVerifiedChunk(
        bundleObjectID: String,
        offset: UInt64,
        maximumBytes: Int = Self.maximumChunkBytes
    ) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= Self.maximumChunkBytes else {
            throw ProviderHandoffBundleObjectStoreError.boundsExceeded
        }
        return try withStore { descriptor, key in
            guard
                let record = try loadIfPresent(
                    bundleObjectID,
                    rootDescriptor: descriptor,
                    keyData: key
                ), record.state == .verified
            else {
                throw ProviderHandoffBundleObjectStoreError.notFound
            }
            guard offset <= record.transportByteLength else {
                throw ProviderHandoffBundleObjectStoreError.boundsExceeded
            }
            let remaining = record.transportByteLength - offset
            let count = min(UInt64(maximumBytes), remaining)
            guard let exactCount = Int(exactly: count) else {
                throw ProviderHandoffBundleObjectStoreError.boundsExceeded
            }
            let objectDescriptor = try Self.openManagedFile(
                rootDescriptor: descriptor,
                name: Self.verifiedFileName(record.bundleObjectID),
                flags: O_RDONLY,
                operation: .openFile
            )
            defer { Darwin.close(objectDescriptor) }
            return try Self.readExactly(
                descriptor: objectDescriptor,
                offset: offset,
                count: exactCount
            )
        }
    }

    /// Memory-maps one immutable verified object for destination-local
    /// authenticated decoding without copying it through provider-control
    /// frames or repeatedly growing an in-memory accumulator.
    public func readVerifiedObject(
        bundleObjectID: String
    ) throws -> Data {
        try withStore { descriptor, key in
            guard
                let record = try loadIfPresent(
                    bundleObjectID,
                    rootDescriptor: descriptor,
                    keyData: key
                ), record.state == .verified,
                let count = Int(exactly: record.transportByteLength),
                count > 0
            else {
                throw ProviderHandoffBundleObjectStoreError.notFound
            }
            try validateBackingFile(record, rootDescriptor: descriptor)
            let objectDescriptor = try Self.openManagedFile(
                rootDescriptor: descriptor,
                name: Self.verifiedFileName(record.bundleObjectID),
                flags: O_RDONLY,
                operation: .openFile
            )
            defer { Darwin.close(objectDescriptor) }
            let mapped = mmap(
                nil,
                count,
                PROT_READ,
                MAP_PRIVATE,
                objectDescriptor,
                0
            )
            guard mapped != MAP_FAILED, let mapped else {
                throw ProviderHandoffBundleObjectStoreError.ioFailure(
                    .map,
                    errno
                )
            }
            return Data(
                bytesNoCopy: mapped,
                count: count,
                deallocator: .custom { pointer, byteCount in
                    _ = munmap(pointer, byteCount)
                }
            )
        }
    }

    private func withStore<T>(
        _ operation: (Int32, Data) throws -> T
    ) throws -> T {
        let descriptor = try Self.openRoot(root)
        defer { Darwin.close(descriptor) }
        let lockDescriptor = try Self.openManagedFile(
            rootDescriptor: descriptor,
            name: Self.lockFileName,
            flags: O_RDWR | O_CREAT,
            mode: mode_t(0o600),
            operation: .createFile
        )
        defer { Darwin.close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw ProviderHandoffBundleObjectStoreError.ioFailure(.lock, errno)
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        let key = try Self.loadOrCreateKey(rootDescriptor: descriptor)
        return try operation(descriptor, key)
    }

    private func loadIfPresent(
        _ bundleObjectID: String,
        rootDescriptor: Int32,
        keyData: Data
    ) throws -> ProviderHandoffBundleObjectRecordV1? {
        _ = try Self.digestFromObjectID(bundleObjectID)
        let data: Data
        do {
            data = try Self.readFile(
                rootDescriptor: rootDescriptor,
                name: Self.metadataFileName(bundleObjectID),
                maximumBytes: Self.maximumMetadataBytes
            )
        } catch ProviderHandoffBundleObjectStoreError.ioFailure(
            .openFile,
            ENOENT
        ) {
            return nil
        }
        return try Self.decodeMetadata(data, keyData: keyData)
    }

    private func persist(
        _ record: ProviderHandoffBundleObjectRecordV1,
        rootDescriptor: Int32,
        keyData: Data
    ) throws {
        try Self.validate(record)
        let encoded = try Self.encodeMetadata(record, keyData: keyData)
        try Self.publishReplacing(
            encoded,
            target: Self.metadataFileName(record.bundleObjectID),
            rootDescriptor: rootDescriptor
        )
    }

    private func validateBackingFile(
        _ record: ProviderHandoffBundleObjectRecordV1,
        rootDescriptor: Int32
    ) throws {
        let name =
            record.state == .verified
            ? Self.verifiedFileName(record.bundleObjectID)
            : Self.partialFileName(record.bundleObjectID)
        let descriptor = try Self.openManagedFile(
            rootDescriptor: rootDescriptor,
            name: name,
            flags: O_RDONLY,
            operation: .openFile
        )
        defer { Darwin.close(descriptor) }
        let metadata = try Self.validateRegularFile(descriptor)
        let expected =
            record.state == .verified
            ? record.transportByteLength
            : record.receivedByteCount
        guard metadata.st_size >= 0 else {
            throw ProviderHandoffBundleObjectStoreError.integrityMismatch
        }
        let actual = UInt64(metadata.st_size)
        if record.state == .verified {
            guard actual == expected else {
                throw ProviderHandoffBundleObjectStoreError.integrityMismatch
            }
        } else if let pendingLength = record.pendingChunkByteLength {
            let (pendingUpperBound, overflow) = expected.addingReportingOverflow(
                pendingLength
            )
            guard
                !overflow,
                actual >= expected,
                actual <= pendingUpperBound
            else {
                throw ProviderHandoffBundleObjectStoreError.integrityMismatch
            }
        } else {
            guard actual == expected else {
                throw ProviderHandoffBundleObjectStoreError.integrityMismatch
            }
        }
    }

    private func verifyFile(
        _ record: ProviderHandoffBundleObjectRecordV1,
        rootDescriptor: Int32,
        fileName: String? = nil
    ) throws {
        let name = fileName ?? Self.verifiedFileName(record.bundleObjectID)
        let descriptor = try Self.openManagedFile(
            rootDescriptor: rootDescriptor,
            name: name,
            flags: O_RDONLY,
            operation: .openFile
        )
        defer { Darwin.close(descriptor) }
        let metadata = try Self.validateRegularFile(descriptor)
        guard
            metadata.st_size >= 0,
            UInt64(metadata.st_size) == record.transportByteLength
        else {
            throw ProviderHandoffBundleObjectStoreError.integrityMismatch
        }
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < record.transportByteLength {
            let count = Int(min(UInt64(1024 * 1024), record.transportByteLength - offset))
            let bytes = try Self.readExactly(
                descriptor: descriptor,
                offset: offset,
                count: count
            )
            hasher.update(data: bytes)
            offset += UInt64(bytes.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == record.transportDigestSHA256 else {
            throw ProviderHandoffBundleObjectStoreError.integrityMismatch
        }
    }

    private static func validate(
        _ record: ProviderHandoffBundleObjectRecordV1
    ) throws {
        let digest = try digestFromObjectID(record.bundleObjectID)
        let pendingFields = [
            record.pendingChunkOffset != nil,
            record.pendingChunkByteLength != nil,
            record.pendingChunkDigestSHA256 != nil,
        ]
        let pendingCount = pendingFields.filter { $0 }.count
        if let pendingDigest = record.pendingChunkDigestSHA256 {
            _ = try ProviderHandoffDigest.parseSHA256(pendingDigest)
        }
        guard
            record.schemaVersion
                == ProviderHandoffBundleObjectRecordV1
                .currentSchemaVersion,
            record.transportByteLength > 0,
            record.transportByteLength <= UInt64(Int64.max),
            record.transportDigestSHA256 == digest,
            record.receivedByteCount <= record.transportByteLength,
            record.objectRevision > 0,
            pendingCount == 0 || pendingCount == 3,
            record.state == .receiving || pendingCount == 0,
            record.state == .receiving
                || record.receivedByteCount == record.transportByteLength
        else {
            throw ProviderHandoffBundleObjectStoreError.invalidRecord
        }
        if let pendingOffset = record.pendingChunkOffset,
            let pendingLength = record.pendingChunkByteLength
        {
            let (upperBound, overflow) = pendingOffset.addingReportingOverflow(
                pendingLength
            )
            guard
                !overflow,
                pendingOffset == record.receivedByteCount,
                pendingLength > 0,
                pendingLength <= UInt64(maximumChunkBytes),
                upperBound <= record.transportByteLength
            else {
                throw ProviderHandoffBundleObjectStoreError.invalidRecord
            }
        }
    }

    private static func sameIdentity(
        _ lhs: ProviderHandoffBundleObjectRecordV1,
        _ rhs: ProviderHandoffBundleObjectRecordV1
    ) -> Bool {
        lhs.bundleObjectID == rhs.bundleObjectID
            && lhs.transportByteLength == rhs.transportByteLength
            && lhs.transportDigestSHA256 == rhs.transportDigestSHA256
    }

    private static func digestFromObjectID(_ value: String) throws -> String {
        guard value.hasPrefix("sha256:") else {
            throw ProviderHandoffBundleObjectStoreError.invalidRecord
        }
        let digest = String(value.dropFirst("sha256:".count))
        _ = try ProviderHandoffDigest.parseSHA256(digest)
        return digest
    }

    private static func metadataFileName(_ objectID: String) -> String {
        "bundle-object-\(objectID.dropFirst("sha256:".count)).meta"
    }

    private static func partialFileName(_ objectID: String) -> String {
        "bundle-object-\(objectID.dropFirst("sha256:".count)).partial"
    }

    private static func verifiedFileName(_ objectID: String) -> String {
        "bundle-object-\(objectID.dropFirst("sha256:".count)).bin"
    }

    private static func encodeMetadata(
        _ record: ProviderHandoffBundleObjectRecordV1,
        keyData: Data
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(record)
        guard payload.count <= maximumMetadataBytes / 2 else {
            throw ProviderHandoffBundleObjectStoreError.boundsExceeded
        }
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: authenticatedMetadata(payload),
            using: SymmetricKey(data: keyData)
        )
        var result = Data()
        result.append(metadataMagic)
        appendBigEndian(metadataSchemaVersion, to: &result)
        appendBigEndian(UInt64(payload.count), to: &result)
        result.append(payload)
        result.append(contentsOf: authenticationCode)
        return result
    }

    private static func decodeMetadata(
        _ data: Data,
        keyData: Data
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        var reader = BundleObjectDataReader(data: data)
        guard
            try reader.read(count: metadataMagic.count) == metadataMagic,
            try reader.readUInt32() == metadataSchemaVersion,
            let length = Int(exactly: try reader.readUInt64()),
            length <= maximumMetadataBytes / 2
        else {
            throw ProviderHandoffBundleObjectStoreError.invalidEncoding
        }
        let payload = try reader.read(count: length)
        let authenticationCode = try reader.read(count: SHA256.byteCount)
        guard
            reader.isAtEnd,
            HMAC<SHA256>.isValidAuthenticationCode(
                authenticationCode,
                authenticating: authenticatedMetadata(payload),
                using: SymmetricKey(data: keyData)
            )
        else {
            throw ProviderHandoffBundleObjectStoreError.integrityMismatch
        }
        let record: ProviderHandoffBundleObjectRecordV1
        do {
            record = try JSONDecoder().decode(
                ProviderHandoffBundleObjectRecordV1.self,
                from: payload
            )
        } catch {
            throw ProviderHandoffBundleObjectStoreError.invalidEncoding
        }
        try validate(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(record) == payload else {
            throw ProviderHandoffBundleObjectStoreError.invalidEncoding
        }
        return record
    }

    private static func authenticatedMetadata(_ payload: Data) -> Data {
        var result = Data()
        result.append(authenticationDomain)
        appendBigEndian(UInt64(payload.count), to: &result)
        result.append(payload)
        return result
    }

    private static func openRoot(_ root: URL) throws -> Int32 {
        guard
            root.isFileURL,
            root.path.hasPrefix("/"),
            !root.path.utf8.contains(0)
        else {
            throw ProviderHandoffBundleObjectStoreError.invalidMetadata
        }
        if root.path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) != 0,
            errno != EEXIST
        {
            throw ProviderHandoffBundleObjectStoreError.ioFailure(
                .createDirectory,
                errno
            )
        }
        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ProviderHandoffBundleObjectStoreError.ioFailure(
                .openDirectory,
                errno
            )
        }
        do {
            var metadata = stat()
            guard
                Darwin.fstat(descriptor, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFDIR,
                metadata.st_uid == Darwin.geteuid(),
                metadata.st_mode & mode_t(0o077) == 0
            else {
                throw ProviderHandoffBundleObjectStoreError.invalidMetadata
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func loadOrCreateKey(
        rootDescriptor: Int32
    ) throws -> Data {
        do {
            let value = try readFile(
                rootDescriptor: rootDescriptor,
                name: keyFileName,
                maximumBytes: keyByteCount
            )
            guard value.count == keyByteCount else {
                throw ProviderHandoffBundleObjectStoreError.integrityMismatch
            }
            return value
        } catch ProviderHandoffBundleObjectStoreError.ioFailure(
            .openFile,
            ENOENT
        ) {
            let value = Data((0..<keyByteCount).map { _ in UInt8.random(in: .min ... .max) })
            do {
                let descriptor = try openNewFile(
                    rootDescriptor: rootDescriptor,
                    name: keyFileName
                )
                defer { Darwin.close(descriptor) }
                try writeAll(value, descriptor: descriptor, offset: 0)
                guard Darwin.fsync(descriptor) == 0 else {
                    throw ProviderHandoffBundleObjectStoreError.ioFailure(
                        .synchronize,
                        errno
                    )
                }
                try synchronizeDirectory(rootDescriptor)
                return value
            } catch ProviderHandoffBundleObjectStoreError.ioFailure(
                .createFile,
                EEXIST
            ) {
                return try readFile(
                    rootDescriptor: rootDescriptor,
                    name: keyFileName,
                    maximumBytes: keyByteCount
                )
            }
        }
    }

    private static func openNewFile(
        rootDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        try openManagedFile(
            rootDescriptor: rootDescriptor,
            name: name,
            flags: O_RDWR | O_CREAT | O_EXCL,
            mode: mode_t(0o600),
            operation: .createFile
        )
    }

    private static func openManagedFile(
        rootDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: mode_t = 0,
        operation: ProviderHandoffBundleObjectStoreError.Operation
    ) throws -> Int32 {
        guard
            !name.isEmpty,
            !name.utf8.contains(0),
            !name.contains("/")
        else {
            throw ProviderHandoffBundleObjectStoreError.invalidMetadata
        }
        let descriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                flags | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
        }
        guard descriptor >= 0 else {
            throw ProviderHandoffBundleObjectStoreError.ioFailure(
                operation,
                errno
            )
        }
        do {
            _ = try validateRegularFile(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateRegularFile(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_mode & mode_t(0o077) == 0,
            metadata.st_nlink == 1
        else {
            throw ProviderHandoffBundleObjectStoreError.invalidMetadata
        }
        return metadata
    }

    private static func readFile(
        rootDescriptor: Int32,
        name: String,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = try openManagedFile(
            rootDescriptor: rootDescriptor,
            name: name,
            flags: O_RDONLY,
            operation: .openFile
        )
        defer { Darwin.close(descriptor) }
        let metadata = try validateRegularFile(descriptor)
        guard
            metadata.st_size >= 0,
            metadata.st_size <= off_t(maximumBytes)
        else {
            throw ProviderHandoffBundleObjectStoreError.boundsExceeded
        }
        return try readExactly(
            descriptor: descriptor,
            offset: 0,
            count: Int(metadata.st_size)
        )
    }

    private static func readExactly(
        descriptor: Int32,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard let fileOffset = off_t(exactly: offset) else {
            throw ProviderHandoffBundleObjectStoreError.boundsExceeded
        }
        var result = Data(count: count)
        var consumed = 0
        while consumed < count {
            let readCount = result.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: consumed),
                    count - consumed,
                    fileOffset + off_t(consumed)
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw ProviderHandoffBundleObjectStoreError.ioFailure(
                    .read,
                    readCount == 0 ? EIO : errno
                )
            }
            consumed += readCount
        }
        return result
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        offset: UInt64
    ) throws {
        guard let fileOffset = off_t(exactly: offset) else {
            throw ProviderHandoffBundleObjectStoreError.boundsExceeded
        }
        var written = 0
        try data.withUnsafeBytes { buffer in
            while written < data.count {
                let count = Darwin.pwrite(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    data.count - written,
                    fileOffset + off_t(written)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ProviderHandoffBundleObjectStoreError.ioFailure(
                        .write,
                        errno
                    )
                }
                written += count
            }
        }
    }

    private static func publishReplacing(
        _ data: Data,
        target: String,
        rootDescriptor: Int32
    ) throws {
        let temporary = ".\(target).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = try openNewFile(
            rootDescriptor: rootDescriptor,
            name: temporary
        )
        defer { Darwin.close(descriptor) }
        do {
            try writeAll(data, descriptor: descriptor, offset: 0)
            guard Darwin.fsync(descriptor) == 0 else {
                throw ProviderHandoffBundleObjectStoreError.ioFailure(
                    .synchronize,
                    errno
                )
            }
            guard
                temporary.withCString({ source in
                    target.withCString { destination in
                        Darwin.renameat(
                            rootDescriptor,
                            source,
                            rootDescriptor,
                            destination
                        )
                    }
                }) == 0
            else {
                throw ProviderHandoffBundleObjectStoreError.ioFailure(
                    .publish,
                    errno
                )
            }
            try synchronizeDirectory(rootDescriptor)
        } catch {
            _ = unlink(rootDescriptor: rootDescriptor, name: temporary)
            throw error
        }
    }

    private static func exists(
        rootDescriptor: Int32,
        name: String
    ) -> Bool {
        name.withCString {
            Darwin.faccessat(rootDescriptor, $0, F_OK, AT_SYMLINK_NOFOLLOW) == 0
        }
    }

    @discardableResult
    private static func unlink(
        rootDescriptor: Int32,
        name: String
    ) -> Bool {
        name.withCString { Darwin.unlinkat(rootDescriptor, $0, 0) == 0 }
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProviderHandoffBundleObjectStoreError.ioFailure(
                .synchronize,
                errno
            )
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

private struct BundleObjectDataReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw ProviderHandoffBundleObjectStoreError.invalidEncoding
        }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func readUInt32() throws -> UInt32 {
        try readInteger(UInt32.self)
    }

    mutating func readUInt64() throws -> UInt64 {
        try readInteger(UInt64.self)
    }

    private mutating func readInteger<T: FixedWidthInteger>(
        _ type: T.Type
    ) throws -> T {
        let bytes = try read(count: MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
