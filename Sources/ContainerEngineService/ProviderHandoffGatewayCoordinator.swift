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

public struct ProviderHandoffGatewayDestinationPossessionV1:
    Equatable,
    Sendable
{
    public var payloadEncryptionKey: ProviderHandoffTrustKeyV1
    public var lineageEncryptionKey: ProviderHandoffTrustKeyV1
    public var proofs: [ProviderHandoffDestinationKeyPossessionProofV1]

    public init(
        payloadEncryptionKey: ProviderHandoffTrustKeyV1,
        lineageEncryptionKey: ProviderHandoffTrustKeyV1,
        proofs: [ProviderHandoffDestinationKeyPossessionProofV1]
    ) {
        self.payloadEncryptionKey = payloadEncryptionKey
        self.lineageEncryptionKey = lineageEncryptionKey
        self.proofs = proofs
    }
}

public struct ProviderHandoffGatewayManifestAssemblyResultV1:
    Equatable,
    Sendable
{
    public var validatedManifest: ProviderHandoffValidatedManifestV1
    public var gatewayState: ProviderHandoffGatewayStateV1

    public init(
        validatedManifest: ProviderHandoffValidatedManifestV1,
        gatewayState: ProviderHandoffGatewayStateV1
    ) {
        self.validatedManifest = validatedManifest
        self.gatewayState = gatewayState
    }

    public static func == (
        lhs: ProviderHandoffGatewayManifestAssemblyResultV1,
        rhs: ProviderHandoffGatewayManifestAssemblyResultV1
    ) -> Bool {
        lhs.validatedManifest.manifest == rhs.validatedManifest.manifest
            && lhs.gatewayState == rhs.gatewayState
    }
}

public enum ProviderHandoffGatewayCoordinatorError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case activeTransactionMismatch
    case duplicateContribution(ProviderHandoffPartKindV1, String)
    case duplicatePartSource(ProviderHandoffPartKindV1)
    case incompleteObject(String)
    case invalidObject(String)
    case invalidPartReceipt(ProviderHandoffPartKindV1)
    case invalidProviderResponse(ContainerEngineProviderHandoffOperationV1)
    case invalidTransactionPhase(ProviderHandoffPhaseV1)
    case missingManifest
    case missingManifestAuthority
    case missingPartSource(ProviderHandoffPartKindV1)
    case missingSourceEndpoint(String)
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
        case let .duplicateContribution(partKind, stateRootUUID):
            return "provider handoff part \(partKind.rawValue) has more than one contribution for source root \(stateRootUUID)"
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
        case .missingManifestAuthority:
            return "provider handoff gateway manifest authority is unavailable"
        case let .missingPartSource(partKind):
            return "provider handoff part \(partKind.rawValue) has no source route"
        case let .missingSourceEndpoint(stateRootUUID):
            return "provider handoff source root \(stateRootUUID) has no authenticated provider endpoint"
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

public struct ProviderHandoffGatewayManifestAuthorityV1: Sendable {
    public let gatewayIdentity: ProviderHandoffGatewayIdentityV1
    public let trustRegistryStore: ProviderHandoffTrustRegistryStore
    public let possessionProofStore: ProviderHandoffPossessionProofStore
    public let transactionSecretStore:
        ProviderHandoffGatewayTransactionSecretStore
    public let nowUnixSeconds: @Sendable () throws -> UInt64

    public init(
        gatewayIdentity: ProviderHandoffGatewayIdentityV1,
        trustRegistryStore: ProviderHandoffTrustRegistryStore,
        possessionProofStore: ProviderHandoffPossessionProofStore,
        transactionSecretStore:
        ProviderHandoffGatewayTransactionSecretStore = .init(),
        nowUnixSeconds: @escaping @Sendable () throws -> UInt64 = {
            let value = Date().timeIntervalSince1970
            guard value.isFinite, value >= 0, value < Double(UInt64.max) else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            return UInt64(value.rounded(.down))
        }
    ) {
        self.gatewayIdentity = gatewayIdentity
        self.trustRegistryStore = trustRegistryStore
        self.possessionProofStore = possessionProofStore
        self.transactionSecretStore = transactionSecretStore
        self.nowUnixSeconds = nowUnixSeconds
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
    private let manifestAuthority: ProviderHandoffGatewayManifestAuthorityV1?
    private let transport: any ProviderHandoffGatewayControlTransport

    public init(
        store: ProviderHandoffGatewayStore,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        manifestAuthority: ProviderHandoffGatewayManifestAuthorityV1? = nil,
        transport: any ProviderHandoffGatewayControlTransport =
            ContainerEngineProviderSessionHandoffTransport()
    ) {
        self.store = store
        self.bootstrap = bootstrap
        self.manifestAuthority = manifestAuthority
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

    /// Proves possession of the exact destination payload and lineage X25519
    /// keys archived by the token's trust-registry revision. Every challenge
    /// byte is derived from the durable gateway transaction seed, so a crash or
    /// lost response replays the same request and can adopt only the exact
    /// signed destination receipt.
    public func proveDestinationKeyPossession(
        tokenID: String,
        destination: ProviderHandoffGatewayProviderEndpointV1
    ) async throws -> ProviderHandoffGatewayDestinationPossessionV1 {
        let state = try store.load()
        let transaction = try requireTransaction(tokenID, in: state)
        let token = transaction.token
        guard
            state.activeTokenID == tokenID,
            token.phase == .draining || token.phase == .quiesced,
            token.destinationProviderFingerprint
            == destination.fingerprint.digest,
            token.destinationStateRootUUID
            == destination.fingerprint.stateRootUUID.uuidString.lowercased(),
            let authority = manifestAuthority
        else {
            if manifestAuthority == nil {
                throw ProviderHandoffGatewayCoordinatorError
                    .missingManifestAuthority
            }
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let now = try authority.nowUnixSeconds()
        let trustRegistry = try authority.trustRegistryStore.loadRevision(
            token.trustRegistryRevision,
            bootstrap: bootstrap
        )
        let keys = try [
            ProviderHandoffKeyPurposeV1.destinationLineageKeyEncryption,
            .destinationPayloadEncryption
        ].map {
            try Self.destinationKey(
                purpose: $0,
                token: token,
                trustRegistry: trustRegistry,
                atUnixSeconds: now
            )
        }
        let secret = try authority.transactionSecretStore.loadOrCreate(
            binding: Self.secretBinding(token)
        )
        var proofs: [ProviderHandoffDestinationKeyPossessionProofV1] = []
        proofs.reserveCapacity(keys.count)
        for key in keys {
            let discriminator = Self.possessionDiscriminator(key)
            let challenge = try Self.possessionChallenge(
                token: token,
                key: key,
                secret: secret
            )
            let body = try ProviderHandoffProviderKeyControlCodec
                .encodePossessionChallenge(
                    ProviderHandoffProviderKeyPossessionRequestV1(
                        trustRegistryRevision: token.trustRegistryRevision,
                        challenge: challenge.transportChallenge
                    )
                )
            let result = try await perform(
                operation: .destinationKeyPossession,
                mediaType: ProviderHandoffProviderKeyControlCodec
                    .possessionChallengeMediaType,
                responseMediaType: ProviderHandoffProviderKeyControlCodec
                    .possessionProofMediaType,
                body: body,
                endpoint: destination,
                identity: "\(token.tokenID):\(token.manifestID):\(discriminator)"
            )
            let proof = try ProviderHandoffProviderKeyControlCodec
                .decodePossessionProof(result.body)
            let validated = try ProviderHandoffPossessionProofCodec.verify(
                proof,
                challenge: challenge,
                trustRegistry: trustRegistry,
                atUnixSeconds: now
            )
            guard
                try authority.possessionProofStore.store(proof)
                == validated.proofRecordDigestSHA256
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidProviderResponse(.destinationKeyPossession)
            }
            proofs.append(proof)
        }
        guard
            let lineageKey = keys.first(where: {
                $0.purpose == .destinationLineageKeyEncryption
            }),
            let payloadKey = keys.first(where: {
                $0.purpose == .destinationPayloadEncryption
            })
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidProviderResponse(.destinationKeyPossession)
        }
        return ProviderHandoffGatewayDestinationPossessionV1(
            payloadEncryptionKey: payloadKey,
            lineageEncryptionKey: lineageKey,
            proofs: proofs
        )
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

    /// Assembles the complete immutable manifest from provider-owned export
    /// contributions, obtains every source authority signature, applies the
    /// gateway signature, validates the exact trust-registry revision, and
    /// atomically binds the result to the quiesced token.
    ///
    /// The transaction seed makes gateway-created lineage material stable
    /// across a crash. If the manifest was already bound, the same unsigned
    /// assembly is checked locally and returned without contacting providers.
    public func assembleAndBindManifest(
        tokenID: String,
        parts: [ProviderHandoffPartV1],
        contributions: [ProviderHandoffSourceContributionV1],
        sourceEndpoints: [
            String: ProviderHandoffGatewayProviderEndpointV1
        ],
        destinationPossession:
        ProviderHandoffGatewayDestinationPossessionV1
    ) async throws -> ProviderHandoffGatewayManifestAssemblyResultV1 {
        var state = try store.load()
        var transaction = try requireTransaction(tokenID, in: state)
        let token = transaction.token
        guard
            state.activeTokenID == tokenID,
            token.phase == .quiesced,
            let authority = manifestAuthority
        else {
            if manifestAuthority == nil {
                throw ProviderHandoffGatewayCoordinatorError
                    .missingManifestAuthority
            }
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(token.phase)
        }

        let now = try authority.nowUnixSeconds()
        let trustRegistry = try authority.trustRegistryStore.loadRevision(
            token.trustRegistryRevision,
            bootstrap: bootstrap
        )
        let secret = try authority.transactionSecretStore.loadOrCreate(
            binding: Self.secretBinding(token)
        )
        let possessionProofs = try Self.validateDestinationPossession(
            destinationPossession,
            token: token,
            authority: authority,
            trustRegistry: trustRegistry,
            secret: secret,
            atUnixSeconds: now
        )
        let requiredProofs = try Self.requiredPossessionProofs(
            possessionProofs,
            parts: parts,
            destinationPossession: destinationPossession
        )
        let proofDigests = requiredProofs.map(
            \.proofRecordDigestSHA256
        ).sorted()
        let assembly = try Self.makeManifestAssembly(
            token: token,
            parts: parts,
            contributions: contributions,
            sourceEndpoints: sourceEndpoints,
            destinationPossession: destinationPossession,
            proofDigests: proofDigests,
            trustRegistry: trustRegistry,
            gatewayIdentity: authority.gatewayIdentity,
            secret: secret,
            atUnixSeconds: now
        )

        if let existing = transaction.manifest {
            guard
                Self.normalizedUnsignedManifest(existing, using: assembly.manifest)
                == assembly.manifest
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            let validated = try ProviderHandoffRecordValidator
                .validateManifest(
                    existing,
                    possessionProofs: requiredProofs,
                    trustRegistry: trustRegistry,
                    atUnixSeconds: now
                )
            return ProviderHandoffGatewayManifestAssemblyResultV1(
                validatedManifest: validated,
                gatewayState: state
            )
        }

        var manifest = assembly.manifest
        var signatures: [String: ProviderHandoffSignatureV1] = [:]
        for contribution in assembly.orderedContributions {
            guard
                let endpoint = sourceEndpoints[
                    contribution.sourceStateRootUUID
                ]
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .missingSourceEndpoint(
                        contribution.sourceStateRootUUID
                    )
            }
            let receipt = try await signSourceManifest(
                ProviderHandoffSourceManifestSignRequestV1(
                    bootstrap: bootstrap,
                    partKind: contribution.partKind,
                    contributionDigestSHA256:
                    contribution.contributionDigestSHA256,
                    candidateManifest: manifest
                ),
                source: endpoint
            )
            try trustRegistry.verify(
                receipt.sourceSignature,
                expectedPurpose: .sourceManifestSigning,
                expectedRole: .sourceProvider,
                providerFingerprint:
                contribution.sourceProviderFingerprint,
                stateRootUUID: contribution.sourceStateRootUUID,
                projectionDigestSHA256:
                receipt.sourceProjectionDigestSHA256,
                atUnixSeconds: now
            )
            if let existing = signatures[
                contribution.sourceStateRootUUID
            ] {
                guard
                    existing.signedProjectionDigestSHA256
                    == receipt.sourceSignature
                    .signedProjectionDigestSHA256,
                    existing.signerKeyID
                    == receipt.sourceSignature.signerKeyID
                else {
                    throw ProviderHandoffGatewayCoordinatorError
                        .invalidPartReceipt(contribution.partKind)
                }
            } else {
                signatures[contribution.sourceStateRootUUID] =
                    receipt.sourceSignature
            }
        }
        guard signatures.count == manifest.sources.count else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        for index in manifest.sources.indices {
            guard
                let signature = signatures[
                    manifest.sources[index].stateRootUUID
                ]
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .missingSourceEndpoint(
                        manifest.sources[index].stateRootUUID
                    )
            }
            manifest.sources[index].sourceSignature = signature
        }
        manifest.manifestDigest = try ProviderHandoffProjections
            .manifestDigest(manifest)
        manifest.coordinatorSignature = try authority.gatewayIdentity.sign(
            projectionDigestSHA256: manifest.manifestDigest,
            purpose: .coordinatorManifestSigning,
            trustRegistryRevision: manifest.trustRegistryRevision
        )
        let validated = try ProviderHandoffRecordValidator.validateManifest(
            manifest,
            possessionProofs: requiredProofs,
            trustRegistry: trustRegistry,
            atUnixSeconds: now
        )

        state = try store.load()
        transaction = try requireTransaction(tokenID, in: state)
        if let existing = transaction.manifest {
            guard existing == manifest else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            return ProviderHandoffGatewayManifestAssemblyResultV1(
                validatedManifest: validated,
                gatewayState: state
            )
        }
        guard transaction.token.phase == .quiesced else {
            throw ProviderHandoffGatewayCoordinatorError
                .invalidTransactionPhase(transaction.token.phase)
        }
        state = try store.update(expectedStoreRevision: state.storeRevision) {
            try ProviderHandoffGatewayStateMachine.bindManifest(
                validated,
                tokenID: tokenID,
                expectedTokenRevision: transaction.token.tokenRevision,
                in: &$0,
                expectedStoreRevision: state.storeRevision
            )
        }
        return ProviderHandoffGatewayManifestAssemblyResultV1(
            validatedManifest: validated,
            gatewayState: state
        )
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

    private struct ManifestAssembly {
        var manifest: ProviderHandoffManifestV1
        var orderedContributions: [ProviderHandoffSourceContributionV1]
    }

    private static func makeManifestAssembly(
        token: ProviderHandoffTokenV1,
        parts: [ProviderHandoffPartV1],
        contributions: [ProviderHandoffSourceContributionV1],
        sourceEndpoints: [
            String: ProviderHandoffGatewayProviderEndpointV1
        ],
        destinationPossession:
        ProviderHandoffGatewayDestinationPossessionV1,
        proofDigests: [String],
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        gatewayIdentity: ProviderHandoffGatewayIdentityV1,
        secret: ProviderHandoffGatewayTransactionSecretV1,
        atUnixSeconds: UInt64
    ) throws -> ManifestAssembly {
        let sourceRoots = token.orderedSourceStateRootUUIDs
        guard
            parts.map(\.kind) == ProviderHandoffPartKindV1.allCases,
            token.preCommitRootExpectations.map(\.stateRootUUID)
            == sourceRoots + [token.destinationStateRootUUID],
            Set(sourceEndpoints.keys) == Set(sourceRoots),
            !proofDigests.isEmpty
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        let destinationExpectation = try requireLast(
            token.preCommitRootExpectations
        )
        let sourceIndex = Dictionary(
            uniqueKeysWithValues: sourceRoots.enumerated().map {
                ($1, $0)
            }
        )
        let partIndex = Dictionary(
            uniqueKeysWithValues:
            ProviderHandoffPartKindV1.allCases.enumerated().map {
                ($1, $0)
            }
        )
        let partByKind = Dictionary(
            uniqueKeysWithValues: parts.map { ($0.kind, $0) }
        )
        var seenContributionKeys = Set<String>()
        var rootsByPart: [ProviderHandoffPartKindV1: [String]] = [:]
        var sourceRecords: [String: ProviderHandoffSourceV1] = [:]
        var sourceEnvelopes: [
            String: DestinationSealedLineageKeyEnvelopeV1
        ] = [:]

        for contribution in contributions {
            let root = contribution.sourceStateRootUUID
            let duplicateKey =
                "\(contribution.partKind.rawValue)\u{0}\(root)"
            guard seenContributionKeys.insert(duplicateKey).inserted else {
                throw ProviderHandoffGatewayCoordinatorError
                    .duplicateContribution(contribution.partKind, root)
            }
            guard
                let endpoint = sourceEndpoints[root],
                endpoint.fingerprint.digest
                == contribution.sourceProviderFingerprint,
                endpoint.fingerprint.stateRootUUID.uuidString.lowercased()
                == root,
                let expectedSourceIndex = sourceIndex[root],
                let part = partByKind[contribution.partKind],
                contribution.schemaVersion
                == ProviderHandoffSourceContributionV1
                .currentSchemaVersion,
                contribution.tokenID == token.tokenID,
                contribution.manifestID == token.manifestID,
                contribution.trustRegistryRevision
                == token.trustRegistryRevision,
                contribution.destinationProviderFingerprint
                == token.destinationProviderFingerprint,
                contribution.destinationStateRootUUID
                == token.destinationStateRootUUID,
                contribution.destinationPreCommitExpectation
                == destinationExpectation,
                contribution.destinationKeyPossessionProofDigestsSHA256
                == proofDigests,
                contribution.resultingAuthorityLineageUUID
                == token.resultingAuthorityLineageUUID,
                contribution.resultingLineageDigestKeyVersion
                == token.resultingLineageDigestKeyVersion,
                contribution.sourcePreCommitExpectation
                == token.preCommitRootExpectations[
                    expectedSourceIndex
                ],
                contribution.part == part,
                part.sourceStateRootUUIDs.contains(root),
                try contribution.contributionDigestSHA256
                == (ProviderHandoffSourceControlCodec
                    .contributionDigest(contribution)),
                contribution.sourceObjectRecord.state == .verified,
                contribution.sourceObjectRecord.bundleObjectID
                == part.payload.bundleObjectID,
                contribution.sourceObjectRecord.transportByteLength
                == part.payload.transportByteLength,
                contribution.sourceObjectRecord.transportDigestSHA256
                == part.payload.transportDigestSHA256,
                contribution.sourceObjectRecord.receivedByteCount
                == part.payload.transportByteLength,
                contribution.destinationSealedLineageKeyEnvelope
                .sourceStateRootUUID == root,
                contribution.destinationSealedLineageKeyEnvelope
                .authorityLineageUUID
                == contribution.authorityLineageUUID,
                contribution.destinationSealedLineageKeyEnvelope.keyVersion
                == contribution.lineageDigestKeyVersion,
                contribution.destinationSealedLineageKeyEnvelope
                .destinationKeyPurpose
                == .destinationLineageKeyEncryption,
                contribution.destinationSealedLineageKeyEnvelope
                .destinationKeyID
                == destinationPossession.lineageEncryptionKey.keyID,
                part.payload.destinationEncryption.map({
                    $0.destinationKeyPurpose
                        == .destinationPayloadEncryption
                        && $0.destinationKeyID
                        == destinationPossession.payloadEncryptionKey.keyID
                }) ?? true
            else {
                if sourceEndpoints[root] == nil {
                    throw ProviderHandoffGatewayCoordinatorError
                        .missingSourceEndpoint(root)
                }
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidPartReceipt(contribution.partKind)
            }
            rootsByPart[contribution.partKind, default: []].append(root)

            let signingKey = try sourceSigningKey(
                providerFingerprint:
                contribution.sourceProviderFingerprint,
                stateRootUUID: root,
                trustRegistry: trustRegistry,
                atUnixSeconds: atUnixSeconds
            )
            let source = ProviderHandoffSourceV1(
                providerFingerprint:
                contribution.sourceProviderFingerprint,
                stateRootUUID: root,
                authorityLineageUUID:
                contribution.authorityLineageUUID,
                lineageDigestKeyVersion:
                contribution.lineageDigestKeyVersion,
                preCommitExpectation:
                contribution.sourcePreCommitExpectation,
                sourceSignature: placeholderSignature(
                    signingKey,
                    trustRegistryRevision: token.trustRegistryRevision
                )
            )
            if let existing = sourceRecords[root] {
                guard existing == source else {
                    throw ProviderHandoffGatewayCoordinatorError
                        .invalidPartReceipt(contribution.partKind)
                }
            } else {
                sourceRecords[root] = source
            }
            let envelope =
                contribution.destinationSealedLineageKeyEnvelope
            if let existing = sourceEnvelopes[root] {
                guard existing == envelope else {
                    throw ProviderHandoffGatewayCoordinatorError
                        .invalidPartReceipt(contribution.partKind)
                }
            } else {
                sourceEnvelopes[root] = envelope
            }
        }

        guard
            Set(sourceRecords.keys) == Set(sourceRoots),
            Set(sourceEnvelopes.keys) == Set(sourceRoots)
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        for part in parts {
            let roots = (rootsByPart[part.kind] ?? []).sorted {
                (sourceIndex[$0] ?? .max) < (sourceIndex[$1] ?? .max)
            }
            guard roots == part.sourceStateRootUUIDs else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidPartReceipt(part.kind)
            }
        }
        let sources = try sourceRoots.map { root in
            guard let source = sourceRecords[root] else {
                throw ProviderHandoffGatewayCoordinatorError
                    .missingSourceEndpoint(root)
            }
            return source
        }
        var envelopes = try sourceRoots.map { root in
            guard let envelope = sourceEnvelopes[root] else {
                throw ProviderHandoffGatewayCoordinatorError
                    .missingSourceEndpoint(root)
            }
            return envelope
        }
        try envelopes.append(
            gatewayIdentity.sealLineageKey(
                ProviderHandoffEnvelopeLineageKeyV1(
                    sourceStateRootUUID: nil,
                    authorityLineageUUID:
                    token.resultingAuthorityLineageUUID,
                    keyVersion:
                    token.resultingLineageDigestKeyVersion,
                    rawHMACSHA256Key: secret.derive(
                        domain: "resulting-lineage-key-v1",
                        count: 32
                    )
                ),
                envelopeID:
                "resulting-lineage:\(token.resultingAuthorityLineageUUID):\(token.resultingLineageDigestKeyVersion)",
                tokenID: token.tokenID,
                manifestID: token.manifestID,
                destinationProviderFingerprint:
                token.destinationProviderFingerprint,
                destinationStateRootUUID:
                token.destinationStateRootUUID,
                destinationKeyID:
                destinationPossession.lineageEncryptionKey.keyID,
                destinationPublicKey:
                destinationPossession.lineageEncryptionKey.rawPublicKey,
                nonce: secret.derive(
                    domain: "resulting-lineage-nonce-v1",
                    count: 24
                ),
                trustRegistryRevision: token.trustRegistryRevision,
                ephemeralPrivateKey: secret.derive(
                    domain: "resulting-lineage-ephemeral-v1",
                    count: 32
                )
            )
        )
        let coordinatorKey = try gatewayIdentity.trustKey(
            for: .coordinatorManifestSigning
        )
        let manifest = ProviderHandoffManifestV1(
            manifestID: token.manifestID,
            tokenID: token.tokenID,
            trustRegistryRevision: token.trustRegistryRevision,
            destinationKeyPossessionProofDigestsSHA256:
            proofDigests,
            sources: sources,
            resultingAuthorityLineageUUID:
            token.resultingAuthorityLineageUUID,
            resultingLineageDigestKeyVersion:
            token.resultingLineageDigestKeyVersion,
            destinationSealedLineageKeyEnvelopes: envelopes,
            destinationProviderFingerprint:
            token.destinationProviderFingerprint,
            destinationStateRootUUID: token.destinationStateRootUUID,
            destinationPreCommitExpectation: destinationExpectation,
            parts: parts,
            manifestDigest: String(repeating: "0", count: 64),
            coordinatorSignature: placeholderSignature(
                coordinatorKey,
                trustRegistryRevision: token.trustRegistryRevision
            )
        )
        return ManifestAssembly(
            manifest: manifest,
            orderedContributions: contributions.sorted {
                let leftPart = partIndex[$0.partKind] ?? .max
                let rightPart = partIndex[$1.partKind] ?? .max
                if leftPart != rightPart {
                    return leftPart < rightPart
                }
                return (sourceIndex[$0.sourceStateRootUUID] ?? .max)
                    < (sourceIndex[$1.sourceStateRootUUID] ?? .max)
            }
        )
    }

    private static func normalizedUnsignedManifest(
        _ manifest: ProviderHandoffManifestV1,
        using unsigned: ProviderHandoffManifestV1
    ) -> ProviderHandoffManifestV1 {
        guard manifest.sources.count == unsigned.sources.count else {
            return manifest
        }
        var result = manifest
        for index in result.sources.indices {
            result.sources[index].sourceSignature =
                unsigned.sources[index].sourceSignature
        }
        for index in result.destinationSealedLineageKeyEnvelopes.indices {
            guard
                result.destinationSealedLineageKeyEnvelopes[index]
                .sourceStateRootUUID == nil,
                let replacement = unsigned
                .destinationSealedLineageKeyEnvelopes.first(where: {
                    $0.envelopeID
                        == result.destinationSealedLineageKeyEnvelopes[index]
                        .envelopeID
                        && $0.sourceStateRootUUID == nil
                })
            else { continue }
            result.destinationSealedLineageKeyEnvelopes[index]
                .envelopeSignature = replacement.envelopeSignature
        }
        result.manifestDigest = unsigned.manifestDigest
        result.coordinatorSignature = unsigned.coordinatorSignature
        return result
    }

    private static func requiredPossessionProofs(
        _ proofs: [ProviderHandoffValidatedPossessionProofV1],
        parts: [ProviderHandoffPartV1],
        destinationPossession:
        ProviderHandoffGatewayDestinationPossessionV1
    ) throws -> [ProviderHandoffValidatedPossessionProofV1] {
        var uses: [(ProviderHandoffKeyPurposeV1, String)] = [
            (
                .destinationLineageKeyEncryption,
                destinationPossession.lineageEncryptionKey.keyID
            )
        ]
        for part in parts {
            guard let encryption = part.payload.destinationEncryption else {
                continue
            }
            guard
                encryption.destinationKeyPurpose
                == .destinationPayloadEncryption,
                encryption.destinationKeyID
                == destinationPossession.payloadEncryptionKey.keyID
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .invalidPartReceipt(part.kind)
            }
            if !uses.contains(where: {
                $0.0 == encryption.destinationKeyPurpose
                    && $0.1 == encryption.destinationKeyID
            }) {
                uses.append((
                    encryption.destinationKeyPurpose,
                    encryption.destinationKeyID
                ))
            }
        }
        uses.sort {
            if $0.0.rawValue != $1.0.rawValue {
                return $0.0.rawValue.utf8.lexicographicallyPrecedes(
                    $1.0.rawValue.utf8
                )
            }
            return $0.1.utf8.lexicographicallyPrecedes($1.1.utf8)
        }
        return try uses.map { purpose, keyID in
            let matches = proofs.filter {
                $0.proof.destinationKeyPurpose == purpose
                    && $0.proof.destinationKeyID == keyID
            }
            guard matches.count == 1, let proof = matches.first else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            return proof
        }
    }

    private static func validateDestinationPossession(
        _ possession: ProviderHandoffGatewayDestinationPossessionV1,
        token: ProviderHandoffTokenV1,
        authority: ProviderHandoffGatewayManifestAuthorityV1,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        secret: ProviderHandoffGatewayTransactionSecretV1,
        atUnixSeconds: UInt64
    ) throws -> [ProviderHandoffValidatedPossessionProofV1] {
        let expectedKeys = try [
            ProviderHandoffKeyPurposeV1.destinationLineageKeyEncryption,
            .destinationPayloadEncryption
        ].map {
            try destinationKey(
                purpose: $0,
                token: token,
                trustRegistry: trustRegistry,
                atUnixSeconds: atUnixSeconds
            )
        }
        guard
            expectedKeys.first(where: {
                $0.purpose == .destinationLineageKeyEncryption
            }) == possession.lineageEncryptionKey,
            expectedKeys.first(where: {
                $0.purpose == .destinationPayloadEncryption
            }) == possession.payloadEncryptionKey,
            possession.proofs.count == expectedKeys.count
        else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        var validated: [ProviderHandoffValidatedPossessionProofV1] = []
        for key in expectedKeys {
            let matches = possession.proofs.filter {
                $0.destinationKeyPurpose == key.purpose
                    && $0.destinationKeyID == key.keyID
            }
            guard matches.count == 1, let proof = matches.first else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            let challenge = try possessionChallenge(
                token: token,
                key: key,
                secret: secret
            )
            let value = try ProviderHandoffPossessionProofCodec.verify(
                proof,
                challenge: challenge,
                trustRegistry: trustRegistry,
                atUnixSeconds: atUnixSeconds
            )
            guard
                try authority.possessionProofStore.store(proof)
                == value.proofRecordDigestSHA256
            else {
                throw ProviderHandoffGatewayCoordinatorError
                    .activeTransactionMismatch
            }
            validated.append(value)
        }
        return validated.sorted {
            if $0.proof.destinationKeyPurpose.rawValue
                != $1.proof.destinationKeyPurpose.rawValue
            {
                return $0.proof.destinationKeyPurpose.rawValue.utf8
                    .lexicographicallyPrecedes(
                        $1.proof.destinationKeyPurpose.rawValue.utf8
                    )
            }
            return $0.proof.destinationKeyID.utf8
                .lexicographicallyPrecedes(
                    $1.proof.destinationKeyID.utf8
                )
        }
    }

    private static func possessionChallenge(
        token: ProviderHandoffTokenV1,
        key: ProviderHandoffTrustKeyV1,
        secret: ProviderHandoffGatewayTransactionSecretV1
    ) throws -> ProviderHandoffPendingPossessionChallengeV1 {
        let discriminator = possessionDiscriminator(key)
        let proofID = "possession:" + ProviderHandoffDigest.sha256(
            Data(
                "\(token.tokenID)\u{0}\(token.manifestID)\u{0}\(discriminator)"
                    .utf8
            )
        )
        return try ProviderHandoffPossessionProofCodec.prepareChallenge(
            proofID: proofID,
            tokenID: token.tokenID,
            manifestID: token.manifestID,
            destinationProviderFingerprint:
            token.destinationProviderFingerprint,
            destinationStateRootUUID: token.destinationStateRootUUID,
            destinationKeyPurpose: key.purpose,
            destinationKeyID: key.keyID,
            destinationPublicKey: key.rawPublicKey,
            nonce: secret.derive(
                domain: "destination-possession-nonce-v1",
                discriminator: discriminator,
                count: 24
            ),
            challengePlaintext: secret.derive(
                domain: "destination-possession-plaintext-v1",
                discriminator: discriminator,
                count: 32
            ),
            ephemeralPrivateKey: secret.derive(
                domain: "destination-possession-ephemeral-v1",
                discriminator: discriminator,
                count: 32
            )
        )
    }

    private static func possessionDiscriminator(
        _ key: ProviderHandoffTrustKeyV1
    ) -> String {
        ProviderHandoffDigest.sha256(
            Data("\(key.purpose.rawValue)\u{0}\(key.keyID)".utf8)
        )
    }

    private static func destinationKey(
        purpose: ProviderHandoffKeyPurposeV1,
        token: ProviderHandoffTokenV1,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffTrustKeyV1 {
        let matches = trustRegistry.registry.keys.filter {
            $0.purpose == purpose
                && $0.role == .destinationProvider
                && $0.providerFingerprint
                == token.destinationProviderFingerprint
                && $0.stateRootUUID == token.destinationStateRootUUID
                && $0.algorithm == .x25519V1
        }
        guard matches.count == 1, let key = matches.first else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return try trustRegistry.key(
            identifier: key.keyID,
            purpose: purpose,
            role: .destinationProvider,
            providerFingerprint: token.destinationProviderFingerprint,
            stateRootUUID: token.destinationStateRootUUID,
            atUnixSeconds: atUnixSeconds
        )
    }

    private static func sourceSigningKey(
        providerFingerprint: String,
        stateRootUUID: String,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffTrustKeyV1 {
        let matches = trustRegistry.registry.keys.filter {
            $0.purpose == .sourceManifestSigning
                && $0.role == .sourceProvider
                && $0.providerFingerprint == providerFingerprint
                && $0.stateRootUUID == stateRootUUID
                && $0.algorithm == .ed25519V1
        }
        guard matches.count == 1, let key = matches.first else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return try trustRegistry.key(
            identifier: key.keyID,
            purpose: .sourceManifestSigning,
            role: .sourceProvider,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            atUnixSeconds: atUnixSeconds
        )
    }

    private static func placeholderSignature(
        _ key: ProviderHandoffTrustKeyV1,
        trustRegistryRevision: UInt64
    ) -> ProviderHandoffSignatureV1 {
        ProviderHandoffSignatureV1(
            purpose: key.purpose,
            signerKeyID: key.keyID,
            signerRole: key.role,
            providerFingerprint: key.providerFingerprint,
            stateRootUUID: key.stateRootUUID,
            trustRegistryRevision: trustRegistryRevision,
            signedProjectionDigestSHA256:
            String(repeating: "0", count: 64),
            signature: Data(repeating: 0, count: 64)
        )
    }

    private static func secretBinding(
        _ token: ProviderHandoffTokenV1
    ) -> ProviderHandoffGatewayTransactionSecretBindingV1 {
        ProviderHandoffGatewayTransactionSecretBindingV1(
            tokenID: token.tokenID,
            manifestID: token.manifestID,
            trustRegistryRevision: token.trustRegistryRevision,
            destinationProviderFingerprint:
            token.destinationProviderFingerprint,
            destinationStateRootUUID: token.destinationStateRootUUID,
            resultingAuthorityLineageUUID:
            token.resultingAuthorityLineageUUID,
            resultingLineageDigestKeyVersion:
            token.resultingLineageDigestKeyVersion
        )
    }

    private static func requireLast<T>(_ values: [T]) throws -> T {
        guard let value = values.last else {
            throw ProviderHandoffGatewayCoordinatorError
                .activeTransactionMismatch
        }
        return value
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
