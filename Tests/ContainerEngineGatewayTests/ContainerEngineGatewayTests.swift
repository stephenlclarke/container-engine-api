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
func `recovery control requires the exact supported provider capability`() async throws {
    for (version, status, supported) in [
        (1, ContainerEngineCapabilityStatus.native, true),
        (1, .emulated, true),
        (1, .unavailable, false),
        (2, .native, false)
    ] {
        let fingerprint = try ContainerEngineProviderFingerprint(
            declaration: ContainerEngineProviderDeclaration(
                profile: .stock, kind: .devcontainerStock, implementationVersion: "1.0.0",
                runtimeRevisions: ["runtime": "test"], stateSchemaVersion: 1,
                capabilities: [ContainerEngineProviderCapability(
                    identifier: "engine.control.recovery", version: UInt32(version), status: status
                )]
            ), stateRootUUID: UUID()
        )
        let gateway = try ContainerEngineGatewayResponder(
            providerSocketPath: "/tmp/missing-provider.sock", fingerprint: fingerprint
        )
        for target in ["/_container-family/recovery", "/v1.53/_container-family/recovery"] {
            for method in [DockerHTTPMethod.get, .post] {
                let response = await gateway.respond(to: .init(method: method, target: target))
                // An admitted route reaches the unavailable test provider, not 404.
                #expect(response.status == (supported ? 503 : 404))
            }
        }
        #expect(await gateway.respond(to: .init(method: .delete, target: "/_container-family/recovery")).status == 404)
        #expect(await gateway.respond(to: .init(method: .get, target: "/_container-family/unknown")).status == 404)
        if supported {
            #expect(await gateway.respond(to: .init(method: .get, target: "/v1.99/_container-family/recovery"))
                .status == 400)
        }
    }
}

@Test
func `gateway advertises only declared provider routes`() async throws {
    let fingerprint = try ContainerEngineProviderFingerprint(
        declaration: ContainerEngineProviderDeclaration(
            profile: .stock,
            kind: .devcontainerStock,
            implementationVersion: "1.0.0",
            runtimeRevisions: ["runtime": "test"],
            stateSchemaVersion: 1,
            capabilities: []
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
        gateway.ledger.routes.first { $0.identifier == "SystemPingHead" }?
            .disposition == .implemented
    )
    #expect(
        gateway.ledger.routes.first { $0.identifier == "SystemVersion" }?
            .disposition == .unimplemented
    )
    #expect(
        gateway.ledger.routes.first { $0.identifier == "ContainerWait" }?
            .disposition == .unimplemented
    )
    #expect(
        gateway.ledger.routes.first { $0.identifier == "ImagePush" }?.disposition
            == .unimplemented
    )
    #expect(
        gateway.ledger.routes.first { $0.identifier == "VolumeCreate" }?
            .disposition == .unimplemented
    )
    let unavailable = await gateway.respond(
        to: DockerHTTPRequest(method: .post, target: "/images/example/push")
    )
    #expect(unavailable.status == 501)
    let platform = await gateway.respond(
        to: DockerHTTPRequest(method: .post, target: "/swarm/init")
    )
    #expect(platform.status == 501)
    let unavailableVolume = await gateway.respond(
        to: DockerHTTPRequest(method: .post, target: "/volumes/create")
    )
    #expect(unavailableVolume.status == 501)
    let unknown = await gateway.respond(
        to: DockerHTTPRequest(method: .get, target: "/not-an-engine-route")
    )
    #expect(unknown.status == 404)
    #expect(await gateway.respond(to: .init(method: .get, target: "/_container-family/recovery")).status == 404)

    let ping = await gateway.respond(
        to: DockerHTTPRequest(method: .get, target: "/_ping")
    )
    #expect(ping.status == 200)
    #expect(ping.headers["API-Version"] == "1.53")
    #expect(ping.headers["Builder-Version"] == "2")
    #expect(ping.headers["Docker-Experimental"] == "false")
    #expect(ping.headers["OSType"] == "linux")
    #expect(ping.headers["Swarm"] == "inactive")
    if case let .bytes(body) = ping.body {
        #expect(body == Data("OK".utf8))
    } else {
        Issue.record("expected gateway-local ping bytes")
    }

    let head = await gateway.respond(
        to: DockerHTTPRequest(method: .head, target: "/_ping")
    )
    #expect(head.status == 200)
    #expect(head.headers == ping.headers)
    if case let .bytes(body) = head.body {
        #expect(body.isEmpty)
    } else {
        Issue.record("expected gateway-local head bytes")
    }

    let waitFingerprint = try ContainerEngineProviderFingerprint(
        declaration: ContainerEngineProviderDeclaration(
            profile: .enhanced,
            kind: .containerAuthority,
            implementationVersion: "1.0.0",
            runtimeRevisions: ["runtime": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerWait",
                    status: .native
                )
            ]
        ),
        stateRootUUID: UUID()
    )
    let waitGateway = try ContainerEngineGatewayResponder(
        providerSocketPath: "/tmp/missing-provider.sock",
        fingerprint: waitFingerprint
    )
    #expect(
        waitGateway.ledger.routes.first { $0.identifier == "ContainerWait" }?
            .disposition == .implemented
    )
}
