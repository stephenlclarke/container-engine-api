//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Security
import Testing

@Suite("Provider handoff gateway transaction secret store", .serialized)
struct ProviderHandoffGatewayTransactionSecretStoreTests {
    @Test
    func `Transaction derivations survive restart and remain domain separated`() throws {
        let service =
            "io.github.stephenlclarke.container-engine.tests.\(UUID().uuidString)"
        defer {
            SecItemDelete(
                [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service
                ] as CFDictionary
            )
        }
        let firstStore = ProviderHandoffGatewayTransactionSecretStore(
            service: service
        )
        let binding = Self.binding()
        let first = try firstStore.loadOrCreate(binding: binding)
        let nonce = try first.derive(
            domain: "possession-nonce-v1",
            discriminator: "payload-key",
            count: 24
        )
        let challenge = try first.derive(
            domain: "possession-challenge-v1",
            discriminator: "payload-key",
            count: 32
        )

        let restarted = try ProviderHandoffGatewayTransactionSecretStore(
            service: service
        ).loadOrCreate(binding: binding)

        #expect(first == restarted)
        #expect(
            try restarted.derive(
                domain: "possession-nonce-v1",
                discriminator: "payload-key",
                count: 24
            ) == nonce
        )
        #expect(
            try restarted.derive(
                domain: "possession-challenge-v1",
                discriminator: "payload-key",
                count: 32
            ) == challenge
        )
        #expect(Data(nonce) != challenge.prefix(24))
    }

    @Test
    func `A changed transaction binding cannot adopt another transaction seed`() throws {
        let service =
            "io.github.stephenlclarke.container-engine.tests.\(UUID().uuidString)"
        defer {
            SecItemDelete(
                [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service
                ] as CFDictionary
            )
        }
        let store = ProviderHandoffGatewayTransactionSecretStore(
            service: service
        )
        let first = try store.loadOrCreate(binding: Self.binding())
        var changed = Self.binding()
        changed.manifestID = "manifest-2"
        let second = try store.loadOrCreate(binding: changed)

        #expect(first.binding != second.binding)
        #expect(first.rawDerivationKey != second.rawDerivationKey)
        #expect(throws: ProviderHandoffGatewayTransactionSecretStoreError.notFound) {
            var absent = Self.binding()
            absent.tokenID = "token-absent"
            _ = try store.load(binding: absent)
        }
    }

    private static func binding()
        -> ProviderHandoffGatewayTransactionSecretBindingV1
    {
        ProviderHandoffGatewayTransactionSecretBindingV1(
            tokenID: "token-1",
            manifestID: "manifest-1",
            trustRegistryRevision: 7,
            destinationProviderFingerprint:
            "sha256:" + String(repeating: "a", count: 64),
            destinationStateRootUUID:
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            resultingAuthorityLineageUUID:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            resultingLineageDigestKeyVersion: 3
        )
    }
}
