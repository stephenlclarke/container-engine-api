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
import Security

public struct ProviderHandoffProviderKeyEnrollmentContextV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var providerFingerprint: String
    public var stateRootUUID: String
    public var owningBundleIdentifier: String
    public var codeRequirementDigestSHA256: String
    public var teamIdentifier: String?
    public var providerRegistrationDigestSHA256: String
    public var enrolledAtUnixSeconds: UInt64
    public var notBeforeUnixSeconds: UInt64
    public var notAfterUnixSeconds: UInt64

    public init(
        providerFingerprint: String,
        stateRootUUID: String,
        owningBundleIdentifier: String,
        codeRequirementDigestSHA256: String,
        teamIdentifier: String?,
        providerRegistrationDigestSHA256: String,
        enrolledAtUnixSeconds: UInt64,
        notBeforeUnixSeconds: UInt64,
        notAfterUnixSeconds: UInt64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.providerFingerprint = providerFingerprint
        self.stateRootUUID = stateRootUUID
        self.owningBundleIdentifier = owningBundleIdentifier
        self.codeRequirementDigestSHA256 = codeRequirementDigestSHA256
        self.teamIdentifier = teamIdentifier
        self.providerRegistrationDigestSHA256 =
            providerRegistrationDigestSHA256
        self.enrolledAtUnixSeconds = enrolledAtUnixSeconds
        self.notBeforeUnixSeconds = notBeforeUnixSeconds
        self.notAfterUnixSeconds = notAfterUnixSeconds
    }
}

public enum ProviderHandoffProviderKeyStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case bindingMismatch
    case duplicatePurpose(ProviderHandoffKeyPurposeV1)
    case invalidContext
    case invalidEncoding
    case invalidKey(ProviderHandoffKeyPurposeV1)
    case keyNotFound(ProviderHandoffKeyPurposeV1)
    case keySetTooLarge
    case keychain(OSStatus)
    case notFound

    public var description: String {
        switch self {
        case .bindingMismatch:
            "provider handoff private keys do not match the selected provider binding"
        case .duplicatePurpose(let purpose):
            "provider handoff private key set contains duplicate purpose \(purpose.rawValue)"
        case .invalidContext:
            "provider handoff private key enrollment context is invalid"
        case .invalidEncoding:
            "provider handoff private key Keychain value is invalid"
        case .invalidKey(let purpose):
            "provider handoff private key for \(purpose.rawValue) is invalid"
        case .keyNotFound(let purpose):
            "provider handoff private key for \(purpose.rawValue) was not found"
        case .keySetTooLarge:
            "provider handoff private key set exceeds its 64 KiB bound"
        case .keychain(let status):
            "provider handoff private key Keychain operation failed with status \(status)"
        case .notFound:
            "provider handoff private key set does not exist"
        }
    }
}

/// Loaded provider identity whose raw private keys never leave RuntimeSPI.
///
/// Each operational purpose has a distinct key and trust-registry entry. The
/// public helpers below permit only the cryptographic operation associated with
/// that purpose; callers cannot request arbitrary raw private-key bytes.
public struct ProviderHandoffProviderIdentityV1: Sendable {
    public let context: ProviderHandoffProviderKeyEnrollmentContextV1
    public let trustKeys: [ProviderHandoffTrustKeyV1]

    private let privateKeysByPurpose: [ProviderHandoffKeyPurposeV1: Data]

    fileprivate init(
        context: ProviderHandoffProviderKeyEnrollmentContextV1,
        materials: [ProviderHandoffProviderKeyStore.StoredKeyMaterialV1]
    ) {
        self.context = context
        trustKeys = materials.map(\.trustKey)
        privateKeysByPurpose = Dictionary(
            uniqueKeysWithValues: materials.map {
                ($0.trustKey.purpose, $0.privateKey)
            }
        )
    }

    public func trustKey(
        for purpose: ProviderHandoffKeyPurposeV1
    ) throws -> ProviderHandoffTrustKeyV1 {
        guard let value = trustKeys.first(where: { $0.purpose == purpose }) else {
            throw ProviderHandoffProviderKeyStoreError.keyNotFound(purpose)
        }
        return value
    }

    public func sign(
        projectionDigestSHA256: String,
        purpose: ProviderHandoffKeyPurposeV1,
        trustRegistryRevision: UInt64
    ) throws -> ProviderHandoffSignatureV1 {
        guard
            [.sourceManifestSigning, .lineageKeyEnvelopeSigning]
                .contains(purpose),
            let privateKey = privateKeysByPurpose[purpose]
        else {
            throw ProviderHandoffProviderKeyStoreError.keyNotFound(purpose)
        }
        let key = try trustKey(for: purpose)
        return try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: projectionDigestSHA256,
            purpose: purpose,
            signerKeyID: key.keyID,
            signerRole: key.role,
            providerFingerprint: context.providerFingerprint,
            stateRootUUID: context.stateRootUUID,
            trustRegistryRevision: trustRegistryRevision,
            privateKey: privateKey
        )
    }

    public func respond(
        to challenge: ProviderHandoffPendingPossessionChallengeV1,
        trustRegistryRevision: UInt64
    ) throws -> ProviderHandoffDestinationKeyPossessionProofV1 {
        try respond(
            to: challenge.transportChallenge,
            trustRegistryRevision: trustRegistryRevision
        )
    }

    public func respond(
        to challenge: ProviderHandoffDestinationPossessionChallengeV1,
        trustRegistryRevision: UInt64
    ) throws -> ProviderHandoffDestinationKeyPossessionProofV1 {
        guard
            challenge.destinationProviderFingerprint
                == context.providerFingerprint,
            challenge.destinationStateRootUUID == context.stateRootUUID,
            [.destinationPayloadEncryption, .destinationLineageKeyEncryption]
                .contains(challenge.destinationKeyPurpose),
            let destinationPrivateKey = privateKeysByPurpose[
                challenge.destinationKeyPurpose
            ],
            try trustKey(for: challenge.destinationKeyPurpose).keyID
                == challenge.destinationKeyID,
            let possessionPrivateKey = privateKeysByPurpose[
                .destinationPossessionSigning
            ]
        else {
            throw ProviderHandoffProviderKeyStoreError.bindingMismatch
        }
        let possessionKey = try trustKey(
            for: .destinationPossessionSigning
        )
        return try ProviderHandoffPossessionProofCodec.respond(
            to: challenge,
            destinationPrivateKey: destinationPrivateKey,
            possessionSigningKeyID: possessionKey.keyID,
            trustRegistryRevision: trustRegistryRevision,
            possessionSigningPrivateKey: possessionPrivateKey
        )
    }

    public func open(
        _ envelope: DestinationSealedLineageKeyEnvelopeV1,
        tokenID: String,
        manifestID: String,
        sourceProviderFingerprint: String?,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffEnvelopeLineageKeyV1 {
        guard
            envelope.destinationKeyPurpose
                == .destinationLineageKeyEncryption,
            try trustKey(for: .destinationLineageKeyEncryption).keyID
                == envelope.destinationKeyID,
            let privateKey = privateKeysByPurpose[
                .destinationLineageKeyEncryption
            ]
        else {
            throw ProviderHandoffProviderKeyStoreError.bindingMismatch
        }
        return try ProviderHandoffLineageKeyEnvelopeCodec.open(
            envelope,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: context.providerFingerprint,
            destinationStateRootUUID: context.stateRootUUID,
            sourceProviderFingerprint: sourceProviderFingerprint,
            trustRegistry: trustRegistry,
            atUnixSeconds: atUnixSeconds,
            destinationPrivateKey: privateKey
        )
    }

    public func sealLineageKey(
        _ lineageKey: ProviderHandoffEnvelopeLineageKeyV1,
        envelopeID: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce: Data,
        trustRegistryRevision: UInt64,
        ephemeralPrivateKey: Data? = nil
    ) throws -> DestinationSealedLineageKeyEnvelopeV1 {
        guard
            lineageKey.sourceStateRootUUID == context.stateRootUUID,
            let privateKey = privateKeysByPurpose[
                .lineageKeyEnvelopeSigning
            ]
        else {
            throw ProviderHandoffProviderKeyStoreError.bindingMismatch
        }
        let signingKey = try trustKey(for: .lineageKeyEnvelopeSigning)
        return try ProviderHandoffLineageKeyEnvelopeCodec.prepare(
            lineageKey,
            envelopeID: envelopeID,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyID: destinationKeyID,
            destinationPublicKey: destinationPublicKey,
            nonce: nonce,
            signerKeyID: signingKey.keyID,
            signerRole: .sourceProvider,
            signerProviderFingerprint: context.providerFingerprint,
            signerStateRootUUID: context.stateRootUUID,
            trustRegistryRevision: trustRegistryRevision,
            signerPrivateKey: privateKey,
            ephemeralPrivateKey: ephemeralPrivateKey
        )
    }

    public func open(
        _ payload: ProviderHandoffPreparedPayloadV1,
        expectedPartKind: ProviderHandoffPartKindV1,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1]
    ) throws -> ProviderHandoffPayloadPackageV1 {
        guard
            payload.descriptor.destinationEncryption?.destinationKeyPurpose
                == .destinationPayloadEncryption,
            let keyID = payload.descriptor.destinationEncryption?
                .destinationKeyID,
            try trustKey(for: .destinationPayloadEncryption).keyID == keyID,
            let privateKey = privateKeysByPurpose[
                .destinationPayloadEncryption
            ]
        else {
            throw ProviderHandoffProviderKeyStoreError.bindingMismatch
        }
        return try ProviderHandoffPayloadCodec.openSealed(
            payload,
            expectedPartKind: expectedPartKind,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: sourceOrder,
            lineageKeys: lineageKeys,
            destinationProviderFingerprint: context.providerFingerprint,
            destinationStateRootUUID: context.stateRootUUID,
            destinationPrivateKey: privateKey
        )
    }
}

/// Current-user Keychain persistence for provider-owned handoff private keys.
///
/// The full purpose-separated key set is one immutable Keychain value. A
/// duplicate first-writer race adopts only a byte-valid winner with the exact
/// provider/root binding. A restart may supply a new proposed enrollment time
/// and validity window, but an existing key set retains its immutable original
/// enrollment record. A changed provider binding never rotates or replaces
/// private keys implicitly.
public struct ProviderHandoffProviderKeyStore: Sendable {
    public static let maximumKeySetBytes = 64 * 1024

    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String =
            "io.github.stephenlclarke.container-engine.provider-handoff",
        account: String = "provider-private-keys-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadOrCreate(
        context: ProviderHandoffProviderKeyEnrollmentContextV1
    ) throws -> ProviderHandoffProviderIdentityV1 {
        try Self.validate(context)
        do {
            return try load(expectedContext: context)
        } catch ProviderHandoffProviderKeyStoreError.notFound {
            let generated = try Self.generate(context: context)
            let encoded = try Self.encode(generated)
            do {
                try add(encoded)
                return try Self.identity(generated, expectedContext: context)
            } catch ProviderHandoffProviderKeyStoreError
                .keychain(errSecDuplicateItem)
            {
                return try load(expectedContext: context)
            }
        }
    }

    public func load(
        expectedContext: ProviderHandoffProviderKeyEnrollmentContextV1
    ) throws -> ProviderHandoffProviderIdentityV1 {
        try Self.validate(expectedContext)
        let value = try Self.decode(read())
        return try Self.identity(value, expectedContext: expectedContext)
    }

    private func add(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData] = data
        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderHandoffProviderKeyStoreError.keychain(status)
        }
    }

    private func read() throws -> Data {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw ProviderHandoffProviderKeyStoreError.invalidEncoding
            }
            guard data.count <= Self.maximumKeySetBytes else {
                throw ProviderHandoffProviderKeyStoreError.keySetTooLarge
            }
            return data
        case errSecItemNotFound:
            throw ProviderHandoffProviderKeyStoreError.notFound
        default:
            throw ProviderHandoffProviderKeyStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    static func removeForTesting(
        service: String,
        account: String
    ) throws {
        let status = SecItemDelete(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
            ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderHandoffProviderKeyStoreError.keychain(status)
        }
    }

    fileprivate struct StoredKeyMaterialV1: Codable, Equatable, Sendable {
        var trustKey: ProviderHandoffTrustKeyV1
        var privateKey: Data
    }

    private struct StoredKeySetV1: Codable, Equatable, Sendable {
        static let currentSchemaVersion: UInt32 = 1

        var schemaVersion: UInt32
        var context: ProviderHandoffProviderKeyEnrollmentContextV1
        var materials: [StoredKeyMaterialV1]
    }

    private static let keySpecifications:
        [(
            purpose: ProviderHandoffKeyPurposeV1,
            algorithm: ProviderHandoffPublicKeyAlgorithmV1,
            role: ProviderHandoffKeyRoleV1
        )] = [
            (.sourceManifestSigning, .ed25519V1, .sourceProvider),
            (.lineageKeyEnvelopeSigning, .ed25519V1, .sourceProvider),
            (.destinationPossessionSigning, .ed25519V1, .destinationProvider),
            (.destinationPayloadEncryption, .x25519V1, .destinationProvider),
            (.destinationLineageKeyEncryption, .x25519V1, .destinationProvider),
        ]

    private static func generate(
        context: ProviderHandoffProviderKeyEnrollmentContextV1
    ) throws -> StoredKeySetV1 {
        let materials = try keySpecifications.map { specification in
            let privateKey: Data
            let publicKey: Data
            switch specification.algorithm {
            case .ed25519V1:
                privateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
                publicKey = try ProviderHandoffCrypto.ed25519PublicKey(
                    for: privateKey
                )
            case .x25519V1:
                privateKey = ProviderHandoffCrypto.generateX25519PrivateKey()
                publicKey = try ProviderHandoffCrypto.x25519PublicKey(
                    for: privateKey
                )
            }
            let keyID = try ProviderHandoffCrypto.trustKeyID(
                algorithm: specification.algorithm,
                role: specification.role,
                purpose: specification.purpose,
                providerFingerprint: context.providerFingerprint,
                stateRootUUID: context.stateRootUUID,
                rawPublicKey: publicKey
            )
            var trustKey = ProviderHandoffTrustKeyV1(
                keyID: keyID,
                algorithm: specification.algorithm,
                role: specification.role,
                purpose: specification.purpose,
                providerFingerprint: context.providerFingerprint,
                stateRootUUID: context.stateRootUUID,
                rawPublicKey: publicKey,
                provenance: ProviderHandoffPublicKeyProvenanceV1(
                    enrollmentID: UUID().uuidString.lowercased(),
                    owningBundleIdentifier: context.owningBundleIdentifier,
                    codeRequirementDigestSHA256:
                        context.codeRequirementDigestSHA256,
                    teamIdentifier: context.teamIdentifier,
                    providerRegistrationDigestSHA256:
                        context.providerRegistrationDigestSHA256,
                    enrolledAtUnixSeconds: context.enrolledAtUnixSeconds,
                    enrollmentProofSignature: nil
                ),
                notBeforeUnixSeconds: context.notBeforeUnixSeconds,
                notAfterUnixSeconds: context.notAfterUnixSeconds,
                rotationPredecessorKeyID: nil,
                revokedAtUnixSeconds: nil,
                revocationReason: nil
            )
            if specification.algorithm == .ed25519V1 {
                trustKey.provenance.enrollmentProofSignature =
                    try ProviderHandoffTrustRegistryValidator
                    .enrollmentProofSignature(
                        for: trustKey,
                        privateKey: privateKey
                    )
            }
            return StoredKeyMaterialV1(
                trustKey: trustKey,
                privateKey: privateKey
            )
        }.sorted {
            $0.trustKey.keyID.utf8.lexicographicallyPrecedes(
                $1.trustKey.keyID.utf8
            )
        }
        return StoredKeySetV1(
            schemaVersion: StoredKeySetV1.currentSchemaVersion,
            context: context,
            materials: materials
        )
    }

    private static func identity(
        _ value: StoredKeySetV1,
        expectedContext: ProviderHandoffProviderKeyEnrollmentContextV1
    ) throws -> ProviderHandoffProviderIdentityV1 {
        guard
            value.schemaVersion == StoredKeySetV1.currentSchemaVersion,
            bindingMatches(value.context, expectedContext)
        else {
            throw ProviderHandoffProviderKeyStoreError.bindingMismatch
        }
        try validate(value.context)
        let sorted = value.materials.sorted {
            $0.trustKey.keyID.utf8.lexicographicallyPrecedes(
                $1.trustKey.keyID.utf8
            )
        }
        guard sorted == value.materials else {
            throw ProviderHandoffProviderKeyStoreError.invalidEncoding
        }
        var purposes = Set<ProviderHandoffKeyPurposeV1>()
        for material in value.materials {
            guard purposes.insert(material.trustKey.purpose).inserted else {
                throw ProviderHandoffProviderKeyStoreError.duplicatePurpose(
                    material.trustKey.purpose
                )
            }
            try validate(material, context: value.context)
        }
        guard
            purposes == Set(keySpecifications.map(\.purpose)),
            value.materials.count == keySpecifications.count
        else {
            throw ProviderHandoffProviderKeyStoreError.invalidEncoding
        }
        return ProviderHandoffProviderIdentityV1(
            context: value.context,
            materials: value.materials
        )
    }

    private static func bindingMatches(
        _ stored: ProviderHandoffProviderKeyEnrollmentContextV1,
        _ expected: ProviderHandoffProviderKeyEnrollmentContextV1
    ) -> Bool {
        stored.schemaVersion == expected.schemaVersion
            && stored.providerFingerprint == expected.providerFingerprint
            && stored.stateRootUUID == expected.stateRootUUID
            && stored.owningBundleIdentifier
                == expected.owningBundleIdentifier
            && stored.codeRequirementDigestSHA256
                == expected.codeRequirementDigestSHA256
            && stored.teamIdentifier == expected.teamIdentifier
            && stored.providerRegistrationDigestSHA256
                == expected.providerRegistrationDigestSHA256
    }

    private static func validate(
        _ context: ProviderHandoffProviderKeyEnrollmentContextV1
    ) throws {
        let fingerprintDigest =
            context.providerFingerprint
                .hasPrefix("sha256:")
            ? String(context.providerFingerprint.dropFirst(7))
            : ""
        guard
            context.schemaVersion
                == ProviderHandoffProviderKeyEnrollmentContextV1
                .currentSchemaVersion,
            context.providerFingerprint.utf8.count <= 256,
            context.providerFingerprint.precomposedStringWithCanonicalMapping
                == context.providerFingerprint,
            (try? ProviderHandoffDigest.parseSHA256(fingerprintDigest))?.count
                == 32,
            let root = UUID(uuidString: context.stateRootUUID),
            root.uuidString.lowercased() == context.stateRootUUID,
            !context.owningBundleIdentifier.isEmpty,
            context.owningBundleIdentifier.utf8.count <= 256,
            context.owningBundleIdentifier
                .precomposedStringWithCanonicalMapping
                == context.owningBundleIdentifier,
            (try? ProviderHandoffDigest.parseSHA256(
                context.codeRequirementDigestSHA256
            ))?.count == 32,
            (try? ProviderHandoffDigest.parseSHA256(
                context.providerRegistrationDigestSHA256
            ))?.count == 32,
            context.teamIdentifier?.isEmpty != true,
            context.teamIdentifier?.utf8.count ?? 0 <= 128,
            context.enrolledAtUnixSeconds >= context.notBeforeUnixSeconds,
            context.enrolledAtUnixSeconds <= context.notAfterUnixSeconds,
            context.notBeforeUnixSeconds <= context.notAfterUnixSeconds
        else {
            throw ProviderHandoffProviderKeyStoreError.invalidContext
        }
    }

    private static func validate(
        _ material: StoredKeyMaterialV1,
        context: ProviderHandoffProviderKeyEnrollmentContextV1
    ) throws {
        let key = material.trustKey
        guard
            let specification = keySpecifications.first(where: {
                $0.purpose == key.purpose
            }),
            key.algorithm == specification.algorithm,
            key.role == specification.role,
            key.providerFingerprint == context.providerFingerprint,
            key.stateRootUUID == context.stateRootUUID,
            key.provenance.owningBundleIdentifier
                == context.owningBundleIdentifier,
            key.provenance.codeRequirementDigestSHA256
                == context.codeRequirementDigestSHA256,
            key.provenance.teamIdentifier == context.teamIdentifier,
            key.provenance.providerRegistrationDigestSHA256
                == context.providerRegistrationDigestSHA256,
            key.provenance.enrolledAtUnixSeconds
                == context.enrolledAtUnixSeconds,
            key.notBeforeUnixSeconds == context.notBeforeUnixSeconds,
            key.notAfterUnixSeconds == context.notAfterUnixSeconds,
            key.rotationPredecessorKeyID == nil,
            key.revokedAtUnixSeconds == nil,
            key.revocationReason == nil,
            !key.provenance.enrollmentID.isEmpty,
            UUID(uuidString: key.provenance.enrollmentID)?.uuidString
                .lowercased() == key.provenance.enrollmentID,
            material.privateKey.count == 32
        else {
            throw ProviderHandoffProviderKeyStoreError.invalidKey(key.purpose)
        }
        let publicKey: Data
        switch key.algorithm {
        case .ed25519V1:
            publicKey = try ProviderHandoffCrypto.ed25519PublicKey(
                for: material.privateKey
            )
            guard let proof = key.provenance.enrollmentProofSignature else {
                throw ProviderHandoffProviderKeyStoreError.invalidKey(
                    key.purpose
                )
            }
            do {
                let digest =
                    try ProviderHandoffProjections
                    .enrollmentProofDigest(key)
                try ProviderHandoffCrypto.verifyEd25519Message(
                    ProviderHandoffDigest.parseSHA256(digest),
                    signature: proof,
                    publicKey: publicKey
                )
            } catch {
                throw ProviderHandoffProviderKeyStoreError.invalidKey(
                    key.purpose
                )
            }
        case .x25519V1:
            guard key.provenance.enrollmentProofSignature == nil else {
                throw ProviderHandoffProviderKeyStoreError.invalidKey(
                    key.purpose
                )
            }
            publicKey = try ProviderHandoffCrypto.x25519PublicKey(
                for: material.privateKey
            )
            try ProviderHandoffCrypto.validateX25519PublicKey(publicKey)
        }
        guard
            publicKey == key.rawPublicKey,
            try ProviderHandoffCrypto.trustKeyID(
                algorithm: key.algorithm,
                role: key.role,
                purpose: key.purpose,
                providerFingerprint: key.providerFingerprint,
                stateRootUUID: key.stateRootUUID,
                rawPublicKey: key.rawPublicKey
            ) == key.keyID
        else {
            throw ProviderHandoffProviderKeyStoreError.invalidKey(key.purpose)
        }
    }

    private static func encode(_ value: StoredKeySetV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumKeySetBytes else {
            throw ProviderHandoffProviderKeyStoreError.keySetTooLarge
        }
        return data
    }

    private static func decode(_ data: Data) throws -> StoredKeySetV1 {
        guard data.count <= maximumKeySetBytes else {
            throw ProviderHandoffProviderKeyStoreError.keySetTooLarge
        }
        do {
            let value = try JSONDecoder().decode(StoredKeySetV1.self, from: data)
            guard try encode(value) == data else {
                throw ProviderHandoffProviderKeyStoreError.invalidEncoding
            }
            return value
        } catch let error as ProviderHandoffProviderKeyStoreError {
            throw error
        } catch {
            throw ProviderHandoffProviderKeyStoreError.invalidEncoding
        }
    }
}
