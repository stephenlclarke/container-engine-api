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
import Testing

@testable import ContainerEngineRuntimeSPI

struct ProviderHandoffPartStagingStoreTests {
    @Test
    func `declare replays an advanced record and rejects changed immutable identity`() throws {
        try withTemporaryDirectory { root in
            let store = ProviderHandoffPartStagingStore(root: root)
            var record = try store.declare(try makeDeclared())
            record = try store.update(
                tokenID: record.tokenID,
                manifestID: record.manifestID,
                partKind: record.partKind,
                expectedStagingRevision: record.stagingRevision
            ) {
                try ProviderHandoffPartStagingStateMachine.beginRetrieval(
                    &$0,
                    expectedRevision: record.stagingRevision
                )
            }

            #expect(try store.declare(try makeDeclared()) == record)
            let changed = try ProviderHandoffPartStagingStateMachine.declared(
                tokenID: record.tokenID,
                manifestID: record.manifestID,
                manifestDigest: String(repeating: "b", count: 64),
                partKind: record.partKind,
                bundleObjectID: record.bundleObjectID,
                payloadDescriptorDigestSHA256:
                    record.payloadDescriptorDigestSHA256
            )
            #expect(
                throws: ProviderHandoffPartStagingStoreError.duplicateRecord
            ) {
                try store.declare(changed)
            }
            #expect(try store.records() == [record])
        }
    }

    @Test
    func `store persists CAS transitions and exact replay`() throws {
        try withTemporaryDirectory { root in
            let store = ProviderHandoffPartStagingStore(root: root)
            let declared = try makeDeclared()
            #expect(try store.declare(declared) == declared)
            #expect(try store.declare(declared) == declared)

            let retrieving = try store.update(
                tokenID: declared.tokenID,
                manifestID: declared.manifestID,
                partKind: declared.partKind,
                expectedStagingRevision: 1
            ) {
                try ProviderHandoffPartStagingStateMachine.beginRetrieval(
                    &$0,
                    expectedRevision: 1
                )
            }
            #expect(retrieving.state == .retrieving)
            #expect(
                try store.load(
                    tokenID: declared.tokenID,
                    manifestID: declared.manifestID,
                    partKind: declared.partKind
                ) == retrieving
            )
            #expect(
                throws: ProviderHandoffPartStagingStoreError.revisionMismatch(
                    expected: 1,
                    actual: 2
                )
            ) {
                _ = try store.update(
                    tokenID: declared.tokenID,
                    manifestID: declared.manifestID,
                    partKind: declared.partKind,
                    expectedStagingRevision: 1
                ) { _ in }
            }
        }
    }

    @Test
    func `store rejects another descriptor for the same part identity`() throws {
        try withTemporaryDirectory { root in
            let store = ProviderHandoffPartStagingStore(root: root)
            let declared = try makeDeclared()
            _ = try store.declare(declared)
            var conflicting = declared
            conflicting.bundleObjectID = "sha256:\(digest("other-bundle"))"
            #expect(throws: ProviderHandoffPartStagingStoreError.duplicateRecord) {
                _ = try store.declare(conflicting)
            }
        }
    }

    private func makeDeclared() throws -> ProviderHandoffPartStagingRecordV1 {
        try ProviderHandoffPartStagingStateMachine.declared(
            tokenID: "token-1",
            manifestID: "manifest-1",
            manifestDigest: digest("manifest"),
            partKind: .logging,
            bundleObjectID: "sha256:\(digest("bundle"))",
            payloadDescriptorDigestSHA256: digest("descriptor")
        )
    }

    private func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-handoff-staging-store-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }
}
