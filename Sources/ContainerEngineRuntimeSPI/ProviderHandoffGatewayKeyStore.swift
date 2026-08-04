//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation
import Security

public struct ProviderHandoffGatewayKeyEnrollmentContextV1:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: UInt32
    public var owningBundleIdentifier: String
    public var codeRequirementDigestSHA256: String
    public var teamIdentifier: String?
    public var gatewayRegistrationDigestSHA256: String
    public var enrolledAtUnixSeconds: UInt64
    public var notBeforeUnixSeconds: UInt64
    public var notAfterUnixSeconds: UInt64

    public init(
        owningBundleIdentifier: String,
        codeRequirementDigestSHA256: String,
        teamIdentifier: String?,
        gatewayRegistrationDigestSHA256: String,
        enrolledAtUnixSeconds: UInt64,
        notBeforeUnixSeconds: UInt64,
        notAfterUnixSeconds: UInt64
    ) {
        schemaVersion = 1
        self.owningBundleIdentifier = owningBundleIdentifier
        self.codeRequirementDigestSHA256 = codeRequirementDigestSHA256
        self.teamIdentifier = teamIdentifier
        self.gatewayRegistrationDigestSHA256 =
            gatewayRegistrationDigestSHA256
        self.enrolledAtUnixSeconds = enrolledAtUnixSeconds
        self.notBeforeUnixSeconds = notBeforeUnixSeconds
        self.notAfterUnixSeconds = notAfterUnixSeconds
    }

    public static func registrationDigest(
        codeIdentity: ProviderHandoffCodeIdentityV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-gateway-registration-v1",
            projection: .map([
                .init(
                    "codeRequirementDigestSHA256",
                    .byteString(
                        try ProviderHandoffDigest.parseSHA256(
                            codeIdentity.designatedRequirementDigestSHA256
                        )
                    )
                ),
                .init(
                    "owningBundleIdentifier",
                    .textString(codeIdentity.signingIdentifier)
                ),
                .init("schemaVersion", .unsigned(1)),
                .init("teamIdentifier", .optional(codeIdentity.teamIdentifier)),
            ])
        )
    }
}

public enum ProviderHandoffGatewayKeyStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case bindingMismatch
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
            "provider handoff gateway keys do not match the gateway code identity"
        case .invalidContext:
            "provider handoff gateway key enrollment context is invalid"
        case .invalidEncoding:
            "provider handoff gateway key Keychain value is invalid"
        case .invalidKey(let purpose):
            "provider handoff gateway key for \(purpose.rawValue) is invalid"
        case .keyNotFound(let purpose):
            "provider handoff gateway key for \(purpose.rawValue) was not found"
        case .keySetTooLarge:
            "provider handoff gateway key set exceeds its 64 KiB bound"
        case .keychain(let status):
            "provider handoff gateway key Keychain operation failed with status \(status)"
        case .notFound:
            "provider handoff gateway key set does not exist"
        }
    }
}

public struct ProviderHandoffGatewayIdentityV1: Sendable {
    public let context: ProviderHandoffGatewayKeyEnrollmentContextV1
    public let trustKeys: [ProviderHandoffTrustKeyV1]
    public let bootstrap: ProviderHandoffPinnedBootstrapKeyV1

    private let privateKeysByPurpose: [ProviderHandoffKeyPurposeV1: Data]

    fileprivate init(
        context: ProviderHandoffGatewayKeyEnrollmentContextV1,
        materials: [ProviderHandoffGatewayKeyStore.StoredKeyMaterialV1]
    ) throws {
        self.context = context
        trustKeys = materials.map(\.trustKey)
        privateKeysByPurpose = Dictionary(
            uniqueKeysWithValues: materials.map {
                ($0.trustKey.purpose, $0.privateKey)
            }
        )
        guard
            let bootstrapKey = materials.first(where: {
                $0.trustKey.purpose == .trustRegistrySigning
            })?.trustKey
        else {
            throw ProviderHandoffGatewayKeyStoreError.keyNotFound(
                .trustRegistrySigning
            )
        }
        bootstrap = ProviderHandoffPinnedBootstrapKeyV1(
            keyID: bootstrapKey.keyID,
            rawPublicKey: bootstrapKey.rawPublicKey,
            codeRequirementDigestSHA256:
                context.codeRequirementDigestSHA256
        )
    }

    public func trustKey(
        for purpose: ProviderHandoffKeyPurposeV1
    ) throws -> ProviderHandoffTrustKeyV1 {
        guard let value = trustKeys.first(where: { $0.purpose == purpose }) else {
            throw ProviderHandoffGatewayKeyStoreError.keyNotFound(purpose)
        }
        return value
    }

    public func sign(
        projectionDigestSHA256: String,
        purpose: ProviderHandoffKeyPurposeV1,
        trustRegistryRevision: UInt64
    ) throws -> ProviderHandoffSignatureV1 {
        guard
            [
                .coordinatorManifestSigning,
                .lineageKeyEnvelopeSigning,
                .coordinatorCommitSigning,
                .coordinatorTerminalOutcomeSigning,
            ].contains(purpose),
            let privateKey = privateKeysByPurpose[purpose]
        else {
            throw ProviderHandoffGatewayKeyStoreError.keyNotFound(purpose)
        }
        let key = try trustKey(for: purpose)
        return try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: projectionDigestSHA256,
            purpose: purpose,
            signerKeyID: key.keyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: trustRegistryRevision,
            privateKey: privateKey
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
            lineageKey.sourceStateRootUUID == nil,
            let privateKey = privateKeysByPurpose[
                .lineageKeyEnvelopeSigning
            ]
        else {
            throw ProviderHandoffGatewayKeyStoreError.keyNotFound(
                .lineageKeyEnvelopeSigning
            )
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
            signerRole: .gatewayCoordinator,
            signerProviderFingerprint: nil,
            signerStateRootUUID: nil,
            trustRegistryRevision: trustRegistryRevision,
            signerPrivateKey: privateKey,
            ephemeralPrivateKey: ephemeralPrivateKey
        )
    }

    public func makeTrustRegistry(
        providerKeys: [ProviderHandoffTrustKeyV1],
        registryRevision: UInt64,
        issuedAtUnixSeconds: UInt64,
        previousRegistry: ProviderHandoffTrustRegistryV1? = nil
    ) throws -> ProviderHandoffValidatedTrustRegistryV1 {
        guard
            let bootstrapPrivateKey = privateKeysByPurpose[
                .trustRegistrySigning
            ]
        else {
            throw ProviderHandoffGatewayKeyStoreError.keyNotFound(
                .trustRegistrySigning
            )
        }
        let keys = (trustKeys + providerKeys).sorted {
            $0.keyID.utf8.lexicographicallyPrecedes($1.keyID.utf8)
        }
        var registry = ProviderHandoffTrustRegistryV1(
            registryRevision: registryRevision,
            issuedAtUnixSeconds: issuedAtUnixSeconds,
            keys: keys,
            registryDigestSHA256: String(repeating: "0", count: 64),
            registrySignature: ProviderHandoffSignatureV1(
                purpose: .trustRegistrySigning,
                signerKeyID: bootstrap.keyID,
                signerRole: .gatewayCoordinator,
                providerFingerprint: nil,
                stateRootUUID: nil,
                trustRegistryRevision: registryRevision,
                signedProjectionDigestSHA256: String(
                    repeating: "0",
                    count: 64
                ),
                signature: Data(repeating: 0, count: 64)
            )
        )
        registry.registryDigestSHA256 =
            try ProviderHandoffProjections
            .trustRegistryDigest(registry)
        registry.registrySignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: registry.registryDigestSHA256,
            purpose: .trustRegistrySigning,
            signerKeyID: bootstrap.keyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: registryRevision,
            privateKey: bootstrapPrivateKey
        )
        return try ProviderHandoffTrustRegistryValidator.validate(
            registry,
            bootstrap: bootstrap,
            previousRegistry: previousRegistry
        )
    }
}

public struct ProviderHandoffGatewayKeyStore: Sendable {
    public static let maximumKeySetBytes = 64 * 1024

    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String =
            "io.github.stephenlclarke.container-engine.provider-handoff",
        account: String = "gateway-private-keys-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadOrCreate(
        context: ProviderHandoffGatewayKeyEnrollmentContextV1
    ) throws -> ProviderHandoffGatewayIdentityV1 {
        try Self.validate(context)
        do {
            return try load(expectedContext: context)
        } catch ProviderHandoffGatewayKeyStoreError.notFound {
            let generated = try Self.generate(context: context)
            let encoded = try Self.encode(generated)
            do {
                try add(encoded)
                return try Self.identity(generated, expectedContext: context)
            } catch ProviderHandoffGatewayKeyStoreError
                .keychain(errSecDuplicateItem)
            {
                return try load(expectedContext: context)
            }
        }
    }

    public func load(
        expectedContext: ProviderHandoffGatewayKeyEnrollmentContextV1
    ) throws -> ProviderHandoffGatewayIdentityV1 {
        try Self.validate(expectedContext)
        return try Self.identity(
            Self.decode(read()),
            expectedContext: expectedContext
        )
    }

    private func add(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData] = data
        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderHandoffGatewayKeyStoreError.keychain(status)
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
                throw ProviderHandoffGatewayKeyStoreError.invalidEncoding
            }
            guard data.count <= Self.maximumKeySetBytes else {
                throw ProviderHandoffGatewayKeyStoreError.keySetTooLarge
            }
            return data
        case errSecItemNotFound:
            throw ProviderHandoffGatewayKeyStoreError.notFound
        default:
            throw ProviderHandoffGatewayKeyStoreError.keychain(status)
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
            throw ProviderHandoffGatewayKeyStoreError.keychain(status)
        }
    }

    fileprivate struct StoredKeyMaterialV1: Codable, Equatable, Sendable {
        var trustKey: ProviderHandoffTrustKeyV1
        var privateKey: Data
    }

    private struct StoredKeySetV1: Codable, Equatable, Sendable {
        var schemaVersion: UInt32
        var context: ProviderHandoffGatewayKeyEnrollmentContextV1
        var materials: [StoredKeyMaterialV1]
    }

    private static let purposes: [ProviderHandoffKeyPurposeV1] = [
        .trustRegistrySigning,
        .coordinatorManifestSigning,
        .lineageKeyEnvelopeSigning,
        .coordinatorCommitSigning,
        .coordinatorTerminalOutcomeSigning,
    ]

    private static func generate(
        context: ProviderHandoffGatewayKeyEnrollmentContextV1
    ) throws -> StoredKeySetV1 {
        let materials = try purposes.map { purpose in
            let privateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
            let publicKey = try ProviderHandoffCrypto.ed25519PublicKey(
                for: privateKey
            )
            let keyID = try ProviderHandoffCrypto.trustKeyID(
                algorithm: .ed25519V1,
                role: .gatewayCoordinator,
                purpose: purpose,
                providerFingerprint: nil,
                stateRootUUID: nil,
                rawPublicKey: publicKey
            )
            var key = ProviderHandoffTrustKeyV1(
                keyID: keyID,
                algorithm: .ed25519V1,
                role: .gatewayCoordinator,
                purpose: purpose,
                providerFingerprint: nil,
                stateRootUUID: nil,
                rawPublicKey: publicKey,
                provenance: ProviderHandoffPublicKeyProvenanceV1(
                    enrollmentID: UUID().uuidString.lowercased(),
                    owningBundleIdentifier: context.owningBundleIdentifier,
                    codeRequirementDigestSHA256:
                        context.codeRequirementDigestSHA256,
                    teamIdentifier: context.teamIdentifier,
                    providerRegistrationDigestSHA256:
                        context.gatewayRegistrationDigestSHA256,
                    enrolledAtUnixSeconds: context.enrolledAtUnixSeconds,
                    enrollmentProofSignature: nil
                ),
                notBeforeUnixSeconds: context.notBeforeUnixSeconds,
                notAfterUnixSeconds: context.notAfterUnixSeconds,
                rotationPredecessorKeyID: nil,
                revokedAtUnixSeconds: nil,
                revocationReason: nil
            )
            if purpose != .trustRegistrySigning {
                key.provenance.enrollmentProofSignature =
                    try ProviderHandoffTrustRegistryValidator
                    .enrollmentProofSignature(
                        for: key,
                        privateKey: privateKey
                    )
            }
            return StoredKeyMaterialV1(
                trustKey: key,
                privateKey: privateKey
            )
        }.sorted {
            $0.trustKey.keyID.utf8.lexicographicallyPrecedes(
                $1.trustKey.keyID.utf8
            )
        }
        return StoredKeySetV1(
            schemaVersion: 1,
            context: context,
            materials: materials
        )
    }

    private static func identity(
        _ value: StoredKeySetV1,
        expectedContext: ProviderHandoffGatewayKeyEnrollmentContextV1
    ) throws -> ProviderHandoffGatewayIdentityV1 {
        guard
            value.schemaVersion == 1,
            bindingMatches(value.context, expectedContext),
            value.materials.count == purposes.count,
            Set(value.materials.map(\.trustKey.purpose)) == Set(purposes),
            value.materials.map(\.trustKey.keyID)
                == value.materials.map(\.trustKey.keyID).sorted()
        else {
            throw ProviderHandoffGatewayKeyStoreError.bindingMismatch
        }
        try validate(value.context)
        for material in value.materials {
            try validate(material, context: value.context)
        }
        return try ProviderHandoffGatewayIdentityV1(
            context: value.context,
            materials: value.materials
        )
    }

    private static func bindingMatches(
        _ stored: ProviderHandoffGatewayKeyEnrollmentContextV1,
        _ expected: ProviderHandoffGatewayKeyEnrollmentContextV1
    ) -> Bool {
        stored.schemaVersion == expected.schemaVersion
            && stored.owningBundleIdentifier
                == expected.owningBundleIdentifier
            && stored.codeRequirementDigestSHA256
                == expected.codeRequirementDigestSHA256
            && stored.teamIdentifier == expected.teamIdentifier
            && stored.gatewayRegistrationDigestSHA256
                == expected.gatewayRegistrationDigestSHA256
    }

    private static func validate(
        _ context: ProviderHandoffGatewayKeyEnrollmentContextV1
    ) throws {
        guard
            context.schemaVersion == 1,
            !context.owningBundleIdentifier.isEmpty,
            context.owningBundleIdentifier.utf8.count <= 256,
            context.owningBundleIdentifier
                .precomposedStringWithCanonicalMapping
                == context.owningBundleIdentifier,
            (try? ProviderHandoffDigest.parseSHA256(
                context.codeRequirementDigestSHA256
            )) != nil,
            (try? ProviderHandoffDigest.parseSHA256(
                context.gatewayRegistrationDigestSHA256
            )) != nil,
            context.teamIdentifier?.isEmpty != true,
            context.teamIdentifier?.utf8.count ?? 0 <= 128,
            context.enrolledAtUnixSeconds >= context.notBeforeUnixSeconds,
            context.enrolledAtUnixSeconds <= context.notAfterUnixSeconds
        else {
            throw ProviderHandoffGatewayKeyStoreError.invalidContext
        }
    }

    private static func validate(
        _ material: StoredKeyMaterialV1,
        context: ProviderHandoffGatewayKeyEnrollmentContextV1
    ) throws {
        let key = material.trustKey
        guard
            purposes.contains(key.purpose),
            key.algorithm == .ed25519V1,
            key.role == .gatewayCoordinator,
            key.providerFingerprint == nil,
            key.stateRootUUID == nil,
            key.provenance.owningBundleIdentifier
                == context.owningBundleIdentifier,
            key.provenance.codeRequirementDigestSHA256
                == context.codeRequirementDigestSHA256,
            key.provenance.teamIdentifier == context.teamIdentifier,
            key.provenance.providerRegistrationDigestSHA256
                == context.gatewayRegistrationDigestSHA256,
            key.provenance.enrolledAtUnixSeconds
                == context.enrolledAtUnixSeconds,
            key.notBeforeUnixSeconds == context.notBeforeUnixSeconds,
            key.notAfterUnixSeconds == context.notAfterUnixSeconds,
            key.rotationPredecessorKeyID == nil,
            key.revokedAtUnixSeconds == nil,
            key.revocationReason == nil,
            material.privateKey.count == 32
        else {
            throw ProviderHandoffGatewayKeyStoreError.invalidKey(key.purpose)
        }
        let publicKey = try ProviderHandoffCrypto.ed25519PublicKey(
            for: material.privateKey
        )
        guard
            publicKey == key.rawPublicKey,
            try ProviderHandoffCrypto.trustKeyID(
                algorithm: key.algorithm,
                role: key.role,
                purpose: key.purpose,
                providerFingerprint: nil,
                stateRootUUID: nil,
                rawPublicKey: key.rawPublicKey
            ) == key.keyID
        else {
            throw ProviderHandoffGatewayKeyStoreError.invalidKey(key.purpose)
        }
        if key.purpose == .trustRegistrySigning {
            guard key.provenance.enrollmentProofSignature == nil else {
                throw ProviderHandoffGatewayKeyStoreError.invalidKey(key.purpose)
            }
        } else {
            do {
                try ProviderHandoffTrustRegistryValidator
                    .validateEnrollmentKey(key)
            } catch {
                throw ProviderHandoffGatewayKeyStoreError.invalidKey(key.purpose)
            }
        }
    }

    private static func encode(_ value: StoredKeySetV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumKeySetBytes else {
            throw ProviderHandoffGatewayKeyStoreError.keySetTooLarge
        }
        return data
    }

    private static func decode(_ data: Data) throws -> StoredKeySetV1 {
        guard data.count <= maximumKeySetBytes else {
            throw ProviderHandoffGatewayKeyStoreError.keySetTooLarge
        }
        do {
            let value = try JSONDecoder().decode(StoredKeySetV1.self, from: data)
            guard try encode(value) == data else {
                throw ProviderHandoffGatewayKeyStoreError.invalidEncoding
            }
            return value
        } catch let error as ProviderHandoffGatewayKeyStoreError {
            throw error
        } catch {
            throw ProviderHandoffGatewayKeyStoreError.invalidEncoding
        }
    }
}
