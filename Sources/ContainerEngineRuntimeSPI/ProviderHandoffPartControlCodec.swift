//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// Bounded request for staging one manifest-declared provider handoff part.
///
/// The request deliberately carries no plaintext, private key, decoded
/// controller state, or gateway-only possession challenge. The destination
/// loads the exact signed trust-registry archive and its own durable possession
/// receipts before it accepts the manifest.
public struct ProviderHandoffPartStageRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var partKind: ProviderHandoffPartKindV1
    public var bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    public var manifest: ProviderHandoffManifestV1

    public init(
        partKind: ProviderHandoffPartKindV1,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        manifest: ProviderHandoffManifestV1
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.partKind = partKind
        self.bootstrap = bootstrap
        self.manifest = manifest
    }
}

/// Redacted completion receipt for a staged controller part.
///
/// Controller-private references remain protected by the destination. The
/// generic gateway receives only the common record, which contains the opaque
/// protected receipt digest required by the signed commit expectation.
public struct ProviderHandoffPartStageReceiptV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var commonRecord: ProviderHandoffPartStagingRecordV1

    public init(commonRecord: ProviderHandoffPartStagingRecordV1) {
        schemaVersion = Self.currentSchemaVersion
        self.commonRecord = commonRecord
    }
}

public struct ProviderHandoffPartPromoteRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var stage: ProviderHandoffPartStageRequestV1
    public var commitRecord: ProviderHandoffCommitRecordV1
    public var gatewayState: ProviderHandoffGatewayStateV1

    public init(
        stage: ProviderHandoffPartStageRequestV1,
        commitRecord: ProviderHandoffCommitRecordV1,
        gatewayState: ProviderHandoffGatewayStateV1
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.stage = stage
        self.commitRecord = commitRecord
        self.gatewayState = gatewayState
    }
}

public struct ProviderHandoffPartOpaqueControllerReceiptV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var partKind: ProviderHandoffPartKindV1
    public var mediaType: String
    public var body: Data
    public var bodyDigestSHA256: String

    public init(
        partKind: ProviderHandoffPartKindV1,
        mediaType: String,
        body: Data
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.partKind = partKind
        self.mediaType = mediaType
        self.body = body
        bodyDigestSHA256 = ProviderHandoffDigest.sha256(body)
    }
}

public struct ProviderHandoffPartActivateRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var stage: ProviderHandoffPartStageRequestV1
    public var commitRecord: ProviderHandoffCommitRecordV1
    public var terminalOutcome: ProviderHandoffTerminalOutcomeV1
    public var gatewayState: ProviderHandoffGatewayStateV1
    public var promotionReceipt: ProviderHandoffPartOpaqueControllerReceiptV1

    public init(
        stage: ProviderHandoffPartStageRequestV1,
        commitRecord: ProviderHandoffCommitRecordV1,
        terminalOutcome: ProviderHandoffTerminalOutcomeV1,
        gatewayState: ProviderHandoffGatewayStateV1,
        promotionReceipt: ProviderHandoffPartOpaqueControllerReceiptV1
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.stage = stage
        self.commitRecord = commitRecord
        self.terminalOutcome = terminalOutcome
        self.gatewayState = gatewayState
        self.promotionReceipt = promotionReceipt
    }
}

public struct ProviderHandoffPartCompensateRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var stage: ProviderHandoffPartStageRequestV1
    public var terminalOutcome: ProviderHandoffTerminalOutcomeV1
    public var gatewayState: ProviderHandoffGatewayStateV1

    public init(
        stage: ProviderHandoffPartStageRequestV1,
        terminalOutcome: ProviderHandoffTerminalOutcomeV1,
        gatewayState: ProviderHandoffGatewayStateV1
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.stage = stage
        self.terminalOutcome = terminalOutcome
        self.gatewayState = gatewayState
    }
}

public enum ProviderHandoffPartOperationV1:
    String,
    Codable,
    Equatable,
    Sendable
{
    case activate
    case compensate
}

public struct ProviderHandoffPartOperationReceiptV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var operation: ProviderHandoffPartOperationV1
    public var partKind: ProviderHandoffPartKindV1
    public var tokenID: String
    public var manifestID: String
    public var evidenceDigestSHA256: String

    public init(
        operation: ProviderHandoffPartOperationV1,
        partKind: ProviderHandoffPartKindV1,
        tokenID: String,
        manifestID: String,
        evidenceDigestSHA256: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.operation = operation
        self.partKind = partKind
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.evidenceDigestSHA256 = evidenceDigestSHA256
    }
}

public enum ProviderHandoffPartControlCodecError:
    Error,
    Equatable,
    Sendable
{
    case boundsExceeded
    case invalidEncoding
    case invalidRequest
    case invalidResponse
}

/// Canonical sorted-key JSON for provider part-control metadata.
public enum ProviderHandoffPartControlCodec {
    public static let stageRequestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-stage-request.v1+json"
    public static let stageReceiptMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-stage-receipt.v1+json"
    public static let promoteRequestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-promote-request.v1+json"
    public static let promotionReceiptMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-promotion-receipt.v1+json"
    public static let activateRequestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-activate-request.v1+json"
    public static let compensateRequestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-compensate-request.v1+json"
    public static let operationReceiptMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-operation-receipt.v1+json"

    public static func encodeStageRequest(
        _ value: ProviderHandoffPartStageRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion
                == ProviderHandoffPartStageRequestV1.currentSchemaVersion,
            value.bootstrap.rawPublicKey.count == 32,
            (try? ProviderHandoffDigest.parseSHA256(
                value.bootstrap.codeRequirementDigestSHA256
            )) != nil,
            !value.bootstrap.keyID.isEmpty,
            !value.manifest.tokenID.isEmpty,
            !value.manifest.manifestID.isEmpty,
            value.manifest.trustRegistryRevision > 0,
            value.manifest.parts.contains(where: {
                $0.kind == value.partKind
            })
        else {
            throw ProviderHandoffPartControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeStageRequest(
        _ data: Data
    ) throws -> ProviderHandoffPartStageRequestV1 {
        let value: ProviderHandoffPartStageRequestV1 = try decode(data)
        guard try encodeStageRequest(value) == data else {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeStageReceipt(
        _ value: ProviderHandoffPartStageReceiptV1
    ) throws -> Data {
        guard
            value.schemaVersion
                == ProviderHandoffPartStageReceiptV1.currentSchemaVersion,
            value.commonRecord.state == .imported,
            value.commonRecord.stagedImportReceiptDigestSHA256 != nil
        else {
            throw ProviderHandoffPartControlCodecError.invalidResponse
        }
        try ProviderHandoffPartStagingStateMachine.validate(value.commonRecord)
        return try encode(value)
    }

    public static func decodeStageReceipt(
        _ data: Data
    ) throws -> ProviderHandoffPartStageReceiptV1 {
        let value: ProviderHandoffPartStageReceiptV1 = try decode(data)
        guard try encodeStageReceipt(value) == data else {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodePromoteRequest(
        _ value: ProviderHandoffPartPromoteRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion
                == ProviderHandoffPartPromoteRequestV1.currentSchemaVersion,
            validStage(value.stage),
            value.commitRecord.intent.tokenID == value.stage.manifest.tokenID,
            value.commitRecord.intent.manifestID
                == value.stage.manifest.manifestID,
            value.commitRecord.intent.manifestDigest
                == value.stage.manifest.manifestDigest
        else {
            throw ProviderHandoffPartControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodePromoteRequest(
        _ data: Data
    ) throws -> ProviderHandoffPartPromoteRequestV1 {
        let value: ProviderHandoffPartPromoteRequestV1 = try decode(data)
        guard try encodePromoteRequest(value) == data else {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodePromotionReceipt(
        _ value: ProviderHandoffPartOpaqueControllerReceiptV1
    ) throws -> Data {
        guard
            value.schemaVersion
                == ProviderHandoffPartOpaqueControllerReceiptV1
                .currentSchemaVersion,
            !value.mediaType.isEmpty,
            value.mediaType.utf8.count <= 256,
            !value.body.isEmpty,
            value.body.count
                <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes,
            ProviderHandoffDigest.sha256(value.body)
                == value.bodyDigestSHA256
        else {
            throw ProviderHandoffPartControlCodecError.invalidResponse
        }
        return try encode(value)
    }

    public static func decodePromotionReceipt(
        _ data: Data
    ) throws -> ProviderHandoffPartOpaqueControllerReceiptV1 {
        let value: ProviderHandoffPartOpaqueControllerReceiptV1 = try decode(data)
        guard try encodePromotionReceipt(value) == data else {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeActivateRequest(
        _ value: ProviderHandoffPartActivateRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion
                == ProviderHandoffPartActivateRequestV1.currentSchemaVersion,
            validStage(value.stage),
            value.commitRecord.intent.tokenID == value.stage.manifest.tokenID,
            value.commitRecord.intent.manifestID
                == value.stage.manifest.manifestID,
            value.terminalOutcome.tokenID == value.stage.manifest.tokenID,
            value.terminalOutcome.manifestID
                == value.stage.manifest.manifestID,
            value.terminalOutcome.manifestDigest
                == value.stage.manifest.manifestDigest,
            value.terminalOutcome.phase == .complete,
            value.promotionReceipt.partKind == value.stage.partKind,
            validPromotionReceipt(value.promotionReceipt)
        else {
            throw ProviderHandoffPartControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeActivateRequest(
        _ data: Data
    ) throws -> ProviderHandoffPartActivateRequestV1 {
        let value: ProviderHandoffPartActivateRequestV1 = try decode(data)
        guard try encodeActivateRequest(value) == data else {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeCompensateRequest(
        _ value: ProviderHandoffPartCompensateRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion
                == ProviderHandoffPartCompensateRequestV1.currentSchemaVersion,
            validStage(value.stage),
            value.terminalOutcome.phase == .aborted,
            value.terminalOutcome.tokenID == value.stage.manifest.tokenID,
            value.terminalOutcome.manifestID
                == value.stage.manifest.manifestID,
            value.terminalOutcome.manifestDigest
                == value.stage.manifest.manifestDigest
        else {
            throw ProviderHandoffPartControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeCompensateRequest(
        _ data: Data
    ) throws -> ProviderHandoffPartCompensateRequestV1 {
        let value: ProviderHandoffPartCompensateRequestV1 = try decode(data)
        guard try encodeCompensateRequest(value) == data else {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeOperationReceipt(
        _ value: ProviderHandoffPartOperationReceiptV1
    ) throws -> Data {
        guard
            value.schemaVersion
                == ProviderHandoffPartOperationReceiptV1.currentSchemaVersion,
            !value.tokenID.isEmpty,
            !value.manifestID.isEmpty,
            (try? ProviderHandoffDigest.parseSHA256(
                value.evidenceDigestSHA256
            )) != nil
        else {
            throw ProviderHandoffPartControlCodecError.invalidResponse
        }
        return try encode(value)
    }

    public static func decodeOperationReceipt(
        _ data: Data
    ) throws -> ProviderHandoffPartOperationReceiptV1 {
        let value: ProviderHandoffPartOperationReceiptV1 = try decode(data)
        guard try encodeOperationReceipt(value) == data else {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        return value
    }

    private static func validStage(
        _ value: ProviderHandoffPartStageRequestV1
    ) -> Bool {
        value.schemaVersion
            == ProviderHandoffPartStageRequestV1.currentSchemaVersion
            && value.bootstrap.rawPublicKey.count == 32
            && (try? ProviderHandoffDigest.parseSHA256(
                value.bootstrap.codeRequirementDigestSHA256
            )) != nil
            && !value.bootstrap.keyID.isEmpty
            && !value.manifest.tokenID.isEmpty
            && !value.manifest.manifestID.isEmpty
            && value.manifest.trustRegistryRevision > 0
            && value.manifest.parts.contains(where: {
                $0.kind == value.partKind
            })
    }

    private static func validPromotionReceipt(
        _ value: ProviderHandoffPartOpaqueControllerReceiptV1
    ) -> Bool {
        value.schemaVersion
            == ProviderHandoffPartOpaqueControllerReceiptV1
            .currentSchemaVersion
            && !value.mediaType.isEmpty
            && value.mediaType.utf8.count <= 256
            && !value.body.isEmpty
            && value.body.count
                <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
            && ProviderHandoffDigest.sha256(value.body)
                == value.bodyDigestSHA256
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
        guard
            !data.isEmpty,
            data.count
                <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        else {
            throw ProviderHandoffPartControlCodecError.boundsExceeded
        }
        return data
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard
            !data.isEmpty,
            data.count
                <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        else {
            throw ProviderHandoffPartControlCodecError.boundsExceeded
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderHandoffPartControlCodecError.invalidEncoding
        }
    }
}
