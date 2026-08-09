//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

@Suite("Provider handoff provider key store", .serialized)
struct ProviderHandoffProviderKeyStoreTests {
    @Test
    func `Current executable exposes a stable validated code identity`() throws {
        let first = try ProviderHandoffCodeIdentity.current()
        let second = try ProviderHandoffCodeIdentity.current()

        #expect(first == second)
        #expect(!first.signingIdentifier.isEmpty)
        #expect(
            try ProviderHandoffDigest.parseSHA256(
                first.designatedRequirementDigestSHA256
            ).count == 32
        )
    }

    @Test
    func `Keychain identity is stable, purpose separated, and usable`() throws {
        let fixture = Fixture()
        defer { fixture.remove() }

        let first = try fixture.store.loadOrCreate(context: fixture.context)
        var restartedContext = fixture.context
        restartedContext.enrolledAtUnixSeconds += 1
        restartedContext.notBeforeUnixSeconds += 1
        restartedContext.notAfterUnixSeconds += 1
        let second = try fixture.store.loadOrCreate(
            context: restartedContext
        )

        #expect(first.context == fixture.context)
        #expect(first.trustKeys == second.trustKeys)
        #expect(first.trustKeys.count == 5)
        #expect(first.trustKeys.map(\.keyID) == first.trustKeys.map(\.keyID).sorted())
        #expect(
            Set(first.trustKeys.map(\.purpose))
                == Set([
                    .sourceManifestSigning,
                    .lineageKeyEnvelopeSigning,
                    .destinationPossessionSigning,
                    .destinationPayloadEncryption,
                    .destinationLineageKeyEncryption
                ])
        )
        #expect(Set(first.trustKeys.map(\.keyID)).count == 5)

        for key in first.trustKeys {
            #expect(key.providerFingerprint == fixture.context.providerFingerprint)
            #expect(key.stateRootUUID == fixture.context.stateRootUUID)
            #expect(key.provenance.enrollmentID == key.provenance.enrollmentID.lowercased())
            if key.algorithm == .ed25519V1 {
                #expect(key.provenance.enrollmentProofSignature?.count == 64)
            } else {
                #expect(key.provenance.enrollmentProofSignature == nil)
            }
        }

        let encryptionKey = try first.trustKey(
            for: .destinationPayloadEncryption
        )
        let challenge = try ProviderHandoffPossessionProofCodec.prepareChallenge(
            proofID: "proof-1",
            tokenID: "token-1",
            manifestID: "manifest-1",
            destinationProviderFingerprint:
            fixture.context.providerFingerprint,
            destinationStateRootUUID: fixture.context.stateRootUUID,
            destinationKeyPurpose: .destinationPayloadEncryption,
            destinationKeyID: encryptionKey.keyID,
            destinationPublicKey: encryptionKey.rawPublicKey,
            nonce: Data(repeating: 7, count: 24),
            challengePlaintext: Data(repeating: 11, count: 32),
            ephemeralPrivateKey: Data(repeating: 13, count: 32)
        )
        let proof = try first.respond(
            to: challenge,
            trustRegistryRevision: 9
        )
        #expect(proof.destinationKeyID == encryptionKey.keyID)
        #expect(proof.destinationSignature.trustRegistryRevision == 9)
        #expect(
            try proof.destinationSignature.signerKeyID
                == (first.trustKey(
                    for: .destinationPossessionSigning
                )).keyID
        )

        let sourceRoot = "20000000-0000-4000-8000-000000000002"
        let lineageKey = ProviderHandoffLineageKeyV1(
            sourceStateRootUUID: sourceRoot,
            authorityLineageUUID:
            "30000000-0000-4000-8000-000000000003",
            keyVersion: 4,
            rawHMACSHA256Key: Data(repeating: 17, count: 32)
        )
        let package = try ProviderHandoffPayloadPackageV1(
            partKind: .logging,
            entries: [
                ProviderHandoffPayloadPackageEntryV1(
                    entryID: "logging-1",
                    sourceStateRootUUID: sourceRoot,
                    recordKind: "logging.handoff.v1",
                    schemaVersion: 1,
                    canonicalRecordBytes:
                    ProviderHandoffCanonicalCBOR
                        .encode(.map([.init("schemaVersion", .unsigned(1))]))
                )
            ]
        )
        let prepared = try ProviderHandoffPayloadCodec.prepareSealed(
            package,
            mediaType: "application/example+cbor",
            tokenID: "token-1",
            manifestID: "manifest-1",
            sourceOrder: [sourceRoot],
            lineageKeys: [lineageKey],
            destinationProviderFingerprint:
            fixture.context.providerFingerprint,
            destinationStateRootUUID: fixture.context.stateRootUUID,
            destinationKeyID: encryptionKey.keyID,
            destinationPublicKey: encryptionKey.rawPublicKey,
            nonce: Data(repeating: 19, count: 24),
            ephemeralPrivateKey: Data(repeating: 23, count: 32)
        )
        #expect(
            try first.open(
                prepared,
                expectedPartKind: .logging,
                tokenID: "token-1",
                manifestID: "manifest-1",
                sourceOrder: [sourceRoot],
                lineageKeys: [lineageKey]
            ) == package
        )
    }

    @Test
    func `A changed provider binding cannot adopt or replace existing keys`() throws {
        let fixture = Fixture()
        defer { fixture.remove() }

        let original = try fixture.store.loadOrCreate(context: fixture.context)
        var changed = fixture.context
        changed.providerFingerprint = "sha256:" + String(repeating: "b", count: 64)

        #expect(throws: ProviderHandoffProviderKeyStoreError.bindingMismatch) {
            try fixture.store.loadOrCreate(context: changed)
        }
        #expect(
            try fixture.store.load(expectedContext: fixture.context).trustKeys
                == original.trustKeys
        )
    }

    private struct Fixture {
        let service =
            "io.github.stephenlclarke.container-engine.tests.\(UUID().uuidString)"
        let account = "provider-keys"
        let context = ProviderHandoffProviderKeyEnrollmentContextV1(
            providerFingerprint: "sha256:" + String(repeating: "a", count: 64),
            stateRootUUID: "10000000-0000-4000-8000-000000000001",
            owningBundleIdentifier: "io.github.stephenlclarke.container.apiserver",
            codeRequirementDigestSHA256: String(repeating: "c", count: 64),
            teamIdentifier: "TESTTEAM",
            providerRegistrationDigestSHA256: String(repeating: "d", count: 64),
            enrolledAtUnixSeconds: 100,
            notBeforeUnixSeconds: 100,
            notAfterUnixSeconds: 10000
        )

        var store: ProviderHandoffProviderKeyStore {
            ProviderHandoffProviderKeyStore(
                service: service,
                account: account
            )
        }

        func remove() {
            try? ProviderHandoffProviderKeyStore.removeForTesting(
                service: service,
                account: account
            )
        }
    }
}
