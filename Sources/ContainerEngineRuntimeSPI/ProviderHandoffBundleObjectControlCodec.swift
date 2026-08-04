//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

public struct ProviderHandoffBundleObjectDeclareRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var bundleObjectID: String
    public var transportByteLength: UInt64
    public var transportDigestSHA256: String

    public init(
        bundleObjectID: String,
        transportByteLength: UInt64,
        transportDigestSHA256: String
    ) {
        schemaVersion = 1
        self.bundleObjectID = bundleObjectID
        self.transportByteLength = transportByteLength
        self.transportDigestSHA256 = transportDigestSHA256
    }
}

public struct ProviderHandoffBundleObjectAppendRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var bundleObjectID: String
    public var offset: UInt64
    public var expectedObjectRevision: UInt64
    public var bytes: Data

    public init(
        bundleObjectID: String,
        offset: UInt64,
        expectedObjectRevision: UInt64,
        bytes: Data
    ) {
        schemaVersion = 1
        self.bundleObjectID = bundleObjectID
        self.offset = offset
        self.expectedObjectRevision = expectedObjectRevision
        self.bytes = bytes
    }
}

public struct ProviderHandoffBundleObjectReferenceRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var bundleObjectID: String
    public var expectedObjectRevision: UInt64

    public init(
        bundleObjectID: String,
        expectedObjectRevision: UInt64
    ) {
        schemaVersion = 1
        self.bundleObjectID = bundleObjectID
        self.expectedObjectRevision = expectedObjectRevision
    }
}

public struct ProviderHandoffBundleObjectReadRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var bundleObjectID: String
    public var offset: UInt64
    public var maximumBytes: UInt32

    public init(
        bundleObjectID: String,
        offset: UInt64,
        maximumBytes: UInt32
    ) {
        schemaVersion = 1
        self.bundleObjectID = bundleObjectID
        self.offset = offset
        self.maximumBytes = maximumBytes
    }
}

public struct ProviderHandoffBundleObjectChunkV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var bundleObjectID: String
    public var offset: UInt64
    public var bytes: Data

    public init(bundleObjectID: String, offset: UInt64, bytes: Data) {
        schemaVersion = 1
        self.bundleObjectID = bundleObjectID
        self.offset = offset
        self.bytes = bytes
    }
}

public enum ProviderHandoffBundleObjectControlCodecError:
    Error,
    Equatable,
    Sendable
{
    case boundsExceeded
    case invalidEncoding
    case invalidRequest
}

/// Canonical sorted-key JSON codec for the small provider-control envelopes.
/// The transported bundle bytes remain opaque and content-addressed; JSON is
/// used only for bounded request/receipt framing and is rejected unless it
/// round-trips byte-for-byte to the canonical encoder output.
public enum ProviderHandoffBundleObjectControlCodec {
    public static let requestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-object-control.v1+json"
    public static let recordMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-object-record.v1+json"
    public static let chunkMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-object-chunk.v1+json"
    public static let maximumTransportChunkBytes = 2 * 1024 * 1024

    public static func encodeDeclare(
        _ value: ProviderHandoffBundleObjectDeclareRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            value.transportByteLength > 0,
            value.bundleObjectID
                == "sha256:\(value.transportDigestSHA256)",
            (try? ProviderHandoffDigest.parseSHA256(
                value.transportDigestSHA256
            )) != nil
        else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeDeclare(
        _ data: Data
    ) throws -> ProviderHandoffBundleObjectDeclareRequestV1 {
        let value: ProviderHandoffBundleObjectDeclareRequestV1 = try decode(data)
        guard try encodeDeclare(value) == data else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeAppend(
        _ value: ProviderHandoffBundleObjectAppendRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            value.expectedObjectRevision > 0,
            !value.bytes.isEmpty,
            value.bytes.count <= maximumTransportChunkBytes,
            validObjectID(value.bundleObjectID)
        else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidRequest
        }
        let encoded = try encode(value)
        guard
            encoded.count
                <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        else {
            throw ProviderHandoffBundleObjectControlCodecError.boundsExceeded
        }
        return encoded
    }

    public static func decodeAppend(
        _ data: Data
    ) throws -> ProviderHandoffBundleObjectAppendRequestV1 {
        let value: ProviderHandoffBundleObjectAppendRequestV1 = try decode(data)
        guard try encodeAppend(value) == data else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeReference(
        _ value: ProviderHandoffBundleObjectReferenceRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            value.expectedObjectRevision > 0,
            validObjectID(value.bundleObjectID)
        else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeReference(
        _ data: Data
    ) throws -> ProviderHandoffBundleObjectReferenceRequestV1 {
        let value: ProviderHandoffBundleObjectReferenceRequestV1 = try decode(data)
        guard try encodeReference(value) == data else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeRead(
        _ value: ProviderHandoffBundleObjectReadRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            value.maximumBytes > 0,
            value.maximumBytes <= UInt32(maximumTransportChunkBytes),
            validObjectID(value.bundleObjectID)
        else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeRead(
        _ data: Data
    ) throws -> ProviderHandoffBundleObjectReadRequestV1 {
        let value: ProviderHandoffBundleObjectReadRequestV1 = try decode(data)
        guard try encodeRead(value) == data else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeRecord(
        _ value: ProviderHandoffBundleObjectRecordV1
    ) throws -> Data {
        try encode(value)
    }

    public static func decodeRecord(
        _ data: Data
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        let value: ProviderHandoffBundleObjectRecordV1 = try decode(data)
        guard try encodeRecord(value) == data else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeChunk(
        _ value: ProviderHandoffBundleObjectChunkV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            value.bytes.count <= maximumTransportChunkBytes,
            validObjectID(value.bundleObjectID)
        else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeChunk(
        _ data: Data
    ) throws -> ProviderHandoffBundleObjectChunkV1 {
        let value: ProviderHandoffBundleObjectChunkV1 = try decode(data)
        guard try encodeChunk(value) == data else {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
        return value
    }

    private static func validObjectID(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        return
            (try? ProviderHandoffDigest.parseSHA256(
                String(value.dropFirst("sha256:".count))
            )) != nil
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard
            !data.isEmpty,
            data.count
                <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        else {
            throw ProviderHandoffBundleObjectControlCodecError.boundsExceeded
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderHandoffBundleObjectControlCodecError.invalidEncoding
        }
    }
}

/// Shared limit avoids a dependency from RuntimeSPI back to ProviderSession.
public enum ContainerEngineProviderControlMetadataLimits {
    public static let maximumBodyBytes = 4 * 1024 * 1024
}
