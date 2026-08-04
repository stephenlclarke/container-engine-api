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

public enum ProviderHandoffGatewayStateError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case activeTokenExists(String)
    case commitMismatch
    case duplicateToken(String)
    case invalidManifest
    case invalidState
    case invalidTransition(ProviderHandoffPhaseV1, ProviderHandoffPhaseV1)
    case manifestMismatch
    case missingCommit
    case missingManifest
    case revisionOverflow
    case revisionMismatch(expected: UInt64, actual: UInt64)
    case tokenNotFound(String)
    case unresolvedPart(ProviderHandoffPartKindV1)

    public var description: String {
        switch self {
        case .activeTokenExists(let identifier):
            "provider handoff token \(identifier) is already active"
        case .commitMismatch:
            "provider handoff commit record does not match the staged transaction"
        case .duplicateToken(let identifier):
            "provider handoff token \(identifier) is duplicated"
        case .invalidManifest:
            "provider handoff manifest is structurally invalid"
        case .invalidState:
            "provider handoff gateway state is invalid"
        case .invalidTransition(let from, let to):
            "provider handoff transition \(from.rawValue) -> \(to.rawValue) is invalid"
        case .manifestMismatch:
            "provider handoff manifest does not match the token"
        case .missingCommit:
            "provider handoff has no authoritative commit record"
        case .missingManifest:
            "provider handoff has no immutable manifest"
        case .revisionOverflow:
            "provider handoff revision cannot advance beyond UInt64.max"
        case .revisionMismatch(let expected, let actual):
            "provider handoff revision mismatch: expected \(expected), found \(actual)"
        case .tokenNotFound(let identifier):
            "provider handoff token \(identifier) does not exist"
        case .unresolvedPart(let kind):
            "provider handoff part \(kind.rawValue) is unresolved"
        }
    }
}

public enum ProviderHandoffGatewayStateMachine {
    public static func initialState(
        providerSelection: ProviderHandoffProviderSelectionRecordV1,
        socketDiscovery: ProviderHandoffSocketDiscoveryRecordV1
    ) throws -> ProviderHandoffGatewayStateV1 {
        guard
            providerSelection.selectedProviderFingerprint
                == socketDiscovery.selectedProviderFingerprint,
            providerSelection.selectedStateRootUUID
                == socketDiscovery.selectedStateRootUUID
        else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        _ = try ProviderHandoffProjections.providerSelectionDigest(providerSelection)
        _ = try ProviderHandoffProjections.socketDiscoveryDigest(socketDiscovery)
        return ProviderHandoffGatewayStateV1(
            storeRevision: 1,
            authoritativeCommitRevision: 0,
            providerSelection: providerSelection,
            socketDiscovery: socketDiscovery,
            activeTokenID: nil,
            transactions: []
        )
    }

    public static func adoptTrustRegistryRevision(
        _ trustRegistryRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try checkStoreRevision(state, expected: expectedStoreRevision)
        guard
            state.activeTokenID == nil,
            trustRegistryRevision
                > state.providerSelection.trustRegistryRevision,
            state.providerSelection.selectionRevision < UInt64.max,
            state.storeRevision < UInt64.max
        else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        state.providerSelection.selectionRevision += 1
        state.providerSelection.trustRegistryRevision = trustRegistryRevision
        state.storeRevision += 1
        _ = try ProviderHandoffProjections.providerSelectionDigest(
            state.providerSelection
        )
    }

    public static func begin(
        _ token: ProviderHandoffTokenV1,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try checkStoreRevision(state, expected: expectedStoreRevision)
        guard state.activeTokenID == nil else {
            throw ProviderHandoffGatewayStateError.activeTokenExists(
                state.activeTokenID ?? "unknown"
            )
        }
        guard !state.transactions.contains(where: { $0.token.tokenID == token.tokenID }) else {
            throw ProviderHandoffGatewayStateError.duplicateToken(token.tokenID)
        }
        guard state.storeRevision < UInt64.max else {
            throw ProviderHandoffGatewayStateError.revisionOverflow
        }
        try validateInitialToken(token)
        state.transactions.append(ProviderHandoffGatewayTransactionV1(token: token))
        state.activeTokenID = token.tokenID
        state.storeRevision += 1
    }

    public static func quiesce(
        tokenID: String,
        expectedTokenRevision: UInt64,
        expectations: [ProviderHandoffHeaderExpectationV1],
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try mutate(
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            expectedStoreRevision: expectedStoreRevision,
            in: &state
        ) { transaction in
            guard transaction.token.phase == .draining else {
                throw ProviderHandoffGatewayStateError.invalidTransition(
                    transaction.token.phase,
                    .quiesced
                )
            }
            try validateExpectations(expectations, for: transaction.token)
            transaction.token.preCommitRootExpectations = expectations
            transaction.token.phase = .quiesced
        }
    }

    public static func bindManifest(
        _ validatedManifest: ProviderHandoffValidatedManifestV1,
        tokenID: String,
        expectedTokenRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        let manifest = validatedManifest.manifest
        try checkStoreRevision(state, expected: expectedStoreRevision)
        let existingIndex = try transactionIndex(tokenID, in: state)
        try checkTokenRevision(
            state.transactions[existingIndex].token,
            expected: expectedTokenRevision
        )
        if let existing = state.transactions[existingIndex].manifest {
            guard existing == manifest else {
                throw ProviderHandoffGatewayStateError.manifestMismatch
            }
            return
        }
        try mutate(
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            expectedStoreRevision: expectedStoreRevision,
            in: &state
        ) { transaction in
            guard transaction.token.phase == .quiesced else {
                throw ProviderHandoffGatewayStateError.invalidTransition(
                    transaction.token.phase,
                    .quiesced
                )
            }
            guard transaction.manifest == nil, transaction.token.manifestDigest == nil else {
                throw ProviderHandoffGatewayStateError.manifestMismatch
            }
            try validateManifest(manifest, for: transaction.token)
            transaction.manifest = manifest
            transaction.token.manifestDigest = manifest.manifestDigest
            transaction.token.destinationKeyPossessionProofDigestsSHA256 =
                manifest.destinationKeyPossessionProofDigestsSHA256
        }
    }

    public static func stage(
        tokenID: String,
        expectedTokenRevision: UInt64,
        importedParts: [ProviderHandoffPartImportExpectationV1],
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try mutate(
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            expectedStoreRevision: expectedStoreRevision,
            in: &state
        ) { transaction in
            guard transaction.token.phase == .quiesced else {
                throw ProviderHandoffGatewayStateError.invalidTransition(
                    transaction.token.phase,
                    .staged
                )
            }
            guard let manifest = transaction.manifest else {
                throw ProviderHandoffGatewayStateError.missingManifest
            }
            try validateImportedParts(importedParts, manifest: manifest)
            transaction.token.importedParts = importedParts
            transaction.token.phase = .staged
        }
    }

    public static func recordPreparedRoot(
        _ record: ProviderHandoffRootPrepareRecordV1,
        tokenID: String,
        expectedTokenRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try mutate(
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            expectedStoreRevision: expectedStoreRevision,
            in: &state
        ) { transaction in
            guard
                transaction.token.phase == .staged,
                let manifestDigest = transaction.token.manifestDigest,
                !manifestDigest.isEmpty,
                record.tokenID == transaction.token.tokenID,
                record.manifestID == transaction.token.manifestID
            else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            let nextIndex = transaction.token.rootPrepareRecordDigestsSHA256?.count ?? 0
            guard nextIndex < transaction.token.preCommitRootExpectations.count else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            let expected = transaction.token.preCommitRootExpectations[nextIndex]
            guard
                record.role == expected.role,
                record.stateRootUUID == expected.stateRootUUID,
                record.expectedHeaderDigestSHA256
                    == expected.expectedHeaderDigestSHA256,
                record.preCommitRevisionVectorDigestSHA256
                    == expected.preCommitRevisionVector.revisionVectorDigestSHA256
            else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            let digest = try ProviderHandoffProjections.rootPrepareDigest(record)
            var values = transaction.token.rootPrepareRecordDigestsSHA256 ?? []
            values.append(digest)
            transaction.token.rootPrepareRecordDigestsSHA256 = values
        }
    }

    public static func commit(
        _ validatedRecord: ProviderHandoffValidatedCommitRecordV1,
        tokenID: String,
        expectedTokenRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        let record = validatedRecord.record
        try checkStoreRevision(state, expected: expectedStoreRevision)
        let index = try transactionIndex(tokenID, in: state)
        let transaction = state.transactions[index]
        try checkTokenRevision(transaction.token, expected: expectedTokenRevision)
        guard transaction.token.phase == .staged else {
            throw ProviderHandoffGatewayStateError.invalidTransition(
                transaction.token.phase,
                .committed
            )
        }
        try validateCommit(record, transaction: transaction, state: state)
        guard
            transaction.token.tokenRevision < UInt64.max,
            state.storeRevision < UInt64.max
        else {
            throw ProviderHandoffGatewayStateError.revisionOverflow
        }
        var updated = transaction
        updated.commitRecord = record
        updated.token.phase = .committed
        updated.token.authoritativeCommitRevision = record.intent.authoritativeCommitRevision
        updated.token.commitDigestSHA256 = record.commitDigestSHA256
        updated.token.handoffChainHeadDigestSHA256 = record.handoffChainHeadDigestSHA256
        updated.token.tokenRevision += 1
        state.providerSelection = record.intent.providerSelection.resultingRecord
        state.socketDiscovery = record.intent.socketSelection.resultingRecord
        state.authoritativeCommitRevision = record.intent.authoritativeCommitRevision
        state.transactions[index] = updated
        state.storeRevision += 1
    }

    public static func beginReconciliation(
        tokenID: String,
        expectedTokenRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try transition(
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            from: .committed,
            to: .reconciling,
            in: &state,
            expectedStoreRevision: expectedStoreRevision
        ) { transaction in
            guard transaction.commitRecord != nil else {
                throw ProviderHandoffGatewayStateError.missingCommit
            }
        }
    }

    public static func complete(
        _ validatedOutcome: ProviderHandoffValidatedTerminalOutcomeV1,
        tokenID: String,
        expectedTokenRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try finish(
            validatedOutcome.outcome,
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            from: .reconciling,
            to: .complete,
            in: &state,
            expectedStoreRevision: expectedStoreRevision
        )
    }

    public static func beginAbort(
        tokenID: String,
        expectedTokenRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try mutate(
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            expectedStoreRevision: expectedStoreRevision,
            in: &state
        ) { transaction in
            guard [.draining, .quiesced, .staged].contains(transaction.token.phase) else {
                throw ProviderHandoffGatewayStateError.invalidTransition(
                    transaction.token.phase,
                    .aborting
                )
            }
            transaction.token.phase = .aborting
        }
    }

    public static func finishAbort(
        _ validatedOutcome: ProviderHandoffValidatedTerminalOutcomeV1,
        tokenID: String,
        expectedTokenRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try finish(
            validatedOutcome.outcome,
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            from: .aborting,
            to: .aborted,
            in: &state,
            expectedStoreRevision: expectedStoreRevision
        )
    }

    public static func validate(_ state: ProviderHandoffGatewayStateV1) throws {
        guard
            state.schemaVersion == 1,
            state.storeRevision > 0,
            state.providerSelection.selectedProviderFingerprint
                == state.socketDiscovery.selectedProviderFingerprint,
            state.providerSelection.selectedStateRootUUID
                == state.socketDiscovery.selectedStateRootUUID
        else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        _ = try ProviderHandoffProjections.providerSelectionDigest(
            state.providerSelection
        )
        _ = try ProviderHandoffProjections.socketDiscoveryDigest(
            state.socketDiscovery
        )
        var seen = Set<String>()
        var nonterminal: [String] = []
        for transaction in state.transactions {
            guard seen.insert(transaction.token.tokenID).inserted else {
                throw ProviderHandoffGatewayStateError.duplicateToken(
                    transaction.token.tokenID
                )
            }
            try validateTransaction(transaction)
            if ![.complete, .aborted].contains(transaction.token.phase) {
                nonterminal.append(transaction.token.tokenID)
            }
        }
        guard nonterminal.count <= 1, nonterminal.first == state.activeTokenID else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
    }

    private static func mutate(
        tokenID: String,
        expectedTokenRevision: UInt64,
        expectedStoreRevision: UInt64,
        in state: inout ProviderHandoffGatewayStateV1,
        body: (inout ProviderHandoffGatewayTransactionV1) throws -> Void
    ) throws {
        try checkStoreRevision(state, expected: expectedStoreRevision)
        let index = try transactionIndex(tokenID, in: state)
        try checkTokenRevision(
            state.transactions[index].token,
            expected: expectedTokenRevision
        )
        guard
            state.transactions[index].token.tokenRevision < UInt64.max,
            state.storeRevision < UInt64.max
        else {
            throw ProviderHandoffGatewayStateError.revisionOverflow
        }
        var transaction = state.transactions[index]
        try body(&transaction)
        transaction.token.tokenRevision += 1
        state.transactions[index] = transaction
        state.storeRevision += 1
    }

    private static func transition(
        tokenID: String,
        expectedTokenRevision: UInt64,
        from: ProviderHandoffPhaseV1,
        to: ProviderHandoffPhaseV1,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64,
        body: (inout ProviderHandoffGatewayTransactionV1) throws -> Void
    ) throws {
        try mutate(
            tokenID: tokenID,
            expectedTokenRevision: expectedTokenRevision,
            expectedStoreRevision: expectedStoreRevision,
            in: &state
        ) { transaction in
            guard transaction.token.phase == from else {
                throw ProviderHandoffGatewayStateError.invalidTransition(
                    transaction.token.phase,
                    to
                )
            }
            try body(&transaction)
            transaction.token.phase = to
        }
    }

    private static func finish(
        _ outcome: ProviderHandoffTerminalOutcomeV1,
        tokenID: String,
        expectedTokenRevision: UInt64,
        from: ProviderHandoffPhaseV1,
        to: ProviderHandoffPhaseV1,
        in state: inout ProviderHandoffGatewayStateV1,
        expectedStoreRevision: UInt64
    ) throws {
        try checkStoreRevision(state, expected: expectedStoreRevision)
        let index = try transactionIndex(tokenID, in: state)
        var transaction = state.transactions[index]
        try checkTokenRevision(transaction.token, expected: expectedTokenRevision)
        guard
            transaction.token.tokenRevision < UInt64.max,
            state.storeRevision < UInt64.max
        else {
            throw ProviderHandoffGatewayStateError.revisionOverflow
        }
        guard
            transaction.token.phase == from,
            outcome.phase == to,
            outcome.tokenID == tokenID,
            outcome.manifestID == transaction.token.manifestID,
            outcome.manifestDigest == transaction.token.manifestDigest,
            try ProviderHandoffProjections.terminalOutcomeDigest(outcome)
                == outcome.outcomeDigestSHA256
        else {
            throw ProviderHandoffGatewayStateError.invalidTransition(
                transaction.token.phase,
                to
            )
        }
        if to == .complete, transaction.commitRecord == nil {
            throw ProviderHandoffGatewayStateError.missingCommit
        }
        if to == .aborted, transaction.commitRecord != nil {
            throw ProviderHandoffGatewayStateError.commitMismatch
        }
        try validateTerminalRoots(outcome, transaction: transaction)
        transaction.token.phase = to
        transaction.token.terminalOutcomeDigestSHA256 = outcome.outcomeDigestSHA256
        transaction.token.tokenRevision += 1
        transaction.terminalOutcome = outcome
        state.transactions[index] = transaction
        state.activeTokenID = nil
        state.storeRevision += 1
    }

    private static func validateInitialToken(_ token: ProviderHandoffTokenV1) throws {
        guard
            token.schemaVersion == 1,
            token.tokenRevision == 1,
            token.phase == .draining,
            !token.tokenID.isEmpty,
            !token.manifestID.isEmpty,
            !token.orderedSourceStateRootUUIDs.isEmpty,
            Set(token.orderedSourceStateRootUUIDs).count
                == token.orderedSourceStateRootUUIDs.count,
            !token.orderedSourceStateRootUUIDs.contains(token.destinationStateRootUUID),
            token.trustRegistryRevision > 0,
            token.resultingLineageDigestKeyVersion > 0,
            token.preCommitRootExpectations.isEmpty,
            token.destinationKeyPossessionProofDigestsSHA256.isEmpty,
            token.manifestDigest == nil,
            token.importedParts == nil,
            token.authoritativeCommitRevision == nil,
            token.commitDigestSHA256 == nil,
            token.handoffChainHeadDigestSHA256 == nil,
            token.rootPrepareRecordDigestsSHA256 == nil,
            token.terminalOutcomeDigestSHA256 == nil
        else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        try validateUUIDs(token)
    }

    private static func validateUUIDs(_ token: ProviderHandoffTokenV1) throws {
        let values =
            token.orderedSourceStateRootUUIDs + [
                token.destinationStateRootUUID,
                token.resultingAuthorityLineageUUID,
            ]
        for value in values {
            guard
                let identifier = UUID(uuidString: value),
                identifier.uuidString.lowercased() == value
            else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
        }
    }

    private static func validateExpectations(
        _ values: [ProviderHandoffHeaderExpectationV1],
        for token: ProviderHandoffTokenV1
    ) throws {
        let roots = token.orderedSourceStateRootUUIDs + [token.destinationStateRootUUID]
        guard values.map(\.stateRootUUID) == roots else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        for (index, value) in values.enumerated() {
            _ = try ProviderHandoffProjections.headerExpectation(value)
            if index < token.orderedSourceStateRootUUIDs.count {
                guard
                    value.role == .source,
                    value.expectedHeader.handoffState == .sourceQuiesced,
                    value.expectedHeader.activeHandoffTokenID == token.tokenID
                else {
                    throw ProviderHandoffGatewayStateError.invalidState
                }
            } else {
                guard
                    value.role == .destination,
                    value.expectedHeader.handoffState == .destinationStaged,
                    value.expectedHeader.activeHandoffTokenID == token.tokenID,
                    value.expectedHeader.stagedAuthorityLineageUUID
                        == token.resultingAuthorityLineageUUID
                else {
                    throw ProviderHandoffGatewayStateError.invalidState
                }
            }
        }
    }

    private static func validateManifest(
        _ manifest: ProviderHandoffManifestV1,
        for token: ProviderHandoffTokenV1
    ) throws {
        guard
            manifest.schemaVersion == 1,
            manifest.tokenID == token.tokenID,
            manifest.manifestID == token.manifestID,
            manifest.trustRegistryRevision == token.trustRegistryRevision,
            manifest.destinationProviderFingerprint
                == token.destinationProviderFingerprint,
            manifest.destinationStateRootUUID == token.destinationStateRootUUID,
            manifest.resultingAuthorityLineageUUID
                == token.resultingAuthorityLineageUUID,
            manifest.resultingLineageDigestKeyVersion
                == token.resultingLineageDigestKeyVersion,
            manifest.manifestDigestAlgorithm == .sha256,
            manifest.sources.map(\.stateRootUUID)
                == token.orderedSourceStateRootUUIDs,
            manifest.sources.map(\.preCommitExpectation)
                + [manifest.destinationPreCommitExpectation]
                == token.preCommitRootExpectations,
            manifest.parts.map(\.kind) == ProviderHandoffPartKindV1.allCases,
            !manifest.destinationKeyPossessionProofDigestsSHA256.isEmpty
                || manifest.parts.allSatisfy({
                    $0.payload.protection == .authenticatedPlaintext
                })
        else {
            throw ProviderHandoffGatewayStateError.invalidManifest
        }
        guard
            try ProviderHandoffProjections.manifestDigest(manifest)
                == manifest.manifestDigest,
            manifest.coordinatorSignature.purpose == .coordinatorManifestSigning,
            manifest.coordinatorSignature.signerRole == .gatewayCoordinator,
            manifest.coordinatorSignature.providerFingerprint == nil,
            manifest.coordinatorSignature.stateRootUUID == nil,
            manifest.coordinatorSignature.trustRegistryRevision
                == manifest.trustRegistryRevision,
            manifest.coordinatorSignature.signedProjectionDigestSHA256
                == manifest.manifestDigest
        else {
            throw ProviderHandoffGatewayStateError.invalidManifest
        }
        for digest in manifest.destinationKeyPossessionProofDigestsSHA256 {
            _ = try ProviderHandoffDigest.parseSHA256(digest)
        }
        let sourcesByRoot = Dictionary(
            uniqueKeysWithValues: manifest.sources.map {
                ($0.stateRootUUID, $0.providerFingerprint)
            }
        )
        for source in manifest.sources {
            let digest = try ProviderHandoffProjections.sourceManifestDigest(
                source: source,
                manifest: manifest
            )
            guard
                source.sourceSignature.purpose == .sourceManifestSigning,
                source.sourceSignature.signerRole == .sourceProvider,
                source.sourceSignature.providerFingerprint
                    == source.providerFingerprint,
                source.sourceSignature.stateRootUUID == source.stateRootUUID,
                source.sourceSignature.trustRegistryRevision
                    == manifest.trustRegistryRevision,
                source.sourceSignature.signedProjectionDigestSHA256 == digest
            else {
                throw ProviderHandoffGatewayStateError.invalidManifest
            }
        }
        for envelope in manifest.destinationSealedLineageKeyEnvelopes {
            let digest = try ProviderHandoffProjections.lineageKeyEnvelopeDigest(
                envelope
            )
            let expectedRole: ProviderHandoffKeyRoleV1 =
                envelope.sourceStateRootUUID == nil
                ? .gatewayCoordinator : .sourceProvider
            guard
                envelope.envelopeSignature.purpose
                    == .lineageKeyEnvelopeSigning,
                envelope.envelopeSignature.signerRole == expectedRole,
                envelope.envelopeSignature.providerFingerprint
                    == envelope.sourceStateRootUUID.flatMap({ sourcesByRoot[$0] }),
                envelope.envelopeSignature.stateRootUUID
                    == envelope.sourceStateRootUUID,
                envelope.envelopeSignature.trustRegistryRevision
                    == manifest.trustRegistryRevision,
                envelope.envelopeSignature.signedProjectionDigestSHA256 == digest
            else {
                throw ProviderHandoffGatewayStateError.invalidManifest
            }
        }
        for part in manifest.parts {
            _ = try ProviderHandoffProjections.payloadDescriptorDigest(part.payload)
        }
    }

    private static func validateImportedParts(
        _ imported: [ProviderHandoffPartImportExpectationV1],
        manifest: ProviderHandoffManifestV1
    ) throws {
        guard imported.map(\.partKind) == ProviderHandoffPartKindV1.allCases else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        for (part, expectation) in zip(manifest.parts, imported) {
            if part.disposition == .unsupported
                || part.disposition == .explicitResolutionRequired
            {
                throw ProviderHandoffGatewayStateError.unresolvedPart(part.kind)
            }
            guard
                part.kind == expectation.partKind,
                try ProviderHandoffProjections.payloadDescriptorDigest(part.payload)
                    == expectation.payloadDescriptorDigestSHA256
            else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            _ = try ProviderHandoffDigest.parseSHA256(
                expectation.stagedImportReceiptDigestSHA256
            )
        }
    }

    private static func validateCommit(
        _ record: ProviderHandoffCommitRecordV1,
        transaction: ProviderHandoffGatewayTransactionV1,
        state: ProviderHandoffGatewayStateV1
    ) throws {
        let derivedPostCommitRoots =
            try ProviderHandoffRecordValidator
            .derivePostCommitRoots(
                intent: record.intent,
                chainHeadDigestSHA256: record.handoffChainHeadDigestSHA256
            )
        let commitRecordDigest = try ProviderHandoffProjections.commitRecordDigest(
            record
        )
        let (nextCommitRevision, commitRevisionOverflow) = state
            .authoritativeCommitRevision.addingReportingOverflow(1)
        let (nextProviderSelectionRevision, providerSelectionOverflow) = state
            .providerSelection.selectionRevision.addingReportingOverflow(1)
        let (nextSocketDiscoveryRevision, socketDiscoveryOverflow) = state
            .socketDiscovery.discoveryRevision.addingReportingOverflow(1)
        guard
            !commitRevisionOverflow,
            !providerSelectionOverflow,
            !socketDiscoveryOverflow,
            let manifest = transaction.manifest,
            let manifestDigest = transaction.token.manifestDigest,
            let importedParts = transaction.token.importedParts,
            let prepared = transaction.token.rootPrepareRecordDigestsSHA256,
            prepared.count == transaction.token.preCommitRootExpectations.count,
            record.intent.tokenID == transaction.token.tokenID,
            record.intent.manifestID == transaction.token.manifestID,
            record.intent.manifestDigest == manifestDigest,
            record.intent.trustRegistryRevision == transaction.token.trustRegistryRevision,
            record.intent.authoritativeCommitRevision
                == nextCommitRevision,
            record.intent.preCommitRootExpectations
                == transaction.token.preCommitRootExpectations,
            record.intent.importedParts == importedParts,
            record.intent.destinationKeyPossessionProofDigestsSHA256
                == transaction.token.destinationKeyPossessionProofDigestsSHA256,
            record.intent.resultingAuthorityLineageUUID
                == transaction.token.resultingAuthorityLineageUUID,
            record.intent.resultingLineageDigestKeyVersion
                == transaction.token.resultingLineageDigestKeyVersion,
            record.intent.providerSelection.expectedRecord == state.providerSelection,
            record.intent.socketSelection.expectedRecord == state.socketDiscovery,
            record.intent.providerSelection.resultingRecord.selectionRevision
                == nextProviderSelectionRevision,
            record.intent.socketSelection.resultingRecord.discoveryRevision
                == nextSocketDiscoveryRevision,
            record.intent.providerSelection.resultingRecord.selectedProviderFingerprint
                == manifest.destinationProviderFingerprint,
            record.intent.providerSelection.resultingRecord.selectedStateRootUUID
                == manifest.destinationStateRootUUID,
            record.intent.socketSelection.resultingRecord.selectedProviderFingerprint
                == manifest.destinationProviderFingerprint,
            record.intent.socketSelection.resultingRecord.selectedStateRootUUID
                == manifest.destinationStateRootUUID,
            record.rootPrepareRecordDigestsSHA256 == prepared,
            try ProviderHandoffProjections.commitIntentDigest(record.intent)
                == record.commitDigestSHA256,
            try ProviderHandoffProjections.chainHeadDigest(
                commitDigestSHA256: record.commitDigestSHA256,
                orderedPreCommitHeaders: record.intent.preCommitRootExpectations.map(
                    \.expectedHeader
                )
            ) == record.handoffChainHeadDigestSHA256,
            record.postCommitRoots == derivedPostCommitRoots,
            record.coordinatorSignature.purpose == .coordinatorCommitSigning,
            record.coordinatorSignature.signerRole == .gatewayCoordinator,
            record.coordinatorSignature.providerFingerprint == nil,
            record.coordinatorSignature.stateRootUUID == nil,
            record.coordinatorSignature.trustRegistryRevision
                == record.intent.trustRegistryRevision,
            record.coordinatorSignature.signedProjectionDigestSHA256
                == commitRecordDigest
        else {
            throw ProviderHandoffGatewayStateError.commitMismatch
        }
    }

    private static func validateTransaction(
        _ transaction: ProviderHandoffGatewayTransactionV1
    ) throws {
        let token = transaction.token
        guard token.schemaVersion == 1, token.tokenRevision > 0 else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        try validateUUIDs(token)
        if let manifest = transaction.manifest {
            try validateManifest(manifest, for: token)
            guard token.manifestDigest == manifest.manifestDigest else {
                throw ProviderHandoffGatewayStateError.manifestMismatch
            }
        } else if token.manifestDigest != nil {
            throw ProviderHandoffGatewayStateError.missingManifest
        }
        switch token.phase {
        case .draining:
            guard transaction.manifest == nil, transaction.commitRecord == nil else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
        case .quiesced:
            try validateExpectations(token.preCommitRootExpectations, for: token)
            guard transaction.commitRecord == nil else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
        case .staged, .aborting:
            guard
                let manifest = transaction.manifest,
                let imported = token.importedParts,
                transaction.commitRecord == nil
            else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            try validateImportedParts(imported, manifest: manifest)
        case .committed, .reconciling, .complete:
            guard let commitRecord = transaction.commitRecord else {
                throw ProviderHandoffGatewayStateError.missingCommit
            }
            try validatePersistedCommit(commitRecord, token: token)
        case .aborted:
            guard transaction.commitRecord == nil else {
                throw ProviderHandoffGatewayStateError.commitMismatch
            }
        }
        if [.complete, .aborted].contains(token.phase) {
            guard
                let terminalOutcome = transaction.terminalOutcome,
                token.terminalOutcomeDigestSHA256
                    == terminalOutcome.outcomeDigestSHA256
            else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            try validatePersistedOutcome(terminalOutcome, token: token)
        } else if transaction.terminalOutcome != nil {
            throw ProviderHandoffGatewayStateError.invalidState
        }
    }

    private static func validatePersistedCommit(
        _ record: ProviderHandoffCommitRecordV1,
        token: ProviderHandoffTokenV1
    ) throws {
        let derivedRoots = try ProviderHandoffRecordValidator.derivePostCommitRoots(
            intent: record.intent,
            chainHeadDigestSHA256: record.handoffChainHeadDigestSHA256
        )
        let signedDigest = try ProviderHandoffProjections.commitRecordDigest(record)
        guard
            record.intent.tokenID == token.tokenID,
            record.intent.manifestID == token.manifestID,
            record.intent.manifestDigest == token.manifestDigest,
            record.intent.trustRegistryRevision == token.trustRegistryRevision,
            record.intent.preCommitRootExpectations
                == token.preCommitRootExpectations,
            record.intent.importedParts == token.importedParts,
            record.intent.destinationKeyPossessionProofDigestsSHA256
                == token.destinationKeyPossessionProofDigestsSHA256,
            record.intent.authoritativeCommitRevision
                == token.authoritativeCommitRevision,
            record.commitDigestSHA256 == token.commitDigestSHA256,
            record.handoffChainHeadDigestSHA256
                == token.handoffChainHeadDigestSHA256,
            record.rootPrepareRecordDigestsSHA256
                == token.rootPrepareRecordDigestsSHA256,
            try ProviderHandoffProjections.commitIntentDigest(record.intent)
                == record.commitDigestSHA256,
            try ProviderHandoffProjections.chainHeadDigest(
                commitDigestSHA256: record.commitDigestSHA256,
                orderedPreCommitHeaders: record.intent.preCommitRootExpectations
                    .map(\.expectedHeader)
            ) == record.handoffChainHeadDigestSHA256,
            record.postCommitRoots == derivedRoots,
            record.coordinatorSignature.purpose == .coordinatorCommitSigning,
            record.coordinatorSignature.signerRole == .gatewayCoordinator,
            record.coordinatorSignature.providerFingerprint == nil,
            record.coordinatorSignature.stateRootUUID == nil,
            record.coordinatorSignature.trustRegistryRevision
                == token.trustRegistryRevision,
            record.coordinatorSignature.signedProjectionDigestSHA256
                == signedDigest
        else {
            throw ProviderHandoffGatewayStateError.commitMismatch
        }
    }

    private static func validatePersistedOutcome(
        _ outcome: ProviderHandoffTerminalOutcomeV1,
        token: ProviderHandoffTokenV1
    ) throws {
        guard
            outcome.phase == token.phase,
            outcome.tokenID == token.tokenID,
            outcome.manifestID == token.manifestID,
            outcome.manifestDigest == token.manifestDigest,
            try ProviderHandoffProjections.terminalOutcomeDigest(outcome)
                == outcome.outcomeDigestSHA256,
            outcome.coordinatorSignature.purpose
                == .coordinatorTerminalOutcomeSigning,
            outcome.coordinatorSignature.signerRole == .gatewayCoordinator,
            outcome.coordinatorSignature.providerFingerprint == nil,
            outcome.coordinatorSignature.stateRootUUID == nil,
            outcome.coordinatorSignature.trustRegistryRevision
                == token.trustRegistryRevision,
            outcome.coordinatorSignature.signedProjectionDigestSHA256
                == outcome.outcomeDigestSHA256
        else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
    }

    private static func validateTerminalRoots(
        _ outcome: ProviderHandoffTerminalOutcomeV1,
        transaction: ProviderHandoffGatewayTransactionV1
    ) throws {
        let token = transaction.token
        let orderedRoots =
            token.orderedSourceStateRootUUIDs
            + [token.destinationStateRootUUID]
        guard
            outcome.roots.map(\.stateRootUUID) == orderedRoots,
            outcome.roots.dropLast().allSatisfy({ $0.role == .source }),
            outcome.roots.last?.role == .destination
        else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        if outcome.phase == .aborted, !token.preCommitRootExpectations.isEmpty {
            let expected = token.preCommitRootExpectations.map {
                ProviderHandoffTerminalRootV1(
                    role: $0.role,
                    stateRootUUID: $0.stateRootUUID,
                    terminalHeader: $0.abortHeader,
                    terminalHeaderDigestSHA256: $0.abortHeaderDigestSHA256,
                    terminalRevisionVector: $0.abortRevisionVector
                )
            }
            guard outcome.roots == expected else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            return
        }
        guard outcome.phase == .complete, let commit = transaction.commitRecord else {
            return
        }
        for (index, pair) in zip(outcome.roots, commit.postCommitRoots).enumerated() {
            let terminal = pair.0
            let post = pair.1
            guard
                terminal.role == post.role,
                terminal.stateRootUUID == post.stateRootUUID,
                terminal.terminalHeader.stateRootUUID == post.stateRootUUID,
                terminal.terminalHeader.handoffChainHeadDigest
                    == post.postCommitHeader.handoffChainHeadDigest,
                terminal.terminalHeader.authorityLineageUUID
                    == post.postCommitHeader.authorityLineageUUID,
                terminal.terminalHeader.lineageDigestKeyVersion
                    == post.postCommitHeader.lineageDigestKeyVersion,
                terminal.terminalHeader.selectedProviderFingerprint
                    == post.postCommitHeader.selectedProviderFingerprint,
                terminal.terminalHeader.activeHandoffTokenID == nil,
                terminal.terminalRevisionVector.rootStoreRevision
                    >= post.postCommitRevisionVector.rootStoreRevision,
                controllersDoNotRegress(
                    terminal.terminalRevisionVector.controllerRevisions,
                    from: post.postCommitRevisionVector.controllerRevisions
                )
            else {
                throw ProviderHandoffGatewayStateError.invalidState
            }
            if index == outcome.roots.count - 1 {
                guard
                    post.postCommitHeader.writerEpoch < UInt64.max,
                    post.postCommitRevisionVector.rootStoreRevision < UInt64.max,
                    terminal.terminalHeader.handoffState == .destinationActive,
                    terminal.terminalHeader.stagedAuthorityLineageUUID == nil,
                    terminal.terminalHeader.writerEpoch
                        == post.postCommitHeader.writerEpoch + 1,
                    terminal.terminalRevisionVector.rootStoreRevision
                        >= post.postCommitRevisionVector.rootStoreRevision + 1
                else {
                    throw ProviderHandoffGatewayStateError.invalidState
                }
            } else {
                guard
                    terminal.terminalHeader.handoffState == .sourceTransferred,
                    terminal.terminalHeader.writerEpoch
                        == post.postCommitHeader.writerEpoch
                else {
                    throw ProviderHandoffGatewayStateError.invalidState
                }
            }
        }
    }

    private static func controllersDoNotRegress(
        _ terminal: [ProviderHandoffControllerRevisionV1],
        from committed: [ProviderHandoffControllerRevisionV1]
    ) -> Bool {
        let terminalByID = Dictionary(
            uniqueKeysWithValues: terminal.map { ($0.controllerID, $0.revision) }
        )
        return committed.allSatisfy { committedController in
            terminalByID[committedController.controllerID].map {
                terminalRevision in
                terminalRevision >= committedController.revision
            } ?? false
        }
    }

    private static func transactionIndex(
        _ tokenID: String,
        in state: ProviderHandoffGatewayStateV1
    ) throws -> Int {
        guard
            let index = state.transactions.firstIndex(where: {
                $0.token.tokenID == tokenID
            })
        else {
            throw ProviderHandoffGatewayStateError.tokenNotFound(tokenID)
        }
        return index
    }

    private static func checkStoreRevision(
        _ state: ProviderHandoffGatewayStateV1,
        expected: UInt64
    ) throws {
        guard state.storeRevision == expected else {
            throw ProviderHandoffGatewayStateError.revisionMismatch(
                expected: expected,
                actual: state.storeRevision
            )
        }
    }

    private static func checkTokenRevision(
        _ token: ProviderHandoffTokenV1,
        expected: UInt64
    ) throws {
        guard token.tokenRevision == expected else {
            throw ProviderHandoffGatewayStateError.revisionMismatch(
                expected: expected,
                actual: token.tokenRevision
            )
        }
    }
}
