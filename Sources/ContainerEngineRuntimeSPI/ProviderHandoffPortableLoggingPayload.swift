//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// A timestamped public log record that can be represented by Docker's
/// `json-file` format without depending on a provider implementation type.
public struct ProviderHandoffPortableLogRecordV1: Equatable, Sendable {
    public enum Stream: String, Equatable, Sendable {
        case stdout
        case stderr
    }

    public var secondsSinceUnixEpoch: Int64
    public var nanoseconds: UInt32
    public var stream: Stream
    /// Exact public log bytes. A terminating line feed remains part of the
    /// value, matching Docker's public `log` string.
    public var data: Data

    public init(
        secondsSinceUnixEpoch: Int64,
        nanoseconds: UInt32,
        stream: Stream,
        data: Data
    ) {
        self.secondsSinceUnixEpoch = secondsSinceUnixEpoch
        self.nanoseconds = nanoseconds
        self.stream = stream
        self.data = data
    }
}

/// Provider-neutral input for the portable subset of logging handoff v1.
///
/// This subset deliberately carries no protected options or provider-owned
/// history. It is sufficient for a provider that exposes Docker-compatible
/// `json-file` history and lets the destination independently resolve the
/// same requested logging semantics.
public struct ProviderHandoffPortableLoggingContainerV1: Equatable, Sendable {
    public enum ProviderKind: String, Equatable, Sendable {
        case core
        case native
        case linuxService
        case dockerPlugin
    }

    public var containerID: String
    public var requestedDriver: String?
    public var requestedSafeOptions: [String: String]
    public var resolvedSafeOptions: [String: String]
    public var leaseGeneration: UInt64
    public var providerID: String
    public var providerVersion: String
    public var providerKind: ProviderKind
    public var providerGeneration: UInt64
    public var terminalHistoryEpoch: UInt64
    public var records: [ProviderHandoffPortableLogRecordV1]

    public init(
        containerID: String,
        requestedDriver: String? = nil,
        requestedSafeOptions: [String: String] = [:],
        resolvedSafeOptions: [String: String] = [:],
        leaseGeneration: UInt64 = 1,
        providerID: String,
        providerVersion: String,
        providerKind: ProviderKind = .native,
        providerGeneration: UInt64 = 1,
        terminalHistoryEpoch: UInt64 = 0,
        records: [ProviderHandoffPortableLogRecordV1]
    ) {
        self.containerID = containerID
        self.requestedDriver = requestedDriver
        self.requestedSafeOptions = requestedSafeOptions
        self.resolvedSafeOptions = resolvedSafeOptions
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.providerKind = providerKind
        self.providerGeneration = providerGeneration
        self.terminalHistoryEpoch = terminalHistoryEpoch
        self.records = records
    }
}

public enum ProviderHandoffPortableLoggingPayloadError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case duplicateContainer(String)
    case historyTooLarge(String)
    case invalidContainer(String)
    case invalidRecord(String)
    case timestampOutsideRFC3339Range

    public var description: String {
        switch self {
        case let .duplicateContainer(identifier):
            "portable logging handoff contains duplicate container \(identifier)"
        case let .historyTooLarge(identifier):
            "portable logging history exceeds the payload bound for \(identifier)"
        case let .invalidContainer(identifier):
            "portable logging handoff container is invalid: \(identifier)"
        case let .invalidRecord(identifier):
            "portable logging handoff record is invalid for \(identifier)"
        case .timestampOutsideRFC3339Range:
            "portable logging timestamp is outside Docker's RFC3339 range"
        }
    }
}

/// Identifies one member of a canonical ordered portable logging history set.
public struct ProviderHandoffPortableLoggingHistoryChunkV1:
    Equatable,
    Sendable
{
    public var index: UInt64
    public var count: UInt64

    public init(index: UInt64, count: UInt64) {
        self.index = index
        self.count = count
    }
}

/// Builds the exact logging-handoff-v1 canonical record schema consumed by a
/// conforming Container authority while keeping provider implementation types
/// out of the shared runtime SPI.
public enum ProviderHandoffPortableLoggingPayloadCodec {
    public static let mediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-logging.v1+cbor"
    /// The former aggregate history ceiling, retained as a compatibility-test
    /// threshold now that large histories are transported in bounded chunks.
    public static let maximumHistoryBytes = 64 * 1024 * 1024
    /// The maximum encoded JSON-file bytes carried by one portable store.
    public static let maximumHistoryChunkBytes = 8 * 1024 * 1024
    /// The defensive upper bound on stores in one portable history set.
    public static let maximumHistoryChunkCount: UInt64 = 4096
    /// The stable store identifier used when history fits in one store.
    public static let historyStoreID = "docker-json-file-active"

    // Six-byte JSON escaping is the worst case for one input byte. This bound
    // keeps every encoded line below the destination's 1 MiB record ceiling.
    private static let maximumRecordChunkBytes = 128 * 1024
    private static let maximumEncodedRecordBytes = 1 * 1024 * 1024

    /// Returns the canonical store identifier for one multi-store history
    /// member. The index is zero-based and the count must exceed one.
    public static func historyChunkStoreID(
        index: UInt64,
        count: UInt64
    ) -> String {
        precondition(count > 1 && count <= maximumHistoryChunkCount)
        precondition(index < count)
        return String(
            format: "%@.chunk.%08llu.%08llu",
            historyStoreID,
            index,
            count
        )
    }

    /// Parses a canonical multi-store history identifier.
    public static func parseHistoryChunkStoreID(
        _ storeID: String
    ) -> ProviderHandoffPortableLoggingHistoryChunkV1? {
        let prefix = historyStoreID + ".chunk."
        guard storeID.hasPrefix(prefix) else { return nil }
        let fields = storeID.dropFirst(prefix.count).split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard
            fields.count == 2,
            let index = UInt64(fields[0]),
            let count = UInt64(fields[1]),
            count > 1,
            count <= maximumHistoryChunkCount,
            index < count,
            historyChunkStoreID(index: index, count: count) == storeID
        else { return nil }
        return ProviderHandoffPortableLoggingHistoryChunkV1(
            index: index,
            count: count
        )
    }

    public static func package(
        containers: [ProviderHandoffPortableLoggingContainerV1],
        sourceStateRootUUID: String
    ) throws -> ProviderHandoffPayloadPackageV1 {
        guard
            !containers.isEmpty,
            let sourceRoot = UUID(uuidString: sourceStateRootUUID),
            sourceRoot.uuidString.lowercased() == sourceStateRootUUID
        else {
            throw ProviderHandoffPortableLoggingPayloadError.invalidContainer(
                containers.first?.containerID ?? "unknown"
            )
        }
        let ordered = containers.sorted {
            utf8Less($0.containerID, $1.containerID)
        }
        guard Set(ordered.map(\.containerID)).count == ordered.count else {
            throw ProviderHandoffPortableLoggingPayloadError.duplicateContainer(
                ordered.first?.containerID ?? "unknown"
            )
        }

        var entries: [ProviderHandoffPayloadPackageEntryV1] = []
        for container in ordered {
            try validate(container)
            let historySegments = try encodeHistory(
                container.records,
                containerID: container.containerID
            )
            let segmentCount = UInt64(historySegments.count)
            let histories = try historySegments.enumerated().map {
                index,
                bytes -> (id: String, value: ProviderHandoffCanonicalValue) in
                let storeID =
                    segmentCount == 1
                        ? historyStoreID
                        : historyChunkStoreID(
                            index: UInt64(index),
                            count: segmentCount
                        )
                return try (
                    id: historyEntryID(
                        containerID: container.containerID,
                        storeID: storeID
                    ),
                    value: historyProjection(
                        storeID: storeID,
                        bytes: bytes,
                        terminalHistoryEpoch: container.terminalHistoryEpoch
                    )
                )
            }
            let contractDigest = try ProviderHandoffDigest.domain(
                "container-handoff-portable-logging-contract-v1",
                projection: .map([
                    .init("driver", .textString("json-file")),
                    .init("providerID", .textString(container.providerID)),
                    .init("providerVersion", .textString(container.providerVersion)),
                    .init("safeOptions", stringMap(container.resolvedSafeOptions))
                ])
            )
            let historyRetentionDigest = try ProviderHandoffDigest.domain(
                "container-handoff-logging-history-retention-v1",
                projection: .map([
                    .init("containerID", .textString(container.containerID)),
                    .init(
                        "stores",
                        .array(
                            histories.map {
                                historyRetentionProjection($0.value)
                            }
                        )
                    )
                ])
            )
            let terminalCategoryDigest = try ProviderHandoffDigest.domain(
                "container-handoff-logging-terminal-categories-v1",
                projection: .map([
                    .init("categories", .array([])),
                    .init("containerID", .textString(container.containerID))
                ])
            )
            let record = try ProviderHandoffCanonicalCBOR.encode(
                .map([
                    .init("containerID", .textString(container.containerID)),
                    .init(
                        "historyEntryIDs",
                        .array(histories.map { .textString($0.id) })
                    ),
                    .init("protectedEntryIDs", .array([])),
                    .init(
                        "requested",
                        .map([
                            .init("driver", .optional(container.requestedDriver)),
                            .init("protectedOptionNames", .array([])),
                            .init("safeOptions", stringMap(container.requestedSafeOptions)),
                            .init("schemaVersion", .unsigned(1))
                        ])
                    ),
                    .init("schemaVersion", .unsigned(1)),
                    .init(
                        "sourceResolved",
                        .map([
                            .init("contractDigest", .textString(contractDigest)),
                            .init(
                                "delivery",
                                .map([
                                    .init("effectiveMaxBufferSizeInBytes", .null),
                                    .init("effectiveMode", .textString("blocking")),
                                    .init("maxBufferSizeInBytes", .null),
                                    .init("requestedMode", .null),
                                    .init("schemaVersion", .unsigned(1))
                                ])
                            ),
                            .init("driver", .textString("json-file")),
                            .init("leaseGeneration", .unsigned(container.leaseGeneration)),
                            .init("protectedOptionNames", .array([])),
                            .init("providerGenerationAtResolution", .unsigned(container.providerGeneration)),
                            .init("providerHistoryMigrationReceipt", .null),
                            .init(
                                "providerIdentity",
                                .map([
                                    .init("id", .textString(container.providerID)),
                                    .init("kind", .textString(container.providerKind.rawValue)),
                                    .init("schemaVersion", .unsigned(1)),
                                    .init("version", .textString(container.providerVersion))
                                ])
                            ),
                            .init(
                                "readPolicy",
                                .map([
                                    .init("cache", .null),
                                    .init("schemaVersion", .unsigned(1)),
                                    .init("source", .textString("direct"))
                                ])
                            ),
                            .init("safeOptions", stringMap(container.resolvedSafeOptions)),
                            .init("schemaVersion", .unsigned(1))
                        ])
                    ),
                    .init(
                        "terminalAudit",
                        .map([
                            .init("historyRetentionDigestSHA256", digest(historyRetentionDigest)),
                            .init("schemaVersion", .unsigned(1)),
                            .init("terminalCategoryDigestSHA256", digest(terminalCategoryDigest)),
                            .init("terminalDetachedCleanupCount", .unsigned(0)),
                            .init("terminalReaderCount", .unsigned(0)),
                            .init("terminalWriterCount", .unsigned(0))
                        ])
                    )
                ])
            )
            entries.append(
                ProviderHandoffPayloadPackageEntryV1(
                    entryID: containerEntryID(container.containerID),
                    sourceStateRootUUID: sourceStateRootUUID,
                    recordKind: "logging-container-v1",
                    schemaVersion: 1,
                    canonicalRecordBytes: record
                )
            )
            try entries.append(
                contentsOf: histories.map {
                    try ProviderHandoffPayloadPackageEntryV1(
                        entryID: $0.id,
                        sourceStateRootUUID: sourceStateRootUUID,
                        recordKind: "logging-history-store-v1",
                        schemaVersion: 1,
                        canonicalRecordBytes: ProviderHandoffCanonicalCBOR.encode(
                            $0.value
                        )
                    )
                }
            )
        }
        entries.sort { utf8Less($0.entryID, $1.entryID) }
        return ProviderHandoffPayloadPackageV1(
            partKind: .logging,
            entries: entries
        )
    }

    private static func validate(
        _ container: ProviderHandoffPortableLoggingContainerV1
    ) throws {
        guard
            !container.containerID.isEmpty,
            container.containerID.precomposedStringWithCanonicalMapping
            == container.containerID,
            container.leaseGeneration > 0,
            container.providerGeneration > 0,
            !container.providerID.isEmpty,
            !container.providerVersion.isEmpty,
            container.requestedDriver != "",
            container.requestedSafeOptions.keys.allSatisfy({
                container.resolvedSafeOptions[$0]
                    == container.requestedSafeOptions[$0]
            })
        else {
            throw ProviderHandoffPortableLoggingPayloadError.invalidContainer(
                container.containerID
            )
        }
        guard container.records.allSatisfy({ $0.nanoseconds < 1_000_000_000 })
        else {
            throw ProviderHandoffPortableLoggingPayloadError.invalidRecord(
                container.containerID
            )
        }
    }

    private static func historyProjection(
        storeID: String,
        bytes: Data,
        terminalHistoryEpoch: UInt64
    ) throws -> ProviderHandoffCanonicalValue {
        let storedBytes: Data? = bytes.isEmpty ? nil : bytes
        return try .map([
            .init("byteLength", .unsigned(UInt64(storedBytes?.count ?? 0))),
            .init("bytes", storedBytes.map(ProviderHandoffCanonicalValue.byteString) ?? .null),
            .init("contentDigestSHA256", optionalDigest(storedBytes.map(ProviderHandoffDigest.sha256))),
            .init("compressed", .boolean(false)),
            .init("disposition", .textString(storedBytes == nil ? "empty" : "importVerified")),
            .init("formatVersion", .unsigned(1)),
            .init("kind", .textString("dockerJSONFile")),
            .init("maximumInternalSequence", .unsigned(0)),
            .init("providerExportDigestSHA256", .null),
            .init("providerExportReceipt", .null),
            .init("rotationIndex", .unsigned(0)),
            .init("schemaVersion", .unsigned(1)),
            .init("sourceDeviceID", .null),
            .init("sourceInode", .null),
            .init("storeID", .textString(storeID)),
            .init("terminalHistoryEpoch", .unsigned(terminalHistoryEpoch))
        ])
    }

    private static func historyRetentionProjection(
        _ history: ProviderHandoffCanonicalValue
    ) -> ProviderHandoffCanonicalValue {
        guard case let .map(entries) = history else { preconditionFailure() }
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        return .map([
            .init("byteLength", values["byteLength"] ?? .unsigned(0)),
            .init("contentDigestSHA256", values["contentDigestSHA256"] ?? .null),
            .init("disposition", values["disposition"] ?? .textString("empty")),
            .init("formatVersion", .unsigned(1)),
            .init("kind", .textString("dockerJSONFile")),
            .init("maximumInternalSequence", .unsigned(0)),
            .init("providerExportDigestSHA256", .null),
            .init("rotationIndex", values["rotationIndex"] ?? .unsigned(0)),
            .init("sourceDeviceID", .null),
            .init("sourceInode", .null),
            .init("storeID", values["storeID"] ?? .textString(historyStoreID)),
            .init(
                "terminalHistoryEpoch",
                values["terminalHistoryEpoch"] ?? .unsigned(0)
            )
        ])
    }

    private static func encodeHistory(
        _ records: [ProviderHandoffPortableLogRecordV1],
        containerID: String
    ) throws -> [Data] {
        var outputs = [Data()]
        for record in records {
            let chunks =
                record.data.isEmpty
                    ? [Data()]
                    : stride(from: 0, to: record.data.count, by: maximumRecordChunkBytes)
                    .map { offset -> Data in
                        let upper = min(record.data.count, offset + maximumRecordChunkBytes)
                        return record.data.subdata(in: offset ..< upper)
                    }
            for chunk in chunks {
                let encoded = try encodeRecord(record, data: chunk)
                guard encoded.count <= maximumEncodedRecordBytes else {
                    throw ProviderHandoffPortableLoggingPayloadError.invalidRecord(
                        containerID
                    )
                }
                if let current = outputs.last,
                   !current.isEmpty,
                   current.count + encoded.count > maximumHistoryChunkBytes
                {
                    outputs.append(Data())
                }
                guard
                    encoded.count <= maximumHistoryChunkBytes,
                    outputs.count <= Int(maximumHistoryChunkCount)
                else {
                    throw ProviderHandoffPortableLoggingPayloadError.historyTooLarge(
                        containerID
                    )
                }
                outputs[outputs.count - 1].append(encoded)
            }
        }
        return outputs
    }

    private static func encodeRecord(
        _ record: ProviderHandoffPortableLogRecordV1,
        data: Data
    ) throws -> Data {
        var output = Data("{\"log\":".utf8)
        appendJSONString(data, to: &output)
        output.append(contentsOf: ",\"stream\":".utf8)
        appendJSONString(Data(record.stream.rawValue.utf8), to: &output)
        output.append(contentsOf: ",\"time\":".utf8)
        try appendJSONString(
            Data(timestamp(record).utf8),
            to: &output
        )
        output.append(contentsOf: "}\n".utf8)
        return output
    }

    private static func timestamp(
        _ record: ProviderHandoffPortableLogRecordV1
    ) throws -> String {
        let dayAndSecond = floorQuotientAndRemainder(
            record.secondsSinceUnixEpoch,
            divisor: 86400
        )
        let civil = civilDate(daysSinceUnixEpoch: dayAndSecond.quotient)
        guard (0 ... 9999).contains(civil.year) else {
            throw ProviderHandoffPortableLoggingPayloadError
                .timestampOutsideRFC3339Range
        }
        let hour = dayAndSecond.remainder / 3600
        let minute = (dayAndSecond.remainder % 3600) / 60
        let second = dayAndSecond.remainder % 60
        var formatted = String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld",
            civil.year,
            civil.month,
            civil.day,
            hour,
            minute,
            second
        )
        if record.nanoseconds != 0 {
            var fraction = String(format: "%09u", record.nanoseconds)
            while fraction.last == "0" {
                fraction.removeLast()
            }
            formatted += ".\(fraction)"
        }
        return formatted + "Z"
    }

    private static func appendJSONString(_ bytes: Data, to output: inout Data) {
        output.append(UInt8(ascii: "\""))
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte < 0x80 {
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                    output.append(UInt8(ascii: "\\"))
                    output.append(byte)
                case UInt8(ascii: "\n"):
                    output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
                case UInt8(ascii: "\r"):
                    output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
                case 0x20 ... 0x7E
                    where byte != UInt8(ascii: "<")
                    && byte != UInt8(ascii: ">")
                    && byte != UInt8(ascii: "&"):
                    output.append(byte)
                case 0x7F:
                    output.append(byte)
                default:
                    appendUnicodeEscape(UInt16(byte), to: &output)
                }
                index = bytes.index(after: index)
                continue
            }
            guard let scalar = decodeUTF8Scalar(bytes, at: index) else {
                output.append(contentsOf: #"\ufffd"#.utf8)
                index = bytes.index(after: index)
                continue
            }
            if scalar.value == 0x2028 || scalar.value == 0x2029 {
                appendUnicodeEscape(UInt16(scalar.value), to: &output)
            } else {
                let end = bytes.index(index, offsetBy: scalar.length)
                output.append(contentsOf: bytes[index ..< end])
            }
            index = bytes.index(index, offsetBy: scalar.length)
        }
        output.append(UInt8(ascii: "\""))
    }

    private static func appendUnicodeEscape(
        _ value: UInt16,
        to output: inout Data
    ) {
        let hexadecimal = Array("0123456789abcdef".utf8)
        output.append(contentsOf: #"\u"#.utf8)
        output.append(hexadecimal[Int((value >> 12) & 0xF)])
        output.append(hexadecimal[Int((value >> 8) & 0xF)])
        output.append(hexadecimal[Int((value >> 4) & 0xF)])
        output.append(hexadecimal[Int(value & 0xF)])
    }

    private static func decodeUTF8Scalar(
        _ bytes: Data,
        at index: Data.Index
    ) -> (value: UInt32, length: Int)? {
        let first = bytes[index]
        let remaining = bytes.distance(from: index, to: bytes.endIndex)
        let length: Int
        let minimum: UInt32
        var value: UInt32
        switch first {
        case 0xC2 ... 0xDF:
            length = 2
            minimum = 0x80
            value = UInt32(first & 0x1F)
        case 0xE0 ... 0xEF:
            length = 3
            minimum = 0x800
            value = UInt32(first & 0x0F)
        case 0xF0 ... 0xF4:
            length = 4
            minimum = 0x10000
            value = UInt32(first & 0x07)
        default:
            return nil
        }
        guard remaining >= length else { return nil }
        for offset in 1 ..< length {
            let continuation = bytes[bytes.index(index, offsetBy: offset)]
            guard (0x80 ... 0xBF).contains(continuation) else { return nil }
            value = (value << 6) | UInt32(continuation & 0x3F)
        }
        guard
            value >= minimum,
            value <= 0x10FFFF,
            !(0xD800 ... 0xDFFF).contains(value)
        else { return nil }
        return (value, length)
    }

    private static func floorQuotientAndRemainder(
        _ value: Int64,
        divisor: Int64
    ) -> (quotient: Int64, remainder: Int64) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }

    private static func civilDate(
        daysSinceUnixEpoch: Int64
    ) -> (year: Int64, month: Int64, day: Int64) {
        let shiftedDays = daysSinceUnixEpoch + 719_468
        let era = floorQuotientAndRemainder(
            shiftedDays,
            divisor: 146_097
        ).quotient
        let dayOfEra = shiftedDays - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524
                - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        let dayOfYear =
            dayOfEra
                - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        if month <= 2 {
            year += 1
        }
        return (year, month, day)
    }

    private static func stringMap(
        _ values: [String: String]
    ) -> ProviderHandoffCanonicalValue {
        .map(values.map { .init($0.key, .textString($0.value)) })
    }

    private static func digest(
        _ value: String
    ) throws -> ProviderHandoffCanonicalValue {
        try .byteString(ProviderHandoffDigest.parseSHA256(value))
    }

    private static func optionalDigest(
        _ value: String?
    ) throws -> ProviderHandoffCanonicalValue {
        guard let value else { return .null }
        return try digest(value)
    }

    private static func encodedIdentifier(_ value: String) -> String {
        ProviderHandoffDigest.hex(Data(value.utf8))
    }

    private static func containerEntryID(_ containerID: String) -> String {
        "logging:\(encodedIdentifier(containerID)):00:container"
    }

    private static func historyEntryID(
        containerID: String,
        storeID: String
    ) -> String {
        "logging:\(encodedIdentifier(containerID)):20:history:"
            + encodedIdentifier(storeID)
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
