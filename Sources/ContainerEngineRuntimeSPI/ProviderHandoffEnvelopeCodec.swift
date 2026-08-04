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

import Foundation

public struct ProviderHandoffEnvelopeLineageKeyV1: Equatable, Sendable {
    public var sourceStateRootUUID: String?
    public var authorityLineageUUID: String
    public var keyVersion: UInt64
    public var rawHMACSHA256Key: Data

    public init(
        sourceStateRootUUID: String?,
        authorityLineageUUID: String,
        keyVersion: UInt64,
        rawHMACSHA256Key: Data
    ) {
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.keyVersion = keyVersion
        self.rawHMACSHA256Key = rawHMACSHA256Key
    }
}

public struct ProviderHandoffPendingPossessionChallengeV1: Equatable, Sendable {
    public var proofID: String
    public var tokenID: String
    public var manifestID: String
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var destinationKeyPurpose: ProviderHandoffKeyPurposeV1
    public var destinationKeyID: String
    public var challengeEphemeralPublicKey: Data
    public var challengeNonce: Data
    public var challengeAssociatedDataDigestSHA256: String
    public var challengeCiphertext: Data
    public var challengePlaintext: Data

    public init(
        proofID: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyPurpose: ProviderHandoffKeyPurposeV1,
        destinationKeyID: String,
        challengeEphemeralPublicKey: Data,
        challengeNonce: Data,
        challengeAssociatedDataDigestSHA256: String,
        challengeCiphertext: Data,
        challengePlaintext: Data
    ) {
        self.proofID = proofID
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.destinationKeyPurpose = destinationKeyPurpose
        self.destinationKeyID = destinationKeyID
        self.challengeEphemeralPublicKey = challengeEphemeralPublicKey
        self.challengeNonce = challengeNonce
        self.challengeAssociatedDataDigestSHA256 = challengeAssociatedDataDigestSHA256
        self.challengeCiphertext = challengeCiphertext
        self.challengePlaintext = challengePlaintext
    }

    public var transportChallenge: ProviderHandoffDestinationPossessionChallengeV1 {
        ProviderHandoffDestinationPossessionChallengeV1(
            proofID: proofID,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: destinationKeyPurpose,
            destinationKeyID: destinationKeyID,
            challengeEphemeralPublicKey: challengeEphemeralPublicKey,
            challengeNonce: challengeNonce,
            challengeAssociatedDataDigestSHA256:
                challengeAssociatedDataDigestSHA256,
            challengeCiphertext: challengeCiphertext
        )
    }
}

/// Destination-visible possession challenge. The gateway-only plaintext is
/// deliberately absent and therefore cannot cross the provider session.
public struct ProviderHandoffDestinationPossessionChallengeV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var proofID: String
    public var tokenID: String
    public var manifestID: String
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var destinationKeyPurpose: ProviderHandoffKeyPurposeV1
    public var destinationKeyID: String
    public var challengeEphemeralPublicKey: Data
    public var challengeNonce: Data
    public var challengeAssociatedDataDigestSHA256: String
    public var challengeCiphertext: Data

    public init(
        proofID: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyPurpose: ProviderHandoffKeyPurposeV1,
        destinationKeyID: String,
        challengeEphemeralPublicKey: Data,
        challengeNonce: Data,
        challengeAssociatedDataDigestSHA256: String,
        challengeCiphertext: Data
    ) {
        schemaVersion = 1
        self.proofID = proofID
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.destinationKeyPurpose = destinationKeyPurpose
        self.destinationKeyID = destinationKeyID
        self.challengeEphemeralPublicKey = challengeEphemeralPublicKey
        self.challengeNonce = challengeNonce
        self.challengeAssociatedDataDigestSHA256 =
            challengeAssociatedDataDigestSHA256
        self.challengeCiphertext = challengeCiphertext
    }
}

public struct ProviderHandoffValidatedPossessionProofV1: Sendable {
    public let proof: ProviderHandoffDestinationKeyPossessionProofV1
    public let proofRecordDigestSHA256: String

    internal init(
        proof: ProviderHandoffDestinationKeyPossessionProofV1,
        proofRecordDigestSHA256: String
    ) {
        self.proof = proof
        self.proofRecordDigestSHA256 = proofRecordDigestSHA256
    }
}

public enum ProviderHandoffEnvelopeCodecError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidAssociatedData
    case invalidEnvelope
    case invalidLineageKey
    case invalidPossessionProof

    public var description: String {
        switch self {
        case .invalidAssociatedData:
            "provider handoff envelope associated data is invalid"
        case .invalidEnvelope:
            "provider handoff lineage-key envelope is invalid"
        case .invalidLineageKey:
            "provider handoff lineage key is invalid"
        case .invalidPossessionProof:
            "provider handoff destination-key possession proof is invalid"
        }
    }
}

public enum ProviderHandoffLineageKeyEnvelopeCodec {
    public static let mediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-lineage-key.v1+cbor"

    public static func prepare(
        _ lineageKey: ProviderHandoffEnvelopeLineageKeyV1,
        envelopeID: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce: Data,
        signerKeyID: String,
        signerRole: ProviderHandoffKeyRoleV1,
        signerProviderFingerprint: String?,
        signerStateRootUUID: String?,
        trustRegistryRevision: UInt64,
        signerPrivateKey: Data,
        ephemeralPrivateKey: Data? = nil
    ) throws -> DestinationSealedLineageKeyEnvelopeV1 {
        try validateLineageKey(lineageKey)
        guard !envelopeID.isEmpty, nonce.count == 24 else {
            throw ProviderHandoffEnvelopeCodecError.invalidEnvelope
        }
        if let source = lineageKey.sourceStateRootUUID {
            guard
                signerRole == .sourceProvider,
                signerStateRootUUID == source,
                signerProviderFingerprint != nil
            else {
                throw ProviderHandoffEnvelopeCodecError.invalidEnvelope
            }
        } else {
            guard
                signerRole == .gatewayCoordinator,
                signerProviderFingerprint == nil,
                signerStateRootUUID == nil
            else {
                throw ProviderHandoffEnvelopeCodecError.invalidEnvelope
            }
        }
        let plaintext = try encode(lineageKey)
        let ephemeral =
            ephemeralPrivateKey
            ?? ProviderHandoffCrypto.generateX25519PrivateKey()
        let ephemeralPublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: ephemeral
        )
        let associated = associatedData(
            lineageKey: lineageKey,
            envelopeID: envelopeID,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            plaintextByteLength: UInt64(plaintext.count)
        )
        let associatedDigest = try ProviderHandoffPayloadCodec.associatedDataDigest(
            associated
        )
        let box = try ProviderHandoffCrypto.seal(
            plaintext,
            destinationPublicKey: destinationPublicKey,
            nonce: nonce,
            salt: try hkdfSalt(associated),
            info: hkdfInfo(associatedDigest),
            associatedData: associatedDigest,
            ephemeralPrivateKey: ephemeral
        )
        var envelope = DestinationSealedLineageKeyEnvelopeV1(
            envelopeID: envelopeID,
            sourceStateRootUUID: lineageKey.sourceStateRootUUID,
            authorityLineageUUID: lineageKey.authorityLineageUUID,
            keyVersion: lineageKey.keyVersion,
            destinationKeyPurpose: .destinationLineageKeyEncryption,
            destinationKeyID: destinationKeyID,
            encryptionAlgorithm: .x25519HKDFSHA256XChaCha20Poly1305V1,
            ephemeralPublicKey: box.ephemeralPublicKey,
            nonce: box.nonce,
            canonicalPlaintextByteLength: UInt64(plaintext.count),
            associatedDataDigestSHA256: ProviderHandoffDigest.hex(associatedDigest),
            ciphertext: box.ciphertext,
            envelopeSignature: placeholderSignature()
        )
        let digest = try ProviderHandoffProjections.lineageKeyEnvelopeDigest(envelope)
        envelope.envelopeSignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: digest,
            purpose: .lineageKeyEnvelopeSigning,
            signerKeyID: signerKeyID,
            signerRole: signerRole,
            providerFingerprint: signerProviderFingerprint,
            stateRootUUID: signerStateRootUUID,
            trustRegistryRevision: trustRegistryRevision,
            privateKey: signerPrivateKey
        )
        return envelope
    }

    public static func verify(
        _ envelope: DestinationSealedLineageKeyEnvelopeV1,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        sourceProviderFingerprint: String?,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws {
        let signerRole: ProviderHandoffKeyRoleV1
        let signerProvider: String?
        let signerRoot: String?
        if let source = envelope.sourceStateRootUUID {
            guard let sourceProviderFingerprint else {
                throw ProviderHandoffEnvelopeCodecError.invalidEnvelope
            }
            signerRole = .sourceProvider
            signerProvider = sourceProviderFingerprint
            signerRoot = source
        } else {
            signerRole = .gatewayCoordinator
            signerProvider = nil
            signerRoot = nil
        }
        let digest = try ProviderHandoffProjections.lineageKeyEnvelopeDigest(envelope)
        try trustRegistry.verify(
            envelope.envelopeSignature,
            expectedPurpose: .lineageKeyEnvelopeSigning,
            expectedRole: signerRole,
            providerFingerprint: signerProvider,
            stateRootUUID: signerRoot,
            projectionDigestSHA256: digest,
            atUnixSeconds: atUnixSeconds
        )
        let associated = associatedData(
            lineageKey: ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: envelope.sourceStateRootUUID,
                authorityLineageUUID: envelope.authorityLineageUUID,
                keyVersion: envelope.keyVersion,
                rawHMACSHA256Key: Data(repeating: 0, count: 32)
            ),
            envelopeID: envelope.envelopeID,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyID: envelope.destinationKeyID,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            nonce: envelope.nonce,
            plaintextByteLength: envelope.canonicalPlaintextByteLength
        )
        guard
            envelope.encryptionAlgorithm
                == .x25519HKDFSHA256XChaCha20Poly1305V1,
            envelope.destinationKeyPurpose == .destinationLineageKeyEncryption,
            !envelope.envelopeID.isEmpty,
            envelope.canonicalPlaintextByteLength > 0,
            envelope.ciphertext.count
                == Int(envelope.canonicalPlaintextByteLength) + 16,
            ProviderHandoffDigest.hex(
                try ProviderHandoffPayloadCodec.associatedDataDigest(associated)
            ) == envelope.associatedDataDigestSHA256
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidEnvelope
        }
        _ = try trustRegistry.key(
            identifier: envelope.destinationKeyID,
            purpose: .destinationLineageKeyEncryption,
            role: .destinationProvider,
            providerFingerprint: destinationProviderFingerprint,
            stateRootUUID: destinationStateRootUUID,
            atUnixSeconds: atUnixSeconds
        )
    }

    public static func open(
        _ envelope: DestinationSealedLineageKeyEnvelopeV1,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        sourceProviderFingerprint: String?,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64,
        destinationPrivateKey: Data
    ) throws -> ProviderHandoffEnvelopeLineageKeyV1 {
        try verify(
            envelope,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            sourceProviderFingerprint: sourceProviderFingerprint,
            trustRegistry: trustRegistry,
            atUnixSeconds: atUnixSeconds
        )
        let outer = ProviderHandoffEnvelopeLineageKeyV1(
            sourceStateRootUUID: envelope.sourceStateRootUUID,
            authorityLineageUUID: envelope.authorityLineageUUID,
            keyVersion: envelope.keyVersion,
            rawHMACSHA256Key: Data(repeating: 0, count: 32)
        )
        let associated = associatedData(
            lineageKey: outer,
            envelopeID: envelope.envelopeID,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyID: envelope.destinationKeyID,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            nonce: envelope.nonce,
            plaintextByteLength: envelope.canonicalPlaintextByteLength
        )
        let associatedDigest = try ProviderHandoffPayloadCodec.associatedDataDigest(
            associated
        )
        let plaintext = try ProviderHandoffCrypto.open(
            ProviderHandoffXChaChaSealedBox(
                ephemeralPublicKey: envelope.ephemeralPublicKey,
                nonce: envelope.nonce,
                ciphertext: envelope.ciphertext
            ),
            destinationPrivateKey: destinationPrivateKey,
            salt: try hkdfSalt(associated),
            info: hkdfInfo(associatedDigest),
            associatedData: associatedDigest
        )
        guard UInt64(plaintext.count) == envelope.canonicalPlaintextByteLength else {
            throw ProviderHandoffEnvelopeCodecError.invalidEnvelope
        }
        let decoded = try decode(plaintext)
        guard
            decoded.sourceStateRootUUID == envelope.sourceStateRootUUID,
            decoded.authorityLineageUUID == envelope.authorityLineageUUID,
            decoded.keyVersion == envelope.keyVersion
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidEnvelope
        }
        return decoded
    }

    private static func encode(
        _ value: ProviderHandoffEnvelopeLineageKeyV1
    ) throws -> Data {
        try ProviderHandoffCanonicalCBOR.encode(
            .map([
                .init("authorityLineageUUID", .textString(value.authorityLineageUUID)),
                .init("keyVersion", .unsigned(value.keyVersion)),
                .init("rawLineageHMACSHA256Key", .byteString(value.rawHMACSHA256Key)),
                .init("schemaVersion", .unsigned(1)),
                .init("sourceStateRootUUID", .optional(value.sourceStateRootUUID)),
            ]))
    }

    private static func decode(
        _ data: Data
    ) throws -> ProviderHandoffEnvelopeLineageKeyV1 {
        let decoded = try ProviderHandoffCanonicalCBOR.decode(data)
        guard case .map(let entries) = decoded else {
            throw ProviderHandoffEnvelopeCodecError.invalidLineageKey
        }
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        guard
            Set(values.keys) == [
                "authorityLineageUUID",
                "keyVersion",
                "rawLineageHMACSHA256Key",
                "schemaVersion",
                "sourceStateRootUUID",
            ],
            case .unsigned(1)? = values["schemaVersion"],
            case .textString(let lineage)? = values["authorityLineageUUID"],
            case .unsigned(let version)? = values["keyVersion"],
            case .byteString(let key)? = values["rawLineageHMACSHA256Key"]
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidLineageKey
        }
        let source: String?
        switch values["sourceStateRootUUID"] {
        case .null?:
            source = nil
        case .textString(let value)?:
            source = value
        default:
            throw ProviderHandoffEnvelopeCodecError.invalidLineageKey
        }
        let result = ProviderHandoffEnvelopeLineageKeyV1(
            sourceStateRootUUID: source,
            authorityLineageUUID: lineage,
            keyVersion: version,
            rawHMACSHA256Key: key
        )
        try validateLineageKey(result)
        return result
    }

    private static func validateLineageKey(
        _ value: ProviderHandoffEnvelopeLineageKeyV1
    ) throws {
        guard
            value.sourceStateRootUUID.map(canonicalUUID) != false,
            canonicalUUID(value.authorityLineageUUID),
            value.keyVersion > 0,
            value.rawHMACSHA256Key.count == 32
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidLineageKey
        }
    }

    private static func associatedData(
        lineageKey: ProviderHandoffEnvelopeLineageKeyV1,
        envelopeID: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        ephemeralPublicKey: Data,
        nonce: Data,
        plaintextByteLength: UInt64
    ) -> ProviderHandoffAEADAssociatedDataV1 {
        ProviderHandoffAEADAssociatedDataV1(
            objectKind: .lineageKeyEnvelope,
            tokenID: tokenID,
            manifestID: manifestID,
            objectLocalID: envelopeID,
            partKind: nil,
            mediaType: mediaType,
            payloadSchemaVersion: 1,
            canonicalPlaintextByteLength: plaintextByteLength,
            canonicalContentDigest: nil,
            sourceStateRootUUID: lineageKey.sourceStateRootUUID,
            authorityLineageUUID: lineageKey.authorityLineageUUID,
            lineageDigestKeyVersion: lineageKey.keyVersion,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: .destinationLineageKeyEncryption,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce
        )
    }

    private static func placeholderSignature() -> ProviderHandoffSignatureV1 {
        ProviderHandoffSignatureV1(
            purpose: .lineageKeyEnvelopeSigning,
            signerKeyID: "pending",
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: 1,
            signedProjectionDigestSHA256: String(repeating: "0", count: 64),
            signature: Data(repeating: 0, count: 64)
        )
    }
}

public enum ProviderHandoffPossessionProofCodec {
    public static func prepareChallenge(
        proofID: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyPurpose: ProviderHandoffKeyPurposeV1,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce: Data,
        challengePlaintext: Data? = nil,
        ephemeralPrivateKey: Data? = nil
    ) throws -> ProviderHandoffPendingPossessionChallengeV1 {
        guard
            !proofID.isEmpty,
            [.destinationPayloadEncryption, .destinationLineageKeyEncryption]
                .contains(destinationKeyPurpose),
            nonce.count == 24
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidPossessionProof
        }
        let plaintext = challengePlaintext ?? randomBytes(count: 32)
        guard plaintext.count == 32 else {
            throw ProviderHandoffEnvelopeCodecError.invalidPossessionProof
        }
        let ephemeral =
            ephemeralPrivateKey
            ?? ProviderHandoffCrypto.generateX25519PrivateKey()
        let ephemeralPublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: ephemeral
        )
        let associated = associatedData(
            proofID: proofID,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: destinationKeyPurpose,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce
        )
        let associatedDigest = try ProviderHandoffPayloadCodec.associatedDataDigest(
            associated
        )
        let box = try ProviderHandoffCrypto.seal(
            plaintext,
            destinationPublicKey: destinationPublicKey,
            nonce: nonce,
            salt: try hkdfSalt(associated),
            info: hkdfInfo(associatedDigest),
            associatedData: associatedDigest,
            ephemeralPrivateKey: ephemeral
        )
        return ProviderHandoffPendingPossessionChallengeV1(
            proofID: proofID,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: destinationKeyPurpose,
            destinationKeyID: destinationKeyID,
            challengeEphemeralPublicKey: box.ephemeralPublicKey,
            challengeNonce: box.nonce,
            challengeAssociatedDataDigestSHA256: ProviderHandoffDigest.hex(associatedDigest),
            challengeCiphertext: box.ciphertext,
            challengePlaintext: plaintext
        )
    }

    public static func respond(
        to challenge: ProviderHandoffPendingPossessionChallengeV1,
        destinationPrivateKey: Data,
        possessionSigningKeyID: String,
        trustRegistryRevision: UInt64,
        possessionSigningPrivateKey: Data
    ) throws -> ProviderHandoffDestinationKeyPossessionProofV1 {
        try respond(
            to: challenge.transportChallenge,
            destinationPrivateKey: destinationPrivateKey,
            possessionSigningKeyID: possessionSigningKeyID,
            trustRegistryRevision: trustRegistryRevision,
            possessionSigningPrivateKey: possessionSigningPrivateKey
        )
    }

    public static func respond(
        to challenge: ProviderHandoffDestinationPossessionChallengeV1,
        destinationPrivateKey: Data,
        possessionSigningKeyID: String,
        trustRegistryRevision: UInt64,
        possessionSigningPrivateKey: Data
    ) throws -> ProviderHandoffDestinationKeyPossessionProofV1 {
        let associated = associatedData(challenge)
        let associatedDigest = try ProviderHandoffPayloadCodec.associatedDataDigest(
            associated
        )
        guard
            ProviderHandoffDigest.hex(associatedDigest)
                == challenge.challengeAssociatedDataDigestSHA256
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidAssociatedData
        }
        let plaintext = try ProviderHandoffCrypto.open(
            ProviderHandoffXChaChaSealedBox(
                ephemeralPublicKey: challenge.challengeEphemeralPublicKey,
                nonce: challenge.challengeNonce,
                ciphertext: challenge.challengeCiphertext
            ),
            destinationPrivateKey: destinationPrivateKey,
            salt: try hkdfSalt(associated),
            info: hkdfInfo(associatedDigest),
            associatedData: associatedDigest
        )
        var proof = ProviderHandoffDestinationKeyPossessionProofV1(
            proofID: challenge.proofID,
            tokenID: challenge.tokenID,
            manifestID: challenge.manifestID,
            destinationProviderFingerprint: challenge.destinationProviderFingerprint,
            destinationStateRootUUID: challenge.destinationStateRootUUID,
            destinationKeyPurpose: challenge.destinationKeyPurpose,
            destinationKeyID: challenge.destinationKeyID,
            challengeEphemeralPublicKey: challenge.challengeEphemeralPublicKey,
            challengeNonce: challenge.challengeNonce,
            challengeAssociatedDataDigestSHA256: challenge.challengeAssociatedDataDigestSHA256,
            challengeCiphertext: challenge.challengeCiphertext,
            responseDigestSHA256: String(repeating: "0", count: 64),
            destinationSignature: placeholderPossessionSignature()
        )
        proof.responseDigestSHA256 =
            try ProviderHandoffProjections
            .destinationPossessionResponseDigest(
                proof,
                challengePlaintext: plaintext
            )
        let recordDigest =
            try ProviderHandoffProjections
            .destinationPossessionProofRecordDigest(proof)
        proof.destinationSignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: recordDigest,
            purpose: .destinationPossessionSigning,
            signerKeyID: possessionSigningKeyID,
            signerRole: .destinationProvider,
            providerFingerprint: challenge.destinationProviderFingerprint,
            stateRootUUID: challenge.destinationStateRootUUID,
            trustRegistryRevision: trustRegistryRevision,
            privateKey: possessionSigningPrivateKey
        )
        return proof
    }

    public static func verify(
        _ proof: ProviderHandoffDestinationKeyPossessionProofV1,
        challenge: ProviderHandoffPendingPossessionChallengeV1,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffValidatedPossessionProofV1 {
        guard
            proof.schemaVersion == 1,
            proof.proofID == challenge.proofID,
            proof.tokenID == challenge.tokenID,
            proof.manifestID == challenge.manifestID,
            proof.destinationProviderFingerprint
                == challenge.destinationProviderFingerprint,
            proof.destinationStateRootUUID == challenge.destinationStateRootUUID,
            proof.destinationKeyPurpose == challenge.destinationKeyPurpose,
            proof.destinationKeyID == challenge.destinationKeyID,
            proof.challengeEphemeralPublicKey
                == challenge.challengeEphemeralPublicKey,
            proof.challengeNonce == challenge.challengeNonce,
            proof.challengeAssociatedDataDigestSHA256
                == challenge.challengeAssociatedDataDigestSHA256,
            proof.challengeCiphertext == challenge.challengeCiphertext,
            ProviderHandoffDigest.constantTimeEqual(
                try ProviderHandoffDigest.parseSHA256(proof.responseDigestSHA256),
                try ProviderHandoffDigest.parseSHA256(
                    ProviderHandoffProjections.destinationPossessionResponseDigest(
                        proof,
                        challengePlaintext: challenge.challengePlaintext
                    )
                )
            )
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidPossessionProof
        }
        return try validateDestinationReceipt(
            proof,
            trustRegistry: trustRegistry,
            atUnixSeconds: atUnixSeconds
        )
    }

    /// Revalidates a proof that this destination created and durably recorded
    /// before returning it to the gateway. The gateway separately used its
    /// retained plaintext to validate the response digest; the destination
    /// verifies its own signature, encryption-key binding, and AEAD metadata.
    public static func validateDestinationReceipt(
        _ proof: ProviderHandoffDestinationKeyPossessionProofV1,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffValidatedPossessionProofV1 {
        let challenge = ProviderHandoffDestinationPossessionChallengeV1(
            proofID: proof.proofID,
            tokenID: proof.tokenID,
            manifestID: proof.manifestID,
            destinationProviderFingerprint:
                proof.destinationProviderFingerprint,
            destinationStateRootUUID: proof.destinationStateRootUUID,
            destinationKeyPurpose: proof.destinationKeyPurpose,
            destinationKeyID: proof.destinationKeyID,
            challengeEphemeralPublicKey:
                proof.challengeEphemeralPublicKey,
            challengeNonce: proof.challengeNonce,
            challengeAssociatedDataDigestSHA256:
                proof.challengeAssociatedDataDigestSHA256,
            challengeCiphertext: proof.challengeCiphertext
        )
        let associatedDigest =
            try ProviderHandoffPayloadCodec
            .associatedDataDigest(associatedData(challenge))
        guard
            proof.schemaVersion == 1,
            !proof.proofID.isEmpty,
            !proof.tokenID.isEmpty,
            !proof.manifestID.isEmpty,
            proof.challengeCiphertext.count == 48,
            ProviderHandoffDigest.hex(associatedDigest)
                == proof.challengeAssociatedDataDigestSHA256,
            (try ProviderHandoffDigest.parseSHA256(
                proof.responseDigestSHA256
            )).count == 32
        else {
            throw ProviderHandoffEnvelopeCodecError.invalidPossessionProof
        }
        _ = try trustRegistry.key(
            identifier: proof.destinationKeyID,
            purpose: proof.destinationKeyPurpose,
            role: .destinationProvider,
            providerFingerprint: proof.destinationProviderFingerprint,
            stateRootUUID: proof.destinationStateRootUUID,
            atUnixSeconds: atUnixSeconds
        )
        let recordDigest =
            try ProviderHandoffProjections
            .destinationPossessionProofRecordDigest(proof)
        try trustRegistry.verify(
            proof.destinationSignature,
            expectedPurpose: .destinationPossessionSigning,
            expectedRole: .destinationProvider,
            providerFingerprint: proof.destinationProviderFingerprint,
            stateRootUUID: proof.destinationStateRootUUID,
            projectionDigestSHA256: recordDigest,
            atUnixSeconds: atUnixSeconds
        )
        return ProviderHandoffValidatedPossessionProofV1(
            proof: proof,
            proofRecordDigestSHA256: recordDigest
        )
    }

    private static func associatedData(
        _ value: ProviderHandoffPendingPossessionChallengeV1
    ) -> ProviderHandoffAEADAssociatedDataV1 {
        associatedData(
            proofID: value.proofID,
            tokenID: value.tokenID,
            manifestID: value.manifestID,
            destinationProviderFingerprint: value.destinationProviderFingerprint,
            destinationStateRootUUID: value.destinationStateRootUUID,
            destinationKeyPurpose: value.destinationKeyPurpose,
            destinationKeyID: value.destinationKeyID,
            ephemeralPublicKey: value.challengeEphemeralPublicKey,
            nonce: value.challengeNonce
        )
    }

    private static func associatedData(
        _ value: ProviderHandoffDestinationPossessionChallengeV1
    ) -> ProviderHandoffAEADAssociatedDataV1 {
        associatedData(
            proofID: value.proofID,
            tokenID: value.tokenID,
            manifestID: value.manifestID,
            destinationProviderFingerprint:
                value.destinationProviderFingerprint,
            destinationStateRootUUID: value.destinationStateRootUUID,
            destinationKeyPurpose: value.destinationKeyPurpose,
            destinationKeyID: value.destinationKeyID,
            ephemeralPublicKey: value.challengeEphemeralPublicKey,
            nonce: value.challengeNonce
        )
    }

    private static func associatedData(
        proofID: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyPurpose: ProviderHandoffKeyPurposeV1,
        destinationKeyID: String,
        ephemeralPublicKey: Data,
        nonce: Data
    ) -> ProviderHandoffAEADAssociatedDataV1 {
        ProviderHandoffAEADAssociatedDataV1(
            objectKind: .destinationPossessionChallenge,
            tokenID: tokenID,
            manifestID: manifestID,
            objectLocalID: proofID,
            partKind: nil,
            mediaType: nil,
            payloadSchemaVersion: nil,
            canonicalPlaintextByteLength: 32,
            canonicalContentDigest: nil,
            sourceStateRootUUID: nil,
            authorityLineageUUID: nil,
            lineageDigestKeyVersion: nil,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: destinationKeyPurpose,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce
        )
    }

    private static func placeholderPossessionSignature()
        -> ProviderHandoffSignatureV1
    {
        ProviderHandoffSignatureV1(
            purpose: .destinationPossessionSigning,
            signerKeyID: "pending",
            signerRole: .destinationProvider,
            providerFingerprint: "pending",
            stateRootUUID: "00000000-0000-4000-8000-000000000000",
            trustRegistryRevision: 1,
            signedProjectionDigestSHA256: String(repeating: "0", count: 64),
            signature: Data(repeating: 0, count: 64)
        )
    }
}

private func hkdfSalt(
    _ associated: ProviderHandoffAEADAssociatedDataV1
) throws -> Data {
    try ProviderHandoffDigest.domainBytes(
        "container-handoff-hkdf-salt-v1",
        projection: .map([
            .init("destinationKeyID", .textString(associated.destinationKeyID)),
            .init("destinationKeyPurpose", .textString(associated.destinationKeyPurpose.rawValue)),
            .init("destinationProviderFingerprint", .textString(associated.destinationProviderFingerprint)),
            .init("destinationStateRootUUID", .textString(associated.destinationStateRootUUID)),
            .init("manifestID", .textString(associated.manifestID)),
            .init("objectKind", .textString(associated.objectKind.rawValue)),
            .init("objectLocalID", .textString(associated.objectLocalID)),
            .init("tokenID", .textString(associated.tokenID)),
        ])
    )
}

private func hkdfInfo(_ associatedDataDigest: Data) -> Data {
    var info = Data("container-handoff-x25519-xchacha20poly1305-key-v1".utf8)
    info.append(0)
    info.append(associatedDataDigest)
    return info
}

private func canonicalUUID(_ value: String) -> Bool {
    guard let identifier = UUID(uuidString: value) else { return false }
    return identifier.uuidString.lowercased() == value
}

private func randomBytes(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data(
        (0..<count).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
}
