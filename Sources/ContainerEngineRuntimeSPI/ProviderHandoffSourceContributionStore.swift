//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Darwin
import Foundation

public enum ProviderHandoffSourceContributionStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public enum Operation: String, Equatable, Sendable {
        case createDirectory
        case createTemporary
        case openDirectory
        case openRecord
        case publish
        case read
        case synchronize
        case write
    }

    case conflict
    case invalidMetadata
    case ioFailure(Operation, Int32)
    case notFound

    public var description: String {
        switch self {
        case .conflict:
            "provider handoff source contribution conflicts with its durable identity"
        case .invalidMetadata:
            "provider handoff source contribution storage metadata is unsafe"
        case let .ioFailure(operation, code):
            "provider handoff source contribution store \(operation.rawValue) failed with errno \(code)"
        case .notFound:
            "provider handoff source contribution does not exist"
        }
    }
}

/// Immutable crash-replay storage for source-export receipts.
///
/// One exclusively published file owns each token/manifest/part identity. A
/// replay returns only the byte-identical, codec-validated contribution; a
/// changed payload, destination envelope, or source expectation conflicts.
public struct ProviderHandoffSourceContributionStore: Sendable {
    private static let recordPrefix = "provider-handoff-source-contribution-"
    private static let recordSuffix = ".json"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    @discardableResult
    public func store(
        _ contribution: ProviderHandoffSourceContributionV1
    ) throws -> ProviderHandoffSourceContributionV1 {
        let encoded = try ProviderHandoffSourceControlCodec
            .encodeContribution(contribution)
        try prepareRoot()
        let finalURL = recordURL(
            tokenID: contribution.tokenID,
            manifestID: contribution.manifestID,
            partKind: contribution.partKind
        )
        if let existing = try loadIfPresent(
            tokenID: contribution.tokenID,
            manifestID: contribution.manifestID,
            partKind: contribution.partKind
        ) {
            guard existing == contribution else {
                throw ProviderHandoffSourceContributionStoreError.conflict
            }
            return existing
        }

        let temporaryURL = root.appendingPathComponent(
            ".source-contribution.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffSourceContributionStoreError.ioFailure(
                .createTemporary,
                errno
            )
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }
        _ = try validateFile(descriptor, maximumSize: 0)
        try writeAll(encoded, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProviderHandoffSourceContributionStoreError.ioFailure(
                .synchronize,
                errno
            )
        }
        let result = Darwin.renamex_np(
            temporaryURL.path,
            finalURL.path,
            UInt32(RENAME_EXCL)
        )
        if result != 0 {
            let code = errno
            guard code == EEXIST else {
                throw ProviderHandoffSourceContributionStoreError.ioFailure(
                    .publish,
                    code
                )
            }
            let existing = try load(
                tokenID: contribution.tokenID,
                manifestID: contribution.manifestID,
                partKind: contribution.partKind
            )
            guard existing == contribution else {
                throw ProviderHandoffSourceContributionStoreError.conflict
            }
            return existing
        }
        published = true
        try synchronizeRoot()
        return contribution
    }

    public func load(
        tokenID: String,
        manifestID: String,
        partKind: ProviderHandoffPartKindV1
    ) throws -> ProviderHandoffSourceContributionV1 {
        try prepareRoot()
        guard
            let value = try loadIfPresent(
                tokenID: tokenID,
                manifestID: manifestID,
                partKind: partKind
            )
        else {
            throw ProviderHandoffSourceContributionStoreError.notFound
        }
        return value
    }

    private func loadIfPresent(
        tokenID: String,
        manifestID: String,
        partKind: ProviderHandoffPartKindV1
    ) throws -> ProviderHandoffSourceContributionV1? {
        let url = recordURL(
            tokenID: tokenID,
            manifestID: manifestID,
            partKind: partKind
        )
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw ProviderHandoffSourceContributionStoreError.ioFailure(
                .openRecord,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        let status = try validateFile(
            descriptor,
            maximumSize:
            ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        )
        let bytes = try readAll(descriptor, count: Int(status.st_size))
        let value = try ProviderHandoffSourceControlCodec
            .decodeContribution(bytes)
        guard
            value.tokenID == tokenID,
            value.manifestID == manifestID,
            value.partKind == partKind
        else {
            throw ProviderHandoffSourceContributionStoreError.conflict
        }
        return value
    }

    private func recordURL(
        tokenID: String,
        manifestID: String,
        partKind: ProviderHandoffPartKindV1
    ) -> URL {
        let digest = ProviderHandoffDigest.sha256(
            Data("\(tokenID)\u{0}\(manifestID)\u{0}\(partKind.rawValue)".utf8)
        )
        return root.appendingPathComponent(
            "\(Self.recordPrefix)\(digest)\(Self.recordSuffix)",
            isDirectory: false
        )
    }

    private func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProviderHandoffSourceContributionStoreError.ioFailure(
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
            throw ProviderHandoffSourceContributionStoreError.invalidMetadata
        }
    }

    private func synchronizeRoot() throws {
        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ProviderHandoffSourceContributionStoreError.ioFailure(
                .openDirectory,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProviderHandoffSourceContributionStoreError.ioFailure(
                .synchronize,
                errno
            )
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
            throw ProviderHandoffSourceContributionStoreError.invalidMetadata
        }
        return status
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> Data {
        guard count >= 0 else {
            throw ProviderHandoffSourceContributionStoreError.invalidMetadata
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
                    throw ProviderHandoffSourceContributionStoreError
                        .ioFailure(.read, errno)
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
                    throw ProviderHandoffSourceContributionStoreError
                        .ioFailure(.write, errno)
                }
                offset += result
            }
        }
    }
}
