//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
@testable import ContainerEngineRuntimeSPI
import ContainerEngineService
import ContainerEngineWire
import Foundation
import Security
import Testing

@Suite("Provider handoff gateway manifest assembly", .serialized)
struct ProviderHandoffGatewayManifestAssemblyTests {
    private static let sourceRoot =
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let destinationRoot =
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private static let sourceLineage =
        "11111111-1111-4111-8111-111111111111"
    private static let destinationLineage =
        "22222222-2222-4222-8222-222222222222"
    private static let resultingLineage =
        "33333333-3333-4333-8333-333333333333"
    private static let tokenID = "manifest-assembly-token"
    private static let manifestID = "manifest-assembly-manifest"
    private static let useTime: UInt64 = 500

    @Test
    func `Gateway assembles, signs, binds, and locally replays a manifest`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expectations = try Self.expectations(
            sourceProvider: fixture.sourceEndpoint.fingerprint.digest
        )
        let token = ProviderHandoffTokenV1(
            tokenID: Self.tokenID,
            tokenRevision: 1,
            orderedSourceStateRootUUIDs: [Self.sourceRoot],
            destinationProviderFingerprint:
            fixture.destinationEndpoint.fingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            trustRegistryRevision: 1,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            phase: .draining,
            preCommitRootExpectations: [],
            destinationKeyPossessionProofDigestsSHA256: [],
            manifestID: Self.manifestID
        )
        let transport = ManifestAssemblyTransport(
            sourceEndpoint: fixture.sourceEndpoint,
            destinationEndpoint: fixture.destinationEndpoint,
            sourceIdentity: fixture.sourceIdentity,
            destinationIdentity: fixture.destinationIdentity
        )
        let coordinator = ProviderHandoffGatewayCoordinator(
            store: fixture.gatewayStore,
            bootstrap: fixture.gatewayIdentity.bootstrap,
            manifestAuthority: ProviderHandoffGatewayManifestAuthorityV1(
                gatewayIdentity: fixture.gatewayIdentity,
                trustRegistryStore: fixture.trustRegistryStore,
                possessionProofStore: ProviderHandoffPossessionProofStore(
                    root: fixture.root.appendingPathComponent("proofs")
                ),
                transactionSecretStore:
                ProviderHandoffGatewayTransactionSecretStore(
                    service: fixture.secretService
                ),
                nowUnixSeconds: { Self.useTime }
            ),
            transport: transport
        )
        _ = try await coordinator.begin(token)
        _ = try await coordinator.quiesce(
            tokenID: token.tokenID,
            expectations: expectations
        )
        let possession =
            try await coordinator
                .proveDestinationKeyPossession(
                    tokenID: token.tokenID,
                    destination: fixture.destinationEndpoint
                )
        let proofDigests = try possession.proofs.map {
            try ProviderHandoffProjections
                .destinationPossessionProofRecordDigest($0)
        }.sorted()
        let export = try Self.contributions(
            fixture: fixture,
            expectations: expectations,
            possession: possession,
            proofDigests: proofDigests
        )

        let first = try await coordinator.assembleAndBindManifest(
            tokenID: token.tokenID,
            parts: export.parts,
            contributions: export.contributions,
            sourceEndpoints: [Self.sourceRoot: fixture.sourceEndpoint],
            destinationPossession: possession
        )

        #expect(
            first.validatedManifest.manifest.parts
                == export.parts
        )
        #expect(
            first.validatedManifest.manifest
                .destinationKeyPossessionProofDigestsSHA256
                == proofDigests
        )
        #expect(
            first.gatewayState.transactions[0].manifest
                == first.validatedManifest.manifest
        )
        #expect(first.gatewayState.transactions[0].token.phase == .quiesced)
        #expect(await transport.sourceSignCount() == export.parts.count)

        let replayed = try await coordinator.assembleAndBindManifest(
            tokenID: token.tokenID,
            parts: export.parts,
            contributions: export.contributions,
            sourceEndpoints: [Self.sourceRoot: fixture.sourceEndpoint],
            destinationPossession: possession
        )

        #expect(replayed == first)
        #expect(await transport.sourceSignCount() == export.parts.count)
    }

    @Test
    func `generic source responder exports and replays a sealed logging contribution`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lineageService = "source-lineage-\(UUID().uuidString.lowercased())"
        defer {
            SecItemDelete(
                [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: lineageService
                ] as CFDictionary
            )
        }
        let expectations = try Self.expectations(
            sourceProvider: fixture.sourceEndpoint.fingerprint.digest
        )
        let token = ProviderHandoffTokenV1(
            tokenID: Self.tokenID,
            tokenRevision: 1,
            orderedSourceStateRootUUIDs: [Self.sourceRoot],
            destinationProviderFingerprint:
            fixture.destinationEndpoint.fingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            trustRegistryRevision: 1,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            phase: .draining,
            preCommitRootExpectations: [],
            destinationKeyPossessionProofDigestsSHA256: [],
            manifestID: Self.manifestID
        )
        let transport = ManifestAssemblyTransport(
            sourceEndpoint: fixture.sourceEndpoint,
            destinationEndpoint: fixture.destinationEndpoint,
            sourceIdentity: fixture.sourceIdentity,
            destinationIdentity: fixture.destinationIdentity
        )
        let coordinator = ProviderHandoffGatewayCoordinator(
            store: fixture.gatewayStore,
            bootstrap: fixture.gatewayIdentity.bootstrap,
            manifestAuthority: ProviderHandoffGatewayManifestAuthorityV1(
                gatewayIdentity: fixture.gatewayIdentity,
                trustRegistryStore: fixture.trustRegistryStore,
                possessionProofStore: ProviderHandoffPossessionProofStore(
                    root: fixture.root.appendingPathComponent("source-proof")
                ),
                transactionSecretStore:
                ProviderHandoffGatewayTransactionSecretStore(
                    service: fixture.secretService
                ),
                nowUnixSeconds: { Self.useTime }
            ),
            transport: transport
        )
        _ = try await coordinator.begin(token)
        _ = try await coordinator.quiesce(
            tokenID: token.tokenID,
            expectations: expectations
        )
        let possession =
            try await coordinator
                .proveDestinationKeyPossession(
                    tokenID: token.tokenID,
                    destination: fixture.destinationEndpoint
                )

        let objectStore = ProviderHandoffBundleObjectStore(
            root: fixture.root.appendingPathComponent("source-objects")
        )
        let counter = SourceExportCounter()
        let responder = try ContainerEngineProviderSourceHandoffResponder(
            partKind: .logging,
            mediaType: ProviderHandoffPortableLoggingPayloadCodec.mediaType,
            requiredCapabilities: ["engine.handoff.part.logging.v1"],
            objectStore: objectStore,
            contributionStore: ProviderHandoffSourceContributionStore(
                root: fixture.root.appendingPathComponent("source-contributions")
            ),
            lineageKeyStore: ProviderHandoffLineageKeyStore(
                service: lineageService
            ),
            trustRegistryStore: fixture.trustRegistryStore,
            providerIdentity: fixture.sourceIdentity,
            exportPackage: { request in
                guard request.selectedResourceIDs == ["container-1"] else {
                    throw ContainerEngineProviderSourceHandoffError
                        .invalidRequest
                }
                await counter.increment()
                return try ProviderHandoffPortableLoggingPayloadCodec.package(
                    containers: [
                        ProviderHandoffPortableLoggingContainerV1(
                            containerID: "container-1",
                            providerID: "test-provider",
                            providerVersion: "1",
                            records: []
                        )
                    ],
                    sourceStateRootUUID: Self.sourceRoot
                )
            },
            nowUnixSeconds: { Self.useTime }
        )
        let export = ProviderHandoffPartExportRequestV1(
            partKind: .logging,
            bootstrap: fixture.gatewayIdentity.bootstrap,
            tokenID: Self.tokenID,
            manifestID: Self.manifestID,
            trustRegistryRevision: 1,
            sourceProviderFingerprint:
            fixture.sourceEndpoint.fingerprint.digest,
            sourceStateRootUUID: Self.sourceRoot,
            authorityLineageUUID: Self.sourceLineage,
            lineageDigestKeyVersion: 1,
            sourcePreCommitExpectation: expectations[0],
            destinationProviderFingerprint:
            fixture.destinationEndpoint.fingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            destinationPreCommitExpectation: expectations[1],
            destinationPayloadEncryptionKey:
            possession.payloadEncryptionKey,
            destinationLineageKeyEncryptionKey:
            possession.lineageEncryptionKey,
            destinationKeyPossessionProofs: possession.proofs,
            resultingAuthorityLineageUUID: Self.resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            selectedResourceIDs: ["container-1"]
        )
        let body =
            try ProviderHandoffSourceControlCodec
                .encodeExportRequest(export)
        let control = try ContainerEngineProviderHandoffControlRequestV1(
            requestID: "source-export-logging",
            operation: .partExport,
            bodyMediaType:
            ProviderHandoffSourceControlCodec.exportRequestMediaType,
            body: body
        )
        let context = ContainerEngineProviderHandoffControlContextV1(
            providerFingerprint: fixture.sourceEndpoint.fingerprint,
            authenticatedGatewayCodeIdentity: ProviderHandoffCodeIdentityV1(
                signingIdentifier: "gateway-test",
                teamIdentifier: nil,
                designatedRequirementDigestSHA256:
                fixture.gatewayIdentity.bootstrap
                    .codeRequirementDigestSHA256
            )
        )

        let first = await responder.respond(
            to: control,
            body: body,
            context: context
        )
        #expect(first.response.disposition == .completed)
        let contribution =
            try ProviderHandoffSourceControlCodec
                .decodeContribution(first.body)
        #expect(contribution.part.kind == .logging)
        #expect(
            contribution.part.payload.mediaType
                == ProviderHandoffPortableLoggingPayloadCodec.mediaType
        )
        #expect(
            contribution.part.payload.protection
                == .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2
        )
        #expect(
            try objectStore.load(
                bundleObjectID: contribution.sourceObjectRecord.bundleObjectID
            ).state == .verified
        )
        #expect(await counter.value() == 1)

        let replay = await responder.respond(
            to: control,
            body: body,
            context: context
        )
        #expect(replay.response.disposition == .completed)
        #expect(
            try ProviderHandoffSourceControlCodec.decodeContribution(
                replay.body
            ) == contribution
        )
        #expect(await counter.value() == 1)
    }

    private static func contributions(
        fixture: Fixture,
        expectations: [ProviderHandoffHeaderExpectationV1],
        possession: ProviderHandoffGatewayDestinationPossessionV1,
        proofDigests: [String]
    ) throws -> (
        parts: [ProviderHandoffPartV1],
        contributions: [ProviderHandoffSourceContributionV1]
    ) {
        let lineageKey = ProviderHandoffLineageKeyV1(
            sourceStateRootUUID: sourceRoot,
            authorityLineageUUID: sourceLineage,
            keyVersion: 1,
            rawHMACSHA256Key: Data(repeating: 0x5A, count: 32)
        )
        let lineageEnvelope = try fixture.sourceIdentity.sealLineageKey(
            ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: sourceRoot,
                authorityLineageUUID: sourceLineage,
                keyVersion: 1,
                rawHMACSHA256Key: lineageKey.rawHMACSHA256Key
            ),
            envelopeID: "lineage:\(sourceRoot)",
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint:
            fixture.destinationEndpoint.fingerprint.digest,
            destinationStateRootUUID: destinationRoot,
            destinationKeyID: possession.lineageEncryptionKey.keyID,
            destinationPublicKey:
            possession.lineageEncryptionKey.rawPublicKey,
            nonce: Data(repeating: 0x31, count: 24),
            trustRegistryRevision: 1,
            ephemeralPrivateKey: Data(repeating: 0x32, count: 32)
        )
        var parts: [ProviderHandoffPartV1] = []
        var contributions: [ProviderHandoffSourceContributionV1] = []
        for (index, kind) in ProviderHandoffPartKindV1.allCases.enumerated() {
            let payload = try ProviderHandoffPayloadCodec.prepareSealed(
                ProviderHandoffPayloadPackageV1(
                    partKind: kind,
                    entries: [
                        ProviderHandoffPayloadPackageEntryV1(
                            entryID: "entry-\(kind.rawValue)",
                            sourceStateRootUUID: sourceRoot,
                            recordKind: "manifest-assembly-test",
                            schemaVersion: 1,
                            canonicalRecordBytes:
                            ProviderHandoffCanonicalCBOR.encode(
                                .map([
                                    .init(
                                        "kind",
                                        .textString(kind.rawValue)
                                    )
                                ])
                            )
                        )
                    ]
                ),
                mediaType:
                "application/vnd.io.github.stephenlclarke.container.handoff-test.v1+cbor",
                tokenID: tokenID,
                manifestID: manifestID,
                sourceOrder: [sourceRoot],
                lineageKeys: [lineageKey],
                destinationProviderFingerprint:
                fixture.destinationEndpoint.fingerprint.digest,
                destinationStateRootUUID: destinationRoot,
                destinationKeyID: possession.payloadEncryptionKey.keyID,
                destinationPublicKey:
                possession.payloadEncryptionKey.rawPublicKey,
                nonce: Data(repeating: UInt8(index + 1), count: 24),
                ephemeralPrivateKey:
                Data(repeating: UInt8(index + 33), count: 32)
            )
            let part = ProviderHandoffPartV1(
                kind: kind,
                schemaVersion: 1,
                disposition: .included,
                sourceStateRootUUIDs: [sourceRoot],
                requiredCapabilities: [],
                payload: payload.descriptor
            )
            let object = ProviderHandoffBundleObjectRecordV1(
                bundleObjectID: payload.descriptor.bundleObjectID,
                transportByteLength: payload.descriptor.transportByteLength,
                transportDigestSHA256:
                payload.descriptor.transportDigestSHA256,
                receivedByteCount: payload.descriptor.transportByteLength,
                objectRevision: 2,
                state: .verified
            )
            let contribution =
                try ProviderHandoffSourceControlCodec
                    .finalizeContribution(
                        ProviderHandoffSourceContributionV1(
                            partKind: kind,
                            tokenID: tokenID,
                            manifestID: manifestID,
                            trustRegistryRevision: 1,
                            exportRequestDigestSHA256:
                            digest("export-\(kind.rawValue)"),
                            sourceProviderFingerprint:
                            fixture.sourceEndpoint.fingerprint.digest,
                            sourceStateRootUUID: sourceRoot,
                            authorityLineageUUID: sourceLineage,
                            lineageDigestKeyVersion: 1,
                            sourcePreCommitExpectation: expectations[0],
                            destinationProviderFingerprint:
                            fixture.destinationEndpoint.fingerprint.digest,
                            destinationStateRootUUID: destinationRoot,
                            destinationPreCommitExpectation: expectations[1],
                            destinationKeyPossessionProofDigestsSHA256:
                            proofDigests,
                            resultingAuthorityLineageUUID: resultingLineage,
                            resultingLineageDigestKeyVersion: 2,
                            destinationSealedLineageKeyEnvelope:
                            lineageEnvelope,
                            part: part,
                            sourceObjectRecord: object
                        )
                    )
            parts.append(part)
            contributions.append(contribution)
        }
        return (parts, contributions)
    }

    private static func expectations(
        sourceProvider: String
    ) throws -> [ProviderHandoffHeaderExpectationV1] {
        try [
            expectation(
                role: .source,
                root: sourceRoot,
                lineage: sourceLineage,
                stagedLineage: nil,
                provider: sourceProvider,
                state: .sourceQuiesced,
                abortState: .destinationActive,
                checkpoint: "source-checkpoint"
            ),
            expectation(
                role: .destination,
                root: destinationRoot,
                lineage: destinationLineage,
                stagedLineage: resultingLineage,
                provider: nil,
                state: .destinationStaged,
                abortState: .none,
                checkpoint: nil
            )
        ]
    }

    private static func expectation(
        role: ProviderHandoffRootRoleV1,
        root: String,
        lineage: String,
        stagedLineage: String?,
        provider: String?,
        state: StateRootHandoffStateV1,
        abortState: StateRootHandoffStateV1,
        checkpoint: String?
    ) throws -> ProviderHandoffHeaderExpectationV1 {
        let expected = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID: stagedLineage,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 8,
            selectedProviderFingerprint: provider,
            handoffState: state,
            activeHandoffTokenID: tokenID,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: 1
        )
        let aborted = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID: nil,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 9,
            selectedProviderFingerprint: provider,
            handoffState: abortState,
            activeHandoffTokenID: nil,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: 1
        )
        var expectedVector = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 12,
            snapshotCheckpointID: checkpoint,
            controllerRevisions: [],
            revisionVectorDigestSHA256: digest("expected-vector")
        )
        expectedVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections
                .revisionVectorDigest(expectedVector)
        var abortVector = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 13,
            snapshotCheckpointID: checkpoint,
            controllerRevisions: [],
            revisionVectorDigestSHA256: digest("abort-vector")
        )
        abortVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections.revisionVectorDigest(abortVector)
        return try ProviderHandoffHeaderExpectationV1(
            role: role,
            stateRootUUID: root,
            expectedHeader: expected,
            expectedHeaderDigestSHA256:
            ProviderHandoffProjections
                .stateRootHeaderDigest(expected),
            preCommitRevisionVector: expectedVector,
            abortHeader: aborted,
            abortHeaderDigestSHA256:
            ProviderHandoffProjections
                .stateRootHeaderDigest(aborted),
            abortRevisionVector: abortVector
        )
    }

    fileprivate static func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }

    private struct Fixture {
        let root: URL
        let gatewayService: String
        let sourceService: String
        let destinationService: String
        let trustService: String
        let secretService: String
        let gatewayIdentity: ProviderHandoffGatewayIdentityV1
        let sourceIdentity: ProviderHandoffProviderIdentityV1
        let destinationIdentity: ProviderHandoffProviderIdentityV1
        let sourceEndpoint: ProviderHandoffGatewayProviderEndpointV1
        let destinationEndpoint: ProviderHandoffGatewayProviderEndpointV1
        let trustRegistryStore: ProviderHandoffTrustRegistryStore
        let gatewayStore: ProviderHandoffGatewayStore

        init() throws {
            let identifier = UUID().uuidString.lowercased()
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "container-engine-manifest-assembly-\(identifier)",
                    isDirectory: true
                )
            gatewayService = "gateway-\(identifier)"
            sourceService = "source-\(identifier)"
            destinationService = "destination-\(identifier)"
            trustService = "trust-\(identifier)"
            secretService = "secret-\(identifier)"
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let endpoints = try Self.endpoints()
            sourceEndpoint = endpoints.source
            destinationEndpoint = endpoints.destination
            let codeIdentity = ProviderHandoffCodeIdentityV1(
                signingIdentifier: "container-engine-manifest-tests",
                teamIdentifier: "TESTTEAM",
                designatedRequirementDigestSHA256:
                String(repeating: "c", count: 64)
            )
            gatewayIdentity = try ProviderHandoffGatewayKeyStore(
                service: gatewayService,
                account: "gateway"
            ).loadOrCreate(
                context: ProviderHandoffGatewayKeyEnrollmentContextV1(
                    owningBundleIdentifier: codeIdentity.signingIdentifier,
                    codeRequirementDigestSHA256:
                    codeIdentity.designatedRequirementDigestSHA256,
                    teamIdentifier: codeIdentity.teamIdentifier,
                    gatewayRegistrationDigestSHA256:
                    ProviderHandoffGatewayKeyEnrollmentContextV1
                        .registrationDigest(codeIdentity: codeIdentity),
                    enrolledAtUnixSeconds: 100,
                    notBeforeUnixSeconds: 100,
                    notAfterUnixSeconds: 10000
                )
            )
            sourceIdentity = try Self.providerIdentity(
                endpoint: sourceEndpoint,
                service: sourceService,
                account: "source"
            )
            destinationIdentity = try Self.providerIdentity(
                endpoint: destinationEndpoint,
                service: destinationService,
                account: "destination"
            )
            let registry = try gatewayIdentity.makeTrustRegistry(
                providerKeys:
                sourceIdentity.trustKeys
                    + destinationIdentity.trustKeys,
                registryRevision: 1,
                issuedAtUnixSeconds: 100
            )
            trustRegistryStore = ProviderHandoffTrustRegistryStore(
                service: trustService,
                account: "registry"
            )
            _ = try trustRegistryStore.install(
                registry.registry,
                bootstrap: gatewayIdentity.bootstrap
            )
            gatewayStore = ProviderHandoffGatewayStore(
                root: root.appendingPathComponent("gateway")
            )
            _ = try gatewayStore.loadOrCreate(
                initial: ProviderHandoffGatewayStateMachine.initialState(
                    providerSelection:
                    ProviderHandoffProviderSelectionRecordV1(
                        selectionRevision: 1,
                        selectedProviderFingerprint:
                        sourceEndpoint.fingerprint.digest,
                        selectedStateRootUUID: sourceRoot,
                        providerRegistrationDigestSHA256:
                        String(
                            sourceEndpoint.fingerprint.digest
                                .dropFirst("sha256:".count)
                        ),
                        trustRegistryRevision: 1
                    ),
                    socketDiscovery:
                    ProviderHandoffSocketDiscoveryRecordV1(
                        discoveryRevision: 1,
                        socketInstanceUUID:
                        "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                        ownerUID: 501,
                        minimumEngineAPIVersion: "1.44",
                        maximumEngineAPIVersion: "1.53",
                        selectedProviderFingerprint:
                        sourceEndpoint.fingerprint.digest,
                        selectedStateRootUUID: sourceRoot
                    )
                )
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            try? ProviderHandoffGatewayKeyStore.removeForTesting(
                service: gatewayService,
                account: "gateway"
            )
            try? ProviderHandoffProviderKeyStore.removeForTesting(
                service: sourceService,
                account: "source"
            )
            try? ProviderHandoffProviderKeyStore.removeForTesting(
                service: destinationService,
                account: "destination"
            )
            try? ProviderHandoffTrustRegistryStore.removeForTesting(
                service: trustService,
                account: "registry",
                archivedRevisions: UInt64(1) ... UInt64(1)
            )
            SecItemDelete(
                [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: secretService
                ] as CFDictionary
            )
        }

        private static func providerIdentity(
            endpoint: ProviderHandoffGatewayProviderEndpointV1,
            service: String,
            account: String
        ) throws -> ProviderHandoffProviderIdentityV1 {
            try ProviderHandoffProviderKeyStore(
                service: service,
                account: account
            ).loadOrCreate(
                context: ProviderHandoffProviderKeyEnrollmentContextV1(
                    providerFingerprint: endpoint.fingerprint.digest,
                    stateRootUUID:
                    endpoint.fingerprint.stateRootUUID.uuidString
                        .lowercased(),
                    owningBundleIdentifier: "manifest-assembly-provider",
                    codeRequirementDigestSHA256:
                    String(repeating: "e", count: 64),
                    teamIdentifier: "TESTTEAM",
                    providerRegistrationDigestSHA256:
                    String(
                        endpoint.fingerprint.digest
                            .dropFirst("sha256:".count)
                    ),
                    enrolledAtUnixSeconds: 100,
                    notBeforeUnixSeconds: 100,
                    notAfterUnixSeconds: 10000
                )
            )
        }

        private static func endpoints() throws -> (
            source: ProviderHandoffGatewayProviderEndpointV1,
            destination: ProviderHandoffGatewayProviderEndpointV1
        ) {
            let capability = try ContainerEngineProviderCapability(
                identifier: "engine.handoff.manifest.v1",
                status: .native
            )
            let source = try ContainerEngineProviderDeclaration(
                profile: .enhanced,
                kind: .containerAuthority,
                implementationVersion: "source-test",
                runtimeRevisions: ["container": "source"],
                stateSchemaVersion: 1,
                capabilities: [capability]
            )
            let destination = try ContainerEngineProviderDeclaration(
                profile: .enhanced,
                kind: .containerAuthority,
                implementationVersion: "destination-test",
                runtimeRevisions: ["container": "destination"],
                stateSchemaVersion: 1,
                capabilities: [capability]
            )
            return try (
                ProviderHandoffGatewayProviderEndpointV1(
                    socketPath: "source",
                    fingerprint: ContainerEngineProviderFingerprint(
                        declaration: source,
                        stateRootUUID: UUID(uuidString: sourceRoot)!
                    )
                ),
                ProviderHandoffGatewayProviderEndpointV1(
                    socketPath: "destination",
                    fingerprint: ContainerEngineProviderFingerprint(
                        declaration: destination,
                        stateRootUUID: UUID(uuidString: destinationRoot)!
                    )
                )
            )
        }
    }
}

private actor SourceExportCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor ManifestAssemblyTransport:
    ProviderHandoffGatewayControlTransport
{
    private let sourceEndpoint: ProviderHandoffGatewayProviderEndpointV1
    private let destinationEndpoint: ProviderHandoffGatewayProviderEndpointV1
    private let sourceIdentity: ProviderHandoffProviderIdentityV1
    private let destinationIdentity: ProviderHandoffProviderIdentityV1
    private var signCount = 0

    init(
        sourceEndpoint: ProviderHandoffGatewayProviderEndpointV1,
        destinationEndpoint: ProviderHandoffGatewayProviderEndpointV1,
        sourceIdentity: ProviderHandoffProviderIdentityV1,
        destinationIdentity: ProviderHandoffProviderIdentityV1
    ) {
        self.sourceEndpoint = sourceEndpoint
        self.destinationEndpoint = destinationEndpoint
        self.sourceIdentity = sourceIdentity
        self.destinationIdentity = destinationIdentity
    }

    func sourceSignCount() -> Int {
        signCount
    }

    func perform(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ContainerEngineProviderHandoffControlResultV1 {
        switch request.operation {
        case .destinationKeyPossession:
            guard endpoint == destinationEndpoint else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            let challenge =
                try ProviderHandoffProviderKeyControlCodec
                    .decodePossessionChallenge(body)
            let proof = try destinationIdentity.respond(
                to: challenge.challenge,
                trustRegistryRevision: challenge.trustRegistryRevision
            )
            let responseBody =
                try ProviderHandoffProviderKeyControlCodec
                    .encodePossessionProof(proof)
            return try result(
                requestID: request.requestID,
                mediaType: ProviderHandoffProviderKeyControlCodec
                    .possessionProofMediaType,
                body: responseBody
            )
        case .sourceSignManifest:
            guard endpoint == sourceEndpoint else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            signCount += 1
            let value =
                try ProviderHandoffSourceControlCodec
                    .decodeSignRequest(body)
            let source = try #require(
                value.candidateManifest.sources.first(where: {
                    $0.stateRootUUID
                        == self.sourceIdentity.context.stateRootUUID
                })
            )
            let digest =
                try ProviderHandoffProjections
                    .sourceManifestDigest(
                        source: source,
                        manifest: value.candidateManifest
                    )
            let signature = try sourceIdentity.sign(
                projectionDigestSHA256: digest,
                purpose: .sourceManifestSigning,
                trustRegistryRevision:
                value.candidateManifest.trustRegistryRevision
            )
            let responseBody =
                try ProviderHandoffSourceControlCodec
                    .encodeSignReceipt(
                        ProviderHandoffSourceManifestSignReceiptV1(
                            partKind: value.partKind,
                            tokenID: value.candidateManifest.tokenID,
                            manifestID: value.candidateManifest.manifestID,
                            sourceStateRootUUID: source.stateRootUUID,
                            contributionDigestSHA256:
                            value.contributionDigestSHA256,
                            sourceProjectionDigestSHA256: digest,
                            sourceSignature: signature
                        )
                    )
            return try result(
                requestID: request.requestID,
                mediaType: ProviderHandoffSourceControlCodec
                    .signReceiptMediaType,
                body: responseBody
            )
        default:
            throw
                ProviderHandoffGatewayCoordinatorError
                .invalidProviderResponse(request.operation)
        }
    }

    private func result(
        requestID: String,
        mediaType: String,
        body: Data
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        try ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                requestID: requestID,
                disposition: .completed,
                bodyMediaType: mediaType,
                body: body
            ),
            body: body
        )
    }
}
