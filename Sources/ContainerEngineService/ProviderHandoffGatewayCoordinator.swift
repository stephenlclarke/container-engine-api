//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import Foundation

public struct ProviderHandoffGatewayProviderEndpointV1:
    Equatable,
    Sendable
{
    public var socketPath: String
    public var fingerprint: ContainerEngineProviderFingerprint

    public init(
        socketPath: String,
        fingerprint: ContainerEngineProviderFingerprint
    ) {
        self.socketPath = socketPath
        self.fingerprint = fingerprint
    }
}

public struct ProviderHandoffGatewayPartSourceV1: Equatable, Sendable {
    public var partKind: ProviderHandoffPartKindV1
    public var endpoint: ProviderHandoffGatewayProviderEndpointV1

    public init(
        partKind: ProviderHandoffPartKindV1,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) {
        self.partKind = partKind
        self.endpoint = endpoint
    }
}

public struct ProviderHandoffGatewayStageResultV1: Equatable, Sendable {
    public var gatewayState: ProviderHandoffGatewayStateV1
    public var importedParts: [ProviderHandoffPartImportExpectationV1]

    public init(
        gatewayState: ProviderHandoffGatewayStateV1,
        importedParts: [ProviderHandoffPartImportExpectationV1]
    ) {
        self.gatewayState = gatewayState
        self.importedParts = importedParts
    }
}

public struct ProviderHandoffGatewayPromotionResultV1: Equatable, Sendable {
    public var gatewayState: ProviderHandoffGatewayStateV1
    public var receipts: [ProviderHandoffPartOpaqueControllerReceiptV1]

    public init(
        gatewayState: ProviderHandoffGatewayStateV1,
        receipts: [ProviderHandoffPartOpaqueControllerReceiptV1]
    ) {
        self.gatewayState = gatewayState
        self.receipts = receipts
    }
}

public struct ProviderHandoffGatewayTerminalResultV1: Equatable, Sendable {
    public var gatewayState: ProviderHandoffGatewayStateV1
    public var receipts: [ProviderHandoffPartOperationReceiptV1]

    public init(
        gatewayState: ProviderHandoffGatewayStateV1,
        receipts: [ProviderHandoffPartOperationReceiptV1]
    ) {
        self.gatewayState = gatewayState
        self.receipts = receipts
    }
}

public enum ProviderHandoffGatewayCoordinatorError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case activeTransactionMismatch
    case duplicatePartSource(ProviderHandoffPartKindV1)
    case incompleteObject(String)
    case invalidObject(String)
    case invalidPartReceipt(ProviderHandoffPartKindV1)
    case invalidProviderResponse(ContainerEngineProviderHandoffOperationV1)
    case invalidTransactionPhase(ProviderHandoffPhaseV1)
    case missingManifest
    case missingPartSource(ProviderHandoffPartKindV1)
    case missingPromotionReceipts
    case providerFailure(
        ContainerEngineProviderHandoffOperationV1,
        ContainerEngineProviderHandoffDispositionV1,
        String?
    )

    public var description: String {
        switch self {
        case .activeTransactionMismatch:
            return "provider handoff gateway active transaction changed"
        case let .duplicatePartSource(partKind):
            return "provider handoff part \(partKind.rawValue) has more than one source route"
        case let .incompleteObject(objectID):
            return "provider handoff object \(objectID) ended before its declared length"
        case let .invalidObject(objectID):
            return "provider handoff object \(objectID) failed identity verification"
        case let .invalidPartReceipt(partKind):
            return "provider handoff part \(partKind.rawValue) returned an invalid receipt"
        case let .invalidProviderResponse(operation):
            return "provider handoff operation \(operation.rawValue) returned an invalid response"
        case let .invalidTransactionPhase(phase):
            return "provider handoff gateway transaction is in phase \(phase.rawValue)"
        case .missingManifest:
            return "provider handoff gateway transaction has no manifest"
        case let .missingPartSource(partKind):
            return "provider handoff part \(partKind.rawValue) has no source route"
        case .missingPromotionReceipts:
            return "provider handoff controller promotions are not durably recorded"
        case let .providerFailure(operation, disposition, message):
            let suffix = message.map { ": \($0)" } ?? ""
            return
                "provider handoff operation \(operation.rawValue) failed as \(disposition.rawValue)\(suffix)"
        }
    }
}

public protocol ProviderHandoffGatewayControlTransport: Sendable {
    func perform(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ContainerEngineProviderHandoffControlResultV1
}

public struct ContainerEngineProviderSessionHandoffTransport:
    ProviderHandoffGatewayControlTransport,
    Sendable
{
    public init() {}

    public func perform(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ContainerEngineProviderHandoffControlResultV1 {
        try await ContainerEngineProviderSessionClient(
            socketPath: endpoint.socketPath,
            expectedFingerprint: endpoint.fingerprint
        ).performHandoffControl(request, body: body)
    }
}

/// Serial, crash-replayable orchestration for provider handoff controller
/// parts. The coordinator owns the gateway authority store, streams immutable
/// bundle objects between authenticated provider sessions, freezes the exact
/// redacted import receipts in the token, and persists opaque promotion
/// receipts before Complete can make controller state visible.
public actor ProviderHandoffGatewayCoordinator {
    private let store: ProviderHandoffGatewayStore
    private let bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    private let transport: any ProviderHandoffGatewayControlTransport

    public init(
        store: ProviderHandoffGatewayStore,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        transport: any ProviderHandoffGatewayControlTransport =
            ContainerEngineProviderSessionHandoffTransport()
    ) {
        self.store = store
        self.bootstrap = bootstrap
        self.transport = transport
    }

    public func currentState() throws -> ProviderHandoffGatewayStateV1 {
        try store.load()
    }

    @discardableResult
    public func begin(
        _ token: ProviderHandoffTokenV1
    ) throws -> ProviderHandoffGatewayStateV1 {
        let state = try store.load()
        if let existing = transaction(token.tokenID, in: state) {
            guard existing.token == token else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            return state
        }
        return try store.update(expectedStoreRevision: state.storeRevision) {
            try ProviderHandoffGatewayStateMachine.begin(
                token,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
    }

    @discardableResult
    public func quiesce(
        tokenID: String,
        expectations: [ProviderHandoffHeaderExpectationV1]
    ) throws -> ProviderHandoffGatewayStateV1 {
        let state = try store.load()
        let current = try requireTransaction(tokenID, in: state)
        if current.token.phase == .quiesced {
            guard current.token.preCommitRootExpectations == expectations else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            return state
        }
        guard current.token.phase == .draining else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(current.token.phase)
        }
        return try store.update(expectedStoreRevision: state.storeRevision) {
            try ProviderHandoffGatewayStateMachine.quiesce(
                tokenID: tokenID,
                expectedTokenRevision: current.token.tokenRevision,
                expectations: expectations,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
    }

    /// Requests a source controller to produce one immutable,
    /// destination-sealed part contribution. Replays use the same stable
    /// request ID, and the source must return the exact durable contribution.
    public func exportPart(
        _ request: ProviderHandoffPartExportRequestV1,
        source: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ProviderHandoffSourceContributionV1 {
        guard
            source.fingerprint.digest == request.sourceProviderFingerprint
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let body = try ProviderHandoffSourceControlCodec
            .encodeExportRequest(request)
        let result = try await perform(
            operation: .partExport,
            mediaType:
            ProviderHandoffSourceControlCodec.exportRequestMediaType,
            responseMediaType:
            ProviderHandoffSourceControlCodec.contributionMediaType,
            body: body,
            endpoint: source,
            identity:
            "\(request.tokenID):\(request.manifestID):\(request.partKind.rawValue)"
        )
        let contribution = try ProviderHandoffSourceControlCodec
            .decodeContribution(result.body)
        let proofDigests = try request.destinationKeyPossessionProofs.map {
            try ProviderHandoffProjections
                .destinationPossessionProofRecordDigest($0)
        }.sorted()
        let exportRequestDigest = try ProviderHandoffSourceControlCodec
            .exportRequestDigest(request)
        guard
            contribution.partKind == request.partKind,
            contribution.tokenID == request.tokenID,
            contribution.manifestID == request.manifestID,
            contribution.trustRegistryRevision
            == request.trustRegistryRevision,
            contribution.exportRequestDigestSHA256
            == exportRequestDigest,
            contribution.sourceProviderFingerprint
            == request.sourceProviderFingerprint,
            contribution.sourceStateRootUUID
            == request.sourceStateRootUUID,
            contribution.authorityLineageUUID
            == request.authorityLineageUUID,
            contribution.lineageDigestKeyVersion
            == request.lineageDigestKeyVersion,
            contribution.sourcePreCommitExpectation
            == request.sourcePreCommitExpectation,
            contribution.destinationProviderFingerprint
            == request.destinationProviderFingerprint,
            contribution.destinationStateRootUUID
            == request.destinationStateRootUUID,
            contribution.destinationPreCommitExpectation
            == request.destinationPreCommitExpectation,
            contribution.destinationKeyPossessionProofDigestsSHA256
            == proofDigests,
            contribution.resultingAuthorityLineageUUID
            == request.resultingAuthorityLineageUUID,
            contribution.resultingLineageDigestKeyVersion
            == request.resultingLineageDigestKeyVersion,
            contribution.destinationSealedLineageKeyEnvelope
            .destinationKeyID
            == request.destinationLineageKeyEncryptionKey.keyID,
            contribution.destinationSealedLineageKeyEnvelope
            .sourceStateRootUUID == request.sourceStateRootUUID
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidPartReceipt(request.partKind)
        }
        return contribution
    }

    /// Obtains the source provider's signature only after the gateway has
    /// assembled the complete candidate manifest. The source independently
    /// binds the request to its durable export contribution before signing.
    public func signSourceManifest(
        _ request: ProviderHandoffSourceManifestSignRequestV1,
        source: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ProviderHandoffSourceManifestSignReceiptV1 {
        let body = try ProviderHandoffSourceControlCodec
            .encodeSignRequest(request)
        let manifest = request.candidateManifest
        let result = try await perform(
            operation: .sourceSignManifest,
            mediaType: ProviderHandoffSourceControlCodec.signRequestMediaType,
            responseMediaType:
            ProviderHandoffSourceControlCodec.signReceiptMediaType,
            body: body,
            endpoint: source,
            identity:
            "\(manifest.tokenID):\(manifest.manifestID):\(request.partKind.rawValue):\(request.contributionDigestSHA256)"
        )
        let receipt = try ProviderHandoffSourceControlCodec
            .decodeSignReceipt(result.body)
        guard
            let manifestSource = manifest.sources.first(where: {
                $0.stateRootUUID == receipt.sourceStateRootUUID
                    && $0.providerFingerprint == source.fingerprint.digest
            })
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidPartReceipt(request.partKind)
        }
        let expectedProjectionDigest = try ProviderHandoffProjections
            .sourceManifestDigest(
                source: manifestSource,
                manifest: manifest
            )
        guard
            receipt.partKind == request.partKind,
            receipt.tokenID == manifest.tokenID,
            receipt.manifestID == manifest.manifestID,
            receipt.contributionDigestSHA256
            == request.contributionDigestSHA256,
            receipt.sourceSignature.providerFingerprint
            == source.fingerprint.digest,
            receipt.sourceSignature.trustRegistryRevision
            == manifest.trustRegistryRevision,
            receipt.sourceProjectionDigestSHA256
            == expectedProjectionDigest
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidPartReceipt(request.partKind)
        }
        return receipt
    }

    /// Copies every unique manifest object in bounded chunks, stages every
    /// closed-inventory controller part, and atomically freezes the exact
    /// manifest-order import expectations in the gateway token.
    public func stage(
        _ validatedManifest: ProviderHandoffValidatedManifestV1,
        sources: [ProviderHandoffGatewayPartSourceV1],
        destination: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ProviderHandoffGatewayStageResultV1 {
        let manifest = validatedManifest.manifest
        var state = try store.load()
        var current = try requireTransaction(manifest.tokenID, in: state)
        guard state.activeTokenID == manifest.tokenID else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        if let existing = current.manifest {
            guard existing == manifest else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
        } else {
            guard current.token.phase == .quiesced else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidTransactionPhase(current.token.phase)
            }
            state = try store.update(
                expectedStoreRevision: state.storeRevision
            ) {
                try ProviderHandoffGatewayStateMachine.bindManifest(
                    validatedManifest,
                    tokenID: manifest.tokenID,
                    expectedTokenRevision: current.token.tokenRevision,
                    in: &$0,
                    expectedStoreRevision: state.storeRevision
                )
            }
            current = try requireTransaction(manifest.tokenID, in: state)
        }

        if current.token.phase == .staged,
           let imported = current.token.importedParts
        {
            return ProviderHandoffGatewayStageResultV1(
                gatewayState: state,
                importedParts: imported
            )
        }
        guard current.token.phase == .quiesced else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(current.token.phase)
        }

        let sourceByPart = try sourceRoutes(sources)
        var transferred: [String: ProviderHandoffGatewayProviderEndpointV1] = [:]
        for part in manifest.parts {
            guard
                part.disposition != .unsupported,
                part.disposition != .explicitResolutionRequired
            else {
                throw ProviderHandoffGatewayStateError
                    .unresolvedPart(part.kind)
            }
            guard let source = sourceByPart[part.kind] else {
                throw ProviderHandoffGatewayCoordinatorError
                    .missingPartSource(part.kind)
            }
            if let existing = transferred[part.payload.bundleObjectID] {
                guard existing == source else {
                    throw ProviderHandoffGatewayCoordinatorError
                        .invalidObject(part.payload.bundleObjectID)
                }
            } else {
                try await transfer(
                    part.payload,
                    from: source,
                    to: destination
                )
                transferred[part.payload.bundleObjectID] = source
            }
        }

        var imported: [ProviderHandoffPartImportExpectationV1] = []
        imported.reserveCapacity(manifest.parts.count)
        for part in manifest.parts {
            let stage = ProviderHandoffPartStageRequestV1(
                partKind: part.kind,
                bootstrap: bootstrap,
                manifest: manifest
            )
            let body = try ProviderHandoffPartControlCodec
                .encodeStageRequest(stage)
            let result = try await perform(
                operation: .partStage,
                mediaType:
                ProviderHandoffPartControlCodec.stageRequestMediaType,
                responseMediaType:
                ProviderHandoffPartControlCodec.stageReceiptMediaType,
                body: body,
                endpoint: destination,
                identity: "\(manifest.tokenID):\(part.kind.rawValue):stage"
            )
            let receipt = try ProviderHandoffPartControlCodec
                .decodeStageReceipt(result.body)
            let common = receipt.commonRecord
            let descriptorDigest = try ProviderHandoffProjections
                .payloadDescriptorDigest(part.payload)
            guard
                common.tokenID == manifest.tokenID,
                common.manifestID == manifest.manifestID,
                common.manifestDigest == manifest.manifestDigest,
                common.partKind == part.kind,
                common.bundleObjectID == part.payload.bundleObjectID,
                common.payloadDescriptorDigestSHA256 == descriptorDigest,
                common.state == .imported,
                let privateReceiptDigest =
                common.stagedImportReceiptDigestSHA256
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidPartReceipt(part.kind)
            }
            imported.append(
                ProviderHandoffPartImportExpectationV1(
                    partKind: part.kind,
                    payloadDescriptorDigestSHA256: descriptorDigest,
                    stagedImportReceiptDigestSHA256: privateReceiptDigest
                )
            )
        }

        state = try store.load()
        current = try requireTransaction(manifest.tokenID, in: state)
        if current.token.phase == .staged,
           current.token.importedParts == imported
        {
            return ProviderHandoffGatewayStageResultV1(
                gatewayState: state,
                importedParts: imported
            )
        }
        guard current.token.phase == .quiesced else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(current.token.phase)
        }
        let staged = try store.update(
            expectedStoreRevision: state.storeRevision
        ) {
            try ProviderHandoffGatewayStateMachine.stage(
                tokenID: manifest.tokenID,
                expectedTokenRevision: current.token.tokenRevision,
                importedParts: imported,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
        return ProviderHandoffGatewayStageResultV1(
            gatewayState: staged,
            importedParts: imported
        )
    }

    @discardableResult
    public func recordPreparedRoot(
        _ record: ProviderHandoffRootPrepareRecordV1
    ) throws -> ProviderHandoffGatewayStateV1 {
        let state = try store.load()
        let current = try requireTransaction(record.tokenID, in: state)
        let digest = try ProviderHandoffProjections.rootPrepareDigest(record)
        if current.token.rootPrepareRecordDigestsSHA256?.contains(digest) == true {
            return state
        }
        return try store.update(expectedStoreRevision: state.storeRevision) {
            try ProviderHandoffGatewayStateMachine.recordPreparedRoot(
                record,
                tokenID: record.tokenID,
                expectedTokenRevision: current.token.tokenRevision,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
    }

    @discardableResult
    public func commit(
        _ validatedRecord: ProviderHandoffValidatedCommitRecordV1
    ) throws -> ProviderHandoffGatewayStateV1 {
        let tokenID = validatedRecord.record.intent.tokenID
        let state = try store.load()
        let current = try requireTransaction(tokenID, in: state)
        if current.token.phase == .committed,
           current.commitRecord == validatedRecord.record
        {
            return state
        }
        guard current.token.phase == .staged else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(current.token.phase)
        }
        return try store.update(expectedStoreRevision: state.storeRevision) {
            try ProviderHandoffGatewayStateMachine.commit(
                validatedRecord,
                tokenID: tokenID,
                expectedTokenRevision: current.token.tokenRevision,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
    }

    @discardableResult
    public func beginReconciliation(
        tokenID: String
    ) throws -> ProviderHandoffGatewayStateV1 {
        let state = try store.load()
        let current = try requireTransaction(tokenID, in: state)
        if current.token.phase == .reconciling {
            return state
        }
        guard current.token.phase == .committed else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(current.token.phase)
        }
        return try store.update(expectedStoreRevision: state.storeRevision) {
            try ProviderHandoffGatewayStateMachine.beginReconciliation(
                tokenID: tokenID,
                expectedTokenRevision: current.token.tokenRevision,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
    }

    /// Reconciles every imported controller and durably freezes its opaque
    /// receipt before a terminal Complete outcome can be installed.
    public func promote(
        tokenID: String,
        destination: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ProviderHandoffGatewayPromotionResultV1 {
        var state = try store.load()
        var current = try requireTransaction(tokenID, in: state)
        guard current.token.phase == .reconciling else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(current.token.phase)
        }
        if let receipts = current.promotedPartReceipts {
            return ProviderHandoffGatewayPromotionResultV1(
                gatewayState: state,
                receipts: receipts
            )
        }
        guard
            let manifest = current.manifest,
            let commitRecord = current.commitRecord,
            let imported = current.token.importedParts
        else {
            throw ProviderHandoffGatewayCoordinatorError.missingManifest
        }

        var receipts: [ProviderHandoffPartOpaqueControllerReceiptV1] = []
        receipts.reserveCapacity(imported.count)
        for expectation in imported {
            let stage = ProviderHandoffPartStageRequestV1(
                partKind: expectation.partKind,
                bootstrap: bootstrap,
                manifest: manifest
            )
            let body = try ProviderHandoffPartControlCodec
                .encodePromoteRequest(
                    ProviderHandoffPartPromoteRequestV1(
                        stage: stage,
                        commitRecord: commitRecord,
                        gatewayState: state
                    )
                )
            let result = try await perform(
                operation: .partPromote,
                mediaType:
                ProviderHandoffPartControlCodec.promoteRequestMediaType,
                responseMediaType:
                ProviderHandoffPartControlCodec.promotionReceiptMediaType,
                body: body,
                endpoint: destination,
                identity: "\(tokenID):\(expectation.partKind.rawValue):promote"
            )
            let receipt = try ProviderHandoffPartControlCodec
                .decodePromotionReceipt(result.body)
            guard receipt.partKind == expectation.partKind else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidPartReceipt(expectation.partKind)
            }
            receipts.append(receipt)
        }

        state = try store.load()
        current = try requireTransaction(tokenID, in: state)
        if let existing = current.promotedPartReceipts {
            guard existing == receipts else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            return ProviderHandoffGatewayPromotionResultV1(
                gatewayState: state,
                receipts: existing
            )
        }
        let recorded = try store.update(
            expectedStoreRevision: state.storeRevision
        ) {
            try ProviderHandoffGatewayStateMachine.recordPromotedParts(
                receipts,
                tokenID: tokenID,
                expectedTokenRevision: current.token.tokenRevision,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
        return ProviderHandoffGatewayPromotionResultV1(
            gatewayState: recorded,
            receipts: receipts
        )
    }

    /// Installs the signed Complete outcome first, then activates every exact
    /// promoted receipt. Replaying this method after a crash is safe: Complete
    /// is immutable and controller activation is receipt-bound and idempotent.
    public func completeAndActivate(
        _ validatedOutcome: ProviderHandoffValidatedTerminalOutcomeV1,
        destination: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ProviderHandoffGatewayTerminalResultV1 {
        let outcome = validatedOutcome.outcome
        var state = try store.load()
        var current = try requireTransaction(outcome.tokenID, in: state)
        guard let promotionReceipts = current.promotedPartReceipts else {
            throw ProviderHandoffGatewayCoordinatorError
                .missingPromotionReceipts
        }
        if current.token.phase == .reconciling {
            state = try store.update(
                expectedStoreRevision: state.storeRevision
            ) {
                try ProviderHandoffGatewayStateMachine.complete(
                    validatedOutcome,
                    tokenID: outcome.tokenID,
                    expectedTokenRevision: current.token.tokenRevision,
                    in: &$0,
                    expectedStoreRevision: state.storeRevision
                )
            }
            current = try requireTransaction(outcome.tokenID, in: state)
        } else {
            guard
                current.token.phase == .complete,
                current.terminalOutcome == outcome
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidTransactionPhase(current.token.phase)
            }
        }
        guard
            let manifest = current.manifest,
            let commitRecord = current.commitRecord,
            promotionReceipts.count == manifest.parts.count
        else {
            throw ProviderHandoffGatewayCoordinatorError.missingManifest
        }

        var receipts: [ProviderHandoffPartOperationReceiptV1] = []
        receipts.reserveCapacity(promotionReceipts.count)
        for promotion in promotionReceipts {
            let stage = ProviderHandoffPartStageRequestV1(
                partKind: promotion.partKind,
                bootstrap: bootstrap,
                manifest: manifest
            )
            let body = try ProviderHandoffPartControlCodec
                .encodeActivateRequest(
                    ProviderHandoffPartActivateRequestV1(
                        stage: stage,
                        commitRecord: commitRecord,
                        terminalOutcome: outcome,
                        gatewayState: state,
                        promotionReceipt: promotion
                    )
                )
            let result = try await perform(
                operation: .partActivate,
                mediaType:
                ProviderHandoffPartControlCodec.activateRequestMediaType,
                responseMediaType:
                ProviderHandoffPartControlCodec.operationReceiptMediaType,
                body: body,
                endpoint: destination,
                identity:
                "\(outcome.tokenID):\(promotion.partKind.rawValue):activate"
            )
            let receipt = try ProviderHandoffPartControlCodec
                .decodeOperationReceipt(result.body)
            guard
                receipt.operation == .activate,
                receipt.partKind == promotion.partKind,
                receipt.tokenID == outcome.tokenID,
                receipt.manifestID == outcome.manifestID,
                receipt.evidenceDigestSHA256 == outcome.outcomeDigestSHA256
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidPartReceipt(promotion.partKind)
            }
            receipts.append(receipt)
        }
        return ProviderHandoffGatewayTerminalResultV1(
            gatewayState: state,
            receipts: receipts
        )
    }

    public func abortAndCompensate(
        _ validatedOutcome: ProviderHandoffValidatedTerminalOutcomeV1,
        destination: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ProviderHandoffGatewayTerminalResultV1 {
        let outcome = validatedOutcome.outcome
        var state = try store.load()
        var current = try requireTransaction(outcome.tokenID, in: state)
        if [.draining, .quiesced, .staged].contains(current.token.phase) {
            state = try store.update(
                expectedStoreRevision: state.storeRevision
            ) {
                try ProviderHandoffGatewayStateMachine.beginAbort(
                    tokenID: outcome.tokenID,
                    expectedTokenRevision: current.token.tokenRevision,
                    in: &$0,
                    expectedStoreRevision: state.storeRevision
                )
            }
            current = try requireTransaction(outcome.tokenID, in: state)
        }
        if current.token.phase == .aborting {
            state = try store.update(
                expectedStoreRevision: state.storeRevision
            ) {
                try ProviderHandoffGatewayStateMachine.finishAbort(
                    validatedOutcome,
                    tokenID: outcome.tokenID,
                    expectedTokenRevision: current.token.tokenRevision,
                    in: &$0,
                    expectedStoreRevision: state.storeRevision
                )
            }
            current = try requireTransaction(outcome.tokenID, in: state)
        }
        guard
            current.token.phase == .aborted,
            current.terminalOutcome == outcome
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(current.token.phase)
        }
        guard let manifest = current.manifest else {
            return ProviderHandoffGatewayTerminalResultV1(
                gatewayState: state,
                receipts: []
            )
        }

        var receipts: [ProviderHandoffPartOperationReceiptV1] = []
        for part in manifest.parts {
            let stage = ProviderHandoffPartStageRequestV1(
                partKind: part.kind,
                bootstrap: bootstrap,
                manifest: manifest
            )
            let body = try ProviderHandoffPartControlCodec
                .encodeCompensateRequest(
                    ProviderHandoffPartCompensateRequestV1(
                        stage: stage,
                        terminalOutcome: outcome,
                        gatewayState: state
                    )
                )
            let result = try await perform(
                operation: .partCompensate,
                mediaType:
                ProviderHandoffPartControlCodec.compensateRequestMediaType,
                responseMediaType:
                ProviderHandoffPartControlCodec.operationReceiptMediaType,
                body: body,
                endpoint: destination,
                identity:
                "\(outcome.tokenID):\(part.kind.rawValue):compensate"
            )
            let receipt = try ProviderHandoffPartControlCodec
                .decodeOperationReceipt(result.body)
            guard
                receipt.operation == .compensate,
                receipt.partKind == part.kind,
                receipt.tokenID == outcome.tokenID,
                receipt.manifestID == outcome.manifestID,
                receipt.evidenceDigestSHA256 == outcome.outcomeDigestSHA256
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidPartReceipt(part.kind)
            }
            receipts.append(receipt)
        }
        return ProviderHandoffGatewayTerminalResultV1(
            gatewayState: state,
            receipts: receipts
        )
    }

    private func transfer(
        _ descriptor: ProviderHandoffPayloadDescriptorV1,
        from source: ProviderHandoffGatewayProviderEndpointV1,
        to destination: ProviderHandoffGatewayProviderEndpointV1
    ) async throws {
        let declaration = ProviderHandoffBundleObjectDeclareRequestV1(
            bundleObjectID: descriptor.bundleObjectID,
            transportByteLength: descriptor.transportByteLength,
            transportDigestSHA256: descriptor.transportDigestSHA256
        )
        let declarationBody = try ProviderHandoffBundleObjectControlCodec
            .encodeDeclare(declaration)
        let sourceResult = try await perform(
            operation: .objectDeclare,
            mediaType: ProviderHandoffBundleObjectControlCodec.requestMediaType,
            responseMediaType:
            ProviderHandoffBundleObjectControlCodec.recordMediaType,
            body: declarationBody,
            endpoint: source,
            identity: "\(descriptor.bundleObjectID):source-declare"
        )
        let sourceRecord = try ProviderHandoffBundleObjectControlCodec
            .decodeRecord(sourceResult.body)
        try validate(
            sourceRecord,
            descriptor: descriptor,
            requiresVerified: true
        )
        if source == destination {
            return
        }

        let destinationResult = try await perform(
            operation: .objectDeclare,
            mediaType: ProviderHandoffBundleObjectControlCodec.requestMediaType,
            responseMediaType:
            ProviderHandoffBundleObjectControlCodec.recordMediaType,
            body: declarationBody,
            endpoint: destination,
            identity: "\(descriptor.bundleObjectID):destination-declare"
        )
        var destinationRecord = try ProviderHandoffBundleObjectControlCodec
            .decodeRecord(destinationResult.body)
        try validate(
            destinationRecord,
            descriptor: descriptor,
            requiresVerified: false
        )
        if destinationRecord.state == .verified {
            return
        }

        while destinationRecord.receivedByteCount < descriptor.transportByteLength {
            let remaining = descriptor.transportByteLength
                - destinationRecord.receivedByteCount
            let maximum = UInt32(
                min(
                    UInt64(
                        ProviderHandoffBundleObjectControlCodec
                            .maximumTransportChunkBytes
                    ),
                    remaining
                )
            )
            let readBody = try ProviderHandoffBundleObjectControlCodec
                .encodeRead(
                    ProviderHandoffBundleObjectReadRequestV1(
                        bundleObjectID: descriptor.bundleObjectID,
                        offset: destinationRecord.receivedByteCount,
                        maximumBytes: maximum
                    )
                )
            let readResult = try await perform(
                operation: .objectRead,
                mediaType:
                ProviderHandoffBundleObjectControlCodec.requestMediaType,
                responseMediaType:
                ProviderHandoffBundleObjectControlCodec.chunkMediaType,
                body: readBody,
                endpoint: source,
                identity:
                "\(descriptor.bundleObjectID):read:\(destinationRecord.receivedByteCount)"
            )
            let chunk = try ProviderHandoffBundleObjectControlCodec
                .decodeChunk(readResult.body)
            guard
                chunk.bundleObjectID == descriptor.bundleObjectID,
                chunk.offset == destinationRecord.receivedByteCount,
                !chunk.bytes.isEmpty,
                chunk.bytes.count <= Int(maximum)
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .incompleteObject(descriptor.bundleObjectID)
            }
            let appendBody = try ProviderHandoffBundleObjectControlCodec
                .encodeAppend(
                    ProviderHandoffBundleObjectAppendRequestV1(
                        bundleObjectID: descriptor.bundleObjectID,
                        offset: destinationRecord.receivedByteCount,
                        expectedObjectRevision:
                        destinationRecord.objectRevision,
                        bytes: chunk.bytes
                    )
                )
            let appendResult = try await perform(
                operation: .objectAppend,
                mediaType:
                ProviderHandoffBundleObjectControlCodec.requestMediaType,
                responseMediaType:
                ProviderHandoffBundleObjectControlCodec.recordMediaType,
                body: appendBody,
                endpoint: destination,
                identity:
                "\(descriptor.bundleObjectID):append:\(chunk.offset)"
            )
            destinationRecord = try ProviderHandoffBundleObjectControlCodec
                .decodeRecord(appendResult.body)
            try validate(
                destinationRecord,
                descriptor: descriptor,
                requiresVerified: false
            )
        }

        let verifyBody = try ProviderHandoffBundleObjectControlCodec
            .encodeReference(
                ProviderHandoffBundleObjectReferenceRequestV1(
                    bundleObjectID: descriptor.bundleObjectID,
                    expectedObjectRevision: destinationRecord.objectRevision
                )
            )
        let verifyResult = try await perform(
            operation: .objectVerify,
            mediaType: ProviderHandoffBundleObjectControlCodec.requestMediaType,
            responseMediaType:
            ProviderHandoffBundleObjectControlCodec.recordMediaType,
            body: verifyBody,
            endpoint: destination,
            identity: "\(descriptor.bundleObjectID):verify"
        )
        let verified = try ProviderHandoffBundleObjectControlCodec
            .decodeRecord(verifyResult.body)
        try validate(
            verified,
            descriptor: descriptor,
            requiresVerified: true
        )
    }

    private func perform(
        operation: ContainerEngineProviderHandoffOperationV1,
        mediaType: String,
        responseMediaType: String,
        body: Data,
        endpoint: ProviderHandoffGatewayProviderEndpointV1,
        identity: String
    ) async throws -> ContainerEngineProviderHandoffControlResultV1 {
        let requestID = Self.requestID(operation: operation, identity: identity)
        let request = try ContainerEngineProviderHandoffControlRequestV1(
            requestID: requestID,
            operation: operation,
            bodyMediaType: mediaType,
            body: body
        )
        let result = try await transport.perform(
            request,
            body: body,
            endpoint: endpoint
        )
        guard result.response.requestID == requestID else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidProviderResponse(operation)
        }
        guard result.response.disposition == .completed else {
            throw ProviderHandoffGatewayCoordinatorError.providerFailure(
                operation,
                result.response.disposition,
                result.response.message
            )
        }
        guard result.response.bodyMediaType == responseMediaType else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidProviderResponse(operation)
        }
        return result
    }

    private func validate(
        _ record: ProviderHandoffBundleObjectRecordV1,
        descriptor: ProviderHandoffPayloadDescriptorV1,
        requiresVerified: Bool
    ) throws {
        guard
            record.bundleObjectID == descriptor.bundleObjectID,
            record.transportByteLength == descriptor.transportByteLength,
            record.transportDigestSHA256
            == descriptor.transportDigestSHA256,
            record.receivedByteCount <= descriptor.transportByteLength,
            !requiresVerified
            || (record.state == .verified
                && record.receivedByteCount
                == descriptor.transportByteLength)
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidObject(descriptor.bundleObjectID)
        }
    }

    private func sourceRoutes(
        _ sources: [ProviderHandoffGatewayPartSourceV1]
    ) throws -> [
        ProviderHandoffPartKindV1: ProviderHandoffGatewayProviderEndpointV1
    ] {
        var result: [
            ProviderHandoffPartKindV1:
                ProviderHandoffGatewayProviderEndpointV1
        ] = [:]
        for source in sources {
            guard result.updateValue(source.endpoint, forKey: source.partKind) == nil else {
                throw ProviderHandoffGatewayCoordinatorError
                    .duplicatePartSource(source.partKind)
            }
        }
        return result
    }

    private func requireTransaction(
        _ tokenID: String,
        in state: ProviderHandoffGatewayStateV1
    ) throws -> ProviderHandoffGatewayTransactionV1 {
        guard
            let value = transaction(tokenID, in: state),
            state.activeTokenID == tokenID
            || [.complete, .aborted].contains(value.token.phase)
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return value
    }

    private func transaction(
        _ tokenID: String,
        in state: ProviderHandoffGatewayStateV1
    ) -> ProviderHandoffGatewayTransactionV1? {
        state.transactions.first { $0.token.tokenID == tokenID }
    }

    private static func requestID(
        operation: ContainerEngineProviderHandoffOperationV1,
        identity: String
    ) -> String {
        let digest = ProviderHandoffDigest.sha256(
            Data("\(operation.rawValue)\u{0}\(identity)".utf8)
        )
        return "handoff-\(operation.rawValue)-\(digest.prefix(32))"
    }
}
