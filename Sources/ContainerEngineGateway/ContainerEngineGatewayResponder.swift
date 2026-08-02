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
    public let fingerprint: ContainerEngineProviderFingerprint
    public let ledger: DockerRouteLedger
    private let provider: ContainerEngineProviderSessionClient

    public init(
        providerSocketPath: String,
        fingerprint: ContainerEngineProviderFingerprint
    ) throws {
        self.fingerprint = fingerprint
        let implemented = Set<String>(
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
        ledger = try DockerEngineAPIRouteLedger.make(
            implementedRouteIdentifiers: implemented
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
