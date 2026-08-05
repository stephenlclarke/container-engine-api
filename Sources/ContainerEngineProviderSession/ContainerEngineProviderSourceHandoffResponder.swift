//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import Foundation

public enum ContainerEngineProviderSourceHandoffError:
    Error,
    Equatable,
    Sendable
{
    case invalidConfiguration
    case invalidContribution
    case invalidGatewayIdentity
    case invalidManifest
    case invalidRequest
}

/// Reusable provider-side source exporter and manifest signer.
///
/// Providers supply only an immutable package projection for their selected
/// resources. This responder owns destination-proof validation, lineage-key
/// custody, deterministic payload sealing, content-addressed publication,
/// crash-replay contribution freezing, and final source signing.
public struct ContainerEngineProviderSourceHandoffResponder:
    ContainerEngineProviderHandoffControlResponder,
    Sendable
{
    public typealias ExportPackage =
        @Sendable (ProviderHandoffPartExportRequestV1) async throws
        -> ProviderHandoffPayloadPackageV1
    public typealias ExportPackageSource =
        @Sendable (ProviderHandoffPartExportRequestV1) async throws
        -> ProviderHandoffPayloadPackageSourceV2
    public typealias ExportPackageSourceToDirectory =
        @Sendable (
            ProviderHandoffPartExportRequestV1,
            _ temporaryDirectoryURL: URL
        ) async throws -> ProviderHandoffPayloadPackageSourceV2

    private struct ValidatedExport: Sendable {
        let proofDigests: [String]
    }

    private let partKind: ProviderHandoffPartKindV1
    private let mediaType: String
    private let requiredCapabilities: [String]
    private let objectStore: ProviderHandoffBundleObjectStore
    private let contributionStore: ProviderHandoffSourceContributionStore
    private let lineageKeyStore: ProviderHandoffLineageKeyStore
    private let trustRegistryStore: ProviderHandoffTrustRegistryStore
    private let providerIdentity: ProviderHandoffProviderIdentityV1
    private let exportPackage: ExportPackageSourceToDirectory
    private let nowUnixSeconds: @Sendable () throws -> UInt64
    private let downstream: (any ContainerEngineProviderHandoffControlResponder)?

    public init(
        partKind: ProviderHandoffPartKindV1,
        mediaType: String,
        requiredCapabilities: [String],
        objectStore: ProviderHandoffBundleObjectStore,
        contributionStore: ProviderHandoffSourceContributionStore,
        lineageKeyStore: ProviderHandoffLineageKeyStore,
        trustRegistryStore: ProviderHandoffTrustRegistryStore,
        providerIdentity: ProviderHandoffProviderIdentityV1,
        exportPackage: @escaping ExportPackage,
        nowUnixSeconds: @escaping @Sendable () throws -> UInt64 = {
            let value = Date().timeIntervalSince1970
            guard
                value.isFinite,
                value >= 0,
                value < Double(UInt64.max)
            else {
                throw ContainerEngineProviderSourceHandoffError.invalidRequest
            }
            return UInt64(value.rounded(.down))
        },
        downstream:
            (any ContainerEngineProviderHandoffControlResponder)? = nil
    ) throws {
        let orderedCapabilities = requiredCapabilities.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        guard
            !mediaType.isEmpty,
            mediaType.precomposedStringWithCanonicalMapping == mediaType,
            !orderedCapabilities.isEmpty,
            Set(orderedCapabilities).count == orderedCapabilities.count,
            orderedCapabilities.allSatisfy({
                !$0.isEmpty
                    && $0.precomposedStringWithCanonicalMapping == $0
            })
        else {
            throw ContainerEngineProviderSourceHandoffError
                .invalidConfiguration
        }
        self.partKind = partKind
        self.mediaType = mediaType
        self.requiredCapabilities = orderedCapabilities
        self.objectStore = objectStore
        self.contributionStore = contributionStore
        self.lineageKeyStore = lineageKeyStore
        self.trustRegistryStore = trustRegistryStore
        self.providerIdentity = providerIdentity
        self.exportPackage = { request, _ in
            try await ProviderHandoffPayloadPackageSourceV2(
                exportPackage(request)
            )
        }
        self.nowUnixSeconds = nowUnixSeconds
        self.downstream = downstream
    }

    public init(
        partKind: ProviderHandoffPartKindV1,
        mediaType: String,
        requiredCapabilities: [String],
        objectStore: ProviderHandoffBundleObjectStore,
        contributionStore: ProviderHandoffSourceContributionStore,
        lineageKeyStore: ProviderHandoffLineageKeyStore,
        trustRegistryStore: ProviderHandoffTrustRegistryStore,
        providerIdentity: ProviderHandoffProviderIdentityV1,
        exportPackageSource: @escaping ExportPackageSource,
        nowUnixSeconds: @escaping @Sendable () throws -> UInt64 = {
            let value = Date().timeIntervalSince1970
            guard
                value.isFinite,
                value >= 0,
                value < Double(UInt64.max)
            else {
                throw ContainerEngineProviderSourceHandoffError.invalidRequest
            }
            return UInt64(value.rounded(.down))
        },
        downstream:
            (any ContainerEngineProviderHandoffControlResponder)? = nil
    ) throws {
        let orderedCapabilities = requiredCapabilities.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        guard
            !mediaType.isEmpty,
            mediaType.precomposedStringWithCanonicalMapping == mediaType,
            !orderedCapabilities.isEmpty,
            Set(orderedCapabilities).count == orderedCapabilities.count,
            orderedCapabilities.allSatisfy({
                !$0.isEmpty
                    && $0.precomposedStringWithCanonicalMapping == $0
            })
        else {
            throw ContainerEngineProviderSourceHandoffError
                .invalidConfiguration
        }
        self.partKind = partKind
        self.mediaType = mediaType
        self.requiredCapabilities = orderedCapabilities
        self.objectStore = objectStore
        self.contributionStore = contributionStore
        self.lineageKeyStore = lineageKeyStore
        self.trustRegistryStore = trustRegistryStore
        self.providerIdentity = providerIdentity
        exportPackage = { request, _ in
            try await exportPackageSource(request)
        }
        self.nowUnixSeconds = nowUnixSeconds
        self.downstream = downstream
    }

    public init(
        partKind: ProviderHandoffPartKindV1,
        mediaType: String,
        requiredCapabilities: [String],
        objectStore: ProviderHandoffBundleObjectStore,
        contributionStore: ProviderHandoffSourceContributionStore,
        lineageKeyStore: ProviderHandoffLineageKeyStore,
        trustRegistryStore: ProviderHandoffTrustRegistryStore,
        providerIdentity: ProviderHandoffProviderIdentityV1,
        exportPackageSourceToDirectory:
            @escaping ExportPackageSourceToDirectory,
        nowUnixSeconds: @escaping @Sendable () throws -> UInt64 = {
            let value = Date().timeIntervalSince1970
            guard
                value.isFinite,
                value >= 0,
                value < Double(UInt64.max)
            else {
                throw ContainerEngineProviderSourceHandoffError.invalidRequest
            }
            return UInt64(value.rounded(.down))
        },
        downstream:
            (any ContainerEngineProviderHandoffControlResponder)? = nil
    ) throws {
        let orderedCapabilities = requiredCapabilities.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        guard
            !mediaType.isEmpty,
            mediaType.precomposedStringWithCanonicalMapping == mediaType,
            !orderedCapabilities.isEmpty,
            Set(orderedCapabilities).count == orderedCapabilities.count,
            orderedCapabilities.allSatisfy({
                !$0.isEmpty
                    && $0.precomposedStringWithCanonicalMapping == $0
            })
        else {
            throw ContainerEngineProviderSourceHandoffError
                .invalidConfiguration
        }
        self.partKind = partKind
        self.mediaType = mediaType
        self.requiredCapabilities = orderedCapabilities
        self.objectStore = objectStore
        self.contributionStore = contributionStore
        self.lineageKeyStore = lineageKeyStore
        self.trustRegistryStore = trustRegistryStore
        self.providerIdentity = providerIdentity
        exportPackage = exportPackageSourceToDirectory
        self.nowUnixSeconds = nowUnixSeconds
        self.downstream = downstream
    }

    public func respond(
        to request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async -> ContainerEngineProviderHandoffControlResultV1 {
        guard
            request.operation == .partExport
                || request.operation == .sourceSignManifest
        else {
            guard let downstream else {
                return Self.failure(
                    requestID: request.requestID,
                    disposition: .rejected,
                    message:
                        "selected provider does not implement this handoff operation"
                )
            }
            return await downstream.respond(
                to: request,
                body: body,
                context: context
            )
        }
        do {
            switch request.operation {
            case .partExport:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffSourceControlCodec.exportRequestMediaType
                )
                let contribution = try await export(
                    ProviderHandoffSourceControlCodec.decodeExportRequest(body),
                    context: context
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body:
                        ProviderHandoffSourceControlCodec
                        .encodeContribution(contribution),
                    mediaType:
                        ProviderHandoffSourceControlCodec.contributionMediaType
                )
            case .sourceSignManifest:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffSourceControlCodec.signRequestMediaType
                )
                let receipt = try sign(
                    ProviderHandoffSourceControlCodec.decodeSignRequest(body),
                    context: context
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body:
                        ProviderHandoffSourceControlCodec
                        .encodeSignReceipt(receipt),
                    mediaType:
                        ProviderHandoffSourceControlCodec.signReceiptMediaType
                )
            case .destinationKeyPossession, .destinationKeySnapshot,
                .objectAppend, .objectDeclare, .objectRead, .objectVerify,
                .partActivate, .partCompensate, .partPromote, .partStage,
                .rootApply, .rootPrepare, .rootRelease, .rootSnapshot:
                preconditionFailure("non-source operation passed source switch")
            }
        } catch {
            return Self.failure(
                requestID: request.requestID,
                disposition: Self.disposition(for: error),
                message: Self.message(for: error)
            )
        }
    }

    private func export(
        _ request: ProviderHandoffPartExportRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async throws -> ProviderHandoffSourceContributionV1 {
        let validated = try validateExport(request, context: context)
        let requestDigest =
            try ProviderHandoffSourceControlCodec
            .exportRequestDigest(request)
        do {
            let existing = try contributionStore.load(
                tokenID: request.tokenID,
                manifestID: request.manifestID,
                partKind: partKind
            )
            guard existing.exportRequestDigestSHA256 == requestDigest else {
                throw ContainerEngineProviderSourceHandoffError
                    .invalidContribution
            }
            return existing
        } catch ProviderHandoffSourceContributionStoreError.notFound {
            // First export continues below.
        }

        let lineageKey = try lineageKeyStore.loadOrCreate(
            binding: ProviderHandoffLineageKeyBindingV1(
                providerFingerprint: request.sourceProviderFingerprint,
                sourceStateRootUUID: request.sourceStateRootUUID,
                authorityLineageUUID: request.authorityLineageUUID,
                keyVersion: request.lineageDigestKeyVersion
            )
        )
        let transportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-handoff-export-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: transportRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: transportRoot) }
        let package = try await exportPackage(request, transportRoot)
        guard package.partKind == partKind else {
            throw ContainerEngineProviderSourceHandoffError.invalidRequest
        }
        let payload = try ProviderHandoffPayloadCodec.prepareSealedFile(
            package,
            transportFileURL: transportRoot.appendingPathComponent("payload"),
            mediaType: mediaType,
            tokenID: request.tokenID,
            manifestID: request.manifestID,
            sourceOrder: [request.sourceStateRootUUID],
            lineageKeys: [lineageKey],
            destinationProviderFingerprint:
                request.destinationProviderFingerprint,
            destinationStateRootUUID: request.destinationStateRootUUID,
            destinationKeyID:
                request.destinationPayloadEncryptionKey.keyID,
            destinationPublicKey:
                request.destinationPayloadEncryptionKey.rawPublicKey,
            nonce: Self.derivedBytes(
                domain: "provider-part-payload-nonce-v1",
                requestDigest: requestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 24
            ),
            ephemeralPrivateKey: Self.derivedBytes(
                domain: "provider-part-payload-ephemeral-v1",
                requestDigest: requestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 32
            )
        )
        let objectRecord = try publish(payload)
        let lineageEnvelope = try providerIdentity.sealLineageKey(
            ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: request.sourceStateRootUUID,
                authorityLineageUUID: request.authorityLineageUUID,
                keyVersion: request.lineageDigestKeyVersion,
                rawHMACSHA256Key: lineageKey.rawHMACSHA256Key
            ),
            envelopeID: "lineage:\(request.sourceStateRootUUID)",
            tokenID: request.tokenID,
            manifestID: request.manifestID,
            destinationProviderFingerprint:
                request.destinationProviderFingerprint,
            destinationStateRootUUID: request.destinationStateRootUUID,
            destinationKeyID:
                request.destinationLineageKeyEncryptionKey.keyID,
            destinationPublicKey:
                request.destinationLineageKeyEncryptionKey.rawPublicKey,
            nonce: Self.derivedBytes(
                domain: "provider-lineage-nonce-v1",
                requestDigest: requestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 24
            ),
            trustRegistryRevision: request.trustRegistryRevision,
            ephemeralPrivateKey: Self.derivedBytes(
                domain: "provider-lineage-ephemeral-v1",
                requestDigest: requestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 32
            )
        )
        let part = ProviderHandoffPartV1(
            kind: partKind,
            schemaVersion: package.schemaVersion,
            disposition: .included,
            sourceStateRootUUIDs: [request.sourceStateRootUUID],
            requiredCapabilities: requiredCapabilities,
            payload: payload.descriptor
        )
        let contribution =
            try ProviderHandoffSourceControlCodec
            .finalizeContribution(
                ProviderHandoffSourceContributionV1(
                    partKind: partKind,
                    tokenID: request.tokenID,
                    manifestID: request.manifestID,
                    trustRegistryRevision: request.trustRegistryRevision,
                    exportRequestDigestSHA256: requestDigest,
                    sourceProviderFingerprint:
                        request.sourceProviderFingerprint,
                    sourceStateRootUUID: request.sourceStateRootUUID,
                    authorityLineageUUID: request.authorityLineageUUID,
                    lineageDigestKeyVersion:
                        request.lineageDigestKeyVersion,
                    sourcePreCommitExpectation:
                        request.sourcePreCommitExpectation,
                    destinationProviderFingerprint:
                        request.destinationProviderFingerprint,
                    destinationStateRootUUID:
                        request.destinationStateRootUUID,
                    destinationPreCommitExpectation:
                        request.destinationPreCommitExpectation,
                    destinationKeyPossessionProofDigestsSHA256:
                        validated.proofDigests,
                    resultingAuthorityLineageUUID:
                        request.resultingAuthorityLineageUUID,
                    resultingLineageDigestKeyVersion:
                        request.resultingLineageDigestKeyVersion,
                    destinationSealedLineageKeyEnvelope: lineageEnvelope,
                    part: part,
                    sourceObjectRecord: objectRecord
                )
            )
        return try contributionStore.store(contribution)
    }

    private func sign(
        _ request: ProviderHandoffSourceManifestSignRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) throws -> ProviderHandoffSourceManifestSignReceiptV1 {
        let manifest = request.candidateManifest
        try validateGateway(bootstrap: request.bootstrap, context: context)
        let contribution = try contributionStore.load(
            tokenID: manifest.tokenID,
            manifestID: manifest.manifestID,
            partKind: request.partKind
        )
        guard
            request.partKind == partKind,
            request.contributionDigestSHA256
                == contribution.contributionDigestSHA256,
            manifest.trustRegistryRevision
                == contribution.trustRegistryRevision,
            manifest.destinationProviderFingerprint
                == contribution.destinationProviderFingerprint,
            manifest.destinationStateRootUUID
                == contribution.destinationStateRootUUID,
            manifest.destinationPreCommitExpectation
                == contribution.destinationPreCommitExpectation,
            manifest.destinationKeyPossessionProofDigestsSHA256
                == contribution.destinationKeyPossessionProofDigestsSHA256,
            manifest.resultingAuthorityLineageUUID
                == contribution.resultingAuthorityLineageUUID,
            manifest.resultingLineageDigestKeyVersion
                == contribution.resultingLineageDigestKeyVersion,
            manifest.parts.filter({ $0.kind == partKind })
                == [contribution.part],
            manifest.destinationSealedLineageKeyEnvelopes.filter({
                $0.sourceStateRootUUID == contribution.sourceStateRootUUID
            }) == [contribution.destinationSealedLineageKeyEnvelope],
            let source = manifest.sources.first(where: {
                $0.stateRootUUID == contribution.sourceStateRootUUID
            }),
            source.providerFingerprint
                == contribution.sourceProviderFingerprint,
            source.authorityLineageUUID
                == contribution.authorityLineageUUID,
            source.lineageDigestKeyVersion
                == contribution.lineageDigestKeyVersion,
            source.preCommitExpectation
                == contribution.sourcePreCommitExpectation
        else {
            throw ContainerEngineProviderSourceHandoffError.invalidManifest
        }

        let now = try nowUnixSeconds()
        let trustRegistry = try trustRegistryStore.loadRevision(
            manifest.trustRegistryRevision,
            bootstrap: request.bootstrap
        )
        let signingKey = try providerIdentity.trustKey(
            for: .sourceManifestSigning
        )
        guard
            try trustRegistry.key(
                identifier: signingKey.keyID,
                purpose: .sourceManifestSigning,
                role: .sourceProvider,
                providerFingerprint:
                    providerIdentity.context.providerFingerprint,
                stateRootUUID: providerIdentity.context.stateRootUUID,
                atUnixSeconds: now
            ) == signingKey
        else {
            throw ContainerEngineProviderSourceHandoffError.invalidManifest
        }
        let digest = try ProviderHandoffProjections.sourceManifestDigest(
            source: source,
            manifest: manifest
        )
        let signature = try providerIdentity.sign(
            projectionDigestSHA256: digest,
            purpose: .sourceManifestSigning,
            trustRegistryRevision: manifest.trustRegistryRevision
        )
        return ProviderHandoffSourceManifestSignReceiptV1(
            partKind: partKind,
            tokenID: manifest.tokenID,
            manifestID: manifest.manifestID,
            sourceStateRootUUID: contribution.sourceStateRootUUID,
            contributionDigestSHA256:
                contribution.contributionDigestSHA256,
            sourceProjectionDigestSHA256: digest,
            sourceSignature: signature
        )
    }

    private func validateExport(
        _ request: ProviderHandoffPartExportRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) throws -> ValidatedExport {
        try validateGateway(bootstrap: request.bootstrap, context: context)
        guard
            request.partKind == partKind,
            request.sourceProviderFingerprint
                == providerIdentity.context.providerFingerprint,
            request.sourceStateRootUUID
                == providerIdentity.context.stateRootUUID
        else {
            throw ContainerEngineProviderSourceHandoffError.invalidRequest
        }
        let now = try nowUnixSeconds()
        let trustRegistry = try trustRegistryStore.loadRevision(
            request.trustRegistryRevision,
            bootstrap: request.bootstrap
        )
        for purpose in [
            ProviderHandoffKeyPurposeV1.sourceManifestSigning,
            .lineageKeyEnvelopeSigning,
        ] {
            let key = try providerIdentity.trustKey(for: purpose)
            guard
                try trustRegistry.key(
                    identifier: key.keyID,
                    purpose: purpose,
                    role: .sourceProvider,
                    providerFingerprint:
                        providerIdentity.context.providerFingerprint,
                    stateRootUUID: providerIdentity.context.stateRootUUID,
                    atUnixSeconds: now
                ) == key
            else {
                throw ContainerEngineProviderSourceHandoffError.invalidRequest
            }
        }
        for key in [
            request.destinationPayloadEncryptionKey,
            request.destinationLineageKeyEncryptionKey,
        ] {
            guard
                try trustRegistry.key(
                    identifier: key.keyID,
                    purpose: key.purpose,
                    role: .destinationProvider,
                    providerFingerprint:
                        request.destinationProviderFingerprint,
                    stateRootUUID: request.destinationStateRootUUID,
                    atUnixSeconds: now
                ) == key
            else {
                throw ContainerEngineProviderSourceHandoffError.invalidRequest
            }
        }
        let proofs = try request.destinationKeyPossessionProofs.map {
            try ProviderHandoffPossessionProofCodec
                .validateDestinationReceipt(
                    $0,
                    trustRegistry: trustRegistry,
                    atUnixSeconds: now
                )
        }
        guard
            Set(proofs.map(\.proof.destinationKeyID))
                == Set([
                    request.destinationPayloadEncryptionKey.keyID,
                    request.destinationLineageKeyEncryptionKey.keyID,
                ])
        else {
            throw ContainerEngineProviderSourceHandoffError.invalidRequest
        }
        return ValidatedExport(
            proofDigests: proofs.map(\.proofRecordDigestSHA256).sorted()
        )
    }

    private func validateGateway(
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) throws {
        guard
            bootstrap.codeRequirementDigestSHA256
                == context.authenticatedGatewayCodeIdentity
                .designatedRequirementDigestSHA256,
            context.providerFingerprint.digest
                == providerIdentity.context.providerFingerprint,
            context.providerFingerprint.stateRootUUID.uuidString.lowercased()
                == providerIdentity.context.stateRootUUID
        else {
            throw ContainerEngineProviderSourceHandoffError
                .invalidGatewayIdentity
        }
    }

    private func publish(
        _ payload: ProviderHandoffPreparedPayloadFileV2
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        try objectStore.publishFile(
            at: payload.transportFileURL,
            bundleObjectID: payload.descriptor.bundleObjectID,
            transportByteLength: payload.descriptor.transportByteLength,
            transportDigestSHA256: payload.descriptor.transportDigestSHA256
        )
    }

    private static func derivedBytes(
        domain: String,
        requestDigest: String,
        key: Data,
        count: Int
    ) throws -> Data {
        let authentication = ProviderHandoffDigest.hmacSHA256(
            key: key,
            data: Data("\(domain)\u{0}\(requestDigest)".utf8)
        )
        return try Data(
            ProviderHandoffDigest.parseSHA256(authentication).prefix(count)
        )
    }

    private static func requireMediaType(
        _ actual: String,
        _ expected: String
    ) throws {
        guard actual == expected else {
            throw ContainerEngineProviderSourceHandoffError.invalidRequest
        }
    }

    private static func completed(
        requestID: String,
        body: Data,
        mediaType: String
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        try ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                requestID: requestID,
                disposition: .completed,
                bodyMediaType: mediaType,
                body: body
            ),
            body: body
        )
    }

    private static func failure(
        requestID: String,
        disposition: ContainerEngineProviderHandoffDispositionV1,
        message: String
    ) -> ContainerEngineProviderHandoffControlResultV1 {
        let body = Data()
        return ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                validatedRequestID: requestID,
                disposition: disposition,
                bodyMediaType:
                    "application/vnd.io.github.stephenlclarke.container.handoff-error.v1+json",
                body: body,
                validatedMessage: String(
                    decoding: message.utf8.prefix(1024),
                    as: UTF8.self
                )
            ),
            body: body
        )
    }

    private static func disposition(
        for error: any Error
    ) -> ContainerEngineProviderHandoffDispositionV1 {
        switch error {
        case ProviderHandoffSourceContributionStoreError.conflict,
            ProviderHandoffBundleObjectStoreError.conflictingChunk,
            ProviderHandoffBundleObjectStoreError.identityMismatch,
            ProviderHandoffBundleObjectStoreError.revisionMismatch:
            .conflict
        case ProviderHandoffBundleObjectStoreError.ioFailure,
            ProviderHandoffSourceContributionStoreError.ioFailure:
            .retryableFailure
        case ProviderHandoffBundleObjectStoreError.integrityMismatch,
            ProviderHandoffBundleObjectStoreError.invalidMetadata,
            ProviderHandoffSourceContributionStoreError.invalidMetadata:
            .recoveryRequired
        default:
            .rejected
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let value as ProviderHandoffBundleObjectStoreError:
            value.description
        case let value as ProviderHandoffSourceContributionStoreError:
            value.description
        case ContainerEngineProviderSourceHandoffError
            .invalidGatewayIdentity:
            "provider handoff source rejected the gateway identity"
        case ContainerEngineProviderSourceHandoffError.invalidContribution:
            "provider handoff source contribution is invalid"
        case ContainerEngineProviderSourceHandoffError.invalidManifest:
            "provider handoff source manifest does not match the durable contribution"
        default:
            "provider handoff source control request is invalid"
        }
    }
}
