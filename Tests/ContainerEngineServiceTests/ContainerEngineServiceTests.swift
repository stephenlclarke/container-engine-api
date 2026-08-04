//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
@testable import ContainerEngineService
import ContainerEngineWire
import Foundation
import Testing

struct ContainerEngineServiceTests {
    @Test func `parses required options in any order`() throws {
        let options = try ContainerEngineServiceOptions(
            arguments: [
                "--provider-socket", "/tmp/provider.sock",
                "--state-directory", "/tmp/state",
                "--socket", "/tmp/docker.sock"
            ]
        )
        let expected = try ContainerEngineServiceOptions(
            socket: "/tmp/docker.sock",
            providerSocket: "/tmp/provider.sock",
            stateDirectory: "/tmp/state"
        )
        #expect(options == expected)
    }

    @Test func `rejects missing duplicate and unknown options`() {
        #expect(throws: ContainerEngineServiceOptionError.missingArgument("--socket")) {
            _ = try ContainerEngineServiceOptions(arguments: [])
        }
        #expect(throws: ContainerEngineServiceOptionError.duplicateArgument("--socket")) {
            _ = try ContainerEngineServiceOptions(
                arguments: [
                    "--socket", "/tmp/a.sock",
                    "--socket", "/tmp/b.sock",
                    "--provider-socket", "/tmp/provider.sock",
                    "--state-directory", "/tmp/state"
                ]
            )
        }
        #expect(throws: ContainerEngineServiceOptionError.invalidArgument("--unknown")) {
            _ = try ContainerEngineServiceOptions(
                arguments: ["--unknown", "value"]
            )
        }
    }

    @Test func `starts selected provider and answers public health probes`() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ces-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let declaration = try ContainerEngineProviderDeclaration(
            profile: .enhanced,
            kind: .containerAuthority,
            implementationVersion: "test",
            runtimeRevisions: ["container": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                ContainerEngineProviderCapability(
                    identifier: "engine.route.SystemInfo",
                    status: .native
                )
            ]
        )
        let stateRootUUID = UUID()
        let providerSocket = root.appendingPathComponent("provider.sock").path
        let publicSocket = root.appendingPathComponent("docker.sock").path
        let stateDirectory = root.appendingPathComponent(
            "gateway",
            isDirectory: true
        ).path
        let provider = try ContainerEngineProviderSessionServer(
            responder: HealthProviderResponder(),
            socketPath: providerSocket,
            declaration: declaration,
            stateRootUUID: stateRootUUID
        )
        try provider.start()
        do {
            let runtime = try await ContainerEngineServiceRunner.start(
                options: ContainerEngineServiceOptions(
                    socket: publicSocket,
                    providerSocket: providerSocket,
                    stateDirectory: stateDirectory
                )
            )
            do {
                try ContainerEngineHealthProbe.ping(socketPath: publicSocket)
                try ContainerEngineHealthProbe.systemInfo(
                    socketPath: publicSocket
                )
                try await ContainerEngineHealthProbe
                    .waitUntilProviderResponsive(
                        socketPath: publicSocket,
                        timeout: .seconds(1)
                    )
                #expect(runtime.fingerprint.declaration == declaration)
                #expect(runtime.fingerprint.stateRootUUID == stateRootUUID)
                #expect(runtime.socketPath == publicSocket)
                try await runtime.shutdown()
                await provider.shutdown()
            } catch {
                try? await runtime.shutdown()
                await provider.shutdown()
                throw error
            }
        } catch {
            await provider.shutdown()
            throw error
        }

        #expect(!FileManager.default.fileExists(atPath: publicSocket))
        #expect(!FileManager.default.fileExists(atPath: providerSocket))
    }

    @Test func `responsive wait returns bounded timeout evidence`() async {
        let socket = "/tmp/missing-engine-\(UUID().uuidString.prefix(8)).sock"
        let error = await #expect(throws: ContainerEngineHealthProbeError.self) {
            try await ContainerEngineHealthProbe.waitUntilResponsive(
                socketPath: socket,
                timeout: .milliseconds(1)
            )
        }
        guard case let .timedOut(socketPath, _) = error else {
            Issue.record("expected a timed-out health probe")
            return
        }
        #expect(socketPath == socket)
    }
}

private struct HealthProviderResponder: DockerHTTPResponder {
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        guard request.target == "/info" else {
            return .text("unexpected provider request: \(request.target)", status: 500)
        }
        return DockerHTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: .bytes(Data("{\"ID\":\"test-engine\"}".utf8))
        )
    }
}
