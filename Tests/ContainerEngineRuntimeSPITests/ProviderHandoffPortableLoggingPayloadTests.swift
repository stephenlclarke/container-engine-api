//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@_spi(Testing) import ContainerEngineRuntimeSPI
import Foundation
import Testing

struct ProviderHandoffPortableLoggingPayloadTests {
    private let sourceRoot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    @Test
    func `portable json file history uses the Container handoff schema`() throws {
        let container = ProviderHandoffPortableLoggingContainerV1(
            containerID: "container-1",
            providerID: "devcontainer.apple-container",
            providerVersion: "1.2.3",
            records: [
                ProviderHandoffPortableLogRecordV1(
                    secondsSinceUnixEpoch: 0,
                    nanoseconds: 123_000_000,
                    stream: .stdout,
                    data: Data("hello\n".utf8)
                )
            ]
        )

        let package = try ProviderHandoffPortableLoggingPayloadCodec.package(
            containers: [container],
            sourceStateRootUUID: sourceRoot
        )

        #expect(package.partKind == .logging)
        #expect(package.entries.count == 2)
        #expect(
            package.entries.map(\.recordKind) == [
                "logging-container-v1", "logging-history-store-v1"
            ]
        )
        let historyEntry = try #require(package.entries.last)
        let history = try map(
            ProviderHandoffCanonicalCBOR.decode(
                historyEntry.canonicalRecordBytes
            )
        )
        #expect(try text(history["kind"]) == "dockerJSONFile")
        #expect(try text(history["disposition"]) == "importVerified")
        #expect(
            try bytes(history["bytes"])
                == Data(
                    #"{"log":"hello\n","stream":"stdout","time":"1970-01-01T00:00:00.123Z"}"#.utf8
                ) + Data([0x0A])
        )
        #expect(
            try ProviderHandoffPayloadCodec.decode(
                ProviderHandoffPayloadCodec.encode(
                    package,
                    sourceOrder: [sourceRoot]
                ),
                expectedPartKind: .logging,
                sourceOrder: [sourceRoot]
            ) == package
        )
    }

    @Test
    func `portable history chunks hostile expansion below record limit`() throws {
        let expanded = Data(repeating: 0, count: 200 * 1024)
        let package = try ProviderHandoffPortableLoggingPayloadCodec.package(
            containers: [
                ProviderHandoffPortableLoggingContainerV1(
                    containerID: "container-1",
                    providerID: "devcontainer.apple-container",
                    providerVersion: "1",
                    records: [
                        ProviderHandoffPortableLogRecordV1(
                            secondsSinceUnixEpoch: 1,
                            nanoseconds: 0,
                            stream: .stderr,
                            data: expanded
                        )
                    ]
                )
            ],
            sourceStateRootUUID: sourceRoot
        )
        let history = try map(
            ProviderHandoffCanonicalCBOR.decode(
                #require(package.entries.last).canonicalRecordBytes
            )
        )
        let encoded = try bytes(history["bytes"])
        #expect(encoded.filter { $0 == 0x0A }.count == 2)
        #expect(encoded.count < 2 * 1024 * 1024)
    }

    @Test
    func `portable history above legacy bound uses canonical ordered stores`() throws {
        let package = try ProviderHandoffPortableLoggingPayloadCodec.package(
            containers: [
                ProviderHandoffPortableLoggingContainerV1(
                    containerID: "container-1",
                    providerID: "devcontainer.apple-container",
                    providerVersion: "1",
                    terminalHistoryEpoch: 7,
                    records: [
                        ProviderHandoffPortableLogRecordV1(
                            secondsSinceUnixEpoch: 1,
                            nanoseconds: 0,
                            stream: .stdout,
                            data: Data(
                                repeating: UInt8(ascii: "a"),
                                count:
                                ProviderHandoffPortableLoggingPayloadCodec
                                    .maximumHistoryBytes + 1
                            )
                        )
                    ]
                )
            ],
            sourceStateRootUUID: sourceRoot
        )
        let histories = package.entries.filter {
            $0.recordKind == "logging-history-store-v1"
        }
        #expect(histories.count > 1)
        var byteCount = 0
        for (index, entry) in histories.enumerated() {
            let history = try map(
                ProviderHandoffCanonicalCBOR.decode(
                    entry.canonicalRecordBytes
                )
            )
            let bytes = try bytes(history["bytes"])
            byteCount += bytes.count
            #expect(
                bytes.count
                    <= ProviderHandoffPortableLoggingPayloadCodec
                    .maximumHistoryChunkBytes
            )
            #expect(
                try ProviderHandoffPortableLoggingPayloadCodec
                    .parseHistoryChunkStoreID(text(history["storeID"]))
                    == ProviderHandoffPortableLoggingHistoryChunkV1(
                        index: UInt64(index),
                        count: UInt64(histories.count)
                    )
            )
        }
        #expect(
            byteCount
                > ProviderHandoffPortableLoggingPayloadCodec.maximumHistoryBytes
        )
        #expect(
            try ProviderHandoffPayloadCodec.decode(
                ProviderHandoffPayloadCodec.encode(
                    package,
                    sourceOrder: [sourceRoot]
                ),
                expectedPartKind: .logging,
                sourceOrder: [sourceRoot]
            ) == package
        )
    }

    @Test
    func `portable history crosses former store count ceiling`() throws {
        let formerMaximum = 4096
        let package = try ProviderHandoffPortableLoggingPayloadCodec.package(
            containers: [
                ProviderHandoffPortableLoggingContainerV1(
                    containerID: "container-1",
                    providerID: "devcontainer.apple-container",
                    providerVersion: "1",
                    records: (0 ... formerMaximum).map { index in
                        ProviderHandoffPortableLogRecordV1(
                            secondsSinceUnixEpoch: Int64(index),
                            nanoseconds: 0,
                            stream: .stdout,
                            data: Data("x\n".utf8)
                        )
                    }
                )
            ],
            sourceStateRootUUID: sourceRoot,
            maximumHistoryStoreBytes: 96
        )
        let histories = package.entries.filter {
            $0.recordKind == "logging-history-store-v1"
        }
        #expect(histories.count == formerMaximum + 1)
        let last = try map(
            ProviderHandoffCanonicalCBOR.decode(
                #require(histories.last).canonicalRecordBytes
            )
        )
        #expect(
            try ProviderHandoffPortableLoggingPayloadCodec
                .parseHistoryChunkStoreID(text(last["storeID"]))
                == ProviderHandoffPortableLoggingHistoryChunkV1(
                    index: UInt64(formerMaximum),
                    count: UInt64(formerMaximum + 1)
                )
        )
        #expect(
            try ProviderHandoffPayloadCodec.decode(
                ProviderHandoffPayloadCodec.encode(
                    package,
                    sourceOrder: [sourceRoot]
                ),
                expectedPartKind: .logging,
                sourceOrder: [sourceRoot]
            ) == package
        )
    }

    @Test
    func `portable logging rejects duplicate containers`() {
        let container = ProviderHandoffPortableLoggingContainerV1(
            containerID: "same",
            providerID: "provider",
            providerVersion: "1",
            records: []
        )
        #expect(
            throws:
            ProviderHandoffPortableLoggingPayloadError
                .duplicateContainer("same")
        ) {
            try ProviderHandoffPortableLoggingPayloadCodec.package(
                containers: [container, container],
                sourceStateRootUUID: sourceRoot
            )
        }
    }

    @Test
    func `streamed portable records produce the exact canonical package`() async throws {
        let records = (0 ..< 8).map { index in
            ProviderHandoffPortableLogRecordV1(
                secondsSinceUnixEpoch: Int64(index),
                nanoseconds: UInt32(index),
                stream: index.isMultiple(of: 2) ? .stdout : .stderr,
                data: Data("record-\(index)\n".utf8)
            )
        }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "portable-logging-source-test-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let stream = AsyncThrowingStream<
            ProviderHandoffPortableLogRecordV1,
            any Error
        > { continuation in
            for record in records {
                continuation.yield(record)
            }
            continuation.finish()
        }
        let source = try await ProviderHandoffPortableLoggingPayloadCodec
            .packageSource(
                containers: [
                    ProviderHandoffPortableLoggingContainerSourceV2(
                        containerID: "container-1",
                        providerID: "devcontainer.apple-container",
                        providerVersion: "1",
                        terminalHistoryEpoch: 9,
                        records: stream
                    )
                ],
                sourceStateRootUUID: sourceRoot,
                temporaryDirectoryURL: temporaryRoot,
                maximumHistoryStoreBytes: 192
            )
        #expect(
            source.entries.filter {
                if case .file = $0.canonicalRecord {
                    return true
                }
                return false
            }.count > 1
        )
        let materialized = try ProviderHandoffPayloadPackageV1(
            partKind: source.partKind,
            entries: source.entries.map { entry in
                let recordBytes: Data
                switch entry.canonicalRecord {
                case let .data(data):
                    recordBytes = data
                case let .file(url, byteLength):
                    recordBytes = try Data(contentsOf: url)
                    #expect(UInt64(recordBytes.count) == byteLength)
                }
                return ProviderHandoffPayloadPackageEntryV1(
                    entryID: entry.entryID,
                    sourceStateRootUUID: entry.sourceStateRootUUID,
                    recordKind: entry.recordKind,
                    schemaVersion: entry.schemaVersion,
                    canonicalRecordBytes: recordBytes
                )
            }
        )
        let expected = try ProviderHandoffPortableLoggingPayloadCodec.package(
            containers: [
                ProviderHandoffPortableLoggingContainerV1(
                    containerID: "container-1",
                    providerID: "devcontainer.apple-container",
                    providerVersion: "1",
                    terminalHistoryEpoch: 9,
                    records: records
                )
            ],
            sourceStateRootUUID: sourceRoot,
            maximumHistoryStoreBytes: 192
        )
        #expect(materialized == expected)
    }

    private func map(
        _ value: ProviderHandoffCanonicalValue
    ) throws -> [String: ProviderHandoffCanonicalValue] {
        guard case let .map(entries) = value else {
            throw
                ProviderHandoffPortableLoggingPayloadError
                .invalidContainer("test")
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
    }

    private func text(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> String {
        guard case let .textString(text)? = value else {
            throw
                ProviderHandoffPortableLoggingPayloadError
                .invalidContainer("test")
        }
        return text
    }

    private func bytes(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> Data {
        guard case let .byteString(bytes)? = value else {
            throw
                ProviderHandoffPortableLoggingPayloadError
                .invalidContainer("test")
        }
        return bytes
    }
}
