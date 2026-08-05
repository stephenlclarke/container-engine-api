//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
import ContainerEngineWire
import Foundation
import Testing

@testable import ContainerEngineRuntimeSPI
@testable import ContainerEngineService

struct ContainerEngineServiceTests {
    @Test func `production trust stores are scoped to selected provider root`() {
        let firstRoot = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondRoot = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let first = ContainerEngineServiceTrustConfiguration.production.scoped(
            to: firstRoot
        )
        let second = ContainerEngineServiceTrustConfiguration.production.scoped(
            to: secondRoot
        )

        #expect(first.gatewayKeyStore.account != second.gatewayKeyStore.account)
        #expect(first.trustRegistryStore.account != second.trustRegistryStore.account)
        #expect(
            first.gatewayKeyStore.account
                == "gateway-private-keys-v1.11111111-2222-3333-4444-555555555555"
        )
        #expect(
            first.trustRegistryStore.account
                == "trust-registry-v1.11111111-2222-3333-4444-555555555555"
        )

        let injected = ContainerEngineServiceTrustConfiguration(
            gatewayKeyStore: ProviderHandoffGatewayKeyStore(account: "gateway"),
            trustRegistryStore: ProviderHandoffTrustRegistryStore(account: "registry"),
            nowUnixSeconds: 1
        ).scoped(to: firstRoot)
        #expect(injected.gatewayKeyStore.account == "gateway")
        #expect(injected.trustRegistryStore.account == "registry")
    }

    @Test func `parses required options in any order`() throws {
        let options = try ContainerEngineServiceOptions(
            arguments: [
                "--provider-socket", "/tmp/provider.sock",
                "--state-directory", "/tmp/state",
                "--socket", "/tmp/docker.sock",
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
                    "--state-directory", "/tmp/state",
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
                let gatewayState = try runtime.handoffStore.load()
                #expect(
                    gatewayState.providerSelection.selectedProviderFingerprint
                        == runtime.fingerprint.digest
                )
                #expect(
                    gatewayState.providerSelection.selectedStateRootUUID
                        == stateRootUUID.uuidString.lowercased()
                )
                #expect(gatewayState.activeTokenID == nil)
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
        guard case .timedOut(let socketPath, _) = error else {
            Issue.record("expected a timed-out health probe")
            return
        }
        #expect(socketPath == socket)
    }

    @Test func `provider health attempts receive a realistic bounded budget`() {
        #expect(
            ContainerEngineHealthProbe.attemptTimeoutMilliseconds(
                remaining: .seconds(5)
            ) == 1000
        )
        #expect(
            ContainerEngineHealthProbe.attemptTimeoutMilliseconds(
                remaining: .milliseconds(350)
            ) == 350
        )
        #expect(
            ContainerEngineHealthProbe.attemptTimeoutMilliseconds(
                remaining: .zero
            ) == 1
        )
    }

    @Test func `attested provider enrollment installs trust before serving`() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ces-trust-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let providerKeyService =
            "io.github.stephenlclarke.container-engine.service-provider-tests.\(UUID().uuidString)"
        let gatewayKeyService =
            "io.github.stephenlclarke.container-engine.service-gateway-tests.\(UUID().uuidString)"
        let trustService =
            "io.github.stephenlclarke.container-engine.service-trust-tests.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProviderHandoffProviderKeyStore.removeForTesting(
                service: providerKeyService,
                account: "provider"
            )
            try? ProviderHandoffGatewayKeyStore.removeForTesting(
                service: gatewayKeyService,
                account: "gateway"
            )
            try? ProviderHandoffTrustRegistryStore.removeForTesting(
                service: trustService,
                account: "registry",
                archivedRevisions: 1...1
            )
        }

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
                ),
                ContainerEngineProviderCapability(
                    identifier:
                        "engine.handoff.provider-key-enrollment.v1",
                    status: .native
                ),
            ]
        )
        let stateRootUUID = UUID()
        let fingerprint = try ContainerEngineProviderFingerprint(
            declaration: declaration,
            stateRootUUID: stateRootUUID
        )
        let codeIdentity = try ProviderHandoffCodeIdentity.current()
        let providerIdentity = try ProviderHandoffProviderKeyStore(
            service: providerKeyService,
            account: "provider"
        ).loadOrCreate(
            context: ProviderHandoffProviderKeyEnrollmentContextV1(
                providerFingerprint: fingerprint.digest,
                stateRootUUID: stateRootUUID.uuidString.lowercased(),
                owningBundleIdentifier: codeIdentity.signingIdentifier,
                codeRequirementDigestSHA256:
                    codeIdentity.designatedRequirementDigestSHA256,
                teamIdentifier: codeIdentity.teamIdentifier,
                providerRegistrationDigestSHA256: String(
                    fingerprint.digest.dropFirst("sha256:".count)
                ),
                enrolledAtUnixSeconds: 100,
                notBeforeUnixSeconds: 100,
                notAfterUnixSeconds: 10_000
            )
        )
        let providerSocket = root.appendingPathComponent("provider.sock").path
        let provider = try ContainerEngineProviderSessionServer(
            responder: HealthProviderResponder(),
            handoffControlResponder:
                ContainerEngineProviderIdentityControlResponder(
                    identity: providerIdentity
                ),
            socketPath: providerSocket,
            declaration: declaration,
            stateRootUUID: stateRootUUID
        )
        try provider.start()
        let gatewayKeyStore = ProviderHandoffGatewayKeyStore(
            service: gatewayKeyService,
            account: "gateway"
        )
        let trustStore = ProviderHandoffTrustRegistryStore(
            service: trustService,
            account: "registry"
        )
        do {
            let runtime = try await ContainerEngineServiceRunner.start(
                options: ContainerEngineServiceOptions(
                    socket: root.appendingPathComponent("docker.sock").path,
                    providerSocket: providerSocket,
                    stateDirectory: root.appendingPathComponent("gateway").path
                ),
                trustConfiguration: ContainerEngineServiceTrustConfiguration(
                    gatewayKeyStore: gatewayKeyStore,
                    trustRegistryStore: trustStore,
                    nowUnixSeconds: 100
                )
            )
            do {
                let state = try runtime.handoffStore.load()
                #expect(
                    state.providerSelection.trustRegistryRevision == 1
                )
                let gatewayContext =
                    ProviderHandoffGatewayKeyEnrollmentContextV1(
                        owningBundleIdentifier:
                            codeIdentity.signingIdentifier,
                        codeRequirementDigestSHA256:
                            codeIdentity
                            .designatedRequirementDigestSHA256,
                        teamIdentifier: codeIdentity.teamIdentifier,
                        gatewayRegistrationDigestSHA256:
                            try ProviderHandoffGatewayKeyEnrollmentContextV1
                            .registrationDigest(
                                codeIdentity: codeIdentity
                            ),
                        enrolledAtUnixSeconds: 100,
                        notBeforeUnixSeconds: 100,
                        notAfterUnixSeconds: UInt64.max
                    )
                let gatewayIdentity = try gatewayKeyStore.load(
                    expectedContext: gatewayContext
                )
                let registry = try trustStore.load(
                    bootstrap: gatewayIdentity.bootstrap
                )
                #expect(registry.registry.registryRevision == 1)
                #expect(registry.registry.keys.count == 10)
                #expect(
                    registry.registry.keys.contains(
                        try providerIdentity.trustKey(
                            for: .destinationPayloadEncryption
                        )
                    )
                )
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
