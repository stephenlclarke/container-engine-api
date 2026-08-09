//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

@Suite("Provider handoff lineage key store", .serialized)
struct ProviderHandoffLineageKeyStoreTests {
    @Test
    func `Lineage keys survive restart and remain version separated`() throws {
        let fixture = Fixture()
        defer { fixture.remove(version: 1); fixture.remove(version: 2) }

        let first = try fixture.store.loadOrCreate(
            binding: fixture.binding(version: 1)
        )
        let restarted = try fixture.store.loadOrCreate(
            binding: fixture.binding(version: 1)
        )
        let rotated = try fixture.store.loadOrCreate(
            binding: fixture.binding(version: 2)
        )

        #expect(first == restarted)
        #expect(first.rawHMACSHA256Key.count == 32)
        #expect(rotated.rawHMACSHA256Key.count == 32)
        #expect(first.rawHMACSHA256Key != rotated.rawHMACSHA256Key)
        #expect(rotated.keyVersion == 2)
    }

    @Test
    func `Invalid and changed bindings cannot retrieve a lineage key`() throws {
        let fixture = Fixture()
        defer { fixture.remove(version: 1) }
        _ = try fixture.store.loadOrCreate(binding: fixture.binding(version: 1))

        var changed = fixture.binding(version: 1)
        changed.providerFingerprint = "sha256:" + String(repeating: "b", count: 64)
        #expect(throws: ProviderHandoffLineageKeyStoreError.notFound) {
            try fixture.store.load(binding: changed)
        }

        var invalid = fixture.binding(version: 1)
        invalid.keyVersion = 0
        #expect(throws: ProviderHandoffLineageKeyStoreError.invalidBinding) {
            try fixture.store.loadOrCreate(binding: invalid)
        }
    }

    private struct Fixture {
        let service =
            "io.github.stephenlclarke.container-engine.tests.\(UUID().uuidString)"
        let accountPrefix = "lineage-key"

        var store: ProviderHandoffLineageKeyStore {
            ProviderHandoffLineageKeyStore(
                service: service,
                accountPrefix: accountPrefix
            )
        }

        func binding(version: UInt64) -> ProviderHandoffLineageKeyBindingV1 {
            ProviderHandoffLineageKeyBindingV1(
                providerFingerprint: "sha256:" + String(repeating: "a", count: 64),
                sourceStateRootUUID: "10000000-0000-4000-8000-000000000001",
                authorityLineageUUID: "20000000-0000-4000-8000-000000000002",
                keyVersion: version
            )
        }

        func remove(version: UInt64) {
            try? ProviderHandoffLineageKeyStore.removeForTesting(
                service: service,
                accountPrefix: accountPrefix,
                binding: binding(version: version)
            )
        }
    }
}
