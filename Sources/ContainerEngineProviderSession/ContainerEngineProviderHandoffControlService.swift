//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import Foundation

/// Neutral provider-side handler for durable bundle-object transfer.
///
/// Focused root and part controllers may be supplied as `downstream`; object
/// operations remain common and cannot be reinterpreted by a provider. Every
/// result is bounded and redacted before it returns to the gateway.
public struct ContainerEngineProviderHandoffControlService:
    ContainerEngineProviderHandoffControlResponder,
    Sendable
{
    public let objectStore: ProviderHandoffBundleObjectStore
    private let downstream: (any ContainerEngineProviderHandoffControlResponder)?

    public init(
        objectStore: ProviderHandoffBundleObjectStore,
        downstream: (any ContainerEngineProviderHandoffControlResponder)? = nil
    ) {
        self.objectStore = objectStore
        self.downstream = downstream
    }

    public func respond(
        to request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async -> ContainerEngineProviderHandoffControlResultV1 {
        guard Self.isObjectOperation(request.operation) else {
            guard let downstream else {
                return Self.failure(
                    requestID: request.requestID,
                    disposition: .rejected,
                    message: "selected provider does not implement this handoff operation"
                )
            }
            return await downstream.respond(
                to: request,
                body: body,
                context: context
            )
        }
        guard
            request.bodyMediaType
                == ProviderHandoffBundleObjectControlCodec.requestMediaType
        else {
            return Self.failure(
                requestID: request.requestID,
                disposition: .rejected,
                message: "provider handoff object control media type is unsupported"
            )
        }
        do {
            switch request.operation {
            case .objectDeclare:
                let value =
                    try ProviderHandoffBundleObjectControlCodec
                    .decodeDeclare(body)
                let record = try objectStore.declare(
                    bundleObjectID: value.bundleObjectID,
                    transportByteLength: value.transportByteLength,
                    transportDigestSHA256: value.transportDigestSHA256
                )
                return try Self.success(
                    requestID: request.requestID,
                    body: ProviderHandoffBundleObjectControlCodec.encodeRecord(
                        record
                    ),
                    mediaType:
                        ProviderHandoffBundleObjectControlCodec.recordMediaType
                )
            case .objectAppend:
                let value =
                    try ProviderHandoffBundleObjectControlCodec
                    .decodeAppend(body)
                let record = try objectStore.append(
                    bundleObjectID: value.bundleObjectID,
                    offset: value.offset,
                    bytes: value.bytes,
                    expectedObjectRevision: value.expectedObjectRevision
                )
                return try Self.success(
                    requestID: request.requestID,
                    body: ProviderHandoffBundleObjectControlCodec.encodeRecord(
                        record
                    ),
                    mediaType:
                        ProviderHandoffBundleObjectControlCodec.recordMediaType
                )
            case .objectVerify:
                let value =
                    try ProviderHandoffBundleObjectControlCodec
                    .decodeReference(body)
                let record = try objectStore.verify(
                    bundleObjectID: value.bundleObjectID,
                    expectedObjectRevision: value.expectedObjectRevision
                )
                return try Self.success(
                    requestID: request.requestID,
                    body: ProviderHandoffBundleObjectControlCodec.encodeRecord(
                        record
                    ),
                    mediaType:
                        ProviderHandoffBundleObjectControlCodec.recordMediaType
                )
            case .objectRead:
                let value =
                    try ProviderHandoffBundleObjectControlCodec
                    .decodeRead(body)
                let bytes = try objectStore.readVerifiedChunk(
                    bundleObjectID: value.bundleObjectID,
                    offset: value.offset,
                    maximumBytes: Int(value.maximumBytes)
                )
                return try Self.success(
                    requestID: request.requestID,
                    body: ProviderHandoffBundleObjectControlCodec.encodeChunk(
                        ProviderHandoffBundleObjectChunkV1(
                            bundleObjectID: value.bundleObjectID,
                            offset: value.offset,
                            bytes: bytes
                        )
                    ),
                    mediaType:
                        ProviderHandoffBundleObjectControlCodec.chunkMediaType
                )
            case .destinationKeyPossession, .destinationKeySnapshot,
                .partActivate, .partCompensate, .partPromote, .partStage,
                .rootApply, .rootPrepare, .rootRelease, .rootSnapshot:
                preconditionFailure("non-object operation passed object switch")
            }
        } catch {
            return Self.failure(
                requestID: request.requestID,
                disposition: Self.disposition(for: error),
                message: Self.message(for: error)
            )
        }
    }

    private static func isObjectOperation(
        _ operation: ContainerEngineProviderHandoffOperationV1
    ) -> Bool {
        switch operation {
        case .objectAppend, .objectDeclare, .objectRead, .objectVerify:
            true
        case .destinationKeyPossession, .destinationKeySnapshot,
            .partActivate, .partCompensate, .partPromote, .partStage,
            .rootApply, .rootPrepare, .rootRelease, .rootSnapshot:
            false
        }
    }

    private static func success(
        requestID: String,
        body: Data,
        mediaType: String
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        ContainerEngineProviderHandoffControlResultV1(
            response: try ContainerEngineProviderHandoffControlResponseV1(
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
        let response = ContainerEngineProviderHandoffControlResponseV1(
            validatedRequestID: requestID,
            disposition: disposition,
            bodyMediaType: "application/vnd.io.github.stephenlclarke.container.handoff-error.v1+json",
            body: body,
            validatedMessage: String(
                decoding: message.utf8.prefix(1_024),
                as: UTF8.self
            )
        )
        return ContainerEngineProviderHandoffControlResultV1(
            response: response,
            body: body
        )
    }

    private static func disposition(
        for error: any Error
    ) -> ContainerEngineProviderHandoffDispositionV1 {
        switch error {
        case ProviderHandoffBundleObjectStoreError.conflictingChunk,
            ProviderHandoffBundleObjectStoreError.identityMismatch,
            ProviderHandoffBundleObjectStoreError.revisionMismatch:
            .conflict
        case ProviderHandoffBundleObjectStoreError.integrityMismatch,
            ProviderHandoffBundleObjectStoreError.invalidMetadata:
            .recoveryRequired
        case ProviderHandoffBundleObjectStoreError.ioFailure:
            .retryableFailure
        default:
            .rejected
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let value as ProviderHandoffBundleObjectStoreError:
            value.description
        case is ProviderHandoffBundleObjectControlCodecError:
            "provider handoff object control request is invalid"
        default:
            "provider handoff object control failed"
        }
    }
}
