//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

@Suite("Identity/lifecycle/events handoff payload")
struct ProviderHandoffIdentityLifecyclePayloadTests {
    @Test
    func `empty identity lifecycle packages are rejected`() {
        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.emptyPackage
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    @Test
    func `package rejects a noncanonical source state UUID`() {
        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [fixture(
                    id: String(repeating: "a", count: 64),
                    name: "api"
                )],
                sourceStateRootUUID: "B87E85DF-8B88-49D9-811F-CF0FC2652879"
            )
        }
    }

    @Test
    func `package rejects a malformed selected provider fingerprint`() {
        var container = fixture(
            id: String(repeating: "a", count: 64),
            name: "api"
        )
        container.lifecycle.selectedProviderFingerprint = "sha256:not-a-digest"

        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.invalidContainer(
                container.lifecycle.containerID
            )
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [container],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    @Test
    func `package rejects multiple selected provider fingerprints`() {
        let first = fixture(
            id: String(repeating: "a", count: 64),
            name: "api"
        )
        var second = fixture(
            id: String(repeating: "b", count: 64),
            name: "worker",
            sequence: 2
        )
        second.lifecycle.selectedProviderFingerprint =
            "sha256:" + String(repeating: "e", count: 64)

        #expect(
            throws:
            ProviderHandoffIdentityLifecyclePayloadError
                .inconsistentProviderFingerprint(
                    second.lifecycle.containerID
                )
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [first, second],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    @Test
    func `decoder rejects an unsupported package schema version`() throws {
        var package = try ProviderHandoffIdentityLifecyclePayloadCodec.package(
            containers: [fixture(
                id: String(repeating: "a", count: 64),
                name: "api"
            )],
            sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
        )
        package.schemaVersion =
            ProviderHandoffPayloadPackageV1.currentSchemaVersion + 1

        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.containers(
                from: package
            )
        }
    }

    @Test
    func `package rejects non NFC lifecycle text`() {
        let identifier = String(repeating: "a", count: 64)
        var container = fixture(id: identifier, name: "api")
        container.lifecycle.canonicalName = "e\u{301}"

        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.invalidContainer(
                identifier
            )
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [container],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    @Test
    func `package is ordered and round trips without a second writer`() throws {
        let first = fixture(
            id: String(repeating: "b", count: 64),
            name: "worker",
            sequence: 2
        )
        let second = fixture(
            id: String(repeating: "a", count: 64),
            name: "api",
            sequence: 1
        )

        let package = try ProviderHandoffIdentityLifecyclePayloadCodec.package(
            containers: [first, second],
            sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
        )
        let decoded =
            try ProviderHandoffIdentityLifecyclePayloadCodec
                .containers(from: package)

        #expect(package.partKind == .identityLifecycleEvents)
        #expect(
            package.entries.map(\.entryID) == [
                String(repeating: "a", count: 64),
                String(repeating: "b", count: 64)
            ]
        )
        for entry in package.entries {
            guard
                case .byteString = try ProviderHandoffCanonicalCBOR.decode(
                    entry.canonicalRecordBytes
                )
            else {
                Issue.record("identity/lifecycle record is not canonical CBOR")
                continue
            }
        }
        #expect(decoded == [second, first])
    }

    @Test
    func `decoder rejects noncanonical entry ordering`() throws {
        var package = try ProviderHandoffIdentityLifecyclePayloadCodec.package(
            containers: [
                fixture(
                    id: String(repeating: "a", count: 64),
                    name: "api",
                    sequence: 1
                ),
                fixture(
                    id: String(repeating: "b", count: 64),
                    name: "worker",
                    sequence: 2
                )
            ],
            sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
        )
        package.entries.reverse()

        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.containers(
                from: package
            )
        }
    }

    @Test
    func `decoder rejects mixed source roots`() throws {
        var package = try ProviderHandoffIdentityLifecyclePayloadCodec.package(
            containers: [
                fixture(
                    id: String(repeating: "a", count: 64),
                    name: "api",
                    sequence: 1
                ),
                fixture(
                    id: String(repeating: "b", count: 64),
                    name: "worker",
                    sequence: 2
                )
            ],
            sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
        )
        package.entries[1].sourceStateRootUUID =
            "5b8582aa-fdca-47e3-8040-415c87da05a9"

        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.containers(
                from: package
            )
        }
    }

    @Test
    func `package rejects records above the transport limit`() {
        let identifier = String(repeating: "a", count: 64)
        var container = fixture(id: identifier, name: "api")
        container.pendingOperationIDs = [
            String(
                repeating: "x",
                count:
                ProviderHandoffPayloadPackageFileDecoder
                    .maximumCanonicalRecordBytes
            )
        ]

        #expect(
            throws:
            ProviderHandoffIdentityLifecyclePayloadError
                .recordTooLarge(identifier)
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [container],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    @Test
    func `bare JSON records are rejected by the package decoder`() throws {
        let container = fixture(
            id: String(repeating: "a", count: 64),
            name: "api"
        )
        let json = try JSONEncoder().encode(container)
        let package = ProviderHandoffPayloadPackageV1(
            partKind: .identityLifecycleEvents,
            entries: [
                ProviderHandoffPayloadPackageEntryV1(
                    entryID: container.lifecycle.containerID,
                    sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879",
                    recordKind:
                    ProviderHandoffIdentityLifecyclePayloadCodec.recordKind,
                    schemaVersion:
                    ProviderHandoffIdentityLifecycleContainerV1.schemaVersion,
                    canonicalRecordBytes: json
                )
            ]
        )

        #expect(throws: Error.self) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.containers(
                from: package
            )
        }
    }

    @Test
    func `noncanonical JSON inside canonical CBOR is rejected`() throws {
        let container = fixture(
            id: String(repeating: "a", count: 64),
            name: "api"
        )
        let source = try ProviderHandoffIdentityLifecyclePayloadCodec.package(
            containers: [container],
            sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
        )
        let sourceEntry = try #require(source.entries.first)
        guard
            case var .byteString(json) = try ProviderHandoffCanonicalCBOR.decode(
                sourceEntry.canonicalRecordBytes
            )
        else {
            Issue.record("identity/lifecycle record is not canonical CBOR")
            return
        }
        json.append(UInt8(ascii: " "))
        let package = try ProviderHandoffPayloadPackageV1(
            partKind: .identityLifecycleEvents,
            entries: [
                ProviderHandoffPayloadPackageEntryV1(
                    entryID: sourceEntry.entryID,
                    sourceStateRootUUID: sourceEntry.sourceStateRootUUID,
                    recordKind: sourceEntry.recordKind,
                    schemaVersion: sourceEntry.schemaVersion,
                    canonicalRecordBytes: ProviderHandoffCanonicalCBOR.encode(
                        .byteString(json)
                    )
                )
            ]
        )

        #expect(
            throws: ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.containers(
                from: package
            )
        }
    }

    @Test
    func `duplicate mutable names are rejected`() throws {
        let first = fixture(id: String(repeating: "a", count: 64), name: "api")
        let second = fixture(id: String(repeating: "b", count: 64), name: "api")

        #expect(throws: ProviderHandoffIdentityLifecyclePayloadError.duplicateName("api")) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [first, second],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    @Test
    func `event sequences are unique across the authority package`() throws {
        let firstID = String(repeating: "a", count: 64)
        let secondID = String(repeating: "b", count: 64)
        let first = fixture(id: firstID, name: "api", sequence: 7)
        let second = fixture(id: secondID, name: "worker", sequence: 7)

        #expect(
            throws:
            ProviderHandoffIdentityLifecyclePayloadError
                .invalidEventSequence(secondID)
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [first, second],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    @Test
    func `event revisions and generations cannot regress`() {
        let identifier = String(repeating: "a", count: 64)
        var regressingRevision = fixture(
            id: identifier,
            name: "api"
        )
        regressingRevision.events = [
            event(id: identifier, sequence: 1, revision: 2, generation: 1),
            event(id: identifier, sequence: 2, revision: 1, generation: 2)
        ]
        var regressingGeneration = fixture(
            id: identifier,
            name: "api"
        )
        regressingGeneration.events = [
            event(id: identifier, sequence: 1, revision: 1, generation: 2),
            event(id: identifier, sequence: 2, revision: 2, generation: 1)
        ]

        for container in [regressingRevision, regressingGeneration] {
            #expect(
                throws:
                ProviderHandoffIdentityLifecyclePayloadError
                    .invalidEventSequence(identifier)
            ) {
                try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                    containers: [container],
                    sourceStateRootUUID:
                    "b87e85df-8b88-49d9-811f-cf0fc2652879"
                )
            }
        }
    }

    @Test
    func `container IDs require lowercase ASCII hexadecimal bytes`() throws {
        let identifier = String(repeating: "ａ", count: 64)
        let container = fixture(id: identifier, name: "api")

        #expect(
            throws:
            ProviderHandoffIdentityLifecyclePayloadError
                .invalidContainer(identifier)
        ) {
            try ProviderHandoffIdentityLifecyclePayloadCodec.package(
                containers: [container],
                sourceStateRootUUID: "b87e85df-8b88-49d9-811f-cf0fc2652879"
            )
        }
    }

    private func fixture(
        id: String,
        name: String,
        sequence: UInt64 = 1
    ) -> ProviderHandoffIdentityLifecycleContainerV1 {
        ProviderHandoffIdentityLifecycleContainerV1(
            lifecycle: ContainerLifecycleRecordV2(
                containerID: id,
                canonicalName: name,
                immutableBundleKey: "bundle-\(name)",
                selectedProviderFingerprint: "sha256:" + String(repeating: "f", count: 64),
                snapshot: ContainerLifecycleSnapshotV2(
                    state: .exited,
                    exitCode: 0,
                    processGeneration: 1,
                    transitionRevision: 2,
                    operationGeneration: 2
                )
            ),
            events: [
                ContainerAuthorityEventV2(
                    sequence: sequence,
                    timeNano: 1,
                    action: "create",
                    actorID: id,
                    transitionRevision: 1,
                    operationGeneration: 1
                )
            ]
        )
    }

    private func event(
        id: String,
        sequence: UInt64,
        revision: UInt64,
        generation: UInt64
    ) -> ContainerAuthorityEventV2 {
        ContainerAuthorityEventV2(
            sequence: sequence,
            timeNano: sequence,
            action: "update",
            actorID: id,
            transitionRevision: revision,
            operationGeneration: generation
        )
    }
}
