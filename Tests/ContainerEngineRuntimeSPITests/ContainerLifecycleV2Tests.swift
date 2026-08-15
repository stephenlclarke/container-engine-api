//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

@Suite("Container lifecycle v2 wire contract")
struct ContainerLifecycleV2Tests {
    @Test
    func `records round trip without losing transient state`() throws {
        let record = ContainerLifecycleRecordV2(
            containerID: String(repeating: "a", count: 64),
            canonicalName: "api",
            immutableBundleKey: "legacy-api",
            selectedProviderFingerprint: "sha256:provider",
            snapshot: ContainerLifecycleSnapshotV2(
                state: .restarting,
                running: true,
                restarting: true,
                oomKilled: true,
                exitCode: 137,
                error: "restart pending",
                startedAt: Date(timeIntervalSince1970: 10),
                finishedAt: Date(timeIntervalSince1970: 20),
                restartCount: 3,
                processGeneration: 7,
                transitionRevision: 11,
                operationGeneration: 13
            )
        )

        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ContainerLifecycleRecordV2.self, from: encoded)

        #expect(decoded == record)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.snapshot.state == .restarting)
        #expect(decoded.snapshot.running)
        #expect(decoded.snapshot.pid == 0)
        #expect(decoded.snapshot.operationGeneration == 13)
    }

    @Test
    func `generation-aware waits preserve their associated value`() throws {
        let condition = ContainerWaitConditionV2.processExit(generation: 42)
        let encoded = try JSONEncoder().encode(condition)
        let decoded = try JSONDecoder().decode(ContainerWaitConditionV2.self, from: encoded)

        #expect(decoded == condition)
    }

    @Test
    func `authority events retain state and operation ordering clocks`() throws {
        let event = ContainerAuthorityEventV2(
            sequence: 9,
            timeNano: 123,
            action: "restart",
            actorID: String(repeating: "b", count: 64),
            attributes: ["name": "api"],
            transitionRevision: 8,
            operationGeneration: 4
        )

        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(ContainerAuthorityEventV2.self, from: data) == event)
    }
}
