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

public struct ProviderHandoffPinnedBootstrapKeyV1:
    Codable,
    Equatable,
    Sendable
{
    public var keyID: String
    public var rawPublicKey: Data
    public var codeRequirementDigestSHA256: String

    public init(
        keyID: String,
        rawPublicKey: Data,
        codeRequirementDigestSHA256: String
    ) {
        self.keyID = keyID
        self.rawPublicKey = rawPublicKey
        self.codeRequirementDigestSHA256 = codeRequirementDigestSHA256
    }
}

public enum ProviderHandoffTrustError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case duplicateKey(String)
    case expiredKey(String)
    case invalidBinding(String)
    case invalidEnrollmentProof(String)
    case invalidKey(String)
    case invalidOrder
    case invalidRegistry
    case invalidRegistryRevision(expected: UInt64, actual: UInt64)
    case invalidSignature(String)
    case keyNotFound(String)
    case overlappingKey(String, String)
    case revokedKey(String)

    public var description: String {
        switch self {
        case .duplicateKey(let identifier):
            "provider handoff trust registry contains duplicate key \(identifier)"
        case .expiredKey(let identifier):
            "provider handoff trust key \(identifier) is outside its validity interval"
        case .invalidBinding(let identifier):
            "provider handoff trust key \(identifier) has an invalid role or provider binding"
        case .invalidEnrollmentProof(let identifier):
            "provider handoff trust key \(identifier) has an invalid enrollment proof"
        case .invalidKey(let identifier):
            "provider handoff trust key \(identifier) is invalid"
        case .invalidOrder:
            "provider handoff trust keys are not in canonical key-ID order"
        case .invalidRegistry:
            "provider handoff trust registry is invalid"
        case .invalidRegistryRevision(let expected, let actual):
            "provider handoff trust registry revision mismatch: expected \(expected), found \(actual)"
        case .invalidSignature(let identifier):
            "provider handoff signature from key \(identifier) is invalid"
        case .keyNotFound(let identifier):
            "provider handoff trust key \(identifier) was not found"
        case .overlappingKey(let first, let second):
            "provider handoff trust keys \(first) and \(second) overlap without an explicit rotation chain"
        case .revokedKey(let identifier):
            "provider handoff trust key \(identifier) is revoked"
        }
    }
}

public struct ProviderHandoffValidatedTrustRegistryV1: Sendable {
    public let registry: ProviderHandoffTrustRegistryV1
    public let bootstrap: ProviderHandoffPinnedBootstrapKeyV1

    private let keysByID: [String: ProviderHandoffTrustKeyV1]

    fileprivate init(
        registry: ProviderHandoffTrustRegistryV1,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    ) {
        self.registry = registry
        self.bootstrap = bootstrap
        keysByID = Dictionary(uniqueKeysWithValues: registry.keys.map { ($0.keyID, $0) })
    }

    public func key(
        identifier: String,
        purpose: ProviderHandoffKeyPurposeV1,
        role: ProviderHandoffKeyRoleV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffTrustKeyV1 {
        guard let key = keysByID[identifier] else {
            throw ProviderHandoffTrustError.keyNotFound(identifier)
        }
        guard
            key.purpose == purpose,
            key.role == role,
            key.providerFingerprint == providerFingerprint,
            key.stateRootUUID == stateRootUUID
        else {
            throw ProviderHandoffTrustError.invalidBinding(identifier)
        }
        guard
            atUnixSeconds >= key.notBeforeUnixSeconds,
            atUnixSeconds <= key.notAfterUnixSeconds
        else {
            throw ProviderHandoffTrustError.expiredKey(identifier)
        }
        if let revokedAt = key.revokedAtUnixSeconds, revokedAt <= atUnixSeconds {
            throw ProviderHandoffTrustError.revokedKey(identifier)
        }
        return key
    }

    public func verify(
        _ signature: ProviderHandoffSignatureV1,
        expectedPurpose: ProviderHandoffKeyPurposeV1,
        expectedRole: ProviderHandoffKeyRoleV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        projectionDigestSHA256: String,
        atUnixSeconds: UInt64
    ) throws {
        guard
            signature.purpose == expectedPurpose,
            signature.signerRole == expectedRole,
            signature.providerFingerprint == providerFingerprint,
            signature.stateRootUUID == stateRootUUID,
            signature.trustRegistryRevision == registry.registryRevision,
            signature.signedProjectionDigestSHA256 == projectionDigestSHA256
        else {
            throw ProviderHandoffTrustError.invalidSignature(signature.signerKeyID)
        }
        let key = try key(
            identifier: signature.signerKeyID,
            purpose: expectedPurpose,
            role: expectedRole,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            atUnixSeconds: atUnixSeconds
        )
        guard key.algorithm == .ed25519V1 else {
            throw ProviderHandoffTrustError.invalidSignature(signature.signerKeyID)
        }
        do {
            try ProviderHandoffCrypto.verify(signature, publicKey: key.rawPublicKey)
        } catch {
            throw ProviderHandoffTrustError.invalidSignature(signature.signerKeyID)
        }
    }
}

public enum ProviderHandoffTrustRegistryValidator {
    public static func validateEnrollmentKey(
        _ key: ProviderHandoffTrustKeyV1
    ) throws {
        guard key.purpose != .trustRegistrySigning else {
            throw ProviderHandoffTrustError.invalidKey(key.keyID)
        }
        try validateKey(key, bootstrap: nil)
    }

    public static func validate(
        _ registry: ProviderHandoffTrustRegistryV1,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        previousRegistry: ProviderHandoffTrustRegistryV1? = nil
    ) throws -> ProviderHandoffValidatedTrustRegistryV1 {
        guard
            registry.schemaVersion == 1,
            registry.registryRevision > 0,
            bootstrap.rawPublicKey.count == 32,
            try ProviderHandoffDigest.parseSHA256(bootstrap.codeRequirementDigestSHA256).count == 32
        else {
            throw ProviderHandoffTrustError.invalidRegistry
        }
        let computedBootstrapID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: .trustRegistrySigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: bootstrap.rawPublicKey
        )
        guard computedBootstrapID == bootstrap.keyID else {
            throw ProviderHandoffTrustError.invalidRegistry
        }
        if let previousRegistry {
            guard registry.registryRevision == previousRegistry.registryRevision + 1 else {
                throw ProviderHandoffTrustError.invalidRegistryRevision(
                    expected: previousRegistry.registryRevision + 1,
                    actual: registry.registryRevision
                )
            }
            guard registry.issuedAtUnixSeconds >= previousRegistry.issuedAtUnixSeconds else {
                throw ProviderHandoffTrustError.invalidRegistry
            }
        }

        let sorted = registry.keys.sorted {
            $0.keyID.utf8.lexicographicallyPrecedes($1.keyID.utf8)
        }
        guard sorted == registry.keys else {
            throw ProviderHandoffTrustError.invalidOrder
        }
        var seen = Set<String>()
        for key in registry.keys {
            guard seen.insert(key.keyID).inserted else {
                throw ProviderHandoffTrustError.duplicateKey(key.keyID)
            }
            try validateKey(key, bootstrap: bootstrap)
        }
        try validateOverlaps(registry.keys)

        let digest = try ProviderHandoffProjections.trustRegistryDigest(registry)
        guard
            digest == registry.registryDigestSHA256,
            registry.registrySignature.purpose == .trustRegistrySigning,
            registry.registrySignature.signerRole == .gatewayCoordinator,
            registry.registrySignature.signerKeyID == bootstrap.keyID,
            registry.registrySignature.providerFingerprint == nil,
            registry.registrySignature.stateRootUUID == nil,
            registry.registrySignature.trustRegistryRevision == registry.registryRevision,
            registry.registrySignature.signedProjectionDigestSHA256 == digest
        else {
            throw ProviderHandoffTrustError.invalidRegistry
        }
        do {
            try ProviderHandoffCrypto.verify(
                registry.registrySignature,
                publicKey: bootstrap.rawPublicKey
            )
        } catch {
            throw ProviderHandoffTrustError.invalidRegistry
        }
        return ProviderHandoffValidatedTrustRegistryV1(
            registry: registry,
            bootstrap: bootstrap
        )
    }

    public static func enrollmentProofSignature(
        for key: ProviderHandoffTrustKeyV1,
        privateKey: Data
    ) throws -> Data {
        let digest = try ProviderHandoffProjections.enrollmentProofDigest(key)
        return try ProviderHandoffCrypto.signEd25519Message(
            ProviderHandoffDigest.parseSHA256(digest),
            privateKey: privateKey
        )
    }

    private static func validateKey(
        _ key: ProviderHandoffTrustKeyV1,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1?
    ) throws {
        guard
            !key.keyID.isEmpty,
            key.notBeforeUnixSeconds <= key.notAfterUnixSeconds,
            !key.provenance.enrollmentID.isEmpty,
            !key.provenance.owningBundleIdentifier.isEmpty,
            try ProviderHandoffDigest.parseSHA256(key.provenance.codeRequirementDigestSHA256).count == 32,
            try ProviderHandoffDigest.parseSHA256(key.provenance.providerRegistrationDigestSHA256).count == 32,
            (key.revokedAtUnixSeconds == nil) == (key.revocationReason == nil),
            key.revocationReason?.isEmpty != true
        else {
            throw ProviderHandoffTrustError.invalidKey(key.keyID)
        }
        let computedID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: key.algorithm,
            role: key.role,
            purpose: key.purpose,
            providerFingerprint: key.providerFingerprint,
            stateRootUUID: key.stateRootUUID,
            rawPublicKey: key.rawPublicKey
        )
        guard computedID == key.keyID else {
            throw ProviderHandoffTrustError.invalidKey(key.keyID)
        }
        try validatePurposeBinding(key, bootstrap: bootstrap)

        switch key.algorithm {
        case .ed25519V1:
            guard key.rawPublicKey.count == 32 else {
                throw ProviderHandoffTrustError.invalidKey(key.keyID)
            }
            if key.purpose == .trustRegistrySigning {
                guard
                    let bootstrap,
                    key.keyID == bootstrap.keyID,
                    key.rawPublicKey == bootstrap.rawPublicKey,
                    key.provenance.codeRequirementDigestSHA256
                        == bootstrap.codeRequirementDigestSHA256,
                    key.provenance.enrollmentProofSignature == nil
                else {
                    throw ProviderHandoffTrustError.invalidKey(key.keyID)
                }
            } else {
                guard let proof = key.provenance.enrollmentProofSignature else {
                    throw ProviderHandoffTrustError.invalidEnrollmentProof(key.keyID)
                }
                do {
                    let digest = try ProviderHandoffProjections.enrollmentProofDigest(key)
                    try ProviderHandoffCrypto.verifyEd25519Message(
                        ProviderHandoffDigest.parseSHA256(digest),
                        signature: proof,
                        publicKey: key.rawPublicKey
                    )
                } catch {
                    throw ProviderHandoffTrustError.invalidEnrollmentProof(key.keyID)
                }
            }
        case .x25519V1:
            guard key.provenance.enrollmentProofSignature == nil else {
                throw ProviderHandoffTrustError.invalidEnrollmentProof(key.keyID)
            }
            do {
                try ProviderHandoffCrypto.validateX25519PublicKey(key.rawPublicKey)
            } catch {
                throw ProviderHandoffTrustError.invalidKey(key.keyID)
            }
        }
    }

    private static func validatePurposeBinding(
        _ key: ProviderHandoffTrustKeyV1,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1?
    ) throws {
        let providerBound = key.providerFingerprint != nil && key.stateRootUUID != nil
        let coordinatorBound = key.providerFingerprint == nil && key.stateRootUUID == nil
        if let root = key.stateRootUUID {
            guard
                let identifier = UUID(uuidString: root),
                identifier.uuidString.lowercased() == root
            else {
                throw ProviderHandoffTrustError.invalidBinding(key.keyID)
            }
        }
        let valid: Bool
        switch key.purpose {
        case .trustRegistrySigning:
            valid =
                key.algorithm == .ed25519V1
                && key.role == .gatewayCoordinator
                && coordinatorBound
                && key.keyID == bootstrap?.keyID
        case .coordinatorManifestSigning, .coordinatorCommitSigning,
            .coordinatorTerminalOutcomeSigning:
            valid =
                key.algorithm == .ed25519V1
                && key.role == .gatewayCoordinator
                && coordinatorBound
        case .sourceManifestSigning:
            valid =
                key.algorithm == .ed25519V1
                && key.role == .sourceProvider
                && providerBound
        case .lineageKeyEnvelopeSigning:
            valid =
                key.algorithm == .ed25519V1
                && ((key.role == .sourceProvider && providerBound)
                    || (key.role == .gatewayCoordinator && coordinatorBound))
        case .destinationPossessionSigning:
            valid =
                key.algorithm == .ed25519V1
                && key.role == .destinationProvider
                && providerBound
        case .destinationPayloadEncryption, .destinationLineageKeyEncryption:
            valid =
                key.algorithm == .x25519V1
                && key.role == .destinationProvider
                && providerBound
        }
        guard valid else {
            throw ProviderHandoffTrustError.invalidBinding(key.keyID)
        }
    }

    private static func validateOverlaps(
        _ keys: [ProviderHandoffTrustKeyV1]
    ) throws {
        for firstIndex in keys.indices {
            for secondIndex in keys.indices where secondIndex > firstIndex {
                let first = keys[firstIndex]
                let second = keys[secondIndex]
                guard
                    first.algorithm == second.algorithm,
                    first.role == second.role,
                    first.purpose == second.purpose,
                    first.providerFingerprint == second.providerFingerprint,
                    first.stateRootUUID == second.stateRootUUID,
                    max(first.notBeforeUnixSeconds, second.notBeforeUnixSeconds)
                        <= min(first.notAfterUnixSeconds, second.notAfterUnixSeconds)
                else {
                    continue
                }
                let chained =
                    first.rotationPredecessorKeyID == second.keyID
                    || second.rotationPredecessorKeyID == first.keyID
                guard chained else {
                    throw ProviderHandoffTrustError.overlappingKey(
                        first.keyID,
                        second.keyID
                    )
                }
            }
        }
    }
}
