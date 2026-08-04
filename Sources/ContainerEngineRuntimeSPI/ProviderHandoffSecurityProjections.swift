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

extension ProviderHandoffProjections {
    public static func trustRegistryDigest(
        _ registry: ProviderHandoffTrustRegistryV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-trust-registry-v1",
            projection: .map([
                .init("issuedAtUnixSeconds", .unsigned(registry.issuedAtUnixSeconds)),
                .init("keys", .array(try registry.keys.map(trustKey))),
                .init("registryRevision", .unsigned(registry.registryRevision)),
                .init("schemaVersion", .unsigned(UInt64(registry.schemaVersion))),
            ])
        )
    }

    public static func enrollmentProofDigest(
        _ key: ProviderHandoffTrustKeyV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-ed25519-enrollment-v1",
            projection: .map([
                .init("algorithm", .textString(key.algorithm.rawValue)),
                .init("keyID", .textString(key.keyID)),
                .init("provenance", try provenance(key.provenance, includeProof: false)),
                .init("providerFingerprint", .optional(key.providerFingerprint)),
                .init("purpose", .textString(key.purpose.rawValue)),
                .init("rawPublicKey", .byteString(key.rawPublicKey)),
                .init("role", .textString(key.role.rawValue)),
                .init("stateRootUUID", .optional(key.stateRootUUID)),
            ])
        )
    }

    public static func lineageKeyEnvelopeDigest(
        _ envelope: DestinationSealedLineageKeyEnvelopeV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-lineage-key-envelope-v1",
            projection: try lineageEnvelope(envelope, includeSignature: false)
        )
    }

    public static func destinationPossessionResponseDigest(
        _ proof: ProviderHandoffDestinationKeyPossessionProofV1,
        challengePlaintext: Data
    ) throws -> String {
        guard challengePlaintext.count == 32 else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-destination-key-proof-v1",
            projection: try possessionProof(
                proof,
                challengePlaintext: challengePlaintext,
                includeResponse: false
            )
        )
    }

    public static func destinationPossessionProofRecordDigest(
        _ proof: ProviderHandoffDestinationKeyPossessionProofV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-destination-key-proof-record-v1",
            projection: possessionProof(
                proof,
                challengePlaintext: nil,
                includeResponse: true
            )
        )
    }

    public static func manifestDigest(
        _ manifest: ProviderHandoffManifestV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-manifest-v1",
            projection: manifestProjection(manifest)
        )
    }

    public static func sourceManifestDigest(
        source: ProviderHandoffSourceV1,
        manifest: ProviderHandoffManifestV1
    ) throws -> String {
        guard
            manifest.sources.contains(where: {
                $0.stateRootUUID == source.stateRootUUID
            })
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        let envelopes = manifest.destinationSealedLineageKeyEnvelopes.filter {
            $0.sourceStateRootUUID == source.stateRootUUID
        }
        let contributedParts: [ProviderHandoffCanonicalValue] = try manifest.parts.compactMap { part in
            guard part.sourceStateRootUUIDs.contains(source.stateRootUUID) else {
                return nil
            }
            let sourceDigest: ProviderHandoffCanonicalValue
            if part.payload.protection
                == .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1
            {
                guard
                    let digest = part.payload.canonicalContentDigest
                        .orderedSourceDigests.first(where: {
                            $0.sourceStateRootUUID == source.stateRootUUID
                        })
                else {
                    throw ProviderHandoffProjectionError.invalidRecord
                }
                sourceDigest = try contentSourceDigest(digest)
            } else {
                sourceDigest = .null
            }
            return ProviderHandoffCanonicalValue.map([
                .init("part", try handoffPart(part)),
                .init("sourceDigest", sourceDigest),
            ])
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-source-manifest-v1",
            projection: .map([
                .init("contributedParts", .array(contributedParts)),
                .init("destinationKeyPossessionProofDigestsSHA256", .array(try manifest.destinationKeyPossessionProofDigestsSHA256.map(digestValue))),
                .init("destinationPreCommitExpectation", try headerExpectation(manifest.destinationPreCommitExpectation)),
                .init("destinationProviderFingerprint", .textString(manifest.destinationProviderFingerprint)),
                .init("destinationSealedLineageKeyEnvelopes", .array(try envelopes.map { try lineageEnvelope($0, includeSignature: true) })),
                .init("destinationStateRootUUID", .textString(manifest.destinationStateRootUUID)),
                .init("manifestID", .textString(manifest.manifestID)),
                .init("resultingAuthorityLineageUUID", .textString(manifest.resultingAuthorityLineageUUID)),
                .init("resultingLineageDigestKeyVersion", .unsigned(manifest.resultingLineageDigestKeyVersion)),
                .init("schemaVersion", .unsigned(UInt64(manifest.schemaVersion))),
                .init("source", try handoffSource(source, includeSignature: false)),
                .init("tokenID", .textString(manifest.tokenID)),
                .init("trustRegistryRevision", .unsigned(manifest.trustRegistryRevision)),
            ])
        )
    }

    public static func commitRecordDigest(
        _ record: ProviderHandoffCommitRecordV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-commit-record-v1",
            projection: .map([
                .init("commitDigestSHA256", try digestValue(record.commitDigestSHA256)),
                .init("handoffChainHeadDigestSHA256", try digestValue(record.handoffChainHeadDigestSHA256)),
                .init("intent", try commitIntent(record.intent)),
                .init("postCommitRoots", .array(try record.postCommitRoots.map(postCommitRoot))),
                .init("rootPrepareRecordDigestsSHA256", .array(try record.rootPrepareRecordDigestsSHA256.map(digestValue))),
                .init("schemaVersion", .unsigned(UInt64(record.schemaVersion))),
            ])
        )
    }

    fileprivate static func signature(
        _ value: ProviderHandoffSignatureV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("algorithm", .textString(value.algorithm.rawValue)),
            .init("canonicalBytesVersion", .unsigned(UInt64(value.canonicalBytesVersion))),
            .init("providerFingerprint", .optional(value.providerFingerprint)),
            .init("purpose", .textString(value.purpose.rawValue)),
            .init("signature", .byteString(value.signature)),
            .init("signedProjectionDigestSHA256", try digestValue(value.signedProjectionDigestSHA256)),
            .init("signerKeyID", .textString(value.signerKeyID)),
            .init("signerRole", .textString(value.signerRole.rawValue)),
            .init("stateRootUUID", .optional(value.stateRootUUID)),
            .init("trustRegistryRevision", .unsigned(value.trustRegistryRevision)),
        ])
    }

    fileprivate static func lineageEnvelope(
        _ value: DestinationSealedLineageKeyEnvelopeV1,
        includeSignature: Bool
    ) throws -> ProviderHandoffCanonicalValue {
        var entries: [ProviderHandoffCanonicalMapEntry] = [
            .init("associatedDataDigestSHA256", try digestValue(value.associatedDataDigestSHA256)),
            .init("authorityLineageUUID", .textString(value.authorityLineageUUID)),
            .init("canonicalPlaintextByteLength", .unsigned(value.canonicalPlaintextByteLength)),
            .init("ciphertext", .byteString(value.ciphertext)),
            .init("destinationKeyID", .textString(value.destinationKeyID)),
            .init("destinationKeyPurpose", .textString(value.destinationKeyPurpose.rawValue)),
            .init("encryptionAlgorithm", .textString(value.encryptionAlgorithm.rawValue)),
            .init("envelopeID", .textString(value.envelopeID)),
            .init("ephemeralPublicKey", .byteString(value.ephemeralPublicKey)),
            .init("keyVersion", .unsigned(value.keyVersion)),
            .init("nonce", .byteString(value.nonce)),
            .init("sourceStateRootUUID", .optional(value.sourceStateRootUUID)),
        ]
        if includeSignature {
            entries.append(.init("envelopeSignature", try signature(value.envelopeSignature)))
        }
        return .map(entries)
    }

    fileprivate static func canonicalContentDigest(
        _ value: ProviderHandoffCanonicalContentDigestV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("algorithm", .textString(value.algorithm.rawValue)),
            .init("digest", try digestValue(value.digest)),
            .init("orderedSourceDigests", .array(try value.orderedSourceDigests.map(contentSourceDigest))),
            .init("scope", .textString(value.scope.rawValue)),
        ])
    }

    fileprivate static func contentSourceDigest(
        _ value: ProviderHandoffContentSourceDigestV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("authorityLineageUUID", .textString(value.authorityLineageUUID)),
            .init("lineageDigestKeyVersion", .unsigned(value.lineageDigestKeyVersion)),
            .init("orderedEntryIDs", .array(value.orderedEntryIDs.map(ProviderHandoffCanonicalValue.textString))),
            .init("sourceDigestHMACSHA256", try digestValue(value.sourceDigestHMACSHA256)),
            .init("sourceStateRootUUID", .textString(value.sourceStateRootUUID)),
        ])
    }

    private static func trustKey(
        _ key: ProviderHandoffTrustKeyV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("algorithm", .textString(key.algorithm.rawValue)),
            .init("keyID", .textString(key.keyID)),
            .init("notAfterUnixSeconds", .unsigned(key.notAfterUnixSeconds)),
            .init("notBeforeUnixSeconds", .unsigned(key.notBeforeUnixSeconds)),
            .init("provenance", try provenance(key.provenance, includeProof: true)),
            .init("providerFingerprint", .optional(key.providerFingerprint)),
            .init("purpose", .textString(key.purpose.rawValue)),
            .init("rawPublicKey", .byteString(key.rawPublicKey)),
            .init("revocationReason", .optional(key.revocationReason)),
            .init("revokedAtUnixSeconds", .optional(key.revokedAtUnixSeconds)),
            .init("role", .textString(key.role.rawValue)),
            .init("rotationPredecessorKeyID", .optional(key.rotationPredecessorKeyID)),
            .init("stateRootUUID", .optional(key.stateRootUUID)),
        ])
    }

    private static func provenance(
        _ value: ProviderHandoffPublicKeyProvenanceV1,
        includeProof: Bool
    ) throws -> ProviderHandoffCanonicalValue {
        var entries: [ProviderHandoffCanonicalMapEntry] = [
            .init("codeRequirementDigestSHA256", try digestValue(value.codeRequirementDigestSHA256)),
            .init("enrolledAtUnixSeconds", .unsigned(value.enrolledAtUnixSeconds)),
            .init("enrollmentID", .textString(value.enrollmentID)),
            .init("owningBundleIdentifier", .textString(value.owningBundleIdentifier)),
            .init("providerRegistrationDigestSHA256", try digestValue(value.providerRegistrationDigestSHA256)),
            .init("teamIdentifier", .optional(value.teamIdentifier)),
        ]
        if includeProof {
            entries.append(.init("enrollmentProofSignature", value.enrollmentProofSignature.map(ProviderHandoffCanonicalValue.byteString) ?? .null))
        }
        return .map(entries)
    }

    private static func possessionProof(
        _ value: ProviderHandoffDestinationKeyPossessionProofV1,
        challengePlaintext: Data?,
        includeResponse: Bool
    ) throws -> ProviderHandoffCanonicalValue {
        var entries: [ProviderHandoffCanonicalMapEntry] = [
            .init("challengeAssociatedDataDigestSHA256", try digestValue(value.challengeAssociatedDataDigestSHA256)),
            .init("challengeCiphertext", .byteString(value.challengeCiphertext)),
            .init("challengeEphemeralPublicKey", .byteString(value.challengeEphemeralPublicKey)),
            .init("challengeNonce", .byteString(value.challengeNonce)),
            .init("destinationKeyID", .textString(value.destinationKeyID)),
            .init("destinationKeyPurpose", .textString(value.destinationKeyPurpose.rawValue)),
            .init("destinationProviderFingerprint", .textString(value.destinationProviderFingerprint)),
            .init("destinationStateRootUUID", .textString(value.destinationStateRootUUID)),
            .init("manifestID", .textString(value.manifestID)),
            .init("proofID", .textString(value.proofID)),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("tokenID", .textString(value.tokenID)),
        ]
        if includeResponse {
            entries.append(.init("responseDigestSHA256", try digestValue(value.responseDigestSHA256)))
        } else if let challengePlaintext {
            entries.append(.init("challengePlaintext", .byteString(challengePlaintext)))
        } else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return .map(entries)
    }

    private static func manifestProjection(
        _ manifest: ProviderHandoffManifestV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("destinationKeyPossessionProofDigestsSHA256", .array(try manifest.destinationKeyPossessionProofDigestsSHA256.map(digestValue))),
            .init("destinationPreCommitExpectation", try headerExpectation(manifest.destinationPreCommitExpectation)),
            .init("destinationProviderFingerprint", .textString(manifest.destinationProviderFingerprint)),
            .init("destinationSealedLineageKeyEnvelopes", .array(try manifest.destinationSealedLineageKeyEnvelopes.map { try lineageEnvelope($0, includeSignature: true) })),
            .init("destinationStateRootUUID", .textString(manifest.destinationStateRootUUID)),
            .init("manifestDigestAlgorithm", .textString(manifest.manifestDigestAlgorithm.rawValue)),
            .init("manifestID", .textString(manifest.manifestID)),
            .init("parts", .array(try manifest.parts.map(handoffPart))),
            .init("resultingAuthorityLineageUUID", .textString(manifest.resultingAuthorityLineageUUID)),
            .init("resultingLineageDigestKeyVersion", .unsigned(manifest.resultingLineageDigestKeyVersion)),
            .init("schemaVersion", .unsigned(UInt64(manifest.schemaVersion))),
            .init("sources", .array(try manifest.sources.map { try handoffSource($0, includeSignature: true) })),
            .init("tokenID", .textString(manifest.tokenID)),
            .init("trustRegistryRevision", .unsigned(manifest.trustRegistryRevision)),
        ])
    }

    private static func handoffSource(
        _ value: ProviderHandoffSourceV1,
        includeSignature: Bool
    ) throws -> ProviderHandoffCanonicalValue {
        var entries: [ProviderHandoffCanonicalMapEntry] = [
            .init("authorityLineageUUID", .textString(value.authorityLineageUUID)),
            .init("lineageDigestKeyVersion", .unsigned(value.lineageDigestKeyVersion)),
            .init("preCommitExpectation", try headerExpectation(value.preCommitExpectation)),
            .init("providerFingerprint", .textString(value.providerFingerprint)),
            .init("stateRootUUID", .textString(value.stateRootUUID)),
        ]
        if includeSignature {
            entries.append(.init("sourceSignature", try signature(value.sourceSignature)))
        }
        return .map(entries)
    }

    private static func handoffPart(
        _ value: ProviderHandoffPartV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("disposition", .textString(value.disposition.rawValue)),
            .init("kind", .textString(value.kind.rawValue)),
            .init("payload", try payloadDescriptor(value.payload)),
            .init("requiredCapabilities", .array(value.requiredCapabilities.map(ProviderHandoffCanonicalValue.textString))),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("sourceStateRootUUIDs", .array(value.sourceStateRootUUIDs.map(ProviderHandoffCanonicalValue.textString))),
        ])
    }

    private static func postCommitRoot(
        _ value: ProviderHandoffPostCommitRootV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard
            value.stateRootUUID == value.postCommitHeader.stateRootUUID,
            value.stateRootUUID == value.postCommitRevisionVector.stateRootUUID,
            try stateRootHeaderDigest(value.postCommitHeader)
                == value.postCommitHeaderDigestSHA256,
            try revisionVectorDigest(value.postCommitRevisionVector)
                == value.postCommitRevisionVector.revisionVectorDigestSHA256
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return .map([
            .init("postCommitHeader", try stateRootHeader(value.postCommitHeader)),
            .init("postCommitHeaderDigestSHA256", try digestValue(value.postCommitHeaderDigestSHA256)),
            .init("postCommitRevisionVector", try revisionVectorWithDigestForSecurity(value.postCommitRevisionVector)),
            .init("role", .textString(value.role.rawValue)),
            .init("stateRootUUID", .textString(value.stateRootUUID)),
        ])
    }

    private static func revisionVectorWithDigestForSecurity(
        _ vector: ProviderHandoffRevisionVectorV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard
            try revisionVectorDigest(vector) == vector.revisionVectorDigestSHA256,
            case .map(let entries) = try revisionVector(vector)
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return .map(
            entries + [
                .init("revisionVectorDigestSHA256", try digestValue(vector.revisionVectorDigestSHA256))
            ])
    }

    fileprivate static func digestValue(
        _ digest: String
    ) throws -> ProviderHandoffCanonicalValue {
        .byteString(try ProviderHandoffDigest.parseSHA256(digest))
    }
}
