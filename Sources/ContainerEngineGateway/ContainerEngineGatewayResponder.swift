//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
import ContainerEngineRouter
import ContainerEngineRuntimeSPI
import ContainerEngineWire
import Foundation

/// Owns Engine route advertisement and dispatch for exactly one selected provider.
public struct ContainerEngineGatewayResponder: DockerHTTPResponder, Sendable {
    /// Opt-in native control protocol, distinct from the generated Docker API.
    public static let recoveryCapabilityIdentifier = "engine.control.recovery"
    public static let recoveryCapabilityVersion: UInt32 = 1

    private static let gatewayRouteIdentifiers: Set<String> = [
        "SystemPing",
        "SystemPingHead"
    ]

    public let fingerprint: ContainerEngineProviderFingerprint
    public let ledger: DockerRouteLedger
    private let provider: ContainerEngineProviderSessionClient

    public init(
        providerSocketPath: String,
        fingerprint: ContainerEngineProviderFingerprint
    ) throws {
        self.fingerprint = fingerprint
        let providerRoutes = Set<String>(
            fingerprint.declaration.capabilities.compactMap { capability in
                guard
                    capability.status != .unavailable,
                    capability.identifier.hasPrefix("engine.route.")
                else {
                    return nil
                }
                return String(capability.identifier.dropFirst("engine.route.".count))
            }
        )
        let implemented = providerRoutes.union(Self.gatewayRouteIdentifiers)
        let dockerLedger = try DockerEngineAPIRouteLedger.make(
            implementedRouteIdentifiers: implemented
        )
        let recoveryAvailable = fingerprint.declaration.capabilities.contains {
            $0.identifier == Self.recoveryCapabilityIdentifier
                && $0.version == Self.recoveryCapabilityVersion
                && $0.status != .unavailable
        }
        let recoveryRoutes: [DockerRouteMetadata] = try recoveryAvailable ? [
            (.get, "ContainerFamilyRecoveryInspect"),
            (.post, "ContainerFamilyRecoveryFreeze")
        ].map { method, identifier in
            try DockerRouteMetadata(
                identifier: identifier, method: method,
                pattern: DockerRoutePattern("/_container-family/recovery"),
                introduced: dockerLedger.minimumAPIVersion,
                responseMode: .bytes, disposition: .implemented
            )
        } : []
        // Retain normal method/version validation and the authenticated provider
        // session. Unknown control paths never become generic forwarding routes.
        ledger = try DockerRouteLedger(
            minimumAPIVersion: dockerLedger.minimumAPIVersion,
            maximumAPIVersion: dockerLedger.maximumAPIVersion,
            routes: dockerLedger.routes + recoveryRoutes
        )
        provider = ContainerEngineProviderSessionClient(
            socketPath: providerSocketPath,
            expectedFingerprint: fingerprint
        )
    }

    public func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        do {
            guard let match = try ledger.match(request) else {
                return Self.error(status: 404, message: "page not found")
            }
            if Self.gatewayRouteIdentifiers.contains(match.metadata.identifier) {
                return pingResponse(method: request.method)
            }
            switch match.metadata.disposition {
            case .implemented:
                return await provider.respond(to: request)
            case .platformUnavailable:
                return Self.error(
                    status: 501,
                    message: "\(match.metadata.identifier) is unavailable on local macOS"
                )
            case .unimplemented:
                return Self.error(
                    status: 501,
                    message: "\(match.metadata.identifier) is not implemented by the selected provider"
                )
            }
        } catch let error as DockerRoutingError {
            return Self.error(status: 400, message: String(describing: error))
        } catch {
            return Self.error(status: 500, message: "Engine route dispatch failed")
        }
    }

    private func pingResponse(method: DockerHTTPMethod) -> DockerHTTPResponse {
        DockerHTTPResponse(
            status: 200,
            headers: [
                "API-Version": ledger.maximumAPIVersion.description,
                "Builder-Version": "2",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Docker-Experimental": "false",
                "OSType": "linux",
                "Pragma": "no-cache",
                "Server":
                    "Docker/\(fingerprint.declaration.implementationVersion) (linux)",
                "Swarm": "inactive",
                "Content-Type": "text/plain; charset=utf-8"
            ],
            body: .bytes(method == .head ? Data() : Data("OK".utf8))
        )
    }

    private static func error(status: Int, message: String) -> DockerHTTPResponse {
        (try? DockerHTTPResponse.json(
            DockerErrorEnvelope(message: message),
            status: status
        )) ?? DockerHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: .bytes(Data("{\"message\":\"Engine request failed\"}".utf8))
        )
    }
}
