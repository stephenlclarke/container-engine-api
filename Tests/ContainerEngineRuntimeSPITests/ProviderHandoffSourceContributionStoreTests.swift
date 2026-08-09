//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

struct ProviderHandoffSourceContributionStoreTests {
    @Test
    func `Source contribution is immutable, durable, and exactly replayed`() throws {
        try withTemporaryDirectory { root in
            let store = ProviderHandoffSourceContributionStore(root: root)
            let contribution = try makeContribution()

            #expect(try store.store(contribution) == contribution)
            #expect(try store.store(contribution) == contribution)
            #expect(
                try store.load(
                    tokenID: contribution.tokenID,
                    manifestID: contribution.manifestID,
                    partKind: contribution.partKind
                ) == contribution
            )

            var changed = contribution
            changed.part.requiredCapabilities.append("logging.changed")
            changed = try ProviderHandoffSourceControlCodec
                .finalizeContribution(changed)
            #expect(
                throws: ProviderHandoffSourceContributionStoreError.conflict
            ) {
                try store.store(changed)
            }
        }
    }

    private func makeContribution()
        throws -> ProviderHandoffSourceContributionV1
    {
        let sourceRoot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let destinationRoot = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let sourceLineage = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let destinationLineage = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let resultingLineage = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let sourceProvider = "sha256:" + String(repeating: "1", count: 64)
        let destinationProvider =
            "sha256:" + String(repeating: "2", count: 64)
        let destinationPrivate = ProviderHandoffCrypto
            .generateX25519PrivateKey()
        let destinationPublic = try ProviderHandoffCrypto.x25519PublicKey(
            for: destinationPrivate
        )
        let lineageKey = Data(repeating: 0x41, count: 32)
        let payload = try ProviderHandoffPayloadCodec.prepareSealed(
            ProviderHandoffPayloadPackageV1(
                partKind: .logging,
                entries: [
                    ProviderHandoffPayloadPackageEntryV1(
                        entryID: "logging-container-1",
                        sourceStateRootUUID: sourceRoot,
                        recordKind: "logging.handoff.test",
                        schemaVersion: 1,
                        canonicalRecordBytes:
                        ProviderHandoffCanonicalCBOR.encode(
                            .map([.init("schemaVersion", .unsigned(1))])
                        )
                    )
                ]
            ),
            mediaType: "application/vnd.test.logging+cbor",
            tokenID: "token-1",
            manifestID: "manifest-1",
            sourceOrder: [sourceRoot],
            lineageKeys: [
                ProviderHandoffLineageKeyV1(
                    sourceStateRootUUID: sourceRoot,
                    authorityLineageUUID: sourceLineage,
                    keyVersion: 3,
                    rawHMACSHA256Key: lineageKey
                )
            ],
            destinationProviderFingerprint: destinationProvider,
            destinationStateRootUUID: destinationRoot,
            destinationKeyID: "destination-payload-key",
            destinationPublicKey: destinationPublic,
            nonce: Data(repeating: 0x21, count: 24),
            ephemeralPrivateKey: Data(repeating: 0x31, count: 32)
        )
        let signingPrivate = ProviderHandoffCrypto
            .generateEd25519PrivateKey()
        let envelope = try ProviderHandoffLineageKeyEnvelopeCodec.prepare(
            ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: sourceRoot,
                authorityLineageUUID: sourceLineage,
                keyVersion: 3,
                rawHMACSHA256Key: lineageKey
            ),
            envelopeID: "source-lineage",
            tokenID: "token-1",
            manifestID: "manifest-1",
            destinationProviderFingerprint: destinationProvider,
            destinationStateRootUUID: destinationRoot,
            destinationKeyID: "destination-lineage-key",
            destinationPublicKey: destinationPublic,
            nonce: Data(repeating: 0x22, count: 24),
            signerKeyID: "source-envelope-key",
            signerRole: .sourceProvider,
            signerProviderFingerprint: sourceProvider,
            signerStateRootUUID: sourceRoot,
            trustRegistryRevision: 5,
            signerPrivateKey: signingPrivate,
            ephemeralPrivateKey: Data(repeating: 0x32, count: 32)
        )
        let part = ProviderHandoffPartV1(
            kind: .logging,
            schemaVersion: 1,
            disposition: .included,
            sourceStateRootUUIDs: [sourceRoot],
            requiredCapabilities: ["engine.handoff.part.logging.v1"],
            payload: payload.descriptor
        )
        return try ProviderHandoffSourceControlCodec.finalizeContribution(
            ProviderHandoffSourceContributionV1(
                partKind: .logging,
                tokenID: "token-1",
                manifestID: "manifest-1",
                trustRegistryRevision: 5,
                exportRequestDigestSHA256: digest("request"),
                sourceProviderFingerprint: sourceProvider,
                sourceStateRootUUID: sourceRoot,
                authorityLineageUUID: sourceLineage,
                lineageDigestKeyVersion: 3,
                sourcePreCommitExpectation: expectation(
                    role: .source,
                    root: sourceRoot,
                    lineage: sourceLineage
                ),
                destinationProviderFingerprint: destinationProvider,
                destinationStateRootUUID: destinationRoot,
                destinationPreCommitExpectation: expectation(
                    role: .destination,
                    root: destinationRoot,
                    lineage: destinationLineage
                ),
                destinationKeyPossessionProofDigestsSHA256: [
                    digest("proof-a"),
                    digest("proof-b")
                ].sorted(),
                resultingAuthorityLineageUUID: resultingLineage,
                resultingLineageDigestKeyVersion: 4,
                destinationSealedLineageKeyEnvelope: envelope,
                part: part,
                sourceObjectRecord: ProviderHandoffBundleObjectRecordV1(
                    bundleObjectID: payload.descriptor.bundleObjectID,
                    transportByteLength:
                    payload.descriptor.transportByteLength,
                    transportDigestSHA256:
                    payload.descriptor.transportDigestSHA256,
                    receivedByteCount:
                    payload.descriptor.transportByteLength,
                    objectRevision: 3,
                    state: .verified
                )
            )
        )
    }

    private func expectation(
        role: ProviderHandoffRootRoleV1,
        root: String,
        lineage: String
    ) throws -> ProviderHandoffHeaderExpectationV1 {
        let expected = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID:
            role == .destination ? lineage : nil,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 2,
            selectedProviderFingerprint: nil,
            handoffState:
            role == .source ? .sourceQuiesced : .destinationStaged,
            activeHandoffTokenID: "token-1",
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: 3
        )
        var vector = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 4,
            snapshotCheckpointID: nil,
            controllerRevisions: [],
            revisionVectorDigestSHA256: digest("pending")
        )
        vector.revisionVectorDigestSHA256 = try ProviderHandoffProjections
            .revisionVectorDigest(vector)
        var abort = expected
        abort.handoffState = .none
        abort.activeHandoffTokenID = nil
        abort.stagedAuthorityLineageUUID = nil
        abort.writerEpoch += 1
        var abortVector = vector
        abortVector.rootStoreRevision += 1
        abortVector.revisionVectorDigestSHA256 = try ProviderHandoffProjections
            .revisionVectorDigest(abortVector)
        return try ProviderHandoffHeaderExpectationV1(
            role: role,
            stateRootUUID: root,
            expectedHeader: expected,
            expectedHeaderDigestSHA256: ProviderHandoffProjections
                .stateRootHeaderDigest(expected),
            preCommitRevisionVector: vector,
            abortHeader: abort,
            abortHeaderDigestSHA256: ProviderHandoffProjections
                .stateRootHeaderDigest(abort),
            abortRevisionVector: abortVector
        )
    }

    private func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-handoff-source-contribution-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }
}
