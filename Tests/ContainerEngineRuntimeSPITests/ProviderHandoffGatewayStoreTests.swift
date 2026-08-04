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
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ProviderHandoffGatewayStoreTests {
    @Test
    func `gateway adopts a newer trust registry only while idle`() throws {
        var state = try initialState()
        try ProviderHandoffGatewayStateMachine.adoptTrustRegistryRevision(
            2,
            in: &state,
            expectedStoreRevision: 1
        )
        #expect(state.storeRevision == 2)
        #expect(state.providerSelection.selectionRevision == 2)
        #expect(state.providerSelection.trustRegistryRevision == 2)

        let token = handoffToken()
        var active = try initialState()
        try ProviderHandoffGatewayStateMachine.begin(
            token,
            in: &active,
            expectedStoreRevision: 1
        )
        let snapshot = active
        #expect(throws: ProviderHandoffGatewayStateError.invalidState) {
            try ProviderHandoffGatewayStateMachine.adoptTrustRegistryRevision(
                2,
                in: &active,
                expectedStoreRevision: 2
            )
        }
        #expect(active == snapshot)
    }

    @Test
    func `gateway store persists one active token and rejects stale revision`() throws {
        try withStore { store, _ in
            let initial = try initialState()
            #expect(try store.loadOrCreate(initial: initial) == initial)
            let token = handoffToken()
            let begun = try store.update(expectedStoreRevision: 1) { state in
                try ProviderHandoffGatewayStateMachine.begin(
                    token,
                    in: &state,
                    expectedStoreRevision: 1
                )
            }

            #expect(begun.storeRevision == 2)
            #expect(begun.activeTokenID == token.tokenID)
            #expect(begun.transactions.map(\.token) == [token])
            #expect(try store.load() == begun)
            #expect(
                throws: ProviderHandoffGatewayStoreError.revisionMismatch(
                    expected: 1,
                    actual: 2
                )
            ) {
                try store.update(expectedStoreRevision: 1) { _ in }
            }
            #expect(throws: ProviderHandoffGatewayStateError.activeTokenExists(token.tokenID)) {
                var copy = begun
                try ProviderHandoffGatewayStateMachine.begin(
                    handoffToken(tokenID: "another-token"),
                    in: &copy,
                    expectedStoreRevision: 2
                )
            }
        }
    }

    @Test
    func `quiescence freezes exact ordered source and destination expectations`() throws {
        var state = try initialState()
        let token = handoffToken()
        try ProviderHandoffGatewayStateMachine.begin(
            token,
            in: &state,
            expectedStoreRevision: 1
        )
        let values = try expectations(token: token)
        try ProviderHandoffGatewayStateMachine.quiesce(
            tokenID: token.tokenID,
            expectedTokenRevision: 1,
            expectations: values,
            in: &state,
            expectedStoreRevision: 2
        )

        #expect(state.storeRevision == 3)
        #expect(state.transactions[0].token.tokenRevision == 2)
        #expect(state.transactions[0].token.phase == .quiesced)
        #expect(state.transactions[0].token.preCommitRootExpectations == values)
        try ProviderHandoffGatewayStateMachine.validate(state)
        #expect(throws: ProviderHandoffGatewayStateError.self) {
            var invalid = state
            try ProviderHandoffGatewayStateMachine.beginAbort(
                tokenID: token.tokenID,
                expectedTokenRevision: 1,
                in: &invalid,
                expectedStoreRevision: 3
            )
        }
    }

    @Test
    func `quiesced transaction can durably enter abort recovery`() throws {
        var state = try initialState()
        let token = handoffToken()
        try ProviderHandoffGatewayStateMachine.begin(
            token,
            in: &state,
            expectedStoreRevision: 1
        )
        try ProviderHandoffGatewayStateMachine.quiesce(
            tokenID: token.tokenID,
            expectedTokenRevision: 1,
            expectations: expectations(token: token),
            in: &state,
            expectedStoreRevision: 2
        )

        try ProviderHandoffGatewayStateMachine.beginAbort(
            tokenID: token.tokenID,
            expectedTokenRevision: 2,
            in: &state,
            expectedStoreRevision: 3
        )

        #expect(state.storeRevision == 4)
        #expect(state.transactions[0].token.tokenRevision == 3)
        #expect(state.transactions[0].token.phase == .aborting)
        #expect(state.transactions[0].token.importedParts == nil)
        try ProviderHandoffGatewayStateMachine.validate(state)
    }

    @Test
    func `gateway revisions fail closed at UInt64 max without mutation`() throws {
        var storeBound = try initialState()
        storeBound.storeRevision = UInt64.max
        let storeSnapshot = storeBound
        #expect(throws: ProviderHandoffGatewayStateError.revisionOverflow) {
            try ProviderHandoffGatewayStateMachine.begin(
                handoffToken(),
                in: &storeBound,
                expectedStoreRevision: UInt64.max
            )
        }
        #expect(storeBound == storeSnapshot)

        var tokenBound = try initialState()
        let token = handoffToken()
        try ProviderHandoffGatewayStateMachine.begin(
            token,
            in: &tokenBound,
            expectedStoreRevision: 1
        )
        tokenBound.transactions[0].token.tokenRevision = UInt64.max
        let tokenSnapshot = tokenBound
        #expect(throws: ProviderHandoffGatewayStateError.revisionOverflow) {
            try ProviderHandoffGatewayStateMachine.quiesce(
                tokenID: token.tokenID,
                expectedTokenRevision: UInt64.max,
                expectations: expectations(token: token),
                in: &tokenBound,
                expectedStoreRevision: 2
            )
        }
        #expect(tokenBound == tokenSnapshot)
    }

    @Test
    func `gateway store detects payload mutation before decoding authority state`() throws {
        try withStore { store, root in
            _ = try store.loadOrCreate(initial: initialState())
            let stateURL = root.appendingPathComponent(
                ProviderHandoffGatewayStore.stateFileName
            )
            let encoded = try Data(contentsOf: stateURL)
            var object = try #require(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            var payload = try #require(object["payload"] as? String)
            let index = payload.startIndex
            payload.replaceSubrange(index ... index, with: payload[index] == "A" ? "B" : "A")
            object["payload"] = payload
            let changed = try JSONSerialization.data(withJSONObject: object)
            try changed.write(to: stateURL)
            #expect(chmod(stateURL.path, S_IRUSR | S_IWUSR) == 0)

            #expect(throws: ProviderHandoffGatewayStoreError.integrityMismatch) {
                try store.load()
            }
        }
    }

    private func initialState() throws -> ProviderHandoffGatewayStateV1 {
        try ProviderHandoffGatewayStateMachine.initialState(
            providerSelection: ProviderHandoffProviderSelectionRecordV1(
                selectionRevision: 1,
                selectedProviderFingerprint: "sha256:source-provider",
                selectedStateRootUUID: sourceRoot,
                providerRegistrationDigestSHA256: String(repeating: "a", count: 64),
                trustRegistryRevision: 1
            ),
            socketDiscovery: ProviderHandoffSocketDiscoveryRecordV1(
                discoveryRevision: 1,
                socketInstanceUUID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                ownerUID: UInt32(getuid()),
                minimumEngineAPIVersion: "1.44",
                maximumEngineAPIVersion: "1.53",
                selectedProviderFingerprint: "sha256:source-provider",
                selectedStateRootUUID: sourceRoot
            )
        )
    }

    private func handoffToken(
        tokenID: String = "token-1"
    ) -> ProviderHandoffTokenV1 {
        ProviderHandoffTokenV1(
            tokenID: tokenID,
            tokenRevision: 1,
            orderedSourceStateRootUUIDs: [sourceRoot],
            destinationProviderFingerprint: "sha256:destination-provider",
            destinationStateRootUUID: destinationRoot,
            trustRegistryRevision: 1,
            resultingAuthorityLineageUUID: resultingLineage,
            resultingLineageDigestKeyVersion: 2,
            phase: .draining,
            preCommitRootExpectations: [],
            destinationKeyPossessionProofDigestsSHA256: [],
            manifestID: "manifest-1"
        )
    }

    private func expectations(
        token: ProviderHandoffTokenV1
    ) throws -> [ProviderHandoffHeaderExpectationV1] {
        try [
            expectation(
                role: .source,
                root: sourceRoot,
                lineage: sourceLineage,
                stagedLineage: nil,
                provider: "sha256:source-provider",
                expectedState: .sourceQuiesced,
                abortState: .destinationActive,
                token: token,
                snapshot: "source-checkpoint",
                controllers: [
                    ProviderHandoffControllerRevisionV1(
                        controllerID: "logging",
                        revision: 7,
                        canonicalStateDigestSHA256: String(repeating: "b", count: 64)
                    )
                ]
            ),
            expectation(
                role: .destination,
                root: destinationRoot,
                lineage: destinationLineage,
                stagedLineage: resultingLineage,
                provider: nil,
                expectedState: .destinationStaged,
                abortState: .none,
                token: token,
                snapshot: nil,
                controllers: []
            )
        ]
    }

    private func expectation(
        role: ProviderHandoffRootRoleV1,
        root: String,
        lineage: String,
        stagedLineage: String?,
        provider: String?,
        expectedState: StateRootHandoffStateV1,
        abortState: StateRootHandoffStateV1,
        token: ProviderHandoffTokenV1,
        snapshot: String?,
        controllers: [ProviderHandoffControllerRevisionV1]
    ) throws -> ProviderHandoffHeaderExpectationV1 {
        let expectedHeader = StateRootHeaderV1(
            stateRootUUID: root,
            authorityLineageUUID: lineage,
            stagedAuthorityLineageUUID: stagedLineage,
            currentDataSchemaVersion: 1,
            minimumWriterSchemaVersion: 1,
            writerEpoch: 4,
            selectedProviderFingerprint: provider,
            handoffState: expectedState,
            activeHandoffTokenID: token.tokenID,
            handoffChainHeadDigest: nil,
            lineageDigestKeyVersion: 1
        )
        let abortHeader = StateRootHeaderV1(
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
            lineageDigestKeyVersion: 1
        )
        var preCommitVector = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 10,
            snapshotCheckpointID: snapshot,
            controllerRevisions: controllers,
            revisionVectorDigestSHA256: String(repeating: "0", count: 64)
        )
        preCommitVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections.revisionVectorDigest(preCommitVector)
        var abortVector = ProviderHandoffRevisionVectorV1(
            stateRootUUID: root,
            rootStoreRevision: 11,
            snapshotCheckpointID: snapshot,
            controllerRevisions: controllers,
            revisionVectorDigestSHA256: String(repeating: "0", count: 64)
        )
        abortVector.revisionVectorDigestSHA256 =
            try ProviderHandoffProjections.revisionVectorDigest(abortVector)
        return try ProviderHandoffHeaderExpectationV1(
            role: role,
            stateRootUUID: root,
            expectedHeader: expectedHeader,
            expectedHeaderDigestSHA256: ProviderHandoffProjections.stateRootHeaderDigest(
                expectedHeader
            ),
            preCommitRevisionVector: preCommitVector,
            abortHeader: abortHeader,
            abortHeaderDigestSHA256: ProviderHandoffProjections.stateRootHeaderDigest(
                abortHeader
            ),
            abortRevisionVector: abortVector
        )
    }

    private func withStore(
        _ body: (ProviderHandoffGatewayStore, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "container-engine-handoff-store-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ProviderHandoffGatewayStore(root: root), root)
    }

    private var sourceRoot: String {
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }

    private var destinationRoot: String {
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    }

    private var sourceLineage: String {
        "11111111-1111-4111-8111-111111111111"
    }

    private var destinationLineage: String {
        "22222222-2222-4222-8222-222222222222"
    }

    private var resultingLineage: String {
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    }
}
