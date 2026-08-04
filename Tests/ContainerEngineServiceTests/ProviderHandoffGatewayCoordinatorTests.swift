//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
@testable import ContainerEngineRuntimeSPI
import ContainerEngineService
import ContainerEngineWire
import Foundation
import Testing

@Suite(.serialized)
struct ProviderHandoffGatewayCoordinatorTests {
    private static let sourceRoot =
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let destinationRoot =
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private static let sourceLineage =
        "11111111-1111-4111-8111-111111111111"
    private static let destinationLineage =
        "22222222-2222-4222-8222-222222222222"
    private static let tokenID = "coordinator-token"
    private static let manifestID = "coordinator-manifest"

    @Test
    func `controller transaction streams stages promotes activates and replays`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "container-engine-coordinator-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let endpoints = try Self.endpoints()
        let sourceStore = ProviderHandoffBundleObjectStore(
            root: root.appendingPathComponent("source-objects")
        )
        let destinationStore = ProviderHandoffBundleObjectStore(
            root: root.appendingPathComponent("destination-objects")
        )
        let fixture = try Self.manifest(
            sourceProvider: endpoints.source.fingerprint.digest,
            destinationProvider: endpoints.destination.fingerprint.digest
        )
        for payload in fixture.payloads {
            try Self.publish(payload, to: sourceStore)
        }

        let gatewayStore = ProviderHandoffGatewayStore(
            root: root.appendingPathComponent("gateway")
        )
        _ = try gatewayStore.loadOrCreate(
            initial: Self.initialState(
                sourceProvider: endpoints.source.fingerprint.digest
            )
        )
        let transport = try TestHandoffTransport(
            source: endpoints.source,
            destination: endpoints.destination,
            sourceStore: sourceStore,
            destinationStore: destinationStore
        )
        let coordinator = ProviderHandoffGatewayCoordinator(
            store: gatewayStore,
            bootstrap: ProviderHandoffPinnedBootstrapKeyV1(
                keyID: "gateway-bootstrap",
                rawPublicKey: Data(repeating: 0x41, count: 32),
                codeRequirementDigestSHA256: Self.digest("gateway-code")
            ),
            transport: transport
        )
        let token = ProviderHandoffTokenV1(
            tokenID: Self.tokenID,
            tokenRevision: 1,
            orderedSourceStateRootUUIDs: [Self.sourceRoot],
            destinationProviderFingerprint:
            endpoints.destination.fingerprint.digest,
            destinationStateRootUUID: Self.destinationRoot,
            trustRegistryRevision: 1,
            resultingAuthorityLineageUUID: Self.sourceLineage,
            resultingLineageDigestKeyVersion: 1,
            phase: .draining,
            preCommitRootExpectations: [],
            destinationKeyPossessionProofDigestsSHA256: [],
            manifestID: Self.manifestID
        )
        _ = try await coordinator.begin(token)
        _ = try await coordinator.quiesce(
            tokenID: token.tokenID,
            expectations: fixture.expectations
        )
        let routes = ProviderHandoffPartKindV1.allCases.map {
            ProviderHandoffGatewayPartSourceV1(
                partKind: $0,
                endpoint: endpoints.source
            )
        }

        let first = try await coordinator.stage(
            ProviderHandoffValidatedManifestV1(manifest: fixture.manifest),
            sources: routes,
            destination: endpoints.destination
        )

        #expect(first.importedParts.map(\.partKind) == ProviderHandoffPartKindV1.allCases)
        #expect(first.gatewayState.transactions[0].token.phase == .staged)
        #expect(first.gatewayState.transactions[0].token.importedParts == first.importedParts)
        for payload in fixture.payloads {
            let record = try destinationStore.load(
                bundleObjectID: payload.descriptor.bundleObjectID
            )
            #expect(record.state == .verified)
            #expect(record.receivedByteCount == UInt64(payload.transportBytes.count))
        }
        let firstCounts = await transport.counts()
        #expect(firstCounts.stage == ProviderHandoffPartKindV1.allCases.count)
        #expect(firstCounts.read == fixture.payloads.count)

        let second = try await coordinator.stage(
            ProviderHandoffValidatedManifestV1(manifest: fixture.manifest),
            sources: routes,
            destination: endpoints.destination
        )

        #expect(second == first)
        #expect(await transport.counts() == firstCounts)

        let commit = try Self.commitRecord(
            state: second.gatewayState,
            destinationProvider: endpoints.destination.fingerprint.digest
        )
        for prepare in commit.prepares {
            _ = try await coordinator.recordPreparedRoot(prepare)
        }
        _ = try await coordinator.commit(
            ProviderHandoffValidatedCommitRecordV1(record: commit.record)
        )
        _ = try await coordinator.beginReconciliation(tokenID: Self.tokenID)

        let promoted = try await coordinator.promote(
            tokenID: Self.tokenID,
            destination: endpoints.destination
        )
        #expect(promoted.receipts.map(\.partKind) == ProviderHandoffPartKindV1.allCases)
        #expect(
            promoted.gatewayState.transactions[0].promotedPartReceipts
                == promoted.receipts
        )
        let promotionCounts = await transport.counts()
        #expect(promotionCounts.promote == ProviderHandoffPartKindV1.allCases.count)
        let replayedPromotion = try await coordinator.promote(
            tokenID: Self.tokenID,
            destination: endpoints.destination
        )
        #expect(replayedPromotion == promoted)
        #expect(await transport.counts() == promotionCounts)

        let outcome = try Self.completeOutcome(commit.record)
        let terminal = try await coordinator.completeAndActivate(
            ProviderHandoffValidatedTerminalOutcomeV1(outcome: outcome),
            destination: endpoints.destination
        )
        #expect(terminal.gatewayState.transactions[0].token.phase == .complete)
        #expect(terminal.receipts.count == ProviderHandoffPartKindV1.allCases.count)
        #expect(terminal.receipts.allSatisfy { $0.operation == .activate })
        let terminalCounts = await transport.counts()
        #expect(terminalCounts.activate == ProviderHandoffPartKindV1.allCases.count)

        let replayedTerminal = try await coordinator.completeAndActivate(
            ProviderHandoffValidatedTerminalOutcomeV1(outcome: outcome),
            destination: endpoints.destination
        )
        #expect(replayedTerminal == terminal)
        #expect(
            await transport.counts().activate
                == terminalCounts.activate
                + ProviderHandoffPartKindV1.allCases.count
        )
    }

    private static func endpoints() throws -> (
        source: ProviderHandoffGatewayProviderEndpointV1,
        destination: ProviderHandoffGatewayProviderEndpointV1
    ) {
        let capabilities = try [
            ContainerEngineProviderCapability(
                identifier: "engine.handoff.object-transfer.v1",
                status: .native
            )
        ]
        let sourceDeclaration = try ContainerEngineProviderDeclaration(
            profile: .enhanced,
            kind: .containerAuthority,
            implementationVersion: "source-test",
            runtimeRevisions: ["container": "source"],
            stateSchemaVersion: 1,
            capabilities: capabilities
        )
        let destinationDeclaration = try ContainerEngineProviderDeclaration(
            profile: .enhanced,
            kind: .containerAuthority,
            implementationVersion: "destination-test",
            runtimeRevisions: ["container": "destination"],
            stateSchemaVersion: 1,
            capabilities: capabilities
        )
        return try (
            ProviderHandoffGatewayProviderEndpointV1(
                socketPath: "source",
                fingerprint: ContainerEngineProviderFingerprint(
                    declaration: sourceDeclaration,
                    stateRootUUID: UUID(uuidString: sourceRoot)!
                )
            ),
            ProviderHandoffGatewayProviderEndpointV1(
                socketPath: "destination",
                fingerprint: ContainerEngineProviderFingerprint(
                    declaration: destinationDeclaration,
                    stateRootUUID: UUID(uuidString: destinationRoot)!
                )
            )
        )
    }

    private static func initialState(
        sourceProvider: String
    ) throws -> ProviderHandoffGatewayStateV1 {
        try ProviderHandoffGatewayStateMachine.initialState(
            providerSelection: ProviderHandoffProviderSelectionRecordV1(
                selectionRevision: 1,
                selectedProviderFingerprint: sourceProvider,
                selectedStateRootUUID: sourceRoot,
                providerRegistrationDigestSHA256:
                String(sourceProvider.dropFirst("sha256:".count)),
                trustRegistryRevision: 1
            ),
            socketDiscovery: ProviderHandoffSocketDiscoveryRecordV1(
                discoveryRevision: 1,
                socketInstanceUUID:
                "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                ownerUID: 501,
                minimumEngineAPIVersion: "1.44",
                maximumEngineAPIVersion: "1.53",
                selectedProviderFingerprint: sourceProvider,
                selectedStateRootUUID: sourceRoot
            )
        )
    }

    private static func manifest(
        sourceProvider: String,
        destinationProvider: String
    ) throws -> (
        manifest: ProviderHandoffManifestV1,
        expectations: [ProviderHandoffHeaderExpectationV1],
        payloads: [ProviderHandoffPreparedPayloadV1]
    ) {
        let source = try expectation(
            role: .source,
            root: sourceRoot,
            lineage: sourceLineage,
            stagedLineage: nil,
            provider: sourceProvider,
            state: .sourceQuiesced,
            abortState: .destinationActive,
            checkpoint: "source-checkpoint"
        )
        let destination = try expectation(
            role: .destination,
            root: destinationRoot,
            lineage: destinationLineage,
            stagedLineage: sourceLineage,
            provider: nil,
            state: .destinationStaged,
            abortState: .none,
            checkpoint: nil
        )
        let payloads = try ProviderHandoffPartKindV1.allCases.map { kind in
            try ProviderHandoffPayloadCodec.prepareAuthenticated(
                ProviderHandoffPayloadPackageV1(
                    partKind: kind,
                    entries: [
                        ProviderHandoffPayloadPackageEntryV1(
                            entryID: "evidence-\(kind.rawValue)",
                            sourceStateRootUUID: sourceRoot,
                            recordKind: "test-evidence",
                            schemaVersion: 1,
                            canonicalRecordBytes: ProviderHandoffCanonicalCBOR
                                .encode(
                                    .map([
                                        .init("kind", .textString(kind.rawValue))
                                    ])
                                )
                        )
                    ]
                ),
                mediaType:
                "application/vnd.io.github.stephenlclarke.container.handoff-test.v1+cbor",
                sourceOrder: [sourceRoot]
            )
        }
        let parts = zip(ProviderHandoffPartKindV1.allCases, payloads).map {
            ProviderHandoffPartV1(
                kind: $0.0,
                schemaVersion: 1,
                disposition: .included,
                sourceStateRootUUIDs: [sourceRoot],
                requiredCapabilities: [],
                payload: $0.1.descriptor
            )
        }
        var value = ProviderHandoffManifestV1(
            manifestID: manifestID,
            tokenID: tokenID,
            trustRegistryRevision: 1,
            destinationKeyPossessionProofDigestsSHA256: [],
            sources: [
                ProviderHandoffSourceV1(
                    providerFingerprint: sourceProvider,
                    stateRootUUID: sourceRoot,
                    authorityLineageUUID: sourceLineage,
                    lineageDigestKeyVersion: 1,
                    preCommitExpectation: source,
                    sourceSignature: placeholderSignature(
                        purpose: .sourceManifestSigning,
                        role: .sourceProvider,
                        provider: sourceProvider,
                        root: sourceRoot
                    )
                )
            ],
            resultingAuthorityLineageUUID: sourceLineage,
            resultingLineageDigestKeyVersion: 1,
            destinationSealedLineageKeyEnvelopes: [],
            destinationProviderFingerprint: destinationProvider,
            destinationStateRootUUID: destinationRoot,
            destinationPreCommitExpectation: destination,
            parts: parts,
            manifestDigest: digest("pending-manifest"),
            coordinatorSignature: placeholderSignature(
                purpose: .coordinatorManifestSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        value.sources[0].sourceSignature = try placeholderSignature(
            purpose: .sourceManifestSigning,
            role: .sourceProvider,
            provider: sourceProvider,
            root: sourceRoot,
            signedDigest: ProviderHandoffProjections
                .sourceManifestDigest(
                    source: value.sources[0],
                    manifest: value
                )
        )
        value.manifestDigest = try ProviderHandoffProjections
            .manifestDigest(value)
        value.coordinatorSignature = placeholderSignature(
            purpose: .coordinatorManifestSigning,
            role: .gatewayCoordinator,
            provider: nil,
            root: nil,
            signedDigest: value.manifestDigest
        )
        return (value, [source, destination], payloads)
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
            revisionVectorDigestSHA256: digest("pending-vector")
        )
        expectedVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections
                .revisionVectorDigest(expectedVector)
        var abortVector = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 13,
            snapshotCheckpointID: checkpoint,
            controllerRevisions: [],
            revisionVectorDigestSHA256: digest("pending-abort-vector")
        )
        abortVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections.revisionVectorDigest(abortVector)
        return try ProviderHandoffHeaderExpectationV1(
            role: role,
            stateRootUUID: root,
            expectedHeader: expected,
            expectedHeaderDigestSHA256:
            ProviderHandoffProjections.stateRootHeaderDigest(expected),
            preCommitRevisionVector: expectedVector,
            abortHeader: aborted,
            abortHeaderDigestSHA256:
            ProviderHandoffProjections.stateRootHeaderDigest(aborted),
            abortRevisionVector: abortVector
        )
    }

    private static func publish(
        _ payload: ProviderHandoffPreparedPayloadV1,
        to store: ProviderHandoffBundleObjectStore
    ) throws {
        var record = try store.declare(
            bundleObjectID: payload.descriptor.bundleObjectID,
            transportByteLength: payload.descriptor.transportByteLength,
            transportDigestSHA256:
            payload.descriptor.transportDigestSHA256
        )
        record = try store.append(
            bundleObjectID: payload.descriptor.bundleObjectID,
            offset: 0,
            bytes: payload.transportBytes,
            expectedObjectRevision: record.objectRevision
        )
        _ = try store.verify(
            bundleObjectID: payload.descriptor.bundleObjectID,
            expectedObjectRevision: record.objectRevision
        )
    }

    private static func commitRecord(
        state: ProviderHandoffGatewayStateV1,
        destinationProvider: String
    ) throws -> (
        record: ProviderHandoffCommitRecordV1,
        prepares: [ProviderHandoffRootPrepareRecordV1]
    ) {
        let transaction = try #require(state.transactions.first)
        let imported = try #require(transaction.token.importedParts)
        var resultingProvider = state.providerSelection
        resultingProvider.selectionRevision += 1
        resultingProvider.selectedProviderFingerprint = destinationProvider
        resultingProvider.selectedStateRootUUID = destinationRoot
        resultingProvider.providerRegistrationDigestSHA256 =
            String(destinationProvider.dropFirst("sha256:".count))
        var resultingSocket = state.socketDiscovery
        resultingSocket.discoveryRevision += 1
        resultingSocket.selectedProviderFingerprint = destinationProvider
        resultingSocket.selectedStateRootUUID = destinationRoot
        let intent = try ProviderHandoffCommitIntentV1(
            tokenID: tokenID,
            manifestID: manifestID,
            manifestDigest: #require(transaction.token.manifestDigest),
            trustRegistryRevision: 1,
            authoritativeCommitRevision: state.authoritativeCommitRevision + 1,
            preCommitRootExpectations:
            transaction.token.preCommitRootExpectations,
            importedParts: imported,
            destinationKeyPossessionProofDigestsSHA256: [],
            providerSelection: ProviderHandoffProviderSelectionExpectationV1(
                expectedRecord: state.providerSelection,
                expectedRecordDigestSHA256:
                ProviderHandoffProjections
                    .providerSelectionDigest(state.providerSelection),
                resultingRecord: resultingProvider,
                resultingRecordDigestSHA256:
                ProviderHandoffProjections
                    .providerSelectionDigest(resultingProvider)
            ),
            socketSelection: ProviderHandoffSocketSelectionExpectationV1(
                expectedRecord: state.socketDiscovery,
                expectedRecordDigestSHA256:
                ProviderHandoffProjections
                    .socketDiscoveryDigest(state.socketDiscovery),
                resultingRecord: resultingSocket,
                resultingRecordDigestSHA256:
                ProviderHandoffProjections
                    .socketDiscoveryDigest(resultingSocket)
            ),
            resultingAuthorityLineageUUID: sourceLineage,
            resultingLineageDigestKeyVersion: 1,
            resultingMinimumWriterSchemaVersion: 1
        )
        let commitDigest = try ProviderHandoffProjections
            .commitIntentDigest(intent)
        let chainHead = try ProviderHandoffProjections.chainHeadDigest(
            commitDigestSHA256: commitDigest,
            orderedPreCommitHeaders:
            intent.preCommitRootExpectations.map(\.expectedHeader)
        )
        let postRoots = try ProviderHandoffRecordValidator
            .derivePostCommitRoots(
                intent: intent,
                chainHeadDigestSHA256: chainHead
            )
        let prepares = zip(intent.preCommitRootExpectations, postRoots)
            .map { expectation, post in
                ProviderHandoffRootPrepareRecordV1(
                    tokenID: tokenID,
                    manifestID: manifestID,
                    role: expectation.role,
                    stateRootUUID: expectation.stateRootUUID,
                    commitDigestSHA256: commitDigest,
                    expectedHeaderDigestSHA256:
                    expectation.expectedHeaderDigestSHA256,
                    preCommitRevisionVectorDigestSHA256:
                    expectation.preCommitRevisionVector
                        .revisionVectorDigestSHA256,
                    postCommitHeaderDigestSHA256:
                    post.postCommitHeaderDigestSHA256,
                    postCommitRevisionVectorDigestSHA256:
                    post.postCommitRevisionVector
                        .revisionVectorDigestSHA256,
                    prepareRevision: 1
                )
            }
        var record = try ProviderHandoffCommitRecordV1(
            intent: intent,
            commitDigestSHA256: commitDigest,
            handoffChainHeadDigestSHA256: chainHead,
            postCommitRoots: postRoots,
            rootPrepareRecordDigestsSHA256:
            prepares.map(ProviderHandoffProjections.rootPrepareDigest),
            coordinatorSignature: placeholderSignature(
                purpose: .coordinatorCommitSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        record.coordinatorSignature = try placeholderSignature(
            purpose: .coordinatorCommitSigning,
            role: .gatewayCoordinator,
            provider: nil,
            root: nil,
            signedDigest:
            ProviderHandoffProjections.commitRecordDigest(record)
        )
        return (record, prepares)
    }

    private static func completeOutcome(
        _ commit: ProviderHandoffCommitRecordV1
    ) throws -> ProviderHandoffTerminalOutcomeV1 {
        var roots: [ProviderHandoffTerminalRootV1] = []
        for (index, post) in commit.postCommitRoots.enumerated() {
            var header = post.postCommitHeader
            var vector = post.postCommitRevisionVector
            if index == commit.postCommitRoots.count - 1 {
                header.handoffState = .destinationActive
                header.activeHandoffTokenID = nil
                header.writerEpoch += 1
                vector.rootStoreRevision += 1
                vector.revisionVectorDigestSHA256 =
                    try ProviderHandoffProjections
                        .revisionVectorDigest(vector)
            }
            try roots.append(
                ProviderHandoffTerminalRootV1(
                    role: post.role,
                    stateRootUUID: post.stateRootUUID,
                    terminalHeader: header,
                    terminalHeaderDigestSHA256:
                    ProviderHandoffProjections
                        .stateRootHeaderDigest(header),
                    terminalRevisionVector: vector
                )
            )
        }
        var outcome = ProviderHandoffTerminalOutcomeV1(
            tokenID: tokenID,
            manifestID: manifestID,
            manifestDigest: commit.intent.manifestDigest,
            phase: .complete,
            roots: roots,
            outcomeDigestSHA256: digest("pending-outcome"),
            coordinatorSignature: placeholderSignature(
                purpose: .coordinatorTerminalOutcomeSigning,
                role: .gatewayCoordinator,
                provider: nil,
                root: nil
            )
        )
        outcome.outcomeDigestSHA256 = try ProviderHandoffProjections
            .terminalOutcomeDigest(outcome)
        outcome.coordinatorSignature = placeholderSignature(
            purpose: .coordinatorTerminalOutcomeSigning,
            role: .gatewayCoordinator,
            provider: nil,
            root: nil,
            signedDigest: outcome.outcomeDigestSHA256
        )
        return outcome
    }

    private static func placeholderSignature(
        purpose: ProviderHandoffKeyPurposeV1,
        role: ProviderHandoffKeyRoleV1,
        provider: String?,
        root: String?,
        signedDigest: String = digest("pending-signature")
    ) -> ProviderHandoffSignatureV1 {
        ProviderHandoffSignatureV1(
            purpose: purpose,
            signerKeyID: "test-\(purpose.rawValue)",
            signerRole: role,
            providerFingerprint: provider,
            stateRootUUID: root,
            trustRegistryRevision: 1,
            signedProjectionDigestSHA256: signedDigest,
            signature: Data(repeating: 0x51, count: 64)
        )
    }

    fileprivate static func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }
}

private actor TestHandoffTransport: ProviderHandoffGatewayControlTransport {
    struct Counts: Equatable, Sendable {
        var activate = 0
        var promote = 0
        var read = 0
        var stage = 0
    }

    private let source: ProviderHandoffGatewayProviderEndpointV1
    private let destination: ProviderHandoffGatewayProviderEndpointV1
    private let sourceService: ContainerEngineProviderHandoffControlService
    private let destinationService: ContainerEngineProviderHandoffControlService
    private let codeIdentity: ProviderHandoffCodeIdentityV1
    private var operationCounts = Counts()

    init(
        source: ProviderHandoffGatewayProviderEndpointV1,
        destination: ProviderHandoffGatewayProviderEndpointV1,
        sourceStore: ProviderHandoffBundleObjectStore,
        destinationStore: ProviderHandoffBundleObjectStore
    ) throws {
        self.source = source
        self.destination = destination
        sourceService = ContainerEngineProviderHandoffControlService(
            objectStore: sourceStore
        )
        destinationService = ContainerEngineProviderHandoffControlService(
            objectStore: destinationStore
        )
        codeIdentity = try ProviderHandoffCodeIdentity.current()
    }

    func counts() -> Counts {
        operationCounts
    }

    func perform(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ContainerEngineProviderHandoffControlResultV1 {
        if request.operation == .objectRead {
            operationCounts.read += 1
        }
        if request.operation == .partStage {
            operationCounts.stage += 1
            return try stage(request, body: body, endpoint: endpoint)
        }
        if request.operation == .partPromote {
            operationCounts.promote += 1
            return try promote(request, body: body, endpoint: endpoint)
        }
        if request.operation == .partActivate {
            operationCounts.activate += 1
            return try activate(request, body: body, endpoint: endpoint)
        }
        let context = ContainerEngineProviderHandoffControlContextV1(
            providerFingerprint: endpoint.fingerprint,
            authenticatedGatewayCodeIdentity: codeIdentity
        )
        if endpoint == source {
            return await sourceService.respond(
                to: request,
                body: body,
                context: context
            )
        }
        guard endpoint == destination else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return await destinationService.respond(
            to: request,
            body: body,
            context: context
        )
    }

    private func stage(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        guard endpoint == destination else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let value = try ProviderHandoffPartControlCodec
            .decodeStageRequest(body)
        let part = try #require(
            value.manifest.parts.first { $0.kind == value.partKind }
        )
        var record = try ProviderHandoffPartStagingStateMachine.declared(
            tokenID: value.manifest.tokenID,
            manifestID: value.manifest.manifestID,
            manifestDigest: value.manifest.manifestDigest,
            partKind: value.partKind,
            bundleObjectID: part.payload.bundleObjectID,
            payloadDescriptorDigestSHA256:
            ProviderHandoffProjections
                .payloadDescriptorDigest(part.payload)
        )
        try ProviderHandoffPartStagingStateMachine.beginRetrieval(
            &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordReceivedRanges(
            [
                ProviderHandoffByteRangeV1(
                    lowerBound: 0,
                    upperBoundExclusive: part.payload.transportByteLength
                )
            ],
            transportByteLength: part.payload.transportByteLength,
            in: &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordTransportVerified(
            transportDigestSHA256: part.payload.transportDigestSHA256,
            transportByteLength: part.payload.transportByteLength,
            in: &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordContentVerified(
            canonicalContentDigest: part.payload.canonicalContentDigest.digest,
            sourceDigestVerifications: [],
            protection: .authenticatedPlaintext,
            in: &record,
            expectedRevision: record.stagingRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordImported(
            receiptDigestSHA256:
            ProviderHandoffGatewayCoordinatorTests.digest(
                "receipt-\(value.partKind.rawValue)"
            ),
            in: &record,
            expectedRevision: record.stagingRevision
        )
        let responseBody = try ProviderHandoffPartControlCodec
            .encodeStageReceipt(
                ProviderHandoffPartStageReceiptV1(commonRecord: record)
            )
        return try ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                requestID: request.requestID,
                disposition: .completed,
                bodyMediaType:
                ProviderHandoffPartControlCodec.stageReceiptMediaType,
                body: responseBody
            ),
            body: responseBody
        )
    }

    private func promote(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        guard endpoint == destination else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let value = try ProviderHandoffPartControlCodec
            .decodePromoteRequest(body)
        let receipt = ProviderHandoffPartOpaqueControllerReceiptV1(
            partKind: value.stage.partKind,
            mediaType: "application/x.test-promotion",
            body: Data("promoted-\(value.stage.partKind.rawValue)".utf8)
        )
        let responseBody = try ProviderHandoffPartControlCodec
            .encodePromotionReceipt(receipt)
        return try ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                requestID: request.requestID,
                disposition: .completed,
                bodyMediaType:
                ProviderHandoffPartControlCodec.promotionReceiptMediaType,
                body: responseBody
            ),
            body: responseBody
        )
    }

    private func activate(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        guard endpoint == destination else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let value = try ProviderHandoffPartControlCodec
            .decodeActivateRequest(body)
        let receipt = ProviderHandoffPartOperationReceiptV1(
            operation: .activate,
            partKind: value.stage.partKind,
            tokenID: value.stage.manifest.tokenID,
            manifestID: value.stage.manifest.manifestID,
            evidenceDigestSHA256:
            value.terminalOutcome.outcomeDigestSHA256
        )
        let responseBody = try ProviderHandoffPartControlCodec
            .encodeOperationReceipt(receipt)
        return try ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                requestID: request.requestID,
                disposition: .completed,
                bodyMediaType:
                ProviderHandoffPartControlCodec.operationReceiptMediaType,
                body: responseBody
            ),
            body: responseBody
        )
    }
}
