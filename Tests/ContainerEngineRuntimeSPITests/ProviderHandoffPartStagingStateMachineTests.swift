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

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

struct ProviderHandoffPartStagingStateMachineTests {
    @Test
    func `sealed import advances once and compensates exact receipt`() throws {
        var record = try declared()
        try ProviderHandoffPartStagingStateMachine.beginRetrieval(
            &record,
            expectedRevision: 1
        )
        try ProviderHandoffPartStagingStateMachine.recordReceivedRanges(
            [
                .init(lowerBound: 8, upperBoundExclusive: 16),
                .init(lowerBound: 0, upperBoundExclusive: 8)
            ],
            transportByteLength: 16,
            in: &record,
            expectedRevision: 2
        )
        #expect(
            record.receivedRanges == [
                .init(lowerBound: 0, upperBoundExclusive: 16)
            ]
        )
        try ProviderHandoffPartStagingStateMachine.recordTransportVerified(
            transportDigestSHA256: digest("transport"),
            transportByteLength: 16,
            in: &record,
            expectedRevision: 3
        )
        try ProviderHandoffPartStagingStateMachine.recordDecrypted(
            in: &record,
            expectedRevision: 4
        )
        let source = ProviderHandoffSourceDigestVerificationV1(
            sourceStateRootUUID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            authorityLineageUUID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            lineageDigestKeyVersion: 4,
            computedSourceDigestHMACSHA256: digest("source")
        )
        try ProviderHandoffPartStagingStateMachine.recordContentVerified(
            canonicalContentDigest: digest("content"),
            sourceDigestVerifications: [source],
            protection: .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1,
            in: &record,
            expectedRevision: 5
        )
        try ProviderHandoffPartStagingStateMachine.recordImported(
            receiptDigestSHA256: digest("receipt"),
            in: &record,
            expectedRevision: 6
        )
        let importedRevision = record.stagingRevision
        try ProviderHandoffPartStagingStateMachine.recordImported(
            receiptDigestSHA256: digest("receipt"),
            in: &record,
            expectedRevision: importedRevision
        )
        #expect(record.stagingRevision == importedRevision)
        try ProviderHandoffPartStagingStateMachine.requireCompensation(
            receiptDigestSHA256: digest("receipt"),
            in: &record,
            expectedRevision: importedRevision
        )
        try ProviderHandoffPartStagingStateMachine.recordCompensated(
            in: &record,
            expectedRevision: importedRevision + 1
        )
        #expect(record.state == .compensated)
        #expect(record.stagedImportReceiptDigestSHA256 == digest("receipt"))
        try ProviderHandoffPartStagingStateMachine.validate(record)
    }

    @Test
    func `authenticated payload skips decryption and rejects incomplete transport`() throws {
        var record = try declared()
        try ProviderHandoffPartStagingStateMachine.beginRetrieval(
            &record,
            expectedRevision: 1
        )
        try ProviderHandoffPartStagingStateMachine.recordReceivedRanges(
            [.init(lowerBound: 0, upperBoundExclusive: 7)],
            transportByteLength: 8,
            in: &record,
            expectedRevision: 2
        )
        #expect(throws: ProviderHandoffPartStagingError.transportIncomplete) {
            try ProviderHandoffPartStagingStateMachine.recordTransportVerified(
                transportDigestSHA256: digest("transport"),
                transportByteLength: 8,
                in: &record,
                expectedRevision: 3
            )
        }
        try ProviderHandoffPartStagingStateMachine.recordReceivedRanges(
            [.init(lowerBound: 7, upperBoundExclusive: 8)],
            transportByteLength: 8,
            in: &record,
            expectedRevision: 3
        )
        try ProviderHandoffPartStagingStateMachine.recordTransportVerified(
            transportDigestSHA256: digest("transport"),
            transportByteLength: 8,
            in: &record,
            expectedRevision: 4
        )
        try ProviderHandoffPartStagingStateMachine.recordContentVerified(
            canonicalContentDigest: digest("content"),
            sourceDigestVerifications: [],
            protection: .authenticatedPlaintext,
            in: &record,
            expectedRevision: 5
        )
        #expect(record.state == .contentVerified)
    }

    private func declared() throws -> ProviderHandoffPartStagingRecordV1 {
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
}
