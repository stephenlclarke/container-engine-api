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

public enum ProviderHandoffProjectionError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case duplicateController(String)
    case duplicateRoot(String)
    case invalidDigest(String)
    case invalidHeader(String)
    case invalidOrder
    case invalidRecord
    case invalidUUID(String)

    public var description: String {
        switch self {
        case let .duplicateController(identifier):
            "provider handoff revision vector contains duplicate controller \(identifier)"
        case let .duplicateRoot(identifier):
            "provider handoff contains duplicate state root \(identifier)"
        case let .invalidDigest(value):
            "provider handoff digest is invalid: \(value)"
        case let .invalidHeader(identifier):
            "provider handoff state-root header is invalid: \(identifier)"
        case .invalidOrder:
            "provider handoff record is not in canonical order"
        case .invalidRecord:
            "provider handoff record is invalid"
        case let .invalidUUID(value):
            "provider handoff UUID is not canonical: \(value)"
        }
    }
}

public enum ProviderHandoffProjections {
    public static func stateRootHeaderDigest(_ header: StateRootHeaderV1) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-state-root-header-v1",
            projection: stateRootHeader(header)
        )
    }

    public static func revisionVectorDigest(
        _ vector: ProviderHandoffRevisionVectorV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-revision-vector-v1",
            projection: revisionVector(vector)
        )
    }

    public static func providerSelectionDigest(
        _ record: ProviderHandoffProviderSelectionRecordV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-provider-selection-v1",
            projection: providerSelection(record)
        )
    }

    public static func socketDiscoveryDigest(
        _ record: ProviderHandoffSocketDiscoveryRecordV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-socket-discovery-v1",
            projection: socketDiscovery(record)
        )
    }

    public static func commitIntentDigest(
        _ intent: ProviderHandoffCommitIntentV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-commit-intent-v1",
            projection: commitIntent(intent)
        )
    }

    public static func payloadDescriptorDigest(
        _ descriptor: ProviderHandoffPayloadDescriptorV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-payload-descriptor-v1",
            projection: payloadDescriptor(descriptor)
        )
    }

    public static func chainHeadDigest(
        commitDigestSHA256: String,
        orderedPreCommitHeaders: [StateRootHeaderV1]
    ) throws -> String {
        var seen = Set<String>()
        let roots = try orderedPreCommitHeaders.map { header in
            try validateCanonicalUUID(header.stateRootUUID)
            guard seen.insert(header.stateRootUUID).inserted else {
                throw ProviderHandoffProjectionError.duplicateRoot(
                    header.stateRootUUID
                )
            }
            return try ProviderHandoffCanonicalValue.map([
                .init(
                    "handoffChainHeadDigestSHA256",
                    optionalDigest(header.handoffChainHeadDigest)
                ),
                .init("stateRootUUID", .textString(header.stateRootUUID))
            ])
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-chain-head-v1",
            projection: .map([
                .init(
                    "commitDigestSHA256",
                    .byteString(digestBytes(commitDigestSHA256))
                ),
                .init("orderedPriorChainHeads", .array(roots))
            ])
        )
    }

    public static func rootPrepareDigest(
        _ record: ProviderHandoffRootPrepareRecordV1
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-root-prepare-v1",
            projection: .map([
                .init("commitDigestSHA256", .byteString(digestBytes(record.commitDigestSHA256))),
                .init("expectedHeaderDigestSHA256", .byteString(digestBytes(record.expectedHeaderDigestSHA256))),
                .init("manifestID", .textString(record.manifestID)),
                .init("postCommitHeaderDigestSHA256", .byteString(digestBytes(record.postCommitHeaderDigestSHA256))),
                .init("postCommitRevisionVectorDigestSHA256", .byteString(digestBytes(record.postCommitRevisionVectorDigestSHA256))),
                .init("preCommitRevisionVectorDigestSHA256", .byteString(digestBytes(record.preCommitRevisionVectorDigestSHA256))),
                .init("prepareRevision", .unsigned(record.prepareRevision)),
                .init("role", .textString(record.role.rawValue)),
                .init("schemaVersion", .unsigned(UInt64(record.schemaVersion))),
                .init("stateRootUUID", .textString(record.stateRootUUID)),
                .init("tokenID", .textString(record.tokenID))
            ])
        )
    }

    public static func terminalOutcomeDigest(
        _ outcome: ProviderHandoffTerminalOutcomeV1
    ) throws -> String {
        guard outcome.phase == .aborted || outcome.phase == .complete else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try ProviderHandoffDigest.domain(
            "container-handoff-outcome-v1",
            projection: .map([
                .init("manifestDigest", optionalDigest(outcome.manifestDigest)),
                .init("manifestID", .textString(outcome.manifestID)),
                .init("phase", .textString(outcome.phase.rawValue)),
                .init("roots", .array(outcome.roots.map(terminalRoot))),
                .init("schemaVersion", .unsigned(UInt64(outcome.schemaVersion))),
                .init("tokenID", .textString(outcome.tokenID))
            ])
        )
    }

    public static func stateRootHeader(
        _ header: StateRootHeaderV1
    ) throws -> ProviderHandoffCanonicalValue {
        try validateHeader(header)
        return try .map([
            .init("activeHandoffTokenID", .optional(header.activeHandoffTokenID)),
            .init("authorityLineageUUID", .textString(header.authorityLineageUUID)),
            .init("currentDataSchemaVersion", .unsigned(UInt64(header.currentDataSchemaVersion))),
            .init("handoffChainHeadDigest", optionalDigest(header.handoffChainHeadDigest)),
            .init("handoffState", .textString(header.handoffState.rawValue)),
            .init("lineageDigestKeyVersion", .unsigned(header.lineageDigestKeyVersion)),
            .init("minimumWriterSchemaVersion", .unsigned(UInt64(header.minimumWriterSchemaVersion))),
            .init("schemaVersion", .unsigned(UInt64(header.schemaVersion))),
            .init("selectedProviderFingerprint", .optional(header.selectedProviderFingerprint)),
            .init("stagedAuthorityLineageUUID", .optional(header.stagedAuthorityLineageUUID)),
            .init("stateRootUUID", .textString(header.stateRootUUID)),
            .init("writerEpoch", .unsigned(header.writerEpoch))
        ])
    }

    public static func revisionVector(
        _ vector: ProviderHandoffRevisionVectorV1
    ) throws -> ProviderHandoffCanonicalValue {
        try validateCanonicalUUID(vector.stateRootUUID)
        var seen = Set<String>()
        for controller in vector.controllerRevisions {
            guard !controller.controllerID.isEmpty else {
                throw ProviderHandoffProjectionError.invalidRecord
            }
            guard seen.insert(controller.controllerID).inserted else {
                throw ProviderHandoffProjectionError.duplicateController(
                    controller.controllerID
                )
            }
            _ = try digestBytes(controller.canonicalStateDigestSHA256)
        }
        let sorted = vector.controllerRevisions.sorted {
            $0.controllerID.utf8.lexicographicallyPrecedes($1.controllerID.utf8)
        }
        guard sorted == vector.controllerRevisions else {
            throw ProviderHandoffProjectionError.invalidOrder
        }
        return try .map([
            .init(
                "controllerRevisions",
                .array(vector.controllerRevisions.map(controllerRevision))
            ),
            .init("rootStoreRevision", .unsigned(vector.rootStoreRevision)),
            .init("schemaVersion", .unsigned(UInt64(vector.schemaVersion))),
            .init("snapshotCheckpointID", .optional(vector.snapshotCheckpointID)),
            .init("stateRootUUID", .textString(vector.stateRootUUID))
        ])
    }

    public static func providerSelection(
        _ record: ProviderHandoffProviderSelectionRecordV1
    ) throws -> ProviderHandoffCanonicalValue {
        if let root = record.selectedStateRootUUID {
            try validateCanonicalUUID(root)
        }
        guard
            (record.selectedProviderFingerprint == nil)
            == (record.selectedStateRootUUID == nil),
            (record.selectedProviderFingerprint == nil)
            == (record.providerRegistrationDigestSHA256 == nil)
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try .map([
            .init("providerRegistrationDigestSHA256", optionalDigest(record.providerRegistrationDigestSHA256)),
            .init("schemaVersion", .unsigned(UInt64(record.schemaVersion))),
            .init("selectedProviderFingerprint", .optional(record.selectedProviderFingerprint)),
            .init("selectedStateRootUUID", .optional(record.selectedStateRootUUID)),
            .init("selectionRevision", .unsigned(record.selectionRevision)),
            .init("trustRegistryRevision", .unsigned(record.trustRegistryRevision))
        ])
    }

    public static func socketDiscovery(
        _ record: ProviderHandoffSocketDiscoveryRecordV1
    ) throws -> ProviderHandoffCanonicalValue {
        try validateCanonicalUUID(record.socketInstanceUUID)
        if let root = record.selectedStateRootUUID {
            try validateCanonicalUUID(root)
        }
        guard
            (record.selectedProviderFingerprint == nil)
            == (record.selectedStateRootUUID == nil),
            !record.minimumEngineAPIVersion.isEmpty,
            !record.maximumEngineAPIVersion.isEmpty
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return .map([
            .init("discoveryRevision", .unsigned(record.discoveryRevision)),
            .init("maximumEngineAPIVersion", .textString(record.maximumEngineAPIVersion)),
            .init("minimumEngineAPIVersion", .textString(record.minimumEngineAPIVersion)),
            .init("ownerUID", .unsigned(UInt64(record.ownerUID))),
            .init("schemaVersion", .unsigned(UInt64(record.schemaVersion))),
            .init("selectedProviderFingerprint", .optional(record.selectedProviderFingerprint)),
            .init("selectedStateRootUUID", .optional(record.selectedStateRootUUID)),
            .init("socketInstanceUUID", .textString(record.socketInstanceUUID))
        ])
    }

    public static func headerExpectation(
        _ expectation: ProviderHandoffHeaderExpectationV1
    ) throws -> ProviderHandoffCanonicalValue {
        try validateCanonicalUUID(expectation.stateRootUUID)
        guard
            expectation.expectedHeader.stateRootUUID == expectation.stateRootUUID,
            expectation.abortHeader.stateRootUUID == expectation.stateRootUUID,
            expectation.preCommitRevisionVector.stateRootUUID == expectation.stateRootUUID,
            expectation.abortRevisionVector.stateRootUUID == expectation.stateRootUUID,
            try stateRootHeaderDigest(expectation.expectedHeader)
            == expectation.expectedHeaderDigestSHA256,
            try stateRootHeaderDigest(expectation.abortHeader)
            == expectation.abortHeaderDigestSHA256,
            try revisionVectorDigest(expectation.preCommitRevisionVector)
            == expectation.preCommitRevisionVector.revisionVectorDigestSHA256,
            try revisionVectorDigest(expectation.abortRevisionVector)
            == expectation.abortRevisionVector.revisionVectorDigestSHA256
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try .map([
            .init("abortHeader", stateRootHeader(expectation.abortHeader)),
            .init("abortHeaderDigestSHA256", .byteString(digestBytes(expectation.abortHeaderDigestSHA256))),
            .init("abortRevisionVector", revisionVectorWithDigest(expectation.abortRevisionVector)),
            .init("expectedHeader", stateRootHeader(expectation.expectedHeader)),
            .init("expectedHeaderDigestSHA256", .byteString(digestBytes(expectation.expectedHeaderDigestSHA256))),
            .init("preCommitRevisionVector", revisionVectorWithDigest(expectation.preCommitRevisionVector)),
            .init("role", .textString(expectation.role.rawValue)),
            .init("schemaVersion", .unsigned(UInt64(expectation.schemaVersion))),
            .init("stateRootUUID", .textString(expectation.stateRootUUID))
        ])
    }

    public static func importExpectation(
        _ expectation: ProviderHandoffPartImportExpectationV1
    ) throws -> ProviderHandoffCanonicalValue {
        try .map([
            .init("partKind", .textString(expectation.partKind.rawValue)),
            .init("payloadDescriptorDigestSHA256", .byteString(digestBytes(expectation.payloadDescriptorDigestSHA256))),
            .init("stagedImportReceiptDigestSHA256", .byteString(digestBytes(expectation.stagedImportReceiptDigestSHA256)))
        ])
    }

    public static func payloadDescriptor(
        _ descriptor: ProviderHandoffPayloadDescriptorV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard
            descriptor.schemaVersion == 1,
            descriptor.canonicalEncoding == .deterministicCBORV1,
            descriptor.bundleObjectID == "sha256:\(descriptor.transportDigestSHA256)",
            descriptor.canonicalPlaintextByteLength > 0,
            descriptor.transportByteLength > 0
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        let encryption: ProviderHandoffCanonicalValue =
            if let value = descriptor.destinationEncryption {
                try .map([
                    .init("associatedDataDigestSHA256", .byteString(digestBytes(value.associatedDataDigestSHA256))),
                    .init("destinationKeyID", .textString(value.destinationKeyID)),
                    .init("destinationKeyPurpose", .textString(value.destinationKeyPurpose.rawValue)),
                    .init("encryptionAlgorithm", .textString(value.encryptionAlgorithm.rawValue)),
                    .init("ephemeralPublicKey", .byteString(value.ephemeralPublicKey)),
                    .init("nonce", .byteString(value.nonce))
                ])
            } else {
                .null
            }
        switch descriptor.protection {
        case .authenticatedPlaintext:
            guard
                descriptor.destinationEncryption == nil,
                descriptor.canonicalPlaintextByteLength == descriptor.transportByteLength,
                descriptor.canonicalContentDigest.algorithm == .sha256,
                descriptor.canonicalContentDigest.scope == .publicSHA256V1,
                descriptor.canonicalContentDigest.orderedSourceDigests.isEmpty
            else {
                throw ProviderHandoffProjectionError.invalidRecord
            }
        case .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1:
            guard
                let destination = descriptor.destinationEncryption,
                destination.encryptionAlgorithm
                == .x25519HKDFSHA256XChaCha20Poly1305V1,
                destination.destinationKeyPurpose == .destinationPayloadEncryption,
                destination.ephemeralPublicKey.count == 32,
                destination.nonce.count == 24,
                descriptor.canonicalContentDigest.algorithm != .sha256,
                descriptor.canonicalContentDigest.scope != .publicSHA256V1,
                !descriptor.canonicalContentDigest.orderedSourceDigests.isEmpty
            else {
                throw ProviderHandoffProjectionError.invalidRecord
            }
        case .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2:
            guard
                let destination = descriptor.destinationEncryption,
                destination.encryptionAlgorithm
                == .x25519HKDFSHA256XChaCha20Poly1305FramedV2,
                destination.destinationKeyPurpose == .destinationPayloadEncryption,
                destination.ephemeralPublicKey.count == 32,
                destination.nonce.count == 24,
                descriptor.canonicalContentDigest.algorithm != .sha256,
                descriptor.canonicalContentDigest.scope != .publicSHA256V1,
                !descriptor.canonicalContentDigest.orderedSourceDigests.isEmpty
            else {
                throw ProviderHandoffProjectionError.invalidRecord
            }
        }
        return try .map([
            .init("bundleObjectID", .textString(descriptor.bundleObjectID)),
            .init("canonicalContentDigest", canonicalContentDigest(descriptor.canonicalContentDigest)),
            .init("canonicalEncoding", .textString(descriptor.canonicalEncoding.rawValue)),
            .init("canonicalPlaintextByteLength", .unsigned(descriptor.canonicalPlaintextByteLength)),
            .init("destinationEncryption", encryption),
            .init("mediaType", .textString(descriptor.mediaType)),
            .init("protection", .textString(descriptor.protection.rawValue)),
            .init("schemaVersion", .unsigned(UInt64(descriptor.schemaVersion))),
            .init("transportByteLength", .unsigned(descriptor.transportByteLength)),
            .init("transportDigestSHA256", .byteString(digestBytes(descriptor.transportDigestSHA256)))
        ])
    }

    public static func commitIntent(
        _ intent: ProviderHandoffCommitIntentV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard
            intent.schemaVersion == 1,
            !intent.tokenID.isEmpty,
            !intent.manifestID.isEmpty,
            intent.authoritativeCommitRevision > 0,
            intent.resultingLineageDigestKeyVersion > 0,
            intent.resultingMinimumWriterSchemaVersion > 0
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        try validateCanonicalUUID(intent.resultingAuthorityLineageUUID)
        return try .map([
            .init("authoritativeCommitRevision", .unsigned(intent.authoritativeCommitRevision)),
            .init("destinationKeyPossessionProofDigestsSHA256", .array(intent.destinationKeyPossessionProofDigestsSHA256.map { try .byteString(digestBytes($0)) })),
            .init("importedParts", .array(intent.importedParts.map(importExpectation))),
            .init("manifestDigest", .byteString(digestBytes(intent.manifestDigest))),
            .init("manifestID", .textString(intent.manifestID)),
            .init("preCommitRootExpectations", .array(intent.preCommitRootExpectations.map(headerExpectation))),
            .init("providerSelection", providerSelectionExpectation(intent.providerSelection)),
            .init("resultingAuthorityLineageUUID", .textString(intent.resultingAuthorityLineageUUID)),
            .init("resultingLineageDigestKeyVersion", .unsigned(intent.resultingLineageDigestKeyVersion)),
            .init("resultingMinimumWriterSchemaVersion", .unsigned(UInt64(intent.resultingMinimumWriterSchemaVersion))),
            .init("schemaVersion", .unsigned(UInt64(intent.schemaVersion))),
            .init("socketSelection", socketSelectionExpectation(intent.socketSelection)),
            .init("tokenID", .textString(intent.tokenID)),
            .init("trustRegistryRevision", .unsigned(intent.trustRegistryRevision))
        ])
    }

    private static func controllerRevision(
        _ controller: ProviderHandoffControllerRevisionV1
    ) throws -> ProviderHandoffCanonicalValue {
        try .map([
            .init("canonicalStateDigestSHA256", .byteString(digestBytes(controller.canonicalStateDigestSHA256))),
            .init("controllerID", .textString(controller.controllerID)),
            .init("revision", .unsigned(controller.revision))
        ])
    }

    private static func canonicalContentDigest(
        _ digest: ProviderHandoffCanonicalContentDigestV1
    ) throws -> ProviderHandoffCanonicalValue {
        try .map([
            .init("algorithm", .textString(digest.algorithm.rawValue)),
            .init("digest", .byteString(digestBytes(digest.digest))),
            .init(
                "orderedSourceDigests",
                .array(digest.orderedSourceDigests.map(contentSourceDigest))
            ),
            .init("scope", .textString(digest.scope.rawValue))
        ])
    }

    private static func contentSourceDigest(
        _ digest: ProviderHandoffContentSourceDigestV1
    ) throws -> ProviderHandoffCanonicalValue {
        try .map([
            .init("authorityLineageUUID", .textString(digest.authorityLineageUUID)),
            .init("lineageDigestKeyVersion", .unsigned(digest.lineageDigestKeyVersion)),
            .init("orderedEntryIDs", .array(digest.orderedEntryIDs.map(ProviderHandoffCanonicalValue.textString))),
            .init("sourceDigestHMACSHA256", .byteString(digestBytes(digest.sourceDigestHMACSHA256))),
            .init("sourceStateRootUUID", .textString(digest.sourceStateRootUUID))
        ])
    }

    private static func revisionVectorWithDigest(
        _ vector: ProviderHandoffRevisionVectorV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard try revisionVectorDigest(vector) == vector.revisionVectorDigestSHA256 else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        guard case let .map(entries) = try revisionVector(vector) else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try .map(
            entries + [
                .init(
                    "revisionVectorDigestSHA256",
                    .byteString(digestBytes(vector.revisionVectorDigestSHA256))
                )
            ]
        )
    }

    private static func providerSelectionExpectation(
        _ expectation: ProviderHandoffProviderSelectionExpectationV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard
            try providerSelectionDigest(expectation.expectedRecord)
            == expectation.expectedRecordDigestSHA256,
            try providerSelectionDigest(expectation.resultingRecord)
            == expectation.resultingRecordDigestSHA256
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try .map([
            .init("expectedRecord", providerSelection(expectation.expectedRecord)),
            .init("expectedRecordDigestSHA256", .byteString(digestBytes(expectation.expectedRecordDigestSHA256))),
            .init("resultingRecord", providerSelection(expectation.resultingRecord)),
            .init("resultingRecordDigestSHA256", .byteString(digestBytes(expectation.resultingRecordDigestSHA256)))
        ])
    }

    private static func socketSelectionExpectation(
        _ expectation: ProviderHandoffSocketSelectionExpectationV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard
            try socketDiscoveryDigest(expectation.expectedRecord)
            == expectation.expectedRecordDigestSHA256,
            try socketDiscoveryDigest(expectation.resultingRecord)
            == expectation.resultingRecordDigestSHA256
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try .map([
            .init("expectedRecord", socketDiscovery(expectation.expectedRecord)),
            .init("expectedRecordDigestSHA256", .byteString(digestBytes(expectation.expectedRecordDigestSHA256))),
            .init("resultingRecord", socketDiscovery(expectation.resultingRecord)),
            .init("resultingRecordDigestSHA256", .byteString(digestBytes(expectation.resultingRecordDigestSHA256)))
        ])
    }

    private static func terminalRoot(
        _ root: ProviderHandoffTerminalRootV1
    ) throws -> ProviderHandoffCanonicalValue {
        guard
            root.stateRootUUID == root.terminalHeader.stateRootUUID,
            root.stateRootUUID == root.terminalRevisionVector.stateRootUUID,
            try stateRootHeaderDigest(root.terminalHeader)
            == root.terminalHeaderDigestSHA256,
            try revisionVectorDigest(root.terminalRevisionVector)
            == root.terminalRevisionVector.revisionVectorDigestSHA256
        else {
            throw ProviderHandoffProjectionError.invalidRecord
        }
        return try .map([
            .init("role", .textString(root.role.rawValue)),
            .init("stateRootUUID", .textString(root.stateRootUUID)),
            .init("terminalHeader", stateRootHeader(root.terminalHeader)),
            .init("terminalHeaderDigestSHA256", .byteString(digestBytes(root.terminalHeaderDigestSHA256))),
            .init("terminalRevisionVector", revisionVectorWithDigest(root.terminalRevisionVector))
        ])
    }

    private static func validateHeader(_ header: StateRootHeaderV1) throws {
        try validateCanonicalUUID(header.stateRootUUID)
        try validateCanonicalUUID(header.authorityLineageUUID)
        if let staged = header.stagedAuthorityLineageUUID {
            try validateCanonicalUUID(staged)
        }
        if let chain = header.handoffChainHeadDigest {
            _ = try digestBytes(chain)
        }
        guard
            header.schemaVersion == 1,
            header.currentDataSchemaVersion > 0,
            header.minimumWriterSchemaVersion > 0,
            header.lineageDigestKeyVersion > 0,
            (header.handoffState == .destinationStaged)
            == (header.stagedAuthorityLineageUUID != nil),
            requiresActiveToken(header.handoffState)
            == (header.activeHandoffTokenID != nil),
            header.handoffState != .sourceTransferred
            || header.handoffChainHeadDigest != nil
        else {
            throw ProviderHandoffProjectionError.invalidHeader(
                header.stateRootUUID
            )
        }
    }

    private static func requiresActiveToken(_ state: StateRootHandoffStateV1) -> Bool {
        switch state {
        case .sourceDraining, .sourceQuiesced, .destinationStaged,
             .destinationReconciling:
            true
        case .none, .sourceTransferred, .destinationActive:
            false
        }
    }

    private static func validateCanonicalUUID(_ value: String) throws {
        guard
            let identifier = UUID(uuidString: value),
            identifier.uuidString.lowercased() == value
        else {
            throw ProviderHandoffProjectionError.invalidUUID(value)
        }
    }

    private static func optionalDigest(_ value: String?) throws -> ProviderHandoffCanonicalValue {
        guard let value else { return .null }
        return try .byteString(digestBytes(value))
    }

    private static func digestBytes(_ value: String) throws -> Data {
        do {
            return try ProviderHandoffDigest.parseSHA256(value)
        } catch {
            throw ProviderHandoffProjectionError.invalidDigest(value)
        }
    }
}
