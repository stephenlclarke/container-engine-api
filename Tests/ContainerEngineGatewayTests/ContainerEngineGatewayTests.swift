//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineGateway
import ContainerEngineRuntimeSPI
import ContainerEngineWire
import Foundation
import Testing

@Test
func `gateway advertises only declared provider routes`() async throws {
    let fingerprint = try ContainerEngineProviderFingerprint(
        declaration: ContainerEngineProviderDeclaration(
            profile: .stock,
            kind: .devcontainerStock,
            implementationVersion: "1.0.0",
            runtimeRevisions: ["runtime": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                ContainerEngineProviderCapability(
                    identifier: "engine.route.SystemPing",
                    status: .native
                )
            ]
        ),
        stateRootUUID: UUID()
    )
    let gateway = try ContainerEngineGatewayResponder(
        providerSocketPath: "/tmp/missing-provider.sock",
        fingerprint: fingerprint
    )

    #expect(
        gateway.ledger.routes.first { $0.identifier == "SystemPing" }?.disposition
            == .implemented
    )
    #expect(
        gateway.ledger.routes.first { $0.identifier == "ImagePush" }?.disposition
            == .unimplemented
    )
    let unavailable = await gateway.respond(
        to: DockerHTTPRequest(method: .post, target: "/images/example/push")
    )
    #expect(unavailable.status == 501)
    let platform = await gateway.respond(
        to: DockerHTTPRequest(method: .post, target: "/swarm/init")
    )
    #expect(platform.status == 501)
    let unknown = await gateway.respond(
        to: DockerHTTPRequest(method: .get, target: "/not-an-engine-route")
    )
    #expect(unknown.status == 404)
}
