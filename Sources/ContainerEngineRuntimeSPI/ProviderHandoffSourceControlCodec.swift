//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// Bounded source-side request to export one provider-owned handoff part.
///
/// Destination public keys and possession proofs travel with the request so
/// the source can validate them against the exact archived trust-registry
/// revision before it seals any authority state. Plaintext payloads and
/// lineage keys never cross the provider control channel.
public struct ProviderHandoffPartExportRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var partKind: ProviderHandoffPartKindV1
    public var bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    public var tokenID: String
    public var manifestID: String
    public var trustRegistryRevision: UInt64
    public var sourceProviderFingerprint: String
    public var sourceStateRootUUID: String
    public var authorityLineageUUID: String
    public var lineageDigestKeyVersion: UInt64
    public var sourcePreCommitExpectation: ProviderHandoffHeaderExpectationV1
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var destinationPreCommitExpectation: ProviderHandoffHeaderExpectationV1
    public var destinationPayloadEncryptionKey: ProviderHandoffTrustKeyV1
    public var destinationLineageKeyEncryptionKey: ProviderHandoffTrustKeyV1
    public var destinationKeyPossessionProofs: [ProviderHandoffDestinationKeyPossessionProofV1]
    public var resultingAuthorityLineageUUID: String
    public var resultingLineageDigestKeyVersion: UInt64
    public var selectedResourceIDs: [String]

    public init(
        partKind: ProviderHandoffPartKindV1,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        tokenID: String,
        manifestID: String,
        trustRegistryRevision: UInt64,
        sourceProviderFingerprint: String,
        sourceStateRootUUID: String,
        authorityLineageUUID: String,
        lineageDigestKeyVersion: UInt64,
        sourcePreCommitExpectation: ProviderHandoffHeaderExpectationV1,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationPreCommitExpectation: ProviderHandoffHeaderExpectationV1,
        destinationPayloadEncryptionKey: ProviderHandoffTrustKeyV1,
        destinationLineageKeyEncryptionKey: ProviderHandoffTrustKeyV1,
        destinationKeyPossessionProofs:
        [ProviderHandoffDestinationKeyPossessionProofV1],
        resultingAuthorityLineageUUID: String,
        resultingLineageDigestKeyVersion: UInt64,
        selectedResourceIDs: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.partKind = partKind
        self.bootstrap = bootstrap
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.trustRegistryRevision = trustRegistryRevision
        self.sourceProviderFingerprint = sourceProviderFingerprint
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.lineageDigestKeyVersion = lineageDigestKeyVersion
        self.sourcePreCommitExpectation = sourcePreCommitExpectation
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.destinationPreCommitExpectation = destinationPreCommitExpectation
        self.destinationPayloadEncryptionKey =
            destinationPayloadEncryptionKey
        self.destinationLineageKeyEncryptionKey =
            destinationLineageKeyEncryptionKey
        self.destinationKeyPossessionProofs = destinationKeyPossessionProofs
        self.resultingAuthorityLineageUUID = resultingAuthorityLineageUUID
        self.resultingLineageDigestKeyVersion =
            resultingLineageDigestKeyVersion
        self.selectedResourceIDs = selectedResourceIDs
    }
}

/// Durable, unsigned source contribution returned after export.
///
/// The source object is already immutable and verified, and the lineage key is
/// already sealed to the proven destination. The final source signature is a
/// separate operation because it commits to every part in the assembled
/// manifest, including contributions owned by other controllers.
public struct ProviderHandoffSourceContributionV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var partKind: ProviderHandoffPartKindV1
    public var tokenID: String
    public var manifestID: String
    public var trustRegistryRevision: UInt64
    public var exportRequestDigestSHA256: String
    public var sourceProviderFingerprint: String
    public var sourceStateRootUUID: String
    public var authorityLineageUUID: String
    public var lineageDigestKeyVersion: UInt64
    public var sourcePreCommitExpectation: ProviderHandoffHeaderExpectationV1
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var destinationPreCommitExpectation: ProviderHandoffHeaderExpectationV1
    public var destinationKeyPossessionProofDigestsSHA256: [String]
    public var resultingAuthorityLineageUUID: String
    public var resultingLineageDigestKeyVersion: UInt64
    public var destinationSealedLineageKeyEnvelope: DestinationSealedLineageKeyEnvelopeV1
    public var part: ProviderHandoffPartV1
    public var sourceObjectRecord: ProviderHandoffBundleObjectRecordV1
    public var contributionDigestSHA256: String

    public init(
        partKind: ProviderHandoffPartKindV1,
        tokenID: String,
        manifestID: String,
        trustRegistryRevision: UInt64,
        exportRequestDigestSHA256: String,
        sourceProviderFingerprint: String,
        sourceStateRootUUID: String,
        authorityLineageUUID: String,
        lineageDigestKeyVersion: UInt64,
        sourcePreCommitExpectation: ProviderHandoffHeaderExpectationV1,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationPreCommitExpectation: ProviderHandoffHeaderExpectationV1,
        destinationKeyPossessionProofDigestsSHA256: [String],
        resultingAuthorityLineageUUID: String,
        resultingLineageDigestKeyVersion: UInt64,
        destinationSealedLineageKeyEnvelope:
        DestinationSealedLineageKeyEnvelopeV1,
        part: ProviderHandoffPartV1,
        sourceObjectRecord: ProviderHandoffBundleObjectRecordV1,
        contributionDigestSHA256: String = ""
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.partKind = partKind
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.trustRegistryRevision = trustRegistryRevision
        self.exportRequestDigestSHA256 = exportRequestDigestSHA256
        self.sourceProviderFingerprint = sourceProviderFingerprint
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.lineageDigestKeyVersion = lineageDigestKeyVersion
        self.sourcePreCommitExpectation = sourcePreCommitExpectation
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.destinationPreCommitExpectation = destinationPreCommitExpectation
        self.destinationKeyPossessionProofDigestsSHA256 =
            destinationKeyPossessionProofDigestsSHA256
        self.resultingAuthorityLineageUUID = resultingAuthorityLineageUUID
        self.resultingLineageDigestKeyVersion =
            resultingLineageDigestKeyVersion
        self.destinationSealedLineageKeyEnvelope =
            destinationSealedLineageKeyEnvelope
        self.part = part
        self.sourceObjectRecord = sourceObjectRecord
        self.contributionDigestSHA256 = contributionDigestSHA256
    }
}

public struct ProviderHandoffSourceManifestSignRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    public var partKind: ProviderHandoffPartKindV1
    public var contributionDigestSHA256: String
    public var candidateManifest: ProviderHandoffManifestV1

    public init(
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        partKind: ProviderHandoffPartKindV1,
        contributionDigestSHA256: String,
        candidateManifest: ProviderHandoffManifestV1
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bootstrap = bootstrap
        self.partKind = partKind
        self.contributionDigestSHA256 = contributionDigestSHA256
        self.candidateManifest = candidateManifest
    }
}

public struct ProviderHandoffSourceManifestSignReceiptV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var partKind: ProviderHandoffPartKindV1
    public var tokenID: String
    public var manifestID: String
    public var sourceStateRootUUID: String
    public var contributionDigestSHA256: String
    public var sourceProjectionDigestSHA256: String
    public var sourceSignature: ProviderHandoffSignatureV1

    public init(
        partKind: ProviderHandoffPartKindV1,
        tokenID: String,
        manifestID: String,
        sourceStateRootUUID: String,
        contributionDigestSHA256: String,
        sourceProjectionDigestSHA256: String,
        sourceSignature: ProviderHandoffSignatureV1
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.partKind = partKind
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.sourceStateRootUUID = sourceStateRootUUID
        self.contributionDigestSHA256 = contributionDigestSHA256
        self.sourceProjectionDigestSHA256 = sourceProjectionDigestSHA256
        self.sourceSignature = sourceSignature
    }
}

public enum ProviderHandoffSourceControlCodecError:
    Error,
    Equatable,
    Sendable
{
    case boundsExceeded
    case invalidEncoding
    case invalidRequest
    case invalidResponse
}

/// Canonical sorted-key JSON for provider source-export control metadata.
public enum ProviderHandoffSourceControlCodec {
    public static let exportRequestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-part-export-request.v1+json"
    public static let contributionMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-source-contribution.v1+json"
    public static let signRequestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-source-sign-request.v1+json"
    public static let signReceiptMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-source-sign-receipt.v1+json"

    public static func encodeExportRequest(
        _ value: ProviderHandoffPartExportRequestV1
    ) throws -> Data {
        guard validExportRequest(value) else {
            throw ProviderHandoffSourceControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeExportRequest(
        _ data: Data
    ) throws -> ProviderHandoffPartExportRequestV1 {
        let value: ProviderHandoffPartExportRequestV1 = try decode(data)
        guard try encodeExportRequest(value) == data else {
            throw ProviderHandoffSourceControlCodecError.invalidEncoding
        }
        return value
    }

    public static func exportRequestDigest(
        _ value: ProviderHandoffPartExportRequestV1
    ) throws -> String {
        guard validExportRequest(value) else {
            throw ProviderHandoffSourceControlCodecError.invalidRequest
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-part-export-request-v1",
            projection: .byteString(encode(value))
        )
    }

    public static func finalizeContribution(
        _ value: ProviderHandoffSourceContributionV1
    ) throws -> ProviderHandoffSourceContributionV1 {
        var result = value
        result.contributionDigestSHA256 = try contributionDigest(result)
        guard validContribution(result) else {
            throw ProviderHandoffSourceControlCodecError.invalidResponse
        }
        return result
    }

    public static func contributionDigest(
        _ value: ProviderHandoffSourceContributionV1
    ) throws -> String {
        var unsigned = value
        unsigned.contributionDigestSHA256 = ""
        let bytes = try encode(unsigned)
        return try ProviderHandoffDigest.domain(
            "container-handoff-source-contribution-v1",
            projection: .byteString(bytes)
        )
    }

    public static func encodeContribution(
        _ value: ProviderHandoffSourceContributionV1
    ) throws -> Data {
        guard validContribution(value) else {
            throw ProviderHandoffSourceControlCodecError.invalidResponse
        }
        return try encode(value)
    }

    public static func decodeContribution(
        _ data: Data
    ) throws -> ProviderHandoffSourceContributionV1 {
        let value: ProviderHandoffSourceContributionV1 = try decode(data)
        guard try encodeContribution(value) == data else {
            throw ProviderHandoffSourceControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeSignRequest(
        _ value: ProviderHandoffSourceManifestSignRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion
            == ProviderHandoffSourceManifestSignRequestV1
            .currentSchemaVersion,
            validBootstrap(value.bootstrap),
            validDigest(value.contributionDigestSHA256),
            !value.candidateManifest.tokenID.isEmpty,
            !value.candidateManifest.manifestID.isEmpty,
            value.candidateManifest.trustRegistryRevision > 0,
            value.candidateManifest.parts.contains(where: {
                $0.kind == value.partKind
            })
        else {
            throw ProviderHandoffSourceControlCodecError.invalidRequest
        }
        return try encode(value)
    }

    public static func decodeSignRequest(
        _ data: Data
    ) throws -> ProviderHandoffSourceManifestSignRequestV1 {
        let value: ProviderHandoffSourceManifestSignRequestV1 = try decode(data)
        guard try encodeSignRequest(value) == data else {
            throw ProviderHandoffSourceControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeSignReceipt(
        _ value: ProviderHandoffSourceManifestSignReceiptV1
    ) throws -> Data {
        let signature = value.sourceSignature
        guard
            value.schemaVersion
            == ProviderHandoffSourceManifestSignReceiptV1
            .currentSchemaVersion,
            !value.tokenID.isEmpty,
            !value.manifestID.isEmpty,
            canonicalUUID(value.sourceStateRootUUID),
            validDigest(value.contributionDigestSHA256),
            validDigest(value.sourceProjectionDigestSHA256),
            signature.purpose == .sourceManifestSigning,
            signature.signerRole == .sourceProvider,
            signature.stateRootUUID == value.sourceStateRootUUID,
            signature.signedProjectionDigestSHA256
            == value.sourceProjectionDigestSHA256,
            signature.trustRegistryRevision > 0,
            !signature.signerKeyID.isEmpty,
            signature.providerFingerprint?.isEmpty == false,
            signature.signature.count == 64
        else {
            throw ProviderHandoffSourceControlCodecError.invalidResponse
        }
        return try encode(value)
    }

    public static func decodeSignReceipt(
        _ data: Data
    ) throws -> ProviderHandoffSourceManifestSignReceiptV1 {
        let value: ProviderHandoffSourceManifestSignReceiptV1 = try decode(data)
        guard try encodeSignReceipt(value) == data else {
            throw ProviderHandoffSourceControlCodecError.invalidEncoding
        }
        return value
    }

    private static func validExportRequest(
        _ value: ProviderHandoffPartExportRequestV1
    ) -> Bool {
        let proofs = value.destinationKeyPossessionProofs
        let proofPurposes = proofs.map(\.destinationKeyPurpose)
        return value.schemaVersion
            == ProviderHandoffPartExportRequestV1.currentSchemaVersion
            && validBootstrap(value.bootstrap)
            && validIdentifier(value.tokenID)
            && validIdentifier(value.manifestID)
            && value.trustRegistryRevision > 0
            && validFingerprint(value.sourceProviderFingerprint)
            && canonicalUUID(value.sourceStateRootUUID)
            && canonicalUUID(value.authorityLineageUUID)
            && value.lineageDigestKeyVersion > 0
            && validExpectation(
                value.sourcePreCommitExpectation,
                role: .source,
                stateRootUUID: value.sourceStateRootUUID
            )
            && validFingerprint(value.destinationProviderFingerprint)
            && canonicalUUID(value.destinationStateRootUUID)
            && validExpectation(
                value.destinationPreCommitExpectation,
                role: .destination,
                stateRootUUID: value.destinationStateRootUUID
            )
            && validDestinationKey(
                value.destinationPayloadEncryptionKey,
                purpose: .destinationPayloadEncryption,
                request: value
            )
            && validDestinationKey(
                value.destinationLineageKeyEncryptionKey,
                purpose: .destinationLineageKeyEncryption,
                request: value
            )
            && proofs.count == 2
            && Set(proofPurposes).count == 2
            && Set(proofPurposes)
            == Set([
                .destinationPayloadEncryption,
                .destinationLineageKeyEncryption
            ])
            && proofs
            == proofs.sorted {
                $0.destinationKeyPurpose.rawValue.utf8.lexicographicallyPrecedes(
                    $1.destinationKeyPurpose.rawValue.utf8
                )
            }
            && proofs.allSatisfy { proof in
                proof.schemaVersion == 1
                    && proof.tokenID == value.tokenID
                    && proof.manifestID == value.manifestID
                    && proof.destinationProviderFingerprint
                    == value.destinationProviderFingerprint
                    && proof.destinationStateRootUUID
                    == value.destinationStateRootUUID
                    && proof.destinationKeyID
                    == (proof.destinationKeyPurpose
                        == .destinationPayloadEncryption
                        ? value.destinationPayloadEncryptionKey.keyID
                        : value.destinationLineageKeyEncryptionKey.keyID)
            }
            && canonicalUUID(value.resultingAuthorityLineageUUID)
            && value.resultingLineageDigestKeyVersion > 0
            && canonicalStrings(value.selectedResourceIDs, maximumCount: 4096)
            && !value.selectedResourceIDs.isEmpty
    }

    private static func validContribution(
        _ value: ProviderHandoffSourceContributionV1
    ) -> Bool {
        let part = value.part
        let object = value.sourceObjectRecord
        let envelope = value.destinationSealedLineageKeyEnvelope
        return value.schemaVersion
            == ProviderHandoffSourceContributionV1.currentSchemaVersion
            && validIdentifier(value.tokenID)
            && validIdentifier(value.manifestID)
            && value.trustRegistryRevision > 0
            && validDigest(value.exportRequestDigestSHA256)
            && validFingerprint(value.sourceProviderFingerprint)
            && canonicalUUID(value.sourceStateRootUUID)
            && canonicalUUID(value.authorityLineageUUID)
            && value.lineageDigestKeyVersion > 0
            && validExpectation(
                value.sourcePreCommitExpectation,
                role: .source,
                stateRootUUID: value.sourceStateRootUUID
            )
            && validFingerprint(value.destinationProviderFingerprint)
            && canonicalUUID(value.destinationStateRootUUID)
            && validExpectation(
                value.destinationPreCommitExpectation,
                role: .destination,
                stateRootUUID: value.destinationStateRootUUID
            )
            && canonicalDigests(
                value.destinationKeyPossessionProofDigestsSHA256,
                maximumCount: 16
            )
            && canonicalUUID(value.resultingAuthorityLineageUUID)
            && value.resultingLineageDigestKeyVersion > 0
            && part.kind == value.partKind
            && part.schemaVersion > 0
            && part.disposition == .included
            && part.sourceStateRootUUIDs == [value.sourceStateRootUUID]
            && canonicalStrings(part.requiredCapabilities, maximumCount: 4096)
            && (part.payload.protection
                == .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1
                || part.payload.protection
                == .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2)
            && part.payload.destinationEncryption?.destinationKeyPurpose
            == .destinationPayloadEncryption
            && object.schemaVersion
            == ProviderHandoffBundleObjectRecordV1.currentSchemaVersion
            && object.state == .verified
            && object.bundleObjectID == part.payload.bundleObjectID
            && object.transportByteLength == part.payload.transportByteLength
            && object.transportDigestSHA256
            == part.payload.transportDigestSHA256
            && object.receivedByteCount == object.transportByteLength
            && object.pendingChunkOffset == nil
            && object.pendingChunkByteLength == nil
            && object.pendingChunkDigestSHA256 == nil
            && object.objectRevision > 0
            && envelope.sourceStateRootUUID == value.sourceStateRootUUID
            && envelope.authorityLineageUUID == value.authorityLineageUUID
            && envelope.keyVersion == value.lineageDigestKeyVersion
            && envelope.destinationKeyPurpose
            == .destinationLineageKeyEncryption
            && validDigest(value.contributionDigestSHA256)
            && (try? contributionDigest(value))
            == value.contributionDigestSHA256
    }

    private static func validDestinationKey(
        _ key: ProviderHandoffTrustKeyV1,
        purpose: ProviderHandoffKeyPurposeV1,
        request: ProviderHandoffPartExportRequestV1
    ) -> Bool {
        key.algorithm == .x25519V1
            && key.role == .destinationProvider
            && key.purpose == purpose
            && key.providerFingerprint == request.destinationProviderFingerprint
            && key.stateRootUUID == request.destinationStateRootUUID
            && !key.keyID.isEmpty
            && key.rawPublicKey.count == 32
    }

    private static func validExpectation(
        _ value: ProviderHandoffHeaderExpectationV1,
        role: ProviderHandoffRootRoleV1,
        stateRootUUID: String
    ) -> Bool {
        value.schemaVersion == 1
            && value.role == role
            && value.stateRootUUID == stateRootUUID
            && value.expectedHeader.stateRootUUID == stateRootUUID
            && value.abortHeader.stateRootUUID == stateRootUUID
            && validDigest(value.expectedHeaderDigestSHA256)
            && validDigest(value.abortHeaderDigestSHA256)
    }

    private static func validBootstrap(
        _ value: ProviderHandoffPinnedBootstrapKeyV1
    ) -> Bool {
        !value.keyID.isEmpty
            && value.rawPublicKey.count == 32
            && validDigest(value.codeRequirementDigestSHA256)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.utf8.contains(0)
    }

    private static func validFingerprint(_ value: String) -> Bool {
        value.hasPrefix("sha256:")
            && validDigest(String(value.dropFirst(7)))
    }

    private static func validDigest(_ value: String) -> Bool {
        (try? ProviderHandoffDigest.parseSHA256(value).count) == 32
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        guard let identifier = UUID(uuidString: value) else { return false }
        return identifier.uuidString.lowercased() == value
    }

    private static func canonicalStrings(
        _ values: [String],
        maximumCount: Int
    ) -> Bool {
        values.count <= maximumCount
            && Set(values).count == values.count
            && values.allSatisfy {
                !$0.isEmpty
                    && $0.utf8.count <= 512
                    && !$0.utf8.contains(0)
                    && $0.precomposedStringWithCanonicalMapping == $0
            }
            && values
            == values.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
    }

    private static func canonicalDigests(
        _ values: [String],
        maximumCount: Int
    ) -> Bool {
        values.count <= maximumCount
            && Set(values).count == values.count
            && values.allSatisfy(validDigest)
            && values == values.sorted()
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw ProviderHandoffSourceControlCodecError.invalidEncoding
        }
        guard
            !data.isEmpty,
            data.count
            <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        else {
            throw ProviderHandoffSourceControlCodecError.boundsExceeded
        }
        return data
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard
            !data.isEmpty,
            data.count
            <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        else {
            throw ProviderHandoffSourceControlCodecError.boundsExceeded
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderHandoffSourceControlCodecError.invalidEncoding
        }
    }
}
