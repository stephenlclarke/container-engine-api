//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// A canonical absolute path in a Linux container guest.
///
/// The path is validated before it crosses an authority boundary so a runtime
/// never has to interpret aliases, relative components, or NUL-terminated
/// suffixes differently from the requesting client.
public struct AbsoluteGuestPath: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard value.first == "/", value != "/", !value.utf8.contains(0) else {
            throw ContainerResourceIntentError.invalidAbsoluteGuestPath(value)
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ContainerResourceIntentError.invalidAbsoluteGuestPath(value)
        }

        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid absolute guest path: \(value)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Authority-owned socket kinds that can be projected into a guest.
public enum InboundSocketKind: String, Codable, Equatable, Sendable {
    case engineAPI
}

/// Durable intent to project one authority-owned host socket into a guest.
///
/// Host broker paths are deliberately absent. The selected runtime authority
/// resolves them from its immutable state-root and provider identity.
public struct InboundUnixSocketIntentV1: Codable, Equatable, Sendable {
    public static let dockerSocketPath = "/var/run/docker.sock"

    public var kind: InboundSocketKind
    public var target: AbsoluteGuestPath
    public var inspectSource: String

    public init(
        kind: InboundSocketKind,
        target: AbsoluteGuestPath,
        inspectSource: String
    ) throws {
        switch kind {
        case .engineAPI:
            guard target.value == Self.dockerSocketPath,
                  inspectSource == Self.dockerSocketPath
            else {
                throw ContainerResourceIntentError.invalidEngineAPISocketProjection(
                    target: target.value,
                    inspectSource: inspectSource
                )
            }
        }

        self.kind = kind
        self.target = target
        self.inspectSource = inspectSource
    }

    public static func engineAPI() throws -> Self {
        try Self(
            kind: .engineAPI,
            target: AbsoluteGuestPath(dockerSocketPath),
            inspectSource: dockerSocketPath
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case target
        case inspectSource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(InboundSocketKind.self, forKey: .kind)
        let target = try container.decode(AbsoluteGuestPath.self, forKey: .target)
        let inspectSource = try container.decode(String.self, forKey: .inspectSource)
        do {
            try self.init(kind: kind, target: target, inspectSource: inspectSource)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .inspectSource,
                in: container,
                debugDescription: "invalid inbound Unix socket projection"
            )
        }
    }
}

public enum ContainerResourceIntentError: Error, Equatable, Sendable {
    case invalidAbsoluteGuestPath(String)
    case invalidEngineAPISocketProjection(target: String, inspectSource: String)
}

public extension ContainerEngineProviderCapability {
    /// Typed inbound Unix-socket projection is available at the runtime boundary.
    ///
    /// This deliberately does not claim the higher-level Engine API socket
    /// contract, whose durable grant, credentials, and route ledger are
    /// negotiated separately.
    static let inboundUnixSocketV1Identifier =
        "io.github.stephenlclarke.container.inbound-unix-socket.v1"
}
