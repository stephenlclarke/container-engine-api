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

public enum ProviderHandoffPartDispositionV1: String, Codable, Equatable, Sendable {
    case included
    case empty
    case unsupported
    case retainOffline
    case explicitResolutionRequired
}

public enum ProviderHandoffPartKindV1: String, Codable, CaseIterable, Equatable, Sendable {
    case identityLifecycleEvents
    case imagesAndContent
    case networksAndIPAM
    case volumesAndMounts
    case rootfsConfigsAndSecrets
    case socketGrants
    case resourcesSecurityProfilesAndIDMaps
    case devices
    case namespaces
    case logging
    case modelsAndRoutes
    case buildsAndCache
}

public enum ProviderHandoffCanonicalEncodingV1: String, Codable, Equatable, Sendable {
    case deterministicCBORV1
}

public enum ProviderHandoffDigestAlgorithmV1: String, Codable, Equatable, Sendable {
    case sha256
    case lineageHMACSHA256V1
    case orderedLineageHMACSHA256AggregateV1
}

public enum ProviderHandoffPayloadProtectionV1: String, Codable, Equatable, Sendable {
    case authenticatedPlaintext
    case destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1
}

public enum ProviderHandoffContentDigestScopeV1: String, Codable, Equatable, Sendable {
    case publicSHA256V1
    case singleSourceLineageHMACSHA256V1
    case multiSourceLineageHMACSHA256AggregateV1
}

public struct ProviderHandoffContentSourceDigestV1: Codable, Equatable, Sendable {
    public var sourceStateRootUUID: String
    public var authorityLineageUUID: String
    public var lineageDigestKeyVersion: UInt64
    public var orderedEntryIDs: [String]
    public var sourceDigestHMACSHA256: String

    public init(
        sourceStateRootUUID: String,
        authorityLineageUUID: String,
        lineageDigestKeyVersion: UInt64,
        orderedEntryIDs: [String],
        sourceDigestHMACSHA256: String
    ) {
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.lineageDigestKeyVersion = lineageDigestKeyVersion
        self.orderedEntryIDs = orderedEntryIDs
        self.sourceDigestHMACSHA256 = sourceDigestHMACSHA256
    }
}

public struct ProviderHandoffCanonicalContentDigestV1: Codable, Equatable, Sendable {
    public var algorithm: ProviderHandoffDigestAlgorithmV1
    public var scope: ProviderHandoffContentDigestScopeV1
    public var orderedSourceDigests: [ProviderHandoffContentSourceDigestV1]
    public var digest: String

    public init(
        algorithm: ProviderHandoffDigestAlgorithmV1,
        scope: ProviderHandoffContentDigestScopeV1,
        orderedSourceDigests: [ProviderHandoffContentSourceDigestV1],
        digest: String
    ) {
        self.algorithm = algorithm
        self.scope = scope
        self.orderedSourceDigests = orderedSourceDigests
        self.digest = digest
    }
}

public struct ProviderHandoffPayloadPackageEntryV1: Codable, Equatable, Sendable {
    public var entryID: String
    public var sourceStateRootUUID: String?
    public var recordKind: String
    public var schemaVersion: UInt32
    public var canonicalRecordBytes: Data

    public init(
        entryID: String,
        sourceStateRootUUID: String?,
        recordKind: String,
        schemaVersion: UInt32,
        canonicalRecordBytes: Data
    ) {
        self.entryID = entryID
        self.sourceStateRootUUID = sourceStateRootUUID
        self.recordKind = recordKind
        self.schemaVersion = schemaVersion
        self.canonicalRecordBytes = canonicalRecordBytes
    }
}

public struct ProviderHandoffPayloadPackageV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var partKind: ProviderHandoffPartKindV1
    public var entries: [ProviderHandoffPayloadPackageEntryV1]

    public init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        partKind: ProviderHandoffPartKindV1,
        entries: [ProviderHandoffPayloadPackageEntryV1]
    ) {
        self.schemaVersion = schemaVersion
        self.partKind = partKind
        self.entries = entries
    }
}

public struct ProviderHandoffPayloadDescriptorV1: Codable, Equatable, Sendable {
    public var bundleObjectID: String
    public var mediaType: String
    public var schemaVersion: UInt32
    public var canonicalEncoding: ProviderHandoffCanonicalEncodingV1
    public var canonicalPlaintextByteLength: UInt64
    public var transportByteLength: UInt64
    public var canonicalContentDigest: ProviderHandoffCanonicalContentDigestV1
    public var transportDigestSHA256: String
    public var protection: ProviderHandoffPayloadProtectionV1
    public var destinationEncryption: ProviderHandoffPayloadEncryptionV1?

    public init(
        bundleObjectID: String,
        mediaType: String,
        schemaVersion: UInt32,
        canonicalEncoding: ProviderHandoffCanonicalEncodingV1,
        canonicalPlaintextByteLength: UInt64,
        transportByteLength: UInt64,
        canonicalContentDigest: ProviderHandoffCanonicalContentDigestV1,
        transportDigestSHA256: String,
        protection: ProviderHandoffPayloadProtectionV1,
        destinationEncryption: ProviderHandoffPayloadEncryptionV1?
    ) {
        self.bundleObjectID = bundleObjectID
        self.mediaType = mediaType
        self.schemaVersion = schemaVersion
        self.canonicalEncoding = canonicalEncoding
        self.canonicalPlaintextByteLength = canonicalPlaintextByteLength
        self.transportByteLength = transportByteLength
        self.canonicalContentDigest = canonicalContentDigest
        self.transportDigestSHA256 = transportDigestSHA256
        self.protection = protection
        self.destinationEncryption = destinationEncryption
    }
}

public struct ProviderHandoffPartV1: Codable, Equatable, Sendable {
    public var kind: ProviderHandoffPartKindV1
    public var schemaVersion: UInt32
    public var disposition: ProviderHandoffPartDispositionV1
    public var sourceStateRootUUIDs: [String]
    public var requiredCapabilities: [String]
    public var payload: ProviderHandoffPayloadDescriptorV1

    public init(
        kind: ProviderHandoffPartKindV1,
        schemaVersion: UInt32,
        disposition: ProviderHandoffPartDispositionV1,
        sourceStateRootUUIDs: [String],
        requiredCapabilities: [String],
        payload: ProviderHandoffPayloadDescriptorV1
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.disposition = disposition
        self.sourceStateRootUUIDs = sourceStateRootUUIDs
        self.requiredCapabilities = requiredCapabilities
        self.payload = payload
    }
}

public enum ProviderHandoffSignatureAlgorithmV1: String, Codable, Equatable, Sendable {
    case ed25519V1
}

public enum ProviderHandoffPublicKeyAlgorithmV1: String, Codable, Equatable, Sendable {
    case ed25519V1
    case x25519V1
}

public enum ProviderHandoffKeyRoleV1: String, Codable, Equatable, Sendable {
    case gatewayCoordinator
    case sourceProvider
    case destinationProvider
}

public enum ProviderHandoffKeyPurposeV1: String, Codable, CaseIterable, Equatable, Sendable {
    case trustRegistrySigning
    case sourceManifestSigning
    case coordinatorManifestSigning
    case lineageKeyEnvelopeSigning
    case coordinatorCommitSigning
    case coordinatorTerminalOutcomeSigning
    case destinationPossessionSigning
    case destinationPayloadEncryption
    case destinationLineageKeyEncryption
}

public struct ProviderHandoffPublicKeyProvenanceV1: Codable, Equatable, Sendable {
    public var enrollmentID: String
    public var owningBundleIdentifier: String
    public var codeRequirementDigestSHA256: String
    public var teamIdentifier: String?
    public var providerRegistrationDigestSHA256: String
    public var enrolledAtUnixSeconds: UInt64
    public var enrollmentProofSignature: Data?

    public init(
        enrollmentID: String,
        owningBundleIdentifier: String,
        codeRequirementDigestSHA256: String,
        teamIdentifier: String?,
        providerRegistrationDigestSHA256: String,
        enrolledAtUnixSeconds: UInt64,
        enrollmentProofSignature: Data?
    ) {
        self.enrollmentID = enrollmentID
        self.owningBundleIdentifier = owningBundleIdentifier
        self.codeRequirementDigestSHA256 = codeRequirementDigestSHA256
        self.teamIdentifier = teamIdentifier
        self.providerRegistrationDigestSHA256 = providerRegistrationDigestSHA256
        self.enrolledAtUnixSeconds = enrolledAtUnixSeconds
        self.enrollmentProofSignature = enrollmentProofSignature
    }
}

public struct ProviderHandoffTrustKeyV1: Codable, Equatable, Sendable {
    public var keyID: String
    public var algorithm: ProviderHandoffPublicKeyAlgorithmV1
    public var role: ProviderHandoffKeyRoleV1
    public var purpose: ProviderHandoffKeyPurposeV1
    public var providerFingerprint: String?
    public var stateRootUUID: String?
    public var rawPublicKey: Data
    public var provenance: ProviderHandoffPublicKeyProvenanceV1
    public var notBeforeUnixSeconds: UInt64
    public var notAfterUnixSeconds: UInt64
    public var rotationPredecessorKeyID: String?
    public var revokedAtUnixSeconds: UInt64?
    public var revocationReason: String?

    public init(
        keyID: String,
        algorithm: ProviderHandoffPublicKeyAlgorithmV1,
        role: ProviderHandoffKeyRoleV1,
        purpose: ProviderHandoffKeyPurposeV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        rawPublicKey: Data,
        provenance: ProviderHandoffPublicKeyProvenanceV1,
        notBeforeUnixSeconds: UInt64,
        notAfterUnixSeconds: UInt64,
        rotationPredecessorKeyID: String?,
        revokedAtUnixSeconds: UInt64?,
        revocationReason: String?
    ) {
        self.keyID = keyID
        self.algorithm = algorithm
        self.role = role
        self.purpose = purpose
        self.providerFingerprint = providerFingerprint
        self.stateRootUUID = stateRootUUID
        self.rawPublicKey = rawPublicKey
        self.provenance = provenance
        self.notBeforeUnixSeconds = notBeforeUnixSeconds
        self.notAfterUnixSeconds = notAfterUnixSeconds
        self.rotationPredecessorKeyID = rotationPredecessorKeyID
        self.revokedAtUnixSeconds = revokedAtUnixSeconds
        self.revocationReason = revocationReason
    }
}

public struct ProviderHandoffSignatureV1: Codable, Equatable, Sendable {
    public var algorithm: ProviderHandoffSignatureAlgorithmV1
    public var purpose: ProviderHandoffKeyPurposeV1
    public var signerKeyID: String
    public var signerRole: ProviderHandoffKeyRoleV1
    public var providerFingerprint: String?
    public var stateRootUUID: String?
    public var trustRegistryRevision: UInt64
    public var canonicalBytesVersion: UInt32
    public var signedProjectionDigestSHA256: String
    public var signature: Data

    public init(
        algorithm: ProviderHandoffSignatureAlgorithmV1 = .ed25519V1,
        purpose: ProviderHandoffKeyPurposeV1,
        signerKeyID: String,
        signerRole: ProviderHandoffKeyRoleV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        trustRegistryRevision: UInt64,
        canonicalBytesVersion: UInt32 = 1,
        signedProjectionDigestSHA256: String,
        signature: Data
    ) {
        self.algorithm = algorithm
        self.purpose = purpose
        self.signerKeyID = signerKeyID
        self.signerRole = signerRole
        self.providerFingerprint = providerFingerprint
        self.stateRootUUID = stateRootUUID
        self.trustRegistryRevision = trustRegistryRevision
        self.canonicalBytesVersion = canonicalBytesVersion
        self.signedProjectionDigestSHA256 = signedProjectionDigestSHA256
        self.signature = signature
    }
}

public struct ProviderHandoffTrustRegistryV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var registryRevision: UInt64
    public var issuedAtUnixSeconds: UInt64
    public var keys: [ProviderHandoffTrustKeyV1]
    public var registryDigestSHA256: String
    public var registrySignature: ProviderHandoffSignatureV1

    public init(
        schemaVersion: UInt32 = 1,
        registryRevision: UInt64,
        issuedAtUnixSeconds: UInt64,
        keys: [ProviderHandoffTrustKeyV1],
        registryDigestSHA256: String,
        registrySignature: ProviderHandoffSignatureV1
    ) {
        self.schemaVersion = schemaVersion
        self.registryRevision = registryRevision
        self.issuedAtUnixSeconds = issuedAtUnixSeconds
        self.keys = keys
        self.registryDigestSHA256 = registryDigestSHA256
        self.registrySignature = registrySignature
    }
}

public enum ProviderHandoffEnvelopeAlgorithmV1: String, Codable, Equatable, Sendable {
    case x25519HKDFSHA256XChaCha20Poly1305V1
}

public enum ProviderHandoffAEADObjectKindV1: String, Codable, Equatable, Sendable {
    case partPayload
    case lineageKeyEnvelope
    case destinationPossessionChallenge
}

public struct ProviderHandoffAEADAssociatedDataV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var objectKind: ProviderHandoffAEADObjectKindV1
    public var tokenID: String
    public var manifestID: String
    public var objectLocalID: String
    public var partKind: ProviderHandoffPartKindV1?
    public var mediaType: String?
    public var payloadSchemaVersion: UInt32?
    public var canonicalPlaintextByteLength: UInt64
    public var canonicalContentDigest: ProviderHandoffCanonicalContentDigestV1?
    public var sourceStateRootUUID: String?
    public var authorityLineageUUID: String?
    public var lineageDigestKeyVersion: UInt64?
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var destinationKeyPurpose: ProviderHandoffKeyPurposeV1
    public var destinationKeyID: String
    public var ephemeralPublicKey: Data
    public var nonce: Data

    public init(
        schemaVersion: UInt32 = 1,
        objectKind: ProviderHandoffAEADObjectKindV1,
        tokenID: String,
        manifestID: String,
        objectLocalID: String,
        partKind: ProviderHandoffPartKindV1?,
        mediaType: String?,
        payloadSchemaVersion: UInt32?,
        canonicalPlaintextByteLength: UInt64,
        canonicalContentDigest: ProviderHandoffCanonicalContentDigestV1?,
        sourceStateRootUUID: String?,
        authorityLineageUUID: String?,
        lineageDigestKeyVersion: UInt64?,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyPurpose: ProviderHandoffKeyPurposeV1,
        destinationKeyID: String,
        ephemeralPublicKey: Data,
        nonce: Data
    ) {
        self.schemaVersion = schemaVersion
        self.objectKind = objectKind
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.objectLocalID = objectLocalID
        self.partKind = partKind
        self.mediaType = mediaType
        self.payloadSchemaVersion = payloadSchemaVersion
        self.canonicalPlaintextByteLength = canonicalPlaintextByteLength
        self.canonicalContentDigest = canonicalContentDigest
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.lineageDigestKeyVersion = lineageDigestKeyVersion
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.destinationKeyPurpose = destinationKeyPurpose
        self.destinationKeyID = destinationKeyID
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }
}

public struct ProviderHandoffPayloadEncryptionV1: Codable, Equatable, Sendable {
    public var encryptionAlgorithm: ProviderHandoffEnvelopeAlgorithmV1
    public var destinationKeyPurpose: ProviderHandoffKeyPurposeV1
    public var destinationKeyID: String
    public var ephemeralPublicKey: Data
    public var nonce: Data
    public var associatedDataDigestSHA256: String

    public init(
        encryptionAlgorithm: ProviderHandoffEnvelopeAlgorithmV1,
        destinationKeyPurpose: ProviderHandoffKeyPurposeV1,
        destinationKeyID: String,
        ephemeralPublicKey: Data,
        nonce: Data,
        associatedDataDigestSHA256: String
    ) {
        self.encryptionAlgorithm = encryptionAlgorithm
        self.destinationKeyPurpose = destinationKeyPurpose
        self.destinationKeyID = destinationKeyID
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.associatedDataDigestSHA256 = associatedDataDigestSHA256
    }
}

public enum ProviderHandoffRootRoleV1: String, Codable, Equatable, Sendable {
    case source
    case destination
}

public struct ProviderHandoffControllerRevisionV1: Codable, Equatable, Sendable {
    public var controllerID: String
    public var revision: UInt64
    public var canonicalStateDigestSHA256: String

    public init(controllerID: String, revision: UInt64, canonicalStateDigestSHA256: String) {
        self.controllerID = controllerID
        self.revision = revision
        self.canonicalStateDigestSHA256 = canonicalStateDigestSHA256
    }
}

public struct ProviderHandoffRevisionVectorV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var stateRootUUID: String
    public var rootStoreRevision: UInt64
    public var snapshotCheckpointID: String?
    public var controllerRevisions: [ProviderHandoffControllerRevisionV1]
    public var revisionVectorDigestSHA256: String

    public init(
        schemaVersion: UInt32 = 1,
        stateRootUUID: String,
        rootStoreRevision: UInt64,
        snapshotCheckpointID: String?,
        controllerRevisions: [ProviderHandoffControllerRevisionV1],
        revisionVectorDigestSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.stateRootUUID = stateRootUUID
        self.rootStoreRevision = rootStoreRevision
        self.snapshotCheckpointID = snapshotCheckpointID
        self.controllerRevisions = controllerRevisions
        self.revisionVectorDigestSHA256 = revisionVectorDigestSHA256
    }
}

public enum StateRootHandoffStateV1: String, Codable, Equatable, Sendable {
    case none
    case sourceDraining
    case sourceQuiesced
    case destinationStaged
    case sourceTransferred
    case destinationReconciling
    case destinationActive
}

public struct StateRootHeaderV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var stateRootUUID: String
    public var authorityLineageUUID: String
    public var stagedAuthorityLineageUUID: String?
    public var currentDataSchemaVersion: UInt32
    public var minimumWriterSchemaVersion: UInt32
    public var writerEpoch: UInt64
    public var selectedProviderFingerprint: String?
    public var handoffState: StateRootHandoffStateV1
    public var activeHandoffTokenID: String?
    public var handoffChainHeadDigest: String?
    public var lineageDigestKeyVersion: UInt64

    public init(
        schemaVersion: UInt32 = 1,
        stateRootUUID: String,
        authorityLineageUUID: String,
        stagedAuthorityLineageUUID: String?,
        currentDataSchemaVersion: UInt32,
        minimumWriterSchemaVersion: UInt32,
        writerEpoch: UInt64,
        selectedProviderFingerprint: String?,
        handoffState: StateRootHandoffStateV1,
        activeHandoffTokenID: String?,
        handoffChainHeadDigest: String?,
        lineageDigestKeyVersion: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.stateRootUUID = stateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.stagedAuthorityLineageUUID = stagedAuthorityLineageUUID
        self.currentDataSchemaVersion = currentDataSchemaVersion
        self.minimumWriterSchemaVersion = minimumWriterSchemaVersion
        self.writerEpoch = writerEpoch
        self.selectedProviderFingerprint = selectedProviderFingerprint
        self.handoffState = handoffState
        self.activeHandoffTokenID = activeHandoffTokenID
        self.handoffChainHeadDigest = handoffChainHeadDigest
        self.lineageDigestKeyVersion = lineageDigestKeyVersion
    }
}

public struct ProviderHandoffHeaderExpectationV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var role: ProviderHandoffRootRoleV1
    public var stateRootUUID: String
    public var expectedHeader: StateRootHeaderV1
    public var expectedHeaderDigestSHA256: String
    public var preCommitRevisionVector: ProviderHandoffRevisionVectorV1
    public var abortHeader: StateRootHeaderV1
    public var abortHeaderDigestSHA256: String
    public var abortRevisionVector: ProviderHandoffRevisionVectorV1

    public init(
        schemaVersion: UInt32 = 1,
        role: ProviderHandoffRootRoleV1,
        stateRootUUID: String,
        expectedHeader: StateRootHeaderV1,
        expectedHeaderDigestSHA256: String,
        preCommitRevisionVector: ProviderHandoffRevisionVectorV1,
        abortHeader: StateRootHeaderV1,
        abortHeaderDigestSHA256: String,
        abortRevisionVector: ProviderHandoffRevisionVectorV1
    ) {
        self.schemaVersion = schemaVersion
        self.role = role
        self.stateRootUUID = stateRootUUID
        self.expectedHeader = expectedHeader
        self.expectedHeaderDigestSHA256 = expectedHeaderDigestSHA256
        self.preCommitRevisionVector = preCommitRevisionVector
        self.abortHeader = abortHeader
        self.abortHeaderDigestSHA256 = abortHeaderDigestSHA256
        self.abortRevisionVector = abortRevisionVector
    }
}

public struct ProviderHandoffSourceV1: Codable, Equatable, Sendable {
    public var providerFingerprint: String
    public var stateRootUUID: String
    public var authorityLineageUUID: String
    public var lineageDigestKeyVersion: UInt64
    public var preCommitExpectation: ProviderHandoffHeaderExpectationV1
    public var sourceSignature: ProviderHandoffSignatureV1

    public init(
        providerFingerprint: String,
        stateRootUUID: String,
        authorityLineageUUID: String,
        lineageDigestKeyVersion: UInt64,
        preCommitExpectation: ProviderHandoffHeaderExpectationV1,
        sourceSignature: ProviderHandoffSignatureV1
    ) {
        self.providerFingerprint = providerFingerprint
        self.stateRootUUID = stateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.lineageDigestKeyVersion = lineageDigestKeyVersion
        self.preCommitExpectation = preCommitExpectation
        self.sourceSignature = sourceSignature
    }
}

public struct DestinationSealedLineageKeyEnvelopeV1: Codable, Equatable, Sendable {
    public var envelopeID: String
    public var sourceStateRootUUID: String?
    public var authorityLineageUUID: String
    public var keyVersion: UInt64
    public var destinationKeyPurpose: ProviderHandoffKeyPurposeV1
    public var destinationKeyID: String
    public var encryptionAlgorithm: ProviderHandoffEnvelopeAlgorithmV1
    public var ephemeralPublicKey: Data
    public var nonce: Data
    public var canonicalPlaintextByteLength: UInt64
    public var associatedDataDigestSHA256: String
    public var ciphertext: Data
    public var envelopeSignature: ProviderHandoffSignatureV1

    public init(
        envelopeID: String,
        sourceStateRootUUID: String?,
        authorityLineageUUID: String,
        keyVersion: UInt64,
        destinationKeyPurpose: ProviderHandoffKeyPurposeV1,
        destinationKeyID: String,
        encryptionAlgorithm: ProviderHandoffEnvelopeAlgorithmV1,
        ephemeralPublicKey: Data,
        nonce: Data,
        canonicalPlaintextByteLength: UInt64,
        associatedDataDigestSHA256: String,
        ciphertext: Data,
        envelopeSignature: ProviderHandoffSignatureV1
    ) {
        self.envelopeID = envelopeID
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.keyVersion = keyVersion
        self.destinationKeyPurpose = destinationKeyPurpose
        self.destinationKeyID = destinationKeyID
        self.encryptionAlgorithm = encryptionAlgorithm
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.canonicalPlaintextByteLength = canonicalPlaintextByteLength
        self.associatedDataDigestSHA256 = associatedDataDigestSHA256
        self.ciphertext = ciphertext
        self.envelopeSignature = envelopeSignature
    }
}

public struct ProviderHandoffDestinationKeyPossessionProofV1: Codable, Equatable, Sendable {
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
    public var responseDigestSHA256: String
    public var destinationSignature: ProviderHandoffSignatureV1

    public init(
        schemaVersion: UInt32 = 1,
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
        responseDigestSHA256: String,
        destinationSignature: ProviderHandoffSignatureV1
    ) {
        self.schemaVersion = schemaVersion
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
        self.responseDigestSHA256 = responseDigestSHA256
        self.destinationSignature = destinationSignature
    }
}

public struct ProviderHandoffManifestV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var manifestID: String
    public var tokenID: String
    public var trustRegistryRevision: UInt64
    public var destinationKeyPossessionProofDigestsSHA256: [String]
    public var sources: [ProviderHandoffSourceV1]
    public var resultingAuthorityLineageUUID: String
    public var resultingLineageDigestKeyVersion: UInt64
    public var destinationSealedLineageKeyEnvelopes: [DestinationSealedLineageKeyEnvelopeV1]
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var destinationPreCommitExpectation: ProviderHandoffHeaderExpectationV1
    public var parts: [ProviderHandoffPartV1]
    public var manifestDigestAlgorithm: ProviderHandoffDigestAlgorithmV1
    public var manifestDigest: String
    public var coordinatorSignature: ProviderHandoffSignatureV1

    public init(
        schemaVersion: UInt32 = 1,
        manifestID: String,
        tokenID: String,
        trustRegistryRevision: UInt64,
        destinationKeyPossessionProofDigestsSHA256: [String],
        sources: [ProviderHandoffSourceV1],
        resultingAuthorityLineageUUID: String,
        resultingLineageDigestKeyVersion: UInt64,
        destinationSealedLineageKeyEnvelopes: [DestinationSealedLineageKeyEnvelopeV1],
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationPreCommitExpectation: ProviderHandoffHeaderExpectationV1,
        parts: [ProviderHandoffPartV1],
        manifestDigestAlgorithm: ProviderHandoffDigestAlgorithmV1 = .sha256,
        manifestDigest: String,
        coordinatorSignature: ProviderHandoffSignatureV1
    ) {
        self.schemaVersion = schemaVersion
        self.manifestID = manifestID
        self.tokenID = tokenID
        self.trustRegistryRevision = trustRegistryRevision
        self.destinationKeyPossessionProofDigestsSHA256 = destinationKeyPossessionProofDigestsSHA256
        self.sources = sources
        self.resultingAuthorityLineageUUID = resultingAuthorityLineageUUID
        self.resultingLineageDigestKeyVersion = resultingLineageDigestKeyVersion
        self.destinationSealedLineageKeyEnvelopes = destinationSealedLineageKeyEnvelopes
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.destinationPreCommitExpectation = destinationPreCommitExpectation
        self.parts = parts
        self.manifestDigestAlgorithm = manifestDigestAlgorithm
        self.manifestDigest = manifestDigest
        self.coordinatorSignature = coordinatorSignature
    }
}

public enum ProviderHandoffPhaseV1: String, Codable, Equatable, Sendable {
    case draining
    case quiesced
    case staged
    case aborting
    case committed
    case reconciling
    case complete
    case aborted
}

public struct ProviderHandoffProviderSelectionRecordV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var selectionRevision: UInt64
    public var selectedProviderFingerprint: String?
    public var selectedStateRootUUID: String?
    public var providerRegistrationDigestSHA256: String?
    public var trustRegistryRevision: UInt64

    public init(
        schemaVersion: UInt32 = 1,
        selectionRevision: UInt64,
        selectedProviderFingerprint: String?,
        selectedStateRootUUID: String?,
        providerRegistrationDigestSHA256: String?,
        trustRegistryRevision: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.selectionRevision = selectionRevision
        self.selectedProviderFingerprint = selectedProviderFingerprint
        self.selectedStateRootUUID = selectedStateRootUUID
        self.providerRegistrationDigestSHA256 = providerRegistrationDigestSHA256
        self.trustRegistryRevision = trustRegistryRevision
    }
}

public struct ProviderHandoffProviderSelectionExpectationV1: Codable, Equatable, Sendable {
    public var expectedRecord: ProviderHandoffProviderSelectionRecordV1
    public var expectedRecordDigestSHA256: String
    public var resultingRecord: ProviderHandoffProviderSelectionRecordV1
    public var resultingRecordDigestSHA256: String

    public init(
        expectedRecord: ProviderHandoffProviderSelectionRecordV1,
        expectedRecordDigestSHA256: String,
        resultingRecord: ProviderHandoffProviderSelectionRecordV1,
        resultingRecordDigestSHA256: String
    ) {
        self.expectedRecord = expectedRecord
        self.expectedRecordDigestSHA256 = expectedRecordDigestSHA256
        self.resultingRecord = resultingRecord
        self.resultingRecordDigestSHA256 = resultingRecordDigestSHA256
    }
}

public struct ProviderHandoffSocketDiscoveryRecordV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var discoveryRevision: UInt64
    public var socketInstanceUUID: String
    public var ownerUID: UInt32
    public var minimumEngineAPIVersion: String
    public var maximumEngineAPIVersion: String
    public var selectedProviderFingerprint: String?
    public var selectedStateRootUUID: String?

    public init(
        schemaVersion: UInt32 = 1,
        discoveryRevision: UInt64,
        socketInstanceUUID: String,
        ownerUID: UInt32,
        minimumEngineAPIVersion: String,
        maximumEngineAPIVersion: String,
        selectedProviderFingerprint: String?,
        selectedStateRootUUID: String?
    ) {
        self.schemaVersion = schemaVersion
        self.discoveryRevision = discoveryRevision
        self.socketInstanceUUID = socketInstanceUUID
        self.ownerUID = ownerUID
        self.minimumEngineAPIVersion = minimumEngineAPIVersion
        self.maximumEngineAPIVersion = maximumEngineAPIVersion
        self.selectedProviderFingerprint = selectedProviderFingerprint
        self.selectedStateRootUUID = selectedStateRootUUID
    }
}

public struct ProviderHandoffSocketSelectionExpectationV1: Codable, Equatable, Sendable {
    public var expectedRecord: ProviderHandoffSocketDiscoveryRecordV1
    public var expectedRecordDigestSHA256: String
    public var resultingRecord: ProviderHandoffSocketDiscoveryRecordV1
    public var resultingRecordDigestSHA256: String

    public init(
        expectedRecord: ProviderHandoffSocketDiscoveryRecordV1,
        expectedRecordDigestSHA256: String,
        resultingRecord: ProviderHandoffSocketDiscoveryRecordV1,
        resultingRecordDigestSHA256: String
    ) {
        self.expectedRecord = expectedRecord
        self.expectedRecordDigestSHA256 = expectedRecordDigestSHA256
        self.resultingRecord = resultingRecord
        self.resultingRecordDigestSHA256 = resultingRecordDigestSHA256
    }
}

public struct ProviderHandoffTokenV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var tokenID: String
    public var tokenRevision: UInt64
    public var orderedSourceStateRootUUIDs: [String]
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var trustRegistryRevision: UInt64
    public var resultingAuthorityLineageUUID: String
    public var resultingLineageDigestKeyVersion: UInt64
    public var phase: ProviderHandoffPhaseV1
    public var preCommitRootExpectations: [ProviderHandoffHeaderExpectationV1]
    public var destinationKeyPossessionProofDigestsSHA256: [String]
    public var manifestID: String
    public var manifestDigest: String?
    public var importedParts: [ProviderHandoffPartImportExpectationV1]?
    public var authoritativeCommitRevision: UInt64?
    public var commitDigestSHA256: String?
    public var handoffChainHeadDigestSHA256: String?
    public var rootPrepareRecordDigestsSHA256: [String]?
    public var terminalOutcomeDigestSHA256: String?

    public init(
        schemaVersion: UInt32 = 1,
        tokenID: String,
        tokenRevision: UInt64,
        orderedSourceStateRootUUIDs: [String],
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        trustRegistryRevision: UInt64,
        resultingAuthorityLineageUUID: String,
        resultingLineageDigestKeyVersion: UInt64,
        phase: ProviderHandoffPhaseV1,
        preCommitRootExpectations: [ProviderHandoffHeaderExpectationV1],
        destinationKeyPossessionProofDigestsSHA256: [String],
        manifestID: String,
        manifestDigest: String? = nil,
        importedParts: [ProviderHandoffPartImportExpectationV1]? = nil,
        authoritativeCommitRevision: UInt64? = nil,
        commitDigestSHA256: String? = nil,
        handoffChainHeadDigestSHA256: String? = nil,
        rootPrepareRecordDigestsSHA256: [String]? = nil,
        terminalOutcomeDigestSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tokenID = tokenID
        self.tokenRevision = tokenRevision
        self.orderedSourceStateRootUUIDs = orderedSourceStateRootUUIDs
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.trustRegistryRevision = trustRegistryRevision
        self.resultingAuthorityLineageUUID = resultingAuthorityLineageUUID
        self.resultingLineageDigestKeyVersion = resultingLineageDigestKeyVersion
        self.phase = phase
        self.preCommitRootExpectations = preCommitRootExpectations
        self.destinationKeyPossessionProofDigestsSHA256 = destinationKeyPossessionProofDigestsSHA256
        self.manifestID = manifestID
        self.manifestDigest = manifestDigest
        self.importedParts = importedParts
        self.authoritativeCommitRevision = authoritativeCommitRevision
        self.commitDigestSHA256 = commitDigestSHA256
        self.handoffChainHeadDigestSHA256 = handoffChainHeadDigestSHA256
        self.rootPrepareRecordDigestsSHA256 = rootPrepareRecordDigestsSHA256
        self.terminalOutcomeDigestSHA256 = terminalOutcomeDigestSHA256
    }
}

public enum ProviderHandoffPartStagingStateV1: String, Codable, Equatable, Sendable {
    case declared
    case retrieving
    case transportVerified
    case decrypted
    case contentVerified
    case imported
    case compensationRequired
    case compensated
}

public enum ProviderHandoffPartStagingFailureClassV1: String, Codable, Equatable, Sendable {
    case transport
    case authentication
    case canonicalContent
    case capability
    case collision
    case importEffect
    case compensation
}

public struct ProviderHandoffByteRangeV1: Codable, Equatable, Sendable {
    public var lowerBound: UInt64
    public var upperBoundExclusive: UInt64

    public init(lowerBound: UInt64, upperBoundExclusive: UInt64) {
        self.lowerBound = lowerBound
        self.upperBoundExclusive = upperBoundExclusive
    }
}

public struct ProviderHandoffSourceDigestVerificationV1: Codable, Equatable, Sendable {
    public var sourceStateRootUUID: String
    public var authorityLineageUUID: String
    public var lineageDigestKeyVersion: UInt64
    public var computedSourceDigestHMACSHA256: String

    public init(
        sourceStateRootUUID: String,
        authorityLineageUUID: String,
        lineageDigestKeyVersion: UInt64,
        computedSourceDigestHMACSHA256: String
    ) {
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.lineageDigestKeyVersion = lineageDigestKeyVersion
        self.computedSourceDigestHMACSHA256 = computedSourceDigestHMACSHA256
    }
}

public struct ProviderHandoffPartStagingRecordV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var tokenID: String
    public var manifestID: String
    public var manifestDigest: String
    public var partKind: ProviderHandoffPartKindV1
    public var bundleObjectID: String
    public var payloadDescriptorDigestSHA256: String
    public var stagingRevision: UInt64
    public var state: ProviderHandoffPartStagingStateV1
    public var receivedRanges: [ProviderHandoffByteRangeV1]
    public var verifiedTransportDigestSHA256: String?
    public var sourceDigestVerifications: [ProviderHandoffSourceDigestVerificationV1]
    public var verifiedCanonicalContentDigest: String?
    public var stagedImportReceiptDigestSHA256: String?
    public var lastFailureClass: ProviderHandoffPartStagingFailureClassV1?

    public init(
        schemaVersion: UInt32 = 1,
        tokenID: String,
        manifestID: String,
        manifestDigest: String,
        partKind: ProviderHandoffPartKindV1,
        bundleObjectID: String,
        payloadDescriptorDigestSHA256: String,
        stagingRevision: UInt64,
        state: ProviderHandoffPartStagingStateV1,
        receivedRanges: [ProviderHandoffByteRangeV1] = [],
        verifiedTransportDigestSHA256: String? = nil,
        sourceDigestVerifications: [ProviderHandoffSourceDigestVerificationV1] = [],
        verifiedCanonicalContentDigest: String? = nil,
        stagedImportReceiptDigestSHA256: String? = nil,
        lastFailureClass: ProviderHandoffPartStagingFailureClassV1? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.manifestDigest = manifestDigest
        self.partKind = partKind
        self.bundleObjectID = bundleObjectID
        self.payloadDescriptorDigestSHA256 = payloadDescriptorDigestSHA256
        self.stagingRevision = stagingRevision
        self.state = state
        self.receivedRanges = receivedRanges
        self.verifiedTransportDigestSHA256 = verifiedTransportDigestSHA256
        self.sourceDigestVerifications = sourceDigestVerifications
        self.verifiedCanonicalContentDigest = verifiedCanonicalContentDigest
        self.stagedImportReceiptDigestSHA256 = stagedImportReceiptDigestSHA256
        self.lastFailureClass = lastFailureClass
    }
}

public struct ProviderHandoffPartImportExpectationV1: Codable, Equatable, Sendable {
    public var partKind: ProviderHandoffPartKindV1
    public var payloadDescriptorDigestSHA256: String
    public var stagedImportReceiptDigestSHA256: String

    public init(
        partKind: ProviderHandoffPartKindV1,
        payloadDescriptorDigestSHA256: String,
        stagedImportReceiptDigestSHA256: String
    ) {
        self.partKind = partKind
        self.payloadDescriptorDigestSHA256 = payloadDescriptorDigestSHA256
        self.stagedImportReceiptDigestSHA256 = stagedImportReceiptDigestSHA256
    }
}

public struct ProviderHandoffRootPrepareRecordV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var tokenID: String
    public var manifestID: String
    public var role: ProviderHandoffRootRoleV1
    public var stateRootUUID: String
    public var commitDigestSHA256: String
    public var expectedHeaderDigestSHA256: String
    public var preCommitRevisionVectorDigestSHA256: String
    public var postCommitHeaderDigestSHA256: String
    public var postCommitRevisionVectorDigestSHA256: String
    public var prepareRevision: UInt64

    public init(
        schemaVersion: UInt32 = 1,
        tokenID: String,
        manifestID: String,
        role: ProviderHandoffRootRoleV1,
        stateRootUUID: String,
        commitDigestSHA256: String,
        expectedHeaderDigestSHA256: String,
        preCommitRevisionVectorDigestSHA256: String,
        postCommitHeaderDigestSHA256: String,
        postCommitRevisionVectorDigestSHA256: String,
        prepareRevision: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.role = role
        self.stateRootUUID = stateRootUUID
        self.commitDigestSHA256 = commitDigestSHA256
        self.expectedHeaderDigestSHA256 = expectedHeaderDigestSHA256
        self.preCommitRevisionVectorDigestSHA256 = preCommitRevisionVectorDigestSHA256
        self.postCommitHeaderDigestSHA256 = postCommitHeaderDigestSHA256
        self.postCommitRevisionVectorDigestSHA256 = postCommitRevisionVectorDigestSHA256
        self.prepareRevision = prepareRevision
    }
}

public struct ProviderHandoffCommitIntentV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var tokenID: String
    public var manifestID: String
    public var manifestDigest: String
    public var trustRegistryRevision: UInt64
    public var authoritativeCommitRevision: UInt64
    public var preCommitRootExpectations: [ProviderHandoffHeaderExpectationV1]
    public var importedParts: [ProviderHandoffPartImportExpectationV1]
    public var destinationKeyPossessionProofDigestsSHA256: [String]
    public var providerSelection: ProviderHandoffProviderSelectionExpectationV1
    public var socketSelection: ProviderHandoffSocketSelectionExpectationV1
    public var resultingAuthorityLineageUUID: String
    public var resultingLineageDigestKeyVersion: UInt64
    public var resultingMinimumWriterSchemaVersion: UInt32

    public init(
        schemaVersion: UInt32 = 1,
        tokenID: String,
        manifestID: String,
        manifestDigest: String,
        trustRegistryRevision: UInt64,
        authoritativeCommitRevision: UInt64,
        preCommitRootExpectations: [ProviderHandoffHeaderExpectationV1],
        importedParts: [ProviderHandoffPartImportExpectationV1],
        destinationKeyPossessionProofDigestsSHA256: [String],
        providerSelection: ProviderHandoffProviderSelectionExpectationV1,
        socketSelection: ProviderHandoffSocketSelectionExpectationV1,
        resultingAuthorityLineageUUID: String,
        resultingLineageDigestKeyVersion: UInt64,
        resultingMinimumWriterSchemaVersion: UInt32
    ) {
        self.schemaVersion = schemaVersion
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.manifestDigest = manifestDigest
        self.trustRegistryRevision = trustRegistryRevision
        self.authoritativeCommitRevision = authoritativeCommitRevision
        self.preCommitRootExpectations = preCommitRootExpectations
        self.importedParts = importedParts
        self.destinationKeyPossessionProofDigestsSHA256 = destinationKeyPossessionProofDigestsSHA256
        self.providerSelection = providerSelection
        self.socketSelection = socketSelection
        self.resultingAuthorityLineageUUID = resultingAuthorityLineageUUID
        self.resultingLineageDigestKeyVersion = resultingLineageDigestKeyVersion
        self.resultingMinimumWriterSchemaVersion = resultingMinimumWriterSchemaVersion
    }
}

public struct ProviderHandoffPostCommitRootV1: Codable, Equatable, Sendable {
    public var role: ProviderHandoffRootRoleV1
    public var stateRootUUID: String
    public var postCommitHeader: StateRootHeaderV1
    public var postCommitHeaderDigestSHA256: String
    public var postCommitRevisionVector: ProviderHandoffRevisionVectorV1

    public init(
        role: ProviderHandoffRootRoleV1,
        stateRootUUID: String,
        postCommitHeader: StateRootHeaderV1,
        postCommitHeaderDigestSHA256: String,
        postCommitRevisionVector: ProviderHandoffRevisionVectorV1
    ) {
        self.role = role
        self.stateRootUUID = stateRootUUID
        self.postCommitHeader = postCommitHeader
        self.postCommitHeaderDigestSHA256 = postCommitHeaderDigestSHA256
        self.postCommitRevisionVector = postCommitRevisionVector
    }
}

public struct ProviderHandoffCommitRecordV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var intent: ProviderHandoffCommitIntentV1
    public var commitDigestSHA256: String
    public var handoffChainHeadDigestSHA256: String
    public var postCommitRoots: [ProviderHandoffPostCommitRootV1]
    public var rootPrepareRecordDigestsSHA256: [String]
    public var coordinatorSignature: ProviderHandoffSignatureV1

    public init(
        schemaVersion: UInt32 = 1,
        intent: ProviderHandoffCommitIntentV1,
        commitDigestSHA256: String,
        handoffChainHeadDigestSHA256: String,
        postCommitRoots: [ProviderHandoffPostCommitRootV1],
        rootPrepareRecordDigestsSHA256: [String],
        coordinatorSignature: ProviderHandoffSignatureV1
    ) {
        self.schemaVersion = schemaVersion
        self.intent = intent
        self.commitDigestSHA256 = commitDigestSHA256
        self.handoffChainHeadDigestSHA256 = handoffChainHeadDigestSHA256
        self.postCommitRoots = postCommitRoots
        self.rootPrepareRecordDigestsSHA256 = rootPrepareRecordDigestsSHA256
        self.coordinatorSignature = coordinatorSignature
    }
}

public struct ProviderHandoffTerminalRootV1: Codable, Equatable, Sendable {
    public var role: ProviderHandoffRootRoleV1
    public var stateRootUUID: String
    public var terminalHeader: StateRootHeaderV1
    public var terminalHeaderDigestSHA256: String
    public var terminalRevisionVector: ProviderHandoffRevisionVectorV1

    public init(
        role: ProviderHandoffRootRoleV1,
        stateRootUUID: String,
        terminalHeader: StateRootHeaderV1,
        terminalHeaderDigestSHA256: String,
        terminalRevisionVector: ProviderHandoffRevisionVectorV1
    ) {
        self.role = role
        self.stateRootUUID = stateRootUUID
        self.terminalHeader = terminalHeader
        self.terminalHeaderDigestSHA256 = terminalHeaderDigestSHA256
        self.terminalRevisionVector = terminalRevisionVector
    }
}

public struct ProviderHandoffTerminalOutcomeV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var tokenID: String
    public var manifestID: String
    public var manifestDigest: String?
    public var phase: ProviderHandoffPhaseV1
    public var roots: [ProviderHandoffTerminalRootV1]
    public var outcomeDigestSHA256: String
    public var coordinatorSignature: ProviderHandoffSignatureV1

    public init(
        schemaVersion: UInt32 = 1,
        tokenID: String,
        manifestID: String,
        manifestDigest: String?,
        phase: ProviderHandoffPhaseV1,
        roots: [ProviderHandoffTerminalRootV1],
        outcomeDigestSHA256: String,
        coordinatorSignature: ProviderHandoffSignatureV1
    ) {
        self.schemaVersion = schemaVersion
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.manifestDigest = manifestDigest
        self.phase = phase
        self.roots = roots
        self.outcomeDigestSHA256 = outcomeDigestSHA256
        self.coordinatorSignature = coordinatorSignature
    }
}

/// One gateway-retained immutable handoff transaction and its mutable token.
///
/// The manifest, commit record, and terminal outcome are append-only. Progress
/// is represented only by the token revision and closed phase transition.
public struct ProviderHandoffGatewayTransactionV1: Codable, Equatable, Sendable {
    public var token: ProviderHandoffTokenV1
    public var manifest: ProviderHandoffManifestV1?
    public var commitRecord: ProviderHandoffCommitRecordV1?
    /// Ordered, destination-private controller receipts produced while the
    /// signed transaction is reconciling. Persisting these opaque receipts in
    /// the gateway authority makes Complete -> activation replayable after a
    /// gateway restart without asking a controller to promote public state a
    /// second time.
    public var promotedPartReceipts: [ProviderHandoffPartOpaqueControllerReceiptV1]?
    public var terminalOutcome: ProviderHandoffTerminalOutcomeV1?

    public init(
        token: ProviderHandoffTokenV1,
        manifest: ProviderHandoffManifestV1? = nil,
        commitRecord: ProviderHandoffCommitRecordV1? = nil,
        promotedPartReceipts: [ProviderHandoffPartOpaqueControllerReceiptV1]? = nil,
        terminalOutcome: ProviderHandoffTerminalOutcomeV1? = nil
    ) {
        self.token = token
        self.manifest = manifest
        self.commitRecord = commitRecord
        self.promotedPartReceipts = promotedPartReceipts
        self.terminalOutcome = terminalOutcome
    }
}

/// Atomic gateway authority state.
///
/// Provider selection, socket discovery, the authoritative commit revision and
/// the active token are persisted in one replace transaction. Provider roots
/// remain separate authorities and converge from the signed commit record.
public struct ProviderHandoffGatewayStateV1: Codable, Equatable, Sendable {
    public var schemaVersion: UInt32
    public var storeRevision: UInt64
    public var authoritativeCommitRevision: UInt64
    public var providerSelection: ProviderHandoffProviderSelectionRecordV1
    public var socketDiscovery: ProviderHandoffSocketDiscoveryRecordV1
    public var activeTokenID: String?
    public var transactions: [ProviderHandoffGatewayTransactionV1]

    public init(
        schemaVersion: UInt32 = 1,
        storeRevision: UInt64,
        authoritativeCommitRevision: UInt64,
        providerSelection: ProviderHandoffProviderSelectionRecordV1,
        socketDiscovery: ProviderHandoffSocketDiscoveryRecordV1,
        activeTokenID: String?,
        transactions: [ProviderHandoffGatewayTransactionV1]
    ) {
        self.schemaVersion = schemaVersion
        self.storeRevision = storeRevision
        self.authoritativeCommitRevision = authoritativeCommitRevision
        self.providerSelection = providerSelection
        self.socketDiscovery = socketDiscovery
        self.activeTokenID = activeTokenID
        self.transactions = transactions
    }
}
