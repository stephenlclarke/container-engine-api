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

public enum ProviderHandoffPartStagingError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case boundsExceeded
    case immutableIdentityMismatch
    case invalidRecord
    case invalidTransition(
        ProviderHandoffPartStagingStateV1,
        ProviderHandoffPartStagingStateV1
    )
    case receiptMismatch
    case revisionMismatch(expected: UInt64, actual: UInt64)
    case transportIncomplete

    public var description: String {
        switch self {
        case .boundsExceeded:
            "provider handoff part staging range exceeds the payload bound"
        case .immutableIdentityMismatch:
            "provider handoff part staging immutable identity changed"
        case .invalidRecord:
            "provider handoff part staging record is invalid"
        case let .invalidTransition(from, to):
            "provider handoff part staging transition \(from.rawValue) -> \(to.rawValue) is invalid"
        case .receiptMismatch:
            "provider handoff part staging receipt conflicts with the durable record"
        case let .revisionMismatch(expected, actual):
            "provider handoff part staging revision mismatch: expected \(expected), found \(actual)"
        case .transportIncomplete:
            "provider handoff part staging transport is incomplete"
        }
    }
}

public enum ProviderHandoffPartStagingStateMachine {
    public static func declared(
        tokenID: String,
        manifestID: String,
        manifestDigest: String,
        partKind: ProviderHandoffPartKindV1,
        bundleObjectID: String,
        payloadDescriptorDigestSHA256: String
    ) throws -> ProviderHandoffPartStagingRecordV1 {
        let record = ProviderHandoffPartStagingRecordV1(
            tokenID: tokenID,
            manifestID: manifestID,
            manifestDigest: manifestDigest,
            partKind: partKind,
            bundleObjectID: bundleObjectID,
            payloadDescriptorDigestSHA256: payloadDescriptorDigestSHA256,
            stagingRevision: 1,
            state: .declared
        )
        try validate(record)
        return record
    }

    public static func beginRetrieval(
        _ record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        if record.state == .retrieving {
            return
        }
        guard record.state == .declared else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .retrieving
            )
        }
        record.state = .retrieving
        try advance(&record)
    }

    public static func recordReceivedRanges(
        _ ranges: [ProviderHandoffByteRangeV1],
        transportByteLength: UInt64,
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        guard record.state == .retrieving else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .retrieving
            )
        }
        let normalized = try normalize(
            record.receivedRanges + ranges,
            transportByteLength: transportByteLength
        )
        if normalized == record.receivedRanges {
            return
        }
        record.receivedRanges = normalized
        try advance(&record)
    }

    public static func recordTransportVerified(
        transportDigestSHA256: String,
        transportByteLength: UInt64,
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        _ = try ProviderHandoffDigest.parseSHA256(transportDigestSHA256)
        guard transportByteLength > 0 else {
            throw ProviderHandoffPartStagingError.boundsExceeded
        }
        if record.state == .transportVerified,
            record.verifiedTransportDigestSHA256 == transportDigestSHA256
        {
            return
        }
        guard record.state == .retrieving else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .transportVerified
            )
        }
        guard
            record.receivedRanges
                == [
                    ProviderHandoffByteRangeV1(
                        lowerBound: 0,
                        upperBoundExclusive: transportByteLength
                    )
                ]
        else {
            throw ProviderHandoffPartStagingError.transportIncomplete
        }
        record.verifiedTransportDigestSHA256 = transportDigestSHA256
        record.state = .transportVerified
        record.lastFailureClass = nil
        try advance(&record)
    }

    public static func recordDecrypted(
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        if record.state == .decrypted {
            return
        }
        guard record.state == .transportVerified else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .decrypted
            )
        }
        record.state = .decrypted
        record.lastFailureClass = nil
        try advance(&record)
    }

    public static func recordContentVerified(
        canonicalContentDigest: String,
        sourceDigestVerifications: [ProviderHandoffSourceDigestVerificationV1],
        protection: ProviderHandoffPayloadProtectionV1,
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        _ = try ProviderHandoffDigest.parseSHA256(canonicalContentDigest)
        try validateSourceVerifications(sourceDigestVerifications)
        switch protection {
        case .authenticatedPlaintext:
            guard sourceDigestVerifications.isEmpty else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
        case .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1,
            .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2:
            guard !sourceDigestVerifications.isEmpty else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
        }
        if record.state == .contentVerified,
            record.verifiedCanonicalContentDigest == canonicalContentDigest,
            record.sourceDigestVerifications == sourceDigestVerifications
        {
            return
        }
        let expectedSourceState: ProviderHandoffPartStagingStateV1 =
            protection == .authenticatedPlaintext ? .transportVerified : .decrypted
        guard record.state == expectedSourceState else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .contentVerified
            )
        }
        record.sourceDigestVerifications = sourceDigestVerifications
        record.verifiedCanonicalContentDigest = canonicalContentDigest
        record.state = .contentVerified
        record.lastFailureClass = nil
        try advance(&record)
    }

    public static func recordImported(
        receiptDigestSHA256: String,
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        _ = try ProviderHandoffDigest.parseSHA256(receiptDigestSHA256)
        if record.state == .imported {
            guard record.stagedImportReceiptDigestSHA256 == receiptDigestSHA256 else {
                throw ProviderHandoffPartStagingError.receiptMismatch
            }
            return
        }
        guard record.state == .contentVerified else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .imported
            )
        }
        record.stagedImportReceiptDigestSHA256 = receiptDigestSHA256
        record.state = .imported
        record.lastFailureClass = nil
        try advance(&record)
    }

    public static func requireCompensation(
        receiptDigestSHA256: String,
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        _ = try ProviderHandoffDigest.parseSHA256(receiptDigestSHA256)
        if record.state == .compensationRequired {
            guard record.stagedImportReceiptDigestSHA256 == receiptDigestSHA256 else {
                throw ProviderHandoffPartStagingError.receiptMismatch
            }
            return
        }
        guard record.state == .contentVerified || record.state == .imported else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .compensationRequired
            )
        }
        if let existing = record.stagedImportReceiptDigestSHA256,
            existing != receiptDigestSHA256
        {
            throw ProviderHandoffPartStagingError.receiptMismatch
        }
        record.stagedImportReceiptDigestSHA256 = receiptDigestSHA256
        record.state = .compensationRequired
        record.lastFailureClass = nil
        try advance(&record)
    }

    public static func recordCompensated(
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        if record.state == .compensated {
            return
        }
        guard record.state == .compensationRequired else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                .compensated
            )
        }
        record.state = .compensated
        record.lastFailureClass = nil
        try advance(&record)
    }

    public static func recordFailure(
        _ failure: ProviderHandoffPartStagingFailureClassV1,
        in record: inout ProviderHandoffPartStagingRecordV1,
        expectedRevision: UInt64
    ) throws {
        try checkRevision(record, expected: expectedRevision)
        guard record.state != .compensated else {
            throw ProviderHandoffPartStagingError.invalidTransition(
                record.state,
                record.state
            )
        }
        if record.lastFailureClass == failure {
            return
        }
        record.lastFailureClass = failure
        try advance(&record)
    }

    public static func validate(
        _ record: ProviderHandoffPartStagingRecordV1
    ) throws {
        guard
            record.schemaVersion == 1,
            !record.tokenID.isEmpty,
            !record.manifestID.isEmpty,
            record.stagingRevision > 0,
            record.bundleObjectID.hasPrefix("sha256:"),
            record.receivedRanges == normalized(record.receivedRanges)
        else {
            throw ProviderHandoffPartStagingError.invalidRecord
        }
        _ = try ProviderHandoffDigest.parseSHA256(record.manifestDigest)
        _ = try ProviderHandoffDigest.parseSHA256(
            String(record.bundleObjectID.dropFirst("sha256:".count))
        )
        _ = try ProviderHandoffDigest.parseSHA256(
            record.payloadDescriptorDigestSHA256
        )
        if let digest = record.verifiedTransportDigestSHA256 {
            _ = try ProviderHandoffDigest.parseSHA256(digest)
        }
        if let digest = record.verifiedCanonicalContentDigest {
            _ = try ProviderHandoffDigest.parseSHA256(digest)
        }
        if let digest = record.stagedImportReceiptDigestSHA256 {
            _ = try ProviderHandoffDigest.parseSHA256(digest)
        }
        try validateSourceVerifications(record.sourceDigestVerifications)

        let hasTransport = record.verifiedTransportDigestSHA256 != nil
        let hasContent = record.verifiedCanonicalContentDigest != nil
        let hasReceipt = record.stagedImportReceiptDigestSHA256 != nil
        switch record.state {
        case .declared:
            guard
                record.receivedRanges.isEmpty,
                !hasTransport,
                !hasContent,
                !hasReceipt,
                record.sourceDigestVerifications.isEmpty
            else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
        case .retrieving:
            guard
                !hasTransport,
                !hasContent,
                !hasReceipt,
                record.sourceDigestVerifications.isEmpty
            else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
        case .transportVerified, .decrypted:
            guard
                hasTransport,
                !hasContent,
                !hasReceipt,
                record.sourceDigestVerifications.isEmpty
            else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
        case .contentVerified:
            guard hasTransport, hasContent, !hasReceipt else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
        case .imported, .compensationRequired, .compensated:
            guard hasTransport, hasContent, hasReceipt else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
        }
    }

    public static func validateImmutableIdentity(
        _ record: ProviderHandoffPartStagingRecordV1,
        matches expected: ProviderHandoffPartStagingRecordV1
    ) throws {
        guard
            record.schemaVersion == expected.schemaVersion,
            record.tokenID == expected.tokenID,
            record.manifestID == expected.manifestID,
            record.manifestDigest == expected.manifestDigest,
            record.partKind == expected.partKind,
            record.bundleObjectID == expected.bundleObjectID,
            record.payloadDescriptorDigestSHA256
                == expected.payloadDescriptorDigestSHA256
        else {
            throw ProviderHandoffPartStagingError.immutableIdentityMismatch
        }
    }

    private static func normalize(
        _ ranges: [ProviderHandoffByteRangeV1],
        transportByteLength: UInt64
    ) throws -> [ProviderHandoffByteRangeV1] {
        for range in ranges {
            guard
                range.lowerBound < range.upperBoundExclusive,
                range.upperBoundExclusive <= transportByteLength
            else {
                throw ProviderHandoffPartStagingError.boundsExceeded
            }
        }
        return normalized(ranges)
    }

    private static func normalized(
        _ ranges: [ProviderHandoffByteRangeV1]
    ) -> [ProviderHandoffByteRangeV1] {
        let ordered = ranges.sorted {
            if $0.lowerBound != $1.lowerBound {
                return $0.lowerBound < $1.lowerBound
            }
            return $0.upperBoundExclusive < $1.upperBoundExclusive
        }
        var result: [ProviderHandoffByteRangeV1] = []
        for range in ordered where range.lowerBound < range.upperBoundExclusive {
            if let last = result.last,
                range.lowerBound <= last.upperBoundExclusive
            {
                result[result.count - 1].upperBoundExclusive = max(
                    last.upperBoundExclusive,
                    range.upperBoundExclusive
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func validateSourceVerifications(
        _ values: [ProviderHandoffSourceDigestVerificationV1]
    ) throws {
        guard
            values.map(\.sourceStateRootUUID).count
                == Set(values.map(\.sourceStateRootUUID)).count
        else {
            throw ProviderHandoffPartStagingError.invalidRecord
        }
        for value in values {
            guard
                canonicalUUID(value.sourceStateRootUUID) != nil,
                canonicalUUID(value.authorityLineageUUID) != nil,
                value.lineageDigestKeyVersion > 0
            else {
                throw ProviderHandoffPartStagingError.invalidRecord
            }
            _ = try ProviderHandoffDigest.parseSHA256(
                value.computedSourceDigestHMACSHA256
            )
        }
    }

    private static func checkRevision(
        _ record: ProviderHandoffPartStagingRecordV1,
        expected: UInt64
    ) throws {
        guard record.stagingRevision == expected else {
            throw ProviderHandoffPartStagingError.revisionMismatch(
                expected: expected,
                actual: record.stagingRevision
            )
        }
    }

    private static func advance(
        _ record: inout ProviderHandoffPartStagingRecordV1
    ) throws {
        guard record.stagingRevision < UInt64.max else {
            throw ProviderHandoffPartStagingError.invalidRecord
        }
        record.stagingRevision += 1
        try validate(record)
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard
            let uuid = UUID(uuidString: value),
            uuid.uuidString.lowercased() == value
        else {
            return nil
        }
        return uuid
    }
}
