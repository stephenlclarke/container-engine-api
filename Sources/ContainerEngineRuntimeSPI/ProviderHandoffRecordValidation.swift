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

public struct ProviderHandoffValidatedManifestV1: Sendable {
    public let manifest: ProviderHandoffManifestV1
}

public struct ProviderHandoffValidatedCommitRecordV1: Sendable {
    public let record: ProviderHandoffCommitRecordV1
}

public struct ProviderHandoffValidatedTerminalOutcomeV1: Sendable {
    public let outcome: ProviderHandoffTerminalOutcomeV1
}

public enum ProviderHandoffRecordValidationError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidCommit
    case invalidManifest
    case invalidOutcome

    public var description: String {
        switch self {
        case .invalidCommit:
            "provider handoff commit record is invalid"
        case .invalidManifest:
            "provider handoff manifest is invalid"
        case .invalidOutcome:
            "provider handoff terminal outcome is invalid"
        }
    }
}

public enum ProviderHandoffRecordValidator {
    public static func validateManifest(
        _ manifest: ProviderHandoffManifestV1,
        possessionProofs: [ProviderHandoffValidatedPossessionProofV1],
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffValidatedManifestV1 {
        do {
            try validateManifestStructure(manifest)
            guard manifest.trustRegistryRevision == trustRegistry.registry.registryRevision else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }
            let proofDigests =
                possessionProofs
                .map(\.proofRecordDigestSHA256)
                .sorted()
            guard
                proofDigests == manifest.destinationKeyPossessionProofDigestsSHA256,
                Set(proofDigests).count == proofDigests.count
            else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }
            let requiredEncryptionKeys = try requiredEncryptionKeys(manifest)
            let proofKeys = possessionProofs.map {
                EncryptionKeyUse(
                    purpose: $0.proof.destinationKeyPurpose,
                    keyID: $0.proof.destinationKeyID
                )
            }.sorted {
                if $0.purpose.rawValue != $1.purpose.rawValue {
                    return $0.purpose.rawValue.utf8.lexicographicallyPrecedes(
                        $1.purpose.rawValue.utf8
                    )
                }
                return $0.keyID.utf8.lexicographicallyPrecedes($1.keyID.utf8)
            }
            guard
                proofKeys == requiredEncryptionKeys,
                possessionProofs.allSatisfy({ proof in
                    proof.proof.tokenID == manifest.tokenID
                        && proof.proof.manifestID == manifest.manifestID
                        && proof.proof.destinationProviderFingerprint
                            == manifest.destinationProviderFingerprint
                        && proof.proof.destinationStateRootUUID
                            == manifest.destinationStateRootUUID
                })
            else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }

            let sourceByRoot = Dictionary(
                uniqueKeysWithValues: manifest.sources.map {
                    ($0.stateRootUUID, $0.providerFingerprint)
                }
            )
            for envelope in manifest.destinationSealedLineageKeyEnvelopes {
                try ProviderHandoffLineageKeyEnvelopeCodec.verify(
                    envelope,
                    tokenID: manifest.tokenID,
                    manifestID: manifest.manifestID,
                    destinationProviderFingerprint: manifest.destinationProviderFingerprint,
                    destinationStateRootUUID: manifest.destinationStateRootUUID,
                    sourceProviderFingerprint: envelope.sourceStateRootUUID.flatMap {
                        sourceByRoot[$0]
                    },
                    trustRegistry: trustRegistry,
                    atUnixSeconds: atUnixSeconds
                )
            }
            for source in manifest.sources {
                let digest = try ProviderHandoffProjections.sourceManifestDigest(
                    source: source,
                    manifest: manifest
                )
                try trustRegistry.verify(
                    source.sourceSignature,
                    expectedPurpose: .sourceManifestSigning,
                    expectedRole: .sourceProvider,
                    providerFingerprint: source.providerFingerprint,
                    stateRootUUID: source.stateRootUUID,
                    projectionDigestSHA256: digest,
                    atUnixSeconds: atUnixSeconds
                )
            }
            let digest = try ProviderHandoffProjections.manifestDigest(manifest)
            guard digest == manifest.manifestDigest else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }
            try trustRegistry.verify(
                manifest.coordinatorSignature,
                expectedPurpose: .coordinatorManifestSigning,
                expectedRole: .gatewayCoordinator,
                providerFingerprint: nil,
                stateRootUUID: nil,
                projectionDigestSHA256: digest,
                atUnixSeconds: atUnixSeconds
            )
            return ProviderHandoffValidatedManifestV1(manifest: manifest)
        } catch let error as ProviderHandoffRecordValidationError {
            throw error
        } catch {
            throw ProviderHandoffRecordValidationError.invalidManifest
        }
    }

    public static func validateCommitRecord(
        _ record: ProviderHandoffCommitRecordV1,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffValidatedCommitRecordV1 {
        do {
            let derivedRoots = try derivePostCommitRoots(
                intent: record.intent,
                chainHeadDigestSHA256: record.handoffChainHeadDigestSHA256
            )
            guard
                record.schemaVersion == 1,
                record.intent.trustRegistryRevision
                    == trustRegistry.registry.registryRevision,
                try ProviderHandoffProjections.commitIntentDigest(record.intent)
                    == record.commitDigestSHA256,
                try ProviderHandoffProjections.chainHeadDigest(
                    commitDigestSHA256: record.commitDigestSHA256,
                    orderedPreCommitHeaders: record.intent.preCommitRootExpectations
                        .map(\.expectedHeader)
                ) == record.handoffChainHeadDigestSHA256,
                record.rootPrepareRecordDigestsSHA256.count
                    == record.intent.preCommitRootExpectations.count,
                Set(record.rootPrepareRecordDigestsSHA256).count
                    == record.rootPrepareRecordDigestsSHA256.count,
                record.postCommitRoots == derivedRoots
            else {
                throw ProviderHandoffRecordValidationError.invalidCommit
            }
            for digest in record.rootPrepareRecordDigestsSHA256 {
                _ = try ProviderHandoffDigest.parseSHA256(digest)
            }
            try validateSelectionTransition(record.intent)
            let digest = try ProviderHandoffProjections.commitRecordDigest(record)
            try trustRegistry.verify(
                record.coordinatorSignature,
                expectedPurpose: .coordinatorCommitSigning,
                expectedRole: .gatewayCoordinator,
                providerFingerprint: nil,
                stateRootUUID: nil,
                projectionDigestSHA256: digest,
                atUnixSeconds: atUnixSeconds
            )
            return ProviderHandoffValidatedCommitRecordV1(record: record)
        } catch let error as ProviderHandoffRecordValidationError {
            throw error
        } catch {
            throw ProviderHandoffRecordValidationError.invalidCommit
        }
    }

    public static func validateTerminalOutcome(
        _ outcome: ProviderHandoffTerminalOutcomeV1,
        trustRegistry: ProviderHandoffValidatedTrustRegistryV1,
        atUnixSeconds: UInt64
    ) throws -> ProviderHandoffValidatedTerminalOutcomeV1 {
        do {
            guard
                outcome.schemaVersion == 1,
                outcome.phase == .aborted || outcome.phase == .complete,
                !outcome.tokenID.isEmpty,
                !outcome.manifestID.isEmpty,
                !outcome.roots.isEmpty,
                Set(outcome.roots.map(\.stateRootUUID)).count == outcome.roots.count,
                try ProviderHandoffProjections.terminalOutcomeDigest(outcome)
                    == outcome.outcomeDigestSHA256
            else {
                throw ProviderHandoffRecordValidationError.invalidOutcome
            }
            try trustRegistry.verify(
                outcome.coordinatorSignature,
                expectedPurpose: .coordinatorTerminalOutcomeSigning,
                expectedRole: .gatewayCoordinator,
                providerFingerprint: nil,
                stateRootUUID: nil,
                projectionDigestSHA256: outcome.outcomeDigestSHA256,
                atUnixSeconds: atUnixSeconds
            )
            return ProviderHandoffValidatedTerminalOutcomeV1(outcome: outcome)
        } catch let error as ProviderHandoffRecordValidationError {
            throw error
        } catch {
            throw ProviderHandoffRecordValidationError.invalidOutcome
        }
    }

    private static func validateManifestStructure(
        _ manifest: ProviderHandoffManifestV1
    ) throws {
        guard
            manifest.schemaVersion == 1,
            !manifest.manifestID.isEmpty,
            !manifest.tokenID.isEmpty,
            manifest.trustRegistryRevision > 0,
            manifest.manifestDigestAlgorithm == .sha256,
            manifest.resultingLineageDigestKeyVersion > 0,
            canonicalUUID(manifest.resultingAuthorityLineageUUID),
            canonicalUUID(manifest.destinationStateRootUUID),
            !manifest.destinationProviderFingerprint.isEmpty,
            !manifest.sources.isEmpty,
            manifest.parts.map(\.kind) == ProviderHandoffPartKindV1.allCases,
            Set(manifest.sources.map(\.stateRootUUID)).count
                == manifest.sources.count,
            !manifest.sources.contains(where: {
                $0.stateRootUUID == manifest.destinationStateRootUUID
            })
        else {
            throw ProviderHandoffRecordValidationError.invalidManifest
        }
        let sourceOrder = manifest.sources.map(\.stateRootUUID)
        let sourceIndex = Dictionary(
            uniqueKeysWithValues: sourceOrder.enumerated().map { ($1, $0) }
        )
        for source in manifest.sources {
            guard
                canonicalUUID(source.stateRootUUID),
                canonicalUUID(source.authorityLineageUUID),
                source.lineageDigestKeyVersion > 0,
                source.preCommitExpectation.role == .source,
                source.preCommitExpectation.stateRootUUID == source.stateRootUUID,
                source.preCommitExpectation.expectedHeader.authorityLineageUUID
                    == source.authorityLineageUUID,
                source.preCommitExpectation.expectedHeader.lineageDigestKeyVersion
                    == source.lineageDigestKeyVersion
            else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }
            _ = try ProviderHandoffProjections.headerExpectation(
                source.preCommitExpectation
            )
        }
        guard
            manifest.destinationPreCommitExpectation.role == .destination,
            manifest.destinationPreCommitExpectation.stateRootUUID
                == manifest.destinationStateRootUUID,
            manifest.destinationPreCommitExpectation.expectedHeader
                .stagedAuthorityLineageUUID
                == manifest.resultingAuthorityLineageUUID
        else {
            throw ProviderHandoffRecordValidationError.invalidManifest
        }
        _ = try ProviderHandoffProjections.headerExpectation(
            manifest.destinationPreCommitExpectation
        )

        var requiredEnvelopes = Set<LineageKeyUse>()
        var seenEnvelopeIDs = Set<String>()
        var lastEnvelopeOrder: (Int, Data)?
        for envelope in manifest.destinationSealedLineageKeyEnvelopes {
            guard
                seenEnvelopeIDs.insert(envelope.envelopeID).inserted,
                canonicalUUID(envelope.authorityLineageUUID),
                envelope.keyVersion > 0
            else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }
            let order =
                envelope.sourceStateRootUUID.flatMap { sourceIndex[$0] }
                ?? sourceOrder.count
            guard
                envelope.sourceStateRootUUID == nil
                    || sourceIndex[envelope.sourceStateRootUUID ?? ""] != nil,
                lastEnvelopeOrder.map({ previous in
                    previous.0 < order
                        || (previous.0 == order
                            && previous.1.lexicographicallyPrecedes(
                                Data(envelope.envelopeID.utf8)
                            ))
                }) != false
            else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }
            lastEnvelopeOrder = (order, Data(envelope.envelopeID.utf8))
        }

        for part in manifest.parts {
            let orderedSourceRoots = part.sourceStateRootUUIDs.sorted(by: {
                (sourceIndex[$0] ?? .max) < (sourceIndex[$1] ?? .max)
            })
            guard
                part.schemaVersion == 1,
                part.payload.schemaVersion == part.schemaVersion,
                Set(part.sourceStateRootUUIDs).count
                    == part.sourceStateRootUUIDs.count,
                part.sourceStateRootUUIDs.allSatisfy({ sourceIndex[$0] != nil }),
                part.sourceStateRootUUIDs == orderedSourceRoots,
                canonicalStringList(part.requiredCapabilities)
            else {
                throw ProviderHandoffRecordValidationError.invalidManifest
            }
            _ = try ProviderHandoffProjections.payloadDescriptorDigest(part.payload)
            let sourceDigests = part.payload.canonicalContentDigest
                .orderedSourceDigests
            if part.payload.protection
                == .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1
                || part.payload.protection
                    == .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2
            {
                let sourceDigestsMatch = sourceDigests.allSatisfy { digest in
                    guard
                        let source = manifest.sources.first(where: {
                            $0.stateRootUUID == digest.sourceStateRootUUID
                        })
                    else { return false }
                    return digest.authorityLineageUUID
                        == source.authorityLineageUUID
                        && digest.lineageDigestKeyVersion
                            == source.lineageDigestKeyVersion
                }
                guard
                    sourceDigests.map(\.sourceStateRootUUID)
                        == part.sourceStateRootUUIDs,
                    sourceDigestsMatch
                else {
                    throw ProviderHandoffRecordValidationError.invalidManifest
                }
                for digest in sourceDigests {
                    requiredEnvelopes.insert(
                        LineageKeyUse(
                            sourceStateRootUUID: digest.sourceStateRootUUID,
                            authorityLineageUUID: digest.authorityLineageUUID,
                            keyVersion: digest.lineageDigestKeyVersion
                        )
                    )
                }
            }
        }
        let availableEnvelopes = Set(
            manifest.destinationSealedLineageKeyEnvelopes.map {
                LineageKeyUse(
                    sourceStateRootUUID: $0.sourceStateRootUUID,
                    authorityLineageUUID: $0.authorityLineageUUID,
                    keyVersion: $0.keyVersion
                )
            }
        )
        guard
            requiredEnvelopes.isSubset(of: availableEnvelopes),
            availableEnvelopes.contains(
                LineageKeyUse(
                    sourceStateRootUUID: nil,
                    authorityLineageUUID: manifest.resultingAuthorityLineageUUID,
                    keyVersion: manifest.resultingLineageDigestKeyVersion
                )
            )
        else {
            throw ProviderHandoffRecordValidationError.invalidManifest
        }
    }

    private static func requiredEncryptionKeys(
        _ manifest: ProviderHandoffManifestV1
    ) throws -> [EncryptionKeyUse] {
        var keys = Set<EncryptionKeyUse>()
        for part in manifest.parts {
            if let encryption = part.payload.destinationEncryption {
                keys.insert(
                    EncryptionKeyUse(
                        purpose: encryption.destinationKeyPurpose,
                        keyID: encryption.destinationKeyID
                    )
                )
            }
        }
        for envelope in manifest.destinationSealedLineageKeyEnvelopes {
            keys.insert(
                EncryptionKeyUse(
                    purpose: envelope.destinationKeyPurpose,
                    keyID: envelope.destinationKeyID
                )
            )
        }
        return keys.sorted {
            if $0.purpose.rawValue != $1.purpose.rawValue {
                return $0.purpose.rawValue.utf8.lexicographicallyPrecedes(
                    $1.purpose.rawValue.utf8
                )
            }
            return $0.keyID.utf8.lexicographicallyPrecedes($1.keyID.utf8)
        }
    }

    public static func derivePostCommitRoots(
        intent: ProviderHandoffCommitIntentV1,
        chainHeadDigestSHA256: String
    ) throws -> [ProviderHandoffPostCommitRootV1] {
        guard !intent.preCommitRootExpectations.isEmpty else {
            throw ProviderHandoffRecordValidationError.invalidCommit
        }
        return try intent.preCommitRootExpectations.enumerated().map {
            index,
            expectation in
            var header = expectation.expectedHeader
            let (writerEpoch, writerOverflow) = header.writerEpoch
                .addingReportingOverflow(1)
            guard !writerOverflow else {
                throw ProviderHandoffRecordValidationError.invalidCommit
            }
            header.writerEpoch = writerEpoch
            header.handoffChainHeadDigest = chainHeadDigestSHA256
            header.stagedAuthorityLineageUUID = nil
            if index == intent.preCommitRootExpectations.count - 1 {
                guard expectation.role == .destination else {
                    throw ProviderHandoffRecordValidationError.invalidCommit
                }
                header.authorityLineageUUID = intent.resultingAuthorityLineageUUID
                header.lineageDigestKeyVersion = intent.resultingLineageDigestKeyVersion
                header.minimumWriterSchemaVersion = max(
                    header.minimumWriterSchemaVersion,
                    intent.resultingMinimumWriterSchemaVersion
                )
                header.selectedProviderFingerprint =
                    intent.providerSelection
                    .resultingRecord.selectedProviderFingerprint
                header.handoffState = .destinationReconciling
                header.activeHandoffTokenID = intent.tokenID
            } else {
                guard expectation.role == .source else {
                    throw ProviderHandoffRecordValidationError.invalidCommit
                }
                header.handoffState = .sourceTransferred
                header.activeHandoffTokenID = nil
            }
            var vector = expectation.preCommitRevisionVector
            let (rootRevision, revisionOverflow) = vector.rootStoreRevision
                .addingReportingOverflow(1)
            guard !revisionOverflow else {
                throw ProviderHandoffRecordValidationError.invalidCommit
            }
            vector.rootStoreRevision = rootRevision
            vector.revisionVectorDigestSHA256 =
                try ProviderHandoffProjections
                .revisionVectorDigest(vector)
            return try ProviderHandoffPostCommitRootV1(
                role: expectation.role,
                stateRootUUID: expectation.stateRootUUID,
                postCommitHeader: header,
                postCommitHeaderDigestSHA256:
                    ProviderHandoffProjections
                    .stateRootHeaderDigest(header),
                postCommitRevisionVector: vector
            )
        }
    }

    private static func validateSelectionTransition(
        _ intent: ProviderHandoffCommitIntentV1
    ) throws {
        let provider = intent.providerSelection
        let socket = intent.socketSelection
        let (nextProviderRevision, providerOverflow) = provider.expectedRecord
            .selectionRevision.addingReportingOverflow(1)
        let (nextSocketRevision, socketOverflow) = socket.expectedRecord
            .discoveryRevision.addingReportingOverflow(1)
        guard
            !providerOverflow,
            !socketOverflow,
            provider.resultingRecord.selectionRevision
                == nextProviderRevision,
            provider.resultingRecord.selectedProviderFingerprint != nil,
            provider.resultingRecord.selectedStateRootUUID != nil,
            provider.resultingRecord.providerRegistrationDigestSHA256 != nil,
            provider.resultingRecord.trustRegistryRevision
                == intent.trustRegistryRevision,
            socket.resultingRecord.discoveryRevision
                == nextSocketRevision,
            socket.resultingRecord.socketInstanceUUID
                == socket.expectedRecord.socketInstanceUUID,
            socket.resultingRecord.ownerUID == socket.expectedRecord.ownerUID,
            socket.resultingRecord.minimumEngineAPIVersion
                == socket.expectedRecord.minimumEngineAPIVersion,
            socket.resultingRecord.maximumEngineAPIVersion
                == socket.expectedRecord.maximumEngineAPIVersion,
            socket.resultingRecord.selectedProviderFingerprint
                == provider.resultingRecord.selectedProviderFingerprint,
            socket.resultingRecord.selectedStateRootUUID
                == provider.resultingRecord.selectedStateRootUUID
        else {
            throw ProviderHandoffRecordValidationError.invalidCommit
        }
        _ = try ProviderHandoffProjections.commitIntentDigest(intent)
    }

    private static func canonicalStringList(_ values: [String]) -> Bool {
        guard
            Set(values).count == values.count,
            values.allSatisfy({
                !$0.isEmpty && $0.precomposedStringWithCanonicalMapping == $0
            })
        else { return false }
        return values
            == values.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        guard let identifier = UUID(uuidString: value) else { return false }
        return identifier.uuidString.lowercased() == value
    }
}

public enum ProviderHandoffRecordSigner {
    public static func signSource(
        stateRootUUID: String,
        manifest: inout ProviderHandoffManifestV1,
        signerKeyID: String,
        privateKey: Data
    ) throws {
        guard
            let index = manifest.sources.firstIndex(where: {
                $0.stateRootUUID == stateRootUUID
            })
        else {
            throw ProviderHandoffRecordValidationError.invalidManifest
        }
        let source = manifest.sources[index]
        let digest = try ProviderHandoffProjections.sourceManifestDigest(
            source: source,
            manifest: manifest
        )
        manifest.sources[index].sourceSignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: digest,
            purpose: .sourceManifestSigning,
            signerKeyID: signerKeyID,
            signerRole: .sourceProvider,
            providerFingerprint: source.providerFingerprint,
            stateRootUUID: source.stateRootUUID,
            trustRegistryRevision: manifest.trustRegistryRevision,
            privateKey: privateKey
        )
    }

    public static func signManifest(
        _ manifest: inout ProviderHandoffManifestV1,
        signerKeyID: String,
        privateKey: Data
    ) throws {
        manifest.manifestDigest = try ProviderHandoffProjections.manifestDigest(
            manifest
        )
        manifest.coordinatorSignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: manifest.manifestDigest,
            purpose: .coordinatorManifestSigning,
            signerKeyID: signerKeyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: manifest.trustRegistryRevision,
            privateKey: privateKey
        )
    }

    public static func signCommitRecord(
        _ record: inout ProviderHandoffCommitRecordV1,
        signerKeyID: String,
        privateKey: Data
    ) throws {
        record.commitDigestSHA256 =
            try ProviderHandoffProjections
            .commitIntentDigest(record.intent)
        record.handoffChainHeadDigestSHA256 =
            try ProviderHandoffProjections
            .chainHeadDigest(
                commitDigestSHA256: record.commitDigestSHA256,
                orderedPreCommitHeaders: record.intent.preCommitRootExpectations
                    .map(\.expectedHeader)
            )
        record.postCommitRoots =
            try ProviderHandoffRecordValidator
            .derivePostCommitRoots(
                intent: record.intent,
                chainHeadDigestSHA256: record.handoffChainHeadDigestSHA256
            )
        let digest = try ProviderHandoffProjections.commitRecordDigest(record)
        record.coordinatorSignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: digest,
            purpose: .coordinatorCommitSigning,
            signerKeyID: signerKeyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: record.intent.trustRegistryRevision,
            privateKey: privateKey
        )
    }

    public static func signTerminalOutcome(
        _ outcome: inout ProviderHandoffTerminalOutcomeV1,
        trustRegistryRevision: UInt64,
        signerKeyID: String,
        privateKey: Data
    ) throws {
        outcome.outcomeDigestSHA256 =
            try ProviderHandoffProjections
            .terminalOutcomeDigest(outcome)
        outcome.coordinatorSignature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: outcome.outcomeDigestSHA256,
            purpose: .coordinatorTerminalOutcomeSigning,
            signerKeyID: signerKeyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: trustRegistryRevision,
            privateKey: privateKey
        )
    }
}

private struct EncryptionKeyUse: Hashable {
    var purpose: ProviderHandoffKeyPurposeV1
    var keyID: String
}

private struct LineageKeyUse: Hashable {
    var sourceStateRootUUID: String?
    var authorityLineageUUID: String
    var keyVersion: UInt64
}
