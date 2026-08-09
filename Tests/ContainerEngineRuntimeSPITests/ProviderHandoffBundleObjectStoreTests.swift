//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ProviderHandoffBundleObjectStoreTests {
    @Test
    func `bundle object resumes chunks verifies streaming and replays exactly`() throws {
        try withStore { store, root in
            let bytes = Data(
                (0 ..< (5 * 1024 * 1024 + 17)).map {
                    UInt8(truncatingIfNeeded: $0)
                }
            )
            let digest = ProviderHandoffDigest.sha256(bytes)
            let objectID = "sha256:\(digest)"
            var record = try store.declare(
                bundleObjectID: objectID,
                transportByteLength: UInt64(bytes.count),
                transportDigestSHA256: digest
            )
            #expect(record.state == .receiving)
            #expect(record.receivedByteCount == 0)

            let first = bytes.prefix(ProviderHandoffBundleObjectStore.maximumChunkBytes)
            record = try store.append(
                bundleObjectID: objectID,
                offset: 0,
                bytes: Data(first),
                expectedObjectRevision: record.objectRevision
            )
            let firstRevision = record.objectRevision
            #expect(record.receivedByteCount == UInt64(first.count))
            #expect(
                try store.append(
                    bundleObjectID: objectID,
                    offset: 0,
                    bytes: Data(first),
                    expectedObjectRevision: firstRevision
                ) == record
            )

            var conflicting = Data(first)
            conflicting[0] ^= 0xFF
            #expect(throws: ProviderHandoffBundleObjectStoreError.conflictingChunk) {
                _ = try store.append(
                    bundleObjectID: objectID,
                    offset: 0,
                    bytes: conflicting,
                    expectedObjectRevision: firstRevision
                )
            }

            let remainder = Data(bytes.dropFirst(first.count))
            record = try store.append(
                bundleObjectID: objectID,
                offset: record.receivedByteCount,
                bytes: remainder,
                expectedObjectRevision: record.objectRevision
            )
            let recovered = ProviderHandoffBundleObjectStore(root: root)
            #expect(try recovered.load(bundleObjectID: objectID) == record)

            record = try recovered.verify(
                bundleObjectID: objectID,
                expectedObjectRevision: record.objectRevision
            )
            #expect(record.state == .verified)
            #expect(
                try recovered.verify(
                    bundleObjectID: objectID,
                    expectedObjectRevision: record.objectRevision
                ) == record
            )
            #expect(
                try recovered.readVerifiedChunk(
                    bundleObjectID: objectID,
                    offset: 0
                ) == Data(first)
            )
            #expect(
                try recovered.readVerifiedChunk(
                    bundleObjectID: objectID,
                    offset: UInt64(first.count)
                ) == remainder
            )

            let objectPath = root.appendingPathComponent(
                "bundle-object-\(digest).bin"
            ).path
            var metadata = stat()
            #expect(lstat(objectPath, &metadata) == 0)
            #expect(metadata.st_mode & mode_t(0o777) == mode_t(0o400))
        }
    }

    @Test
    func `bundle object rejects digest mismatch without publishing`() throws {
        try withStore { store, root in
            let bytes = Data("transport".utf8)
            let claimedDigest = ProviderHandoffDigest.sha256(
                Data("different".utf8)
            )
            let objectID = "sha256:\(claimedDigest)"
            var record = try store.declare(
                bundleObjectID: objectID,
                transportByteLength: UInt64(bytes.count),
                transportDigestSHA256: claimedDigest
            )
            record = try store.append(
                bundleObjectID: objectID,
                offset: 0,
                bytes: bytes,
                expectedObjectRevision: record.objectRevision
            )
            #expect(throws: ProviderHandoffBundleObjectStoreError.integrityMismatch) {
                _ = try store.verify(
                    bundleObjectID: objectID,
                    expectedObjectRevision: record.objectRevision
                )
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "bundle-object-\(claimedDigest).bin"
                    ).path
                )
            )
        }
    }

    @Test
    func `bundle object detects authenticated metadata mutation`() throws {
        try withStore { store, root in
            let bytes = Data("transport".utf8)
            let digest = ProviderHandoffDigest.sha256(bytes)
            let objectID = "sha256:\(digest)"
            _ = try store.declare(
                bundleObjectID: objectID,
                transportByteLength: UInt64(bytes.count),
                transportDigestSHA256: digest
            )
            let metadataURL = root.appendingPathComponent(
                "bundle-object-\(digest).meta"
            )
            var encoded = try Data(contentsOf: metadataURL)
            encoded[encoded.index(before: encoded.endIndex)] ^= 0xFF
            try encoded.write(to: metadataURL)
            #expect(chmod(metadataURL.path, mode_t(0o600)) == 0)

            #expect(throws: ProviderHandoffBundleObjectStoreError.integrityMismatch) {
                _ = try store.load(bundleObjectID: objectID)
            }
        }
    }

    private func withStore<T>(
        _ operation: (ProviderHandoffBundleObjectStore, URL) throws -> T
    ) throws -> T {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-handoff-bundle-object-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        let root = parent.appendingPathComponent("objects")
        return try operation(
            ProviderHandoffBundleObjectStore(root: root),
            root
        )
    }
}
