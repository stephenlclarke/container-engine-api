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

import ContainerEngineRuntimeSPI
import Foundation
import Testing

@Suite
struct ProviderHandoffSecurityTests {
    @Test
    func `signed registry rejects a key whose binding no longer matches its ID`() throws {
        let fixture = try TrustFixture()
        _ = try fixture.validatedRegistry()

        var changed = fixture.registry
        let index = try #require(
            changed.keys.firstIndex(where: {
                $0.keyID == fixture.sourceEnvelopeSigningKey.keyID
            }))
        changed.keys[index].providerFingerprint = "sha256:other-source"
        changed.registryDigestSHA256 =
            try ProviderHandoffProjections
            .trustRegistryDigest(changed)
        changed.registrySignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: changed.registryDigestSHA256,
            purpose: .trustRegistrySigning,
            signerKeyID: fixture.bootstrap.keyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: changed.registryRevision,
            privateKey: fixture.bootstrapPrivateKey
        )

        #expect(throws: ProviderHandoffTrustError.self) {
            try ProviderHandoffTrustRegistryValidator.validate(
                changed,
                bootstrap: fixture.bootstrap
            )
        }
    }

    @Test
    func `destination proof demonstrates the selected X25519 private key`() throws {
        let fixture = try TrustFixture()
        let registry = try fixture.validatedRegistry()
        let challenge = try ProviderHandoffPossessionProofCodec.prepareChallenge(
            proofID: "proof-lineage",
            tokenID: "token-1",
            manifestID: "manifest-1",
            destinationProviderFingerprint: fixture.destinationProvider,
            destinationStateRootUUID: fixture.destinationRoot,
            destinationKeyPurpose: .destinationLineageKeyEncryption,
            destinationKeyID: fixture.destinationLineageEncryptionKey.keyID,
            destinationPublicKey: fixture.destinationLineageEncryptionKey.rawPublicKey,
            nonce: Data((0x00...0x17).map(UInt8.init)),
            challengePlaintext: Data(repeating: 0xa5, count: 32),
            ephemeralPrivateKey: Data(repeating: 0x33, count: 32)
        )
        let proof = try ProviderHandoffPossessionProofCodec.respond(
            to: challenge,
            destinationPrivateKey: fixture.destinationLineagePrivateKey,
            possessionSigningKeyID: fixture.destinationPossessionSigningKey.keyID,
            trustRegistryRevision: fixture.registry.registryRevision,
            possessionSigningPrivateKey: fixture.destinationPossessionPrivateKey
        )
        let validated = try ProviderHandoffPossessionProofCodec.verify(
            proof,
            challenge: challenge,
            trustRegistry: registry,
            atUnixSeconds: fixture.useTime
        )

        let proofRecordDigest =
            try ProviderHandoffProjections
            .destinationPossessionProofRecordDigest(proof)
        #expect(validated.proofRecordDigestSHA256 == proofRecordDigest)
        var changed = proof
        changed.responseDigestSHA256 = String(repeating: "0", count: 64)
        #expect(throws: ProviderHandoffEnvelopeCodecError.invalidPossessionProof) {
            try ProviderHandoffPossessionProofCodec.verify(
                changed,
                challenge: challenge,
                trustRegistry: registry,
                atUnixSeconds: fixture.useTime
            )
        }
    }

    @Test
    func `lineage envelope verifies before decrypt and round trips exact key binding`() throws {
        let fixture = try TrustFixture()
        let registry = try fixture.validatedRegistry()
        let lineage = ProviderHandoffEnvelopeLineageKeyV1(
            sourceStateRootUUID: fixture.sourceRoot,
            authorityLineageUUID: fixture.sourceLineage,
            keyVersion: 4,
            rawHMACSHA256Key: Data(repeating: 0x5a, count: 32)
        )
        let envelope = try ProviderHandoffLineageKeyEnvelopeCodec.prepare(
            lineage,
            envelopeID: "source-lineage-key",
            tokenID: "token-1",
            manifestID: "manifest-1",
            destinationProviderFingerprint: fixture.destinationProvider,
            destinationStateRootUUID: fixture.destinationRoot,
            destinationKeyID: fixture.destinationLineageEncryptionKey.keyID,
            destinationPublicKey: fixture.destinationLineageEncryptionKey.rawPublicKey,
            nonce: Data((0x20...0x37).map(UInt8.init)),
            signerKeyID: fixture.sourceEnvelopeSigningKey.keyID,
            signerRole: .sourceProvider,
            signerProviderFingerprint: fixture.sourceProvider,
            signerStateRootUUID: fixture.sourceRoot,
            trustRegistryRevision: fixture.registry.registryRevision,
            signerPrivateKey: fixture.sourceEnvelopePrivateKey,
            ephemeralPrivateKey: Data(repeating: 0x44, count: 32)
        )
        let opened = try ProviderHandoffLineageKeyEnvelopeCodec.open(
            envelope,
            tokenID: "token-1",
            manifestID: "manifest-1",
            destinationProviderFingerprint: fixture.destinationProvider,
            destinationStateRootUUID: fixture.destinationRoot,
            sourceProviderFingerprint: fixture.sourceProvider,
            trustRegistry: registry,
            atUnixSeconds: fixture.useTime,
            destinationPrivateKey: fixture.destinationLineagePrivateKey
        )

        #expect(opened == lineage)
        var changed = envelope
        changed.ciphertext[changed.ciphertext.startIndex] ^= 1
        #expect(throws: ProviderHandoffTrustError.self) {
            try ProviderHandoffLineageKeyEnvelopeCodec.open(
                changed,
                tokenID: "token-1",
                manifestID: "manifest-1",
                destinationProviderFingerprint: fixture.destinationProvider,
                destinationStateRootUUID: fixture.destinationRoot,
                sourceProviderFingerprint: fixture.sourceProvider,
                trustRegistry: registry,
                atUnixSeconds: fixture.useTime,
                destinationPrivateKey: fixture.destinationLineagePrivateKey
            )
        }
    }

    @Test
    func `manifest validation binds every part source envelope proof and signature`() throws {
        let fixture = try TrustFixture()
        let registry = try fixture.validatedRegistry()
        let tokenID = "token-1"
        let manifestID = "manifest-1"
        let resultingLineage = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let destinationLineage = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let challenge = try ProviderHandoffPossessionProofCodec.prepareChallenge(
            proofID: "proof-lineage",
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: fixture.destinationProvider,
            destinationStateRootUUID: fixture.destinationRoot,
            destinationKeyPurpose: .destinationLineageKeyEncryption,
            destinationKeyID: fixture.destinationLineageEncryptionKey.keyID,
            destinationPublicKey: fixture.destinationLineageEncryptionKey.rawPublicKey,
            nonce: Data((0x40...0x57).map(UInt8.init)),
            challengePlaintext: Data(repeating: 0x6c, count: 32),
            ephemeralPrivateKey: Data(repeating: 0x55, count: 32)
        )
        let proof = try ProviderHandoffPossessionProofCodec.respond(
            to: challenge,
            destinationPrivateKey: fixture.destinationLineagePrivateKey,
            possessionSigningKeyID: fixture.destinationPossessionSigningKey.keyID,
            trustRegistryRevision: fixture.registry.registryRevision,
            possessionSigningPrivateKey: fixture.destinationPossessionPrivateKey
        )
        let validatedProof = try ProviderHandoffPossessionProofCodec.verify(
            proof,
            challenge: challenge,
            trustRegistry: registry,
            atUnixSeconds: fixture.useTime
        )
        let resultingEnvelope = try ProviderHandoffLineageKeyEnvelopeCodec.prepare(
            ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: nil,
                authorityLineageUUID: resultingLineage,
                keyVersion: 2,
                rawHMACSHA256Key: Data(repeating: 0x7d, count: 32)
            ),
            envelopeID: "resulting-lineage-key",
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: fixture.destinationProvider,
            destinationStateRootUUID: fixture.destinationRoot,
            destinationKeyID: fixture.destinationLineageEncryptionKey.keyID,
            destinationPublicKey: fixture.destinationLineageEncryptionKey.rawPublicKey,
            nonce: Data((0x60...0x77).map(UInt8.init)),
            signerKeyID: fixture.coordinatorEnvelopeSigningKey.keyID,
            signerRole: .gatewayCoordinator,
            signerProviderFingerprint: nil,
            signerStateRootUUID: nil,
            trustRegistryRevision: fixture.registry.registryRevision,
            signerPrivateKey: fixture.coordinatorEnvelopePrivateKey,
            ephemeralPrivateKey: Data(repeating: 0x66, count: 32)
        )
        let sourceExpectation = try expectation(
            role: .source,
            root: fixture.sourceRoot,
            lineage: fixture.sourceLineage,
            stagedLineage: nil,
            provider: fixture.sourceProvider,
            state: .sourceQuiesced,
            abortState: .destinationActive,
            tokenID: tokenID,
            snapshot: "source-checkpoint"
        )
        let destinationExpectation = try expectation(
            role: .destination,
            root: fixture.destinationRoot,
            lineage: destinationLineage,
            stagedLineage: resultingLineage,
            provider: nil,
            state: .destinationStaged,
            abortState: .none,
            tokenID: tokenID,
            snapshot: nil
        )
        let parts = try ProviderHandoffPartKindV1.allCases.map { kind in
            let payload = try ProviderHandoffPayloadCodec.prepareAuthenticated(
                ProviderHandoffPayloadPackageV1(
                    partKind: kind,
                    entries: [
                        ProviderHandoffPayloadPackageEntryV1(
                            entryID: "evidence",
                            sourceStateRootUUID: fixture.sourceRoot,
                            recordKind: "handoff-evidence",
                            schemaVersion: 1,
                            canonicalRecordBytes: try ProviderHandoffCanonicalCBOR.encode(
                                .map([.init("disposition", .textString("included"))])
                            )
                        )
                    ]
                ),
                mediaType: "application/vnd.io.github.stephenlclarke.container.handoff-part.v1+cbor",
                sourceOrder: [fixture.sourceRoot]
            )
            return ProviderHandoffPartV1(
                kind: kind,
                schemaVersion: 1,
                disposition: .included,
                sourceStateRootUUIDs: [fixture.sourceRoot],
                requiredCapabilities: [],
                payload: payload.descriptor
            )
        }
        var manifest = ProviderHandoffManifestV1(
            manifestID: manifestID,
            tokenID: tokenID,
            trustRegistryRevision: fixture.registry.registryRevision,
            destinationKeyPossessionProofDigestsSHA256: [
                validatedProof.proofRecordDigestSHA256
            ],
            sources: [
                ProviderHandoffSourceV1(
                    providerFingerprint: fixture.sourceProvider,
                    stateRootUUID: fixture.sourceRoot,
                    authorityLineageUUID: fixture.sourceLineage,
                    lineageDigestKeyVersion: 4,
                    preCommitExpectation: sourceExpectation,
                    sourceSignature: placeholderSignature(
                        purpose: .sourceManifestSigning,
                        role: .sourceProvider,
                        provider: fixture.sourceProvider,
                        root: fixture.sourceRoot
                    )
                )
            ],
            resultingAuthorityLineageUUID: resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            destinationSealedLineageKeyEnvelopes: [resultingEnvelope],
            destinationProviderFingerprint: fixture.destinationProvider,
            destinationStateRootUUID: fixture.destinationRoot,
            destinationPreCommitExpectation: destinationExpectation,
            parts: parts,
            manifestDigest: String(repeating: "0", count: 64),
            coordinatorSignature: placeholderSignature(
                purpose: .coordinatorManifestSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        try ProviderHandoffRecordSigner.signSource(
            stateRootUUID: fixture.sourceRoot,
            manifest: &manifest,
            signerKeyID: fixture.sourceManifestSigningKey.keyID,
            privateKey: fixture.sourceManifestPrivateKey
        )
        try ProviderHandoffRecordSigner.signManifest(
            &manifest,
            signerKeyID: fixture.coordinatorManifestSigningKey.keyID,
            privateKey: fixture.coordinatorManifestPrivateKey
        )

        let validated = try ProviderHandoffRecordValidator.validateManifest(
            manifest,
            possessionProofs: [validatedProof],
            trustRegistry: registry,
            atUnixSeconds: fixture.useTime
        )
        #expect(validated.manifest == manifest)

        var changed = manifest
        changed.parts[0].disposition = .empty
        #expect(throws: ProviderHandoffRecordValidationError.invalidManifest) {
            try ProviderHandoffRecordValidator.validateManifest(
                changed,
                possessionProofs: [validatedProof],
                trustRegistry: registry,
                atUnixSeconds: fixture.useTime
            )
        }
    }

    private func expectation(
        role: ProviderHandoffRootRoleV1,
        root: String,
        lineage: String,
        stagedLineage: String?,
        provider: String?,
        state: StateRootHandoffStateV1,
        abortState: StateRootHandoffStateV1,
        tokenID: String,
        snapshot: String?
    ) throws -> ProviderHandoffHeaderExpectationV1 {
        let expected = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID: stagedLineage,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 4,
            selectedProviderFingerprint: provider,
            handoffState: state,
            activeHandoffTokenID: tokenID,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: role == .source ? 4 : 1
        )
        let abort = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID: nil,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 5,
            selectedProviderFingerprint: provider,
            handoffState: abortState,
            activeHandoffTokenID: nil,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: role == .source ? 4 : 1
        )
        var preCommit = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 10,
            snapshotCheckpointID: snapshot,
            controllerRevisions: role == .source
                ? [
                    ProviderHandoffControllerRevisionV1(
                        controllerID: "logging",
                        revision: 7,
                        canonicalStateDigestSHA256: String(repeating: "8", count: 64)
                    )
                ] : [],
            revisionVectorDigestSHA256: String(repeating: "0", count: 64)
        )
        preCommit.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections
            .revisionVectorDigest(preCommit)
        var abortVector = preCommit
        abortVector.rootStoreRevision += 1
        abortVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections
            .revisionVectorDigest(abortVector)
        return ProviderHandoffHeaderExpectationV1(
            role: role,
            stateRootUUID: root,
            expectedHeader: expected,
            expectedHeaderDigestSHA256:
                try ProviderHandoffProjections
                .stateRootHeaderDigest(expected),
            preCommitRevisionVector: preCommit,
            abortHeader: abort,
            abortHeaderDigestSHA256:
                try ProviderHandoffProjections
                .stateRootHeaderDigest(abort),
            abortRevisionVector: abortVector
        )
    }

    private func placeholderSignature(
        purpose: ProviderHandoffKeyPurposeV1,
        role: ProviderHandoffKeyRoleV1,
        provider: String?,
        root: String?
    ) -> ProviderHandoffSignatureV1 {
        ProviderHandoffSignatureV1(
            purpose: purpose,
            signerKeyID: "pending",
            signerRole: role,
            providerFingerprint: provider,
            stateRootUUID: root,
            trustRegistryRevision: 1,
            signedProjectionDigestSHA256: String(repeating: "0", count: 64),
            signature: Data(repeating: 0, count: 64)
        )
    }
}

private struct TrustFixture {
    let useTime: UInt64 = 1_800_000_000
    let sourceRoot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let destinationRoot = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let sourceLineage = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let sourceProvider = "sha256:source-provider"
    let destinationProvider = "sha256:destination-provider"

    let bootstrapPrivateKey: Data
    let bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    let coordinatorEnvelopePrivateKey: Data
    let coordinatorEnvelopeSigningKey: ProviderHandoffTrustKeyV1
    let coordinatorManifestPrivateKey: Data
    let coordinatorManifestSigningKey: ProviderHandoffTrustKeyV1
    let sourceManifestPrivateKey: Data
    let sourceManifestSigningKey: ProviderHandoffTrustKeyV1
    let sourceEnvelopePrivateKey: Data
    let sourceEnvelopeSigningKey: ProviderHandoffTrustKeyV1
    let destinationPossessionPrivateKey: Data
    let destinationPossessionSigningKey: ProviderHandoffTrustKeyV1
    let destinationLineagePrivateKey: Data
    let destinationLineageEncryptionKey: ProviderHandoffTrustKeyV1
    let registry: ProviderHandoffTrustRegistryV1

    init() throws {
        bootstrapPrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        let bootstrapPublicKey = try ProviderHandoffCrypto.ed25519PublicKey(
            for: bootstrapPrivateKey
        )
        let bootstrapKeyID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: .trustRegistrySigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: bootstrapPublicKey
        )
        bootstrap = ProviderHandoffPinnedBootstrapKeyV1(
            keyID: bootstrapKeyID,
            rawPublicKey: bootstrapPublicKey,
            codeRequirementDigestSHA256: String(repeating: "1", count: 64)
        )
        let bootstrapTrustKey = ProviderHandoffTrustKeyV1(
            keyID: bootstrapKeyID,
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: .trustRegistrySigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: bootstrapPublicKey,
            provenance: Self.provenance(
                suffix: "bootstrap",
                codeRequirementDigest: bootstrap.codeRequirementDigestSHA256,
                proof: nil
            ),
            notBeforeUnixSeconds: useTime - 100,
            notAfterUnixSeconds: useTime + 100,
            rotationPredecessorKeyID: nil,
            revokedAtUnixSeconds: nil,
            revocationReason: nil
        )

        coordinatorEnvelopePrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        coordinatorEnvelopeSigningKey = try Self.ed25519Key(
            privateKey: coordinatorEnvelopePrivateKey,
            role: .gatewayCoordinator,
            purpose: .lineageKeyEnvelopeSigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            suffix: "coordinator-envelope",
            useTime: useTime
        )
        coordinatorManifestPrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        coordinatorManifestSigningKey = try Self.ed25519Key(
            privateKey: coordinatorManifestPrivateKey,
            role: .gatewayCoordinator,
            purpose: .coordinatorManifestSigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            suffix: "coordinator-manifest",
            useTime: useTime
        )
        sourceManifestPrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        sourceManifestSigningKey = try Self.ed25519Key(
            privateKey: sourceManifestPrivateKey,
            role: .sourceProvider,
            purpose: .sourceManifestSigning,
            providerFingerprint: sourceProvider,
            stateRootUUID: sourceRoot,
            suffix: "source-manifest",
            useTime: useTime
        )
        sourceEnvelopePrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        sourceEnvelopeSigningKey = try Self.ed25519Key(
            privateKey: sourceEnvelopePrivateKey,
            role: .sourceProvider,
            purpose: .lineageKeyEnvelopeSigning,
            providerFingerprint: sourceProvider,
            stateRootUUID: sourceRoot,
            suffix: "source-envelope",
            useTime: useTime
        )
        destinationPossessionPrivateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        destinationPossessionSigningKey = try Self.ed25519Key(
            privateKey: destinationPossessionPrivateKey,
            role: .destinationProvider,
            purpose: .destinationPossessionSigning,
            providerFingerprint: destinationProvider,
            stateRootUUID: destinationRoot,
            suffix: "destination-possession",
            useTime: useTime
        )
        destinationLineagePrivateKey = ProviderHandoffCrypto.generateX25519PrivateKey()
        let destinationLineagePublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: destinationLineagePrivateKey
        )
        destinationLineageEncryptionKey = try Self.x25519Key(
            publicKey: destinationLineagePublicKey,
            purpose: .destinationLineageKeyEncryption,
            providerFingerprint: destinationProvider,
            stateRootUUID: destinationRoot,
            suffix: "destination-lineage",
            useTime: useTime
        )

        let keys = [
            bootstrapTrustKey,
            coordinatorEnvelopeSigningKey,
            coordinatorManifestSigningKey,
            sourceManifestSigningKey,
            sourceEnvelopeSigningKey,
            destinationPossessionSigningKey,
            destinationLineageEncryptionKey,
        ].sorted {
            $0.keyID.utf8.lexicographicallyPrecedes($1.keyID.utf8)
        }
        var value = ProviderHandoffTrustRegistryV1(
            registryRevision: 1,
            issuedAtUnixSeconds: useTime,
            keys: keys,
            registryDigestSHA256: String(repeating: "0", count: 64),
            registrySignature: ProviderHandoffSignatureV1(
                purpose: .trustRegistrySigning,
                signerKeyID: bootstrapKeyID,
                signerRole: .gatewayCoordinator,
                providerFingerprint: nil,
                stateRootUUID: nil,
                trustRegistryRevision: 1,
                signedProjectionDigestSHA256: String(repeating: "0", count: 64),
                signature: Data(repeating: 0, count: 64)
            )
        )
        value.registryDigestSHA256 =
            try ProviderHandoffProjections
            .trustRegistryDigest(value)
        value.registrySignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: value.registryDigestSHA256,
            purpose: .trustRegistrySigning,
            signerKeyID: bootstrapKeyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: value.registryRevision,
            privateKey: bootstrapPrivateKey
        )
        registry = value
    }

    func validatedRegistry() throws -> ProviderHandoffValidatedTrustRegistryV1 {
        try ProviderHandoffTrustRegistryValidator.validate(
            registry,
            bootstrap: bootstrap
        )
    }

    private static func ed25519Key(
        privateKey: Data,
        role: ProviderHandoffKeyRoleV1,
        purpose: ProviderHandoffKeyPurposeV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        suffix: String,
        useTime: UInt64
    ) throws -> ProviderHandoffTrustKeyV1 {
        let publicKey = try ProviderHandoffCrypto.ed25519PublicKey(for: privateKey)
        let keyID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .ed25519V1,
            role: role,
            purpose: purpose,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            rawPublicKey: publicKey
        )
        var key = ProviderHandoffTrustKeyV1(
            keyID: keyID,
            algorithm: .ed25519V1,
            role: role,
            purpose: purpose,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            rawPublicKey: publicKey,
            provenance: provenance(suffix: suffix, proof: nil),
            notBeforeUnixSeconds: useTime - 100,
            notAfterUnixSeconds: useTime + 100,
            rotationPredecessorKeyID: nil,
            revokedAtUnixSeconds: nil,
            revocationReason: nil
        )
        key.provenance.enrollmentProofSignature =
            try ProviderHandoffTrustRegistryValidator
            .enrollmentProofSignature(for: key, privateKey: privateKey)
        return key
    }

    private static func x25519Key(
        publicKey: Data,
        purpose: ProviderHandoffKeyPurposeV1,
        providerFingerprint: String,
        stateRootUUID: String,
        suffix: String,
        useTime: UInt64
    ) throws -> ProviderHandoffTrustKeyV1 {
        let keyID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .x25519V1,
            role: .destinationProvider,
            purpose: purpose,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            rawPublicKey: publicKey
        )
        return ProviderHandoffTrustKeyV1(
            keyID: keyID,
            algorithm: .x25519V1,
            role: .destinationProvider,
            purpose: purpose,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            rawPublicKey: publicKey,
            provenance: provenance(suffix: suffix, proof: nil),
            notBeforeUnixSeconds: useTime - 100,
            notAfterUnixSeconds: useTime + 100,
            rotationPredecessorKeyID: nil,
            revokedAtUnixSeconds: nil,
            revocationReason: nil
        )
    }

    private static func provenance(
        suffix: String,
        codeRequirementDigest: String = String(repeating: "2", count: 64),
        proof: Data?
    ) -> ProviderHandoffPublicKeyProvenanceV1 {
        ProviderHandoffPublicKeyProvenanceV1(
            enrollmentID: "enrollment-\(suffix)",
            owningBundleIdentifier: "io.github.stephenlclarke.\(suffix)",
            codeRequirementDigestSHA256: codeRequirementDigest,
            teamIdentifier: nil,
            providerRegistrationDigestSHA256: String(repeating: "3", count: 64),
            enrolledAtUnixSeconds: 1_799_999_900,
            enrollmentProofSignature: proof
        )
    }
}
