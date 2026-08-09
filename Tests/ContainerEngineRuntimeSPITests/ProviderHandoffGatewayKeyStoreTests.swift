//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

@Suite("Provider handoff gateway key store", .serialized)
struct ProviderHandoffGatewayKeyStoreTests {
    @Test
    func `Gateway identity signs a complete provider trust registry`() throws {
        let gatewayService =
            "io.github.stephenlclarke.container-engine.gateway-tests.\(UUID().uuidString)"
        let providerService =
            "io.github.stephenlclarke.container-engine.provider-tests.\(UUID().uuidString)"
        defer {
            try? ProviderHandoffGatewayKeyStore.removeForTesting(
                service: gatewayService,
                account: "gateway"
            )
            try? ProviderHandoffProviderKeyStore.removeForTesting(
                service: providerService,
                account: "provider"
            )
        }
        let codeIdentity = ProviderHandoffCodeIdentityV1(
            signingIdentifier: "io.github.stephenlclarke.container-engine",
            teamIdentifier: "TESTTEAM",
            designatedRequirementDigestSHA256: String(
                repeating: "a",
                count: 64
            )
        )
        let gatewayContext = try ProviderHandoffGatewayKeyEnrollmentContextV1(
            owningBundleIdentifier: codeIdentity.signingIdentifier,
            codeRequirementDigestSHA256:
            codeIdentity.designatedRequirementDigestSHA256,
            teamIdentifier: codeIdentity.teamIdentifier,
            gatewayRegistrationDigestSHA256:
            ProviderHandoffGatewayKeyEnrollmentContextV1
                .registrationDigest(codeIdentity: codeIdentity),
            enrolledAtUnixSeconds: 100,
            notBeforeUnixSeconds: 100,
            notAfterUnixSeconds: 10000
        )
        let gatewayStore = ProviderHandoffGatewayKeyStore(
            service: gatewayService,
            account: "gateway"
        )
        let gateway = try gatewayStore.loadOrCreate(context: gatewayContext)
        var restartedContext = gatewayContext
        restartedContext.enrolledAtUnixSeconds = 101
        restartedContext.notBeforeUnixSeconds = 101
        restartedContext.notAfterUnixSeconds = 10001
        #expect(
            try gatewayStore.loadOrCreate(context: restartedContext).trustKeys
                == gateway.trustKeys
        )

        let providerContext = ProviderHandoffProviderKeyEnrollmentContextV1(
            providerFingerprint: "sha256:" + String(repeating: "b", count: 64),
            stateRootUUID: "10000000-0000-4000-8000-000000000001",
            owningBundleIdentifier: "io.github.stephenlclarke.container.apiserver",
            codeRequirementDigestSHA256: String(repeating: "c", count: 64),
            teamIdentifier: "TESTTEAM",
            providerRegistrationDigestSHA256: String(repeating: "b", count: 64),
            enrolledAtUnixSeconds: 100,
            notBeforeUnixSeconds: 100,
            notAfterUnixSeconds: 10000
        )
        let provider = try ProviderHandoffProviderKeyStore(
            service: providerService,
            account: "provider"
        ).loadOrCreate(context: providerContext)
        let validated = try gateway.makeTrustRegistry(
            providerKeys: provider.trustKeys,
            registryRevision: 1,
            issuedAtUnixSeconds: 100
        )

        #expect(validated.registry.keys.count == 10)
        #expect(validated.registry.registryRevision == 1)
        #expect(
            validated.registry.registrySignature.signerKeyID
                == gateway.bootstrap.keyID
        )
        #expect(
            try validated.key(
                identifier: (provider.trustKey(
                    for: .destinationPayloadEncryption
                )).keyID,
                purpose: .destinationPayloadEncryption,
                role: .destinationProvider,
                providerFingerprint: providerContext.providerFingerprint,
                stateRootUUID: providerContext.stateRootUUID,
                atUnixSeconds: 100
            ).purpose == .destinationPayloadEncryption
        )
    }
}
