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

    public init(fingerprint: ContainerEngineProviderFingerprint) {
        self.fingerprint = fingerprint
    }
}

enum ProviderSessionFrameKind: String, Codable {
    case cancel
    case closeInput
    case failure
    case gatewayHello
    case next
    case providerHello
    case ready
    case request
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
}

struct ProviderSessionRequest: Codable {
    var method: DockerHTTPMethod
    var target: String
    var headers: [DockerHTTPHeaders.Field]
    var body: Data
}

struct ProviderSessionResponseHead: Codable {
    var status: Int
    var headers: [String: String]
    var bodyKind: ProviderSessionBodyKind
    var terminal: Bool?
}

struct ProviderSessionFrame: Codable {
    static let currentSchemaVersion: UInt32 = 1

    var schemaVersion = currentSchemaVersion
    var kind: ProviderSessionFrameKind
    var fingerprint: ContainerEngineProviderFingerprint?
    var expectedFingerprintDigest: String?
    var request: ProviderSessionRequest?
    var response: ProviderSessionResponseHead?
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
    case fingerprintMismatch(expected: String, received: String)
    case frameTooLarge(Int)
    case invalidFrame(String)
    case invalidSocketPath(String)
    case providerFailure(String)
    case protocolViolation(String)
    case unsupportedProtocolVersion(UInt32)
    case unsafeSocketDirectory(String)
    case unsafeSocketPath(String)

    public var description: String {
        switch self {
        case let .bodyTooLarge(size):
            "provider response body exceeds the limit (\(size) bytes)"
        case .connectionClosed:
            "provider session connection closed"
        case let .fingerprintMismatch(expected, received):
            "provider fingerprint mismatch: expected \(expected), received \(received)"
        case let .frameTooLarge(size):
            "provider session frame exceeds the limit (\(size) bytes)"
        case let .invalidFrame(message):
            "invalid provider session frame: \(message)"
        case let .invalidSocketPath(path):
            "invalid provider Unix socket path: \(path)"
        case let .providerFailure(message):
            "provider request failed: \(message)"
        case let .protocolViolation(message):
            "provider session protocol violation: \(message)"
        case let .unsupportedProtocolVersion(version):
            "unsupported provider session protocol version \(version)"
        case let .unsafeSocketDirectory(path):
            "unsafe provider socket directory: \(path)"
        case let .unsafeSocketPath(path):
            "unsafe provider socket path: \(path)"
        }
    }
}
