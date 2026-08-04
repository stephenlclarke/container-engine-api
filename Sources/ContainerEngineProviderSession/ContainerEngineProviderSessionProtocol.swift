//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import ContainerEngineWire
import Foundation

public struct ContainerEngineProviderSessionDescriptor: Equatable, Sendable {
    public var fingerprint: ContainerEngineProviderFingerprint
    public var codeIdentity: ProviderHandoffCodeIdentityV1

    public init(
        fingerprint: ContainerEngineProviderFingerprint,
        codeIdentity: ProviderHandoffCodeIdentityV1
    ) {
        self.fingerprint = fingerprint
        self.codeIdentity = codeIdentity
    }
}

enum ProviderSessionFrameKind: String, Codable {
    case cancel
    case closeInput
    case controlRequest
    case controlResponse
    case failure
    case gatewayHello
    case next
    case providerHello
    case ready
    case request
    case requestBody
    case requestEnd
    case responseBody
    case responseChunkEnd
    case responseEnd
    case responseHead
    case wait
    case waitResult
    case writeInput
}

enum ProviderSessionBodyKind: String, Codable {
    case bytes
    case hijack
    case stream
    case webSocket
}

struct ProviderSessionRequest: Codable {
    var method: DockerHTTPMethod
    var target: String
    var headers: [DockerHTTPHeaders.Field]
}

struct ProviderSessionResponseHead: Codable {
    var status: Int
    var headers: [String: String]
    var bodyKind: ProviderSessionBodyKind
    var terminal: Bool?
}

public enum ContainerEngineProviderHandoffOperationV1:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case objectAppend
    case objectDeclare
    case objectRead
    case objectVerify
    case destinationKeyPossession
    case destinationKeySnapshot
    case rootSnapshot
    case rootPrepare
    case rootApply
    case rootRelease
    case partExport
    case sourceSignManifest
    case partStage
    case partCompensate
    case partPromote
    case partActivate
}

public enum ContainerEngineProviderHandoffDispositionV1:
    String,
    Codable,
    Equatable,
    Sendable
{
    case completed
    case conflict
    case rejected
    case retryableFailure
    case recoveryRequired
}

/// Closed metadata request sent only over the selected provider's private
/// owner-only session. Bulk handoff objects are staged separately and are
/// referenced by the operation body; this control path never buffers log or
/// image history.
public struct ContainerEngineProviderHandoffControlRequestV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1
    public static let maximumBodyBytes =
        ContainerEngineProviderControlMetadataLimits.maximumBodyBytes

    public var schemaVersion: UInt32
    public var requestID: String
    public var operation: ContainerEngineProviderHandoffOperationV1
    public var bodyMediaType: String
    public var bodyByteLength: UInt64
    public var bodyDigestSHA256: String

    public init(
        requestID: String,
        operation: ContainerEngineProviderHandoffOperationV1,
        bodyMediaType: String,
        body: Data
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
        self.operation = operation
        self.bodyMediaType = bodyMediaType
        bodyByteLength = UInt64(body.count)
        bodyDigestSHA256 = ProviderHandoffDigest.sha256(body)
        try validate(body: body)
    }

    func validate(body: Data) throws {
        guard
            schemaVersion == Self.currentSchemaVersion,
            !requestID.isEmpty,
            requestID.utf8.count <= 128,
            !requestID.utf8.contains(0),
            !bodyMediaType.isEmpty,
            bodyMediaType.utf8.count <= 256,
            !bodyMediaType.utf8.contains(0),
            body.count <= Self.maximumBodyBytes,
            bodyByteLength == UInt64(body.count),
            ProviderHandoffDigest.sha256(body) == bodyDigestSHA256
        else {
            throw ContainerEngineProviderSessionError.invalidControlMessage
        }
        _ = try ProviderHandoffDigest.parseSHA256(bodyDigestSHA256)
    }
}

public struct ContainerEngineProviderHandoffControlResponseV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var requestID: String
    public var disposition: ContainerEngineProviderHandoffDispositionV1
    public var bodyMediaType: String
    public var bodyByteLength: UInt64
    public var bodyDigestSHA256: String
    public var message: String?

    public init(
        requestID: String,
        disposition: ContainerEngineProviderHandoffDispositionV1,
        bodyMediaType: String,
        body: Data,
        message: String? = nil
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
        self.disposition = disposition
        self.bodyMediaType = bodyMediaType
        bodyByteLength = UInt64(body.count)
        bodyDigestSHA256 = ProviderHandoffDigest.sha256(body)
        self.message = message
        try validate(body: body)
    }

    init(
        validatedRequestID requestID: String,
        disposition: ContainerEngineProviderHandoffDispositionV1,
        bodyMediaType: String,
        body: Data,
        validatedMessage message: String?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
        self.disposition = disposition
        self.bodyMediaType = bodyMediaType
        bodyByteLength = UInt64(body.count)
        bodyDigestSHA256 = ProviderHandoffDigest.sha256(body)
        self.message = message
    }

    func validate(body: Data) throws {
        guard
            schemaVersion == Self.currentSchemaVersion,
            !requestID.isEmpty,
            requestID.utf8.count <= 128,
            !requestID.utf8.contains(0),
            !bodyMediaType.isEmpty,
            bodyMediaType.utf8.count <= 256,
            !bodyMediaType.utf8.contains(0),
            body.count
            <= ContainerEngineProviderHandoffControlRequestV1
            .maximumBodyBytes,
            bodyByteLength == UInt64(body.count),
            ProviderHandoffDigest.sha256(body) == bodyDigestSHA256,
            message?.utf8.count ?? 0 <= 1024,
            !(message?.utf8.contains(0) ?? false)
        else {
            throw ContainerEngineProviderSessionError.invalidControlMessage
        }
        _ = try ProviderHandoffDigest.parseSHA256(bodyDigestSHA256)
    }
}

public struct ContainerEngineProviderHandoffControlResultV1:
    Equatable,
    Sendable
{
    public var response: ContainerEngineProviderHandoffControlResponseV1
    public var body: Data

    public init(
        response: ContainerEngineProviderHandoffControlResponseV1,
        body: Data
    ) {
        self.response = response
        self.body = body
    }
}

public struct ContainerEngineProviderHandoffControlContextV1: Sendable {
    public let providerFingerprint: ContainerEngineProviderFingerprint
    public let authenticatedGatewayCodeIdentity: ProviderHandoffCodeIdentityV1

    public init(
        providerFingerprint: ContainerEngineProviderFingerprint,
        authenticatedGatewayCodeIdentity: ProviderHandoffCodeIdentityV1
    ) {
        self.providerFingerprint = providerFingerprint
        self.authenticatedGatewayCodeIdentity = authenticatedGatewayCodeIdentity
    }
}

public protocol ContainerEngineProviderHandoffControlResponder: Sendable {
    func respond(
        to request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async -> ContainerEngineProviderHandoffControlResultV1
}

struct ProviderSessionFrame: Codable {
    static let currentSchemaVersion: UInt32 = 5

    var schemaVersion = currentSchemaVersion
    var kind: ProviderSessionFrameKind
    var fingerprint: ContainerEngineProviderFingerprint?
    var codeIdentity: ProviderHandoffCodeIdentityV1?
    var expectedFingerprintDigest: String?
    var request: ProviderSessionRequest?
    var response: ProviderSessionResponseHead?
    var controlRequest: ContainerEngineProviderHandoffControlRequestV1?
    var controlResponse: ContainerEngineProviderHandoffControlResponseV1?
    var data: Data?
    var channel: DockerStreamChannel?
    var exitCode: Int32?
    var message: String?

    init(kind: ProviderSessionFrameKind) {
        self.kind = kind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ContainerEngineProviderSessionError.unsupportedProtocolVersion(
                schemaVersion
            )
        }
        kind = try container.decode(ProviderSessionFrameKind.self, forKey: .kind)
        fingerprint = try container.decodeIfPresent(
            ContainerEngineProviderFingerprint.self,
            forKey: .fingerprint
        )
        codeIdentity = try container.decodeIfPresent(
            ProviderHandoffCodeIdentityV1.self,
            forKey: .codeIdentity
        )
        expectedFingerprintDigest = try container.decodeIfPresent(
            String.self,
            forKey: .expectedFingerprintDigest
        )
        request = try container.decodeIfPresent(
            ProviderSessionRequest.self,
            forKey: .request
        )
        response = try container.decodeIfPresent(
            ProviderSessionResponseHead.self,
            forKey: .response
        )
        controlRequest = try container.decodeIfPresent(
            ContainerEngineProviderHandoffControlRequestV1.self,
            forKey: .controlRequest
        )
        controlResponse = try container.decodeIfPresent(
            ContainerEngineProviderHandoffControlResponseV1.self,
            forKey: .controlResponse
        )
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        channel = try container.decodeIfPresent(
            DockerStreamChannel.self,
            forKey: .channel
        )
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case codeIdentity
        case controlRequest
        case controlResponse
        case data
        case exitCode
        case expectedFingerprintDigest
        case fingerprint
        case kind
        case message
        case request
        case response
        case schemaVersion
    }
}

public enum ContainerEngineProviderSessionError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case bodyTooLarge(Int)
    case connectionClosed
    case codeIdentityMismatch
    case fingerprintMismatch(expected: String, received: String)
    case frameTooLarge(Int)
    case invalidFrame(String)
    case invalidControlMessage
    case invalidSocketPath(String)
    case providerFailure(String)
    case protocolViolation(String)
    case requestBodyTooLarge(Int)
    case unsupportedProtocolVersion(UInt32)
    case unsafeSocketDirectory(String)
    case unsafeSocketPath(String)

    public var description: String {
        switch self {
        case let .bodyTooLarge(size):
            "provider response body exceeds the limit (\(size) bytes)"
        case .connectionClosed:
            "provider session connection closed"
        case .codeIdentityMismatch:
            "provider session code identity does not match its Unix-socket peer"
        case let .fingerprintMismatch(expected, received):
            "provider fingerprint mismatch: expected \(expected), received \(received)"
        case let .frameTooLarge(size):
            "provider session frame exceeds the limit (\(size) bytes)"
        case let .invalidFrame(message):
            "invalid provider session frame: \(message)"
        case .invalidControlMessage:
            "invalid provider handoff control message"
        case let .invalidSocketPath(path):
            "invalid provider Unix socket path: \(path)"
        case let .providerFailure(message):
            "provider request failed: \(message)"
        case let .protocolViolation(message):
            "provider session protocol violation: \(message)"
        case let .requestBodyTooLarge(size):
            "provider request body exceeds the limit (\(size) bytes)"
        case let .unsupportedProtocolVersion(version):
            "unsupported provider session protocol version \(version)"
        case let .unsafeSocketDirectory(path):
            "unsafe provider socket directory: \(path)"
        case let .unsafeSocketPath(path):
            "unsafe provider socket path: \(path)"
        }
    }
}
