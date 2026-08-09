//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import Foundation

/// Provider-side key enrollment and possession-proof endpoint.
///
/// The gateway can retrieve only registry-ready public keys and can submit only
/// a token-scoped encrypted challenge. Raw private keys and gateway-only
/// challenge plaintext never cross the private provider session.
public struct ContainerEngineProviderIdentityControlResponder:
    ContainerEngineProviderHandoffControlResponder,
    Sendable
{
    private let identity: ProviderHandoffProviderIdentityV1
    private let possessionProofStore: ProviderHandoffPossessionProofStore?
    private let downstream: (any ContainerEngineProviderHandoffControlResponder)?

    public init(
        identity: ProviderHandoffProviderIdentityV1,
        possessionProofStore: ProviderHandoffPossessionProofStore? = nil,
        downstream: (any ContainerEngineProviderHandoffControlResponder)? = nil
    ) {
        self.identity = identity
        self.possessionProofStore = possessionProofStore
        self.downstream = downstream
    }

    public func respond(
        to request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async -> ContainerEngineProviderHandoffControlResultV1 {
        do {
            guard
                context.providerFingerprint.digest
                == identity.context.providerFingerprint
            else {
                throw ProviderHandoffProviderKeyStoreError.bindingMismatch
            }
            switch request.operation {
            case .destinationKeySnapshot:
                guard
                    request.bodyMediaType
                    == ProviderHandoffProviderKeyControlCodec
                    .snapshotRequestMediaType
                else {
                    return Self.failure(
                        requestID: request.requestID,
                        message: "provider key snapshot media type is unsupported"
                    )
                }
                let value =
                    try ProviderHandoffProviderKeyControlCodec
                        .decodeSnapshotRequest(body)
                guard
                    value.expectedProviderFingerprint
                    == identity.context.providerFingerprint,
                    value.expectedStateRootUUID == identity.context.stateRootUUID
                else {
                    throw ProviderHandoffProviderKeyStoreError.bindingMismatch
                }
                return try Self.success(
                    requestID: request.requestID,
                    body: ProviderHandoffProviderKeyControlCodec.encodeSnapshot(
                        ProviderHandoffProviderKeySnapshotV1(
                            context: identity.context,
                            trustKeys: identity.trustKeys
                        )
                    ),
                    mediaType: ProviderHandoffProviderKeyControlCodec
                        .snapshotMediaType
                )
            case .destinationKeyPossession:
                guard
                    request.bodyMediaType
                    == ProviderHandoffProviderKeyControlCodec
                    .possessionChallengeMediaType
                else {
                    return Self.failure(
                        requestID: request.requestID,
                        message: "provider key possession media type is unsupported"
                    )
                }
                let value =
                    try ProviderHandoffProviderKeyControlCodec
                        .decodePossessionChallenge(body)
                let proof = try identity.respond(
                    to: value.challenge,
                    trustRegistryRevision: value.trustRegistryRevision
                )
                _ = try possessionProofStore?.store(proof)
                return try Self.success(
                    requestID: request.requestID,
                    body:
                    ProviderHandoffProviderKeyControlCodec
                        .encodePossessionProof(proof),
                    mediaType: ProviderHandoffProviderKeyControlCodec
                        .possessionProofMediaType
                )
            case .objectAppend, .objectDeclare, .objectRead, .objectVerify,
                 .partActivate, .partCompensate, .partExport, .partPromote,
                 .partStage, .sourceSignManifest,
                 .rootApply, .rootPrepare, .rootRelease, .rootSnapshot:
                guard let downstream else {
                    return Self.failure(
                        requestID: request.requestID,
                        message: "selected provider does not implement this handoff operation"
                    )
                }
                return await downstream.respond(
                    to: request,
                    body: body,
                    context: context
                )
            }
        } catch {
            return Self.failure(
                requestID: request.requestID,
                message: Self.message(for: error)
            )
        }
    }

    private static func success(
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
        message: String
    ) -> ContainerEngineProviderHandoffControlResultV1 {
        let body = Data()
        return ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                validatedRequestID: requestID,
                disposition: .rejected,
                bodyMediaType: "application/vnd.io.github.stephenlclarke.container.handoff-error.v1+json",
                body: body,
                validatedMessage: String(
                    decoding: message.utf8.prefix(1024),
                    as: UTF8.self
                )
            ),
            body: body
        )
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case is ProviderHandoffProviderKeyControlCodecError:
            "provider key control request is invalid"
        case ProviderHandoffProviderKeyStoreError.bindingMismatch:
            "provider key control binding does not match the selected provider"
        default:
            "provider key control request failed"
        }
    }
}
