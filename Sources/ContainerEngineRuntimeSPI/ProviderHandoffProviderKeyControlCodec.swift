//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

public struct ProviderHandoffProviderKeySnapshotRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var expectedProviderFingerprint: String
    public var expectedStateRootUUID: String

    public init(
        expectedProviderFingerprint: String,
        expectedStateRootUUID: String
    ) {
        schemaVersion = 1
        self.expectedProviderFingerprint = expectedProviderFingerprint
        self.expectedStateRootUUID = expectedStateRootUUID
    }
}

public struct ProviderHandoffProviderKeySnapshotV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var context: ProviderHandoffProviderKeyEnrollmentContextV1
    public var trustKeys: [ProviderHandoffTrustKeyV1]

    public init(
        context: ProviderHandoffProviderKeyEnrollmentContextV1,
        trustKeys: [ProviderHandoffTrustKeyV1]
    ) {
        schemaVersion = 1
        self.context = context
        self.trustKeys = trustKeys
    }
}

public struct ProviderHandoffProviderKeyPossessionRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var trustRegistryRevision: UInt64
    public var challenge: ProviderHandoffDestinationPossessionChallengeV1

    public init(
        trustRegistryRevision: UInt64,
        challenge: ProviderHandoffDestinationPossessionChallengeV1
    ) {
        schemaVersion = 1
        self.trustRegistryRevision = trustRegistryRevision
        self.challenge = challenge
    }
}

public enum ProviderHandoffProviderKeyControlCodecError:
    Error,
    Equatable,
    Sendable
{
    case boundsExceeded
    case invalidEncoding
    case invalidRecord
}

/// Canonical JSON framing for provider key enrollment and token-scoped proof.
/// Signature and digest projections remain deterministic CBOR; JSON is only a
/// bounded, byte-canonical private-session transport.
public enum ProviderHandoffProviderKeyControlCodec {
    public static let snapshotRequestMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-provider-key-snapshot-request.v1+json"
    public static let snapshotMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-provider-key-snapshot.v1+json"
    public static let possessionChallengeMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-provider-key-possession-challenge.v1+json"
    public static let possessionProofMediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-provider-key-possession-proof.v1+json"

    public static func encodeSnapshotRequest(
        _ value: ProviderHandoffProviderKeySnapshotRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            validFingerprint(value.expectedProviderFingerprint),
            canonicalUUID(value.expectedStateRootUUID)
        else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidRecord
        }
        return try encode(value)
    }

    public static func decodeSnapshotRequest(
        _ data: Data
    ) throws -> ProviderHandoffProviderKeySnapshotRequestV1 {
        let value: ProviderHandoffProviderKeySnapshotRequestV1 = try decode(data)
        guard try encodeSnapshotRequest(value) == data else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodeSnapshot(
        _ value: ProviderHandoffProviderKeySnapshotV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            !value.trustKeys.isEmpty,
            value.trustKeys.map(\.keyID)
            == value.trustKeys.map(\.keyID).sorted(),
            value.trustKeys.allSatisfy({
                $0.providerFingerprint == value.context.providerFingerprint
                    && $0.stateRootUUID == value.context.stateRootUUID
            })
        else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidRecord
        }
        return try encode(value)
    }

    public static func decodeSnapshot(
        _ data: Data
    ) throws -> ProviderHandoffProviderKeySnapshotV1 {
        let value: ProviderHandoffProviderKeySnapshotV1 = try decode(data)
        guard try encodeSnapshot(value) == data else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodePossessionChallenge(
        _ value: ProviderHandoffProviderKeyPossessionRequestV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            value.trustRegistryRevision > 0,
            !value.challenge.proofID.isEmpty,
            !value.challenge.tokenID.isEmpty,
            !value.challenge.manifestID.isEmpty,
            validFingerprint(value.challenge.destinationProviderFingerprint),
            canonicalUUID(value.challenge.destinationStateRootUUID),
            [.destinationPayloadEncryption, .destinationLineageKeyEncryption]
            .contains(value.challenge.destinationKeyPurpose),
            !value.challenge.destinationKeyID.isEmpty,
            value.challenge.challengeEphemeralPublicKey.count == 32,
            value.challenge.challengeNonce.count == 24,
            (try? ProviderHandoffDigest.parseSHA256(
                value.challenge.challengeAssociatedDataDigestSHA256
            )) != nil,
            value.challenge.challengeCiphertext.count == 48
        else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidRecord
        }
        return try encode(value)
    }

    public static func decodePossessionChallenge(
        _ data: Data
    ) throws -> ProviderHandoffProviderKeyPossessionRequestV1 {
        let value: ProviderHandoffProviderKeyPossessionRequestV1 = try decode(
            data
        )
        guard try encodePossessionChallenge(value) == data else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidEncoding
        }
        return value
    }

    public static func encodePossessionProof(
        _ value: ProviderHandoffDestinationKeyPossessionProofV1
    ) throws -> Data {
        guard
            value.schemaVersion == 1,
            !value.proofID.isEmpty,
            !value.tokenID.isEmpty,
            !value.manifestID.isEmpty,
            validFingerprint(value.destinationProviderFingerprint),
            canonicalUUID(value.destinationStateRootUUID),
            [.destinationPayloadEncryption, .destinationLineageKeyEncryption]
            .contains(value.destinationKeyPurpose),
            !value.destinationKeyID.isEmpty,
            value.challengeEphemeralPublicKey.count == 32,
            value.challengeNonce.count == 24,
            (try? ProviderHandoffDigest.parseSHA256(
                value.challengeAssociatedDataDigestSHA256
            )) != nil,
            value.challengeCiphertext.count == 48,
            (try? ProviderHandoffDigest.parseSHA256(
                value.responseDigestSHA256
            )) != nil,
            value.destinationSignature.purpose
            == .destinationPossessionSigning,
            value.destinationSignature.signerRole == .destinationProvider,
            value.destinationSignature.providerFingerprint
            == value.destinationProviderFingerprint,
            value.destinationSignature.stateRootUUID
            == value.destinationStateRootUUID,
            value.destinationSignature.signature.count == 64
        else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidRecord
        }
        return try encode(value)
    }

    public static func decodePossessionProof(
        _ data: Data
    ) throws -> ProviderHandoffDestinationKeyPossessionProofV1 {
        let value: ProviderHandoffDestinationKeyPossessionProofV1 = try decode(
            data
        )
        guard try encodePossessionProof(value) == data else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidEncoding
        }
        return value
    }

    private static func validFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        return
            (try? ProviderHandoffDigest.parseSHA256(
                String(value.dropFirst(7))
            )) != nil
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            guard
                data.count
                <= ContainerEngineProviderControlMetadataLimits
                .maximumBodyBytes
            else {
                throw ProviderHandoffProviderKeyControlCodecError.boundsExceeded
            }
            return data
        } catch let error as ProviderHandoffProviderKeyControlCodecError {
            throw error
        } catch {
            throw ProviderHandoffProviderKeyControlCodecError.invalidEncoding
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard
            !data.isEmpty,
            data.count
            <= ContainerEngineProviderControlMetadataLimits.maximumBodyBytes
        else {
            throw ProviderHandoffProviderKeyControlCodecError.boundsExceeded
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderHandoffProviderKeyControlCodecError.invalidEncoding
        }
    }
}

public enum ProviderHandoffProviderKeySnapshotValidator {
    public static func validate(
        _ snapshot: ProviderHandoffProviderKeySnapshotV1,
        expectedProviderFingerprint: String,
        expectedStateRootUUID: String,
        peerCodeIdentity: ProviderHandoffCodeIdentityV1,
        providerRegistrationDigestSHA256: String,
        atUnixSeconds: UInt64
    ) throws -> [ProviderHandoffTrustKeyV1] {
        let context = snapshot.context
        guard
            snapshot.schemaVersion == 1,
            context.providerFingerprint == expectedProviderFingerprint,
            context.stateRootUUID == expectedStateRootUUID,
            context.owningBundleIdentifier
            == peerCodeIdentity.signingIdentifier,
            context.codeRequirementDigestSHA256
            == peerCodeIdentity.designatedRequirementDigestSHA256,
            context.teamIdentifier == peerCodeIdentity.teamIdentifier,
            context.providerRegistrationDigestSHA256
            == providerRegistrationDigestSHA256,
            context.enrolledAtUnixSeconds >= context.notBeforeUnixSeconds,
            context.enrolledAtUnixSeconds <= context.notAfterUnixSeconds,
            atUnixSeconds >= context.notBeforeUnixSeconds,
            atUnixSeconds <= context.notAfterUnixSeconds,
            snapshot.trustKeys.count == 5,
            snapshot.trustKeys.map(\.keyID)
            == snapshot.trustKeys.map(\.keyID).sorted()
        else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidRecord
        }
        let expected:
            [ProviderHandoffKeyPurposeV1: (
                ProviderHandoffPublicKeyAlgorithmV1,
                ProviderHandoffKeyRoleV1
            )] = [
                .sourceManifestSigning: (.ed25519V1, .sourceProvider),
                .lineageKeyEnvelopeSigning: (.ed25519V1, .sourceProvider),
                .destinationPossessionSigning: (
                    .ed25519V1,
                    .destinationProvider
                ),
                .destinationPayloadEncryption: (
                    .x25519V1,
                    .destinationProvider
                ),
                .destinationLineageKeyEncryption: (
                    .x25519V1,
                    .destinationProvider
                )
            ]
        guard Set(snapshot.trustKeys.map(\.purpose)) == Set(expected.keys) else {
            throw ProviderHandoffProviderKeyControlCodecError.invalidRecord
        }
        for key in snapshot.trustKeys {
            guard
                let specification = expected[key.purpose],
                key.algorithm == specification.0,
                key.role == specification.1,
                key.providerFingerprint == expectedProviderFingerprint,
                key.stateRootUUID == expectedStateRootUUID,
                key.provenance.owningBundleIdentifier
                == context.owningBundleIdentifier,
                key.provenance.codeRequirementDigestSHA256
                == context.codeRequirementDigestSHA256,
                key.provenance.teamIdentifier == context.teamIdentifier,
                key.provenance.providerRegistrationDigestSHA256
                == providerRegistrationDigestSHA256,
                key.provenance.enrolledAtUnixSeconds
                == context.enrolledAtUnixSeconds,
                key.notBeforeUnixSeconds == context.notBeforeUnixSeconds,
                key.notAfterUnixSeconds == context.notAfterUnixSeconds,
                key.revokedAtUnixSeconds == nil,
                key.revocationReason == nil
            else {
                throw ProviderHandoffProviderKeyControlCodecError.invalidRecord
            }
            try ProviderHandoffTrustRegistryValidator.validateEnrollmentKey(key)
        }
        return snapshot.trustKeys
    }
}
