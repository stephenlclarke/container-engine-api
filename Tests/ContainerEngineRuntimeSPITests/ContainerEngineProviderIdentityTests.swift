//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ContainerEngineProviderIdentityTests {
    @Test
    func `fingerprint is canonical across unordered declarations`() throws {
        let first = try declaration(
            revisions: ["container": "one", "containerization": "two"],
            capabilities: [
                capability("engine.images"),
                capability("engine.containers")
            ]
        )
        let second = try declaration(
            revisions: ["containerization": "two", "container": "one"],
            capabilities: [
                capability("engine.containers"),
                capability("engine.images")
            ]
        )
        let stateRoot = try #require(UUID(uuidString: "2A155723-0B40-4E1F-814C-3954817A8652"))

        let firstFingerprint = try ContainerEngineProviderFingerprint(
            declaration: first,
            stateRootUUID: stateRoot
        )
        let secondFingerprint = try ContainerEngineProviderFingerprint(
            declaration: second,
            stateRootUUID: stateRoot
        )

        #expect(first == second)
        #expect(firstFingerprint.digest == secondFingerprint.digest)
    }

    @Test
    func `selection is private stable and rejects implicit provider switch`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "container-engine-provider-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("provider.json")
        let store = ContainerEngineProviderSelectionStore(path: path)
        let selected = try store.select(declaration())
        let restarted = try store.select(declaration())

        #expect(restarted == selected)
        var fileStatus = stat()
        #expect(lstat(path.path, &fileStatus) == 0)
        #expect(fileStatus.st_mode & (S_IRWXG | S_IRWXO) == 0)
        var directoryStatus = stat()
        #expect(lstat(root.path, &directoryStatus) == 0)
        #expect(directoryStatus.st_mode & (S_IRWXG | S_IRWXO) == 0)

        let other = try declaration(version: "2.0.0")
        #expect(throws: ContainerEngineProviderIdentityError.self) {
            try store.select(other)
        }
        #expect(try store.load() == selected)
    }

    @Test
    func `provider state root is stable and participates in selection`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "container-engine-state-root-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let identityPath = root.appendingPathComponent("state-root-id")
        let identityStore = ContainerEngineStateRootIdentityStore(path: identityPath)
        let stateRoot = try identityStore.loadOrCreate()

        #expect(try identityStore.loadOrCreate() == stateRoot)
        let selectionStore = ContainerEngineProviderSelectionStore(
            path: root.appendingPathComponent("provider.json")
        )
        let selected = try selectionStore.select(
            declaration(),
            stateRootUUID: stateRoot
        )
        #expect(selected.stateRootUUID == stateRoot)
        #expect(throws: ContainerEngineProviderIdentityError.self) {
            try selectionStore.select(
                declaration(),
                stateRootUUID: UUID()
            )
        }
        #expect(try selectionStore.load() == selected)

        var fileStatus = stat()
        #expect(lstat(identityPath.path, &fileStatus) == 0)
        #expect(fileStatus.st_mode & (S_IRWXG | S_IRWXO) == 0)
    }

    @Test
    func `selection refuses a symbolic link`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "container-engine-provider-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        let path = root.appendingPathComponent("provider.json")
        try FileManager.default.createSymbolicLink(
            at: path,
            withDestinationURL: target
        )

        let store = ContainerEngineProviderSelectionStore(path: path)
        #expect(throws: (any Error).self) {
            try store.select(declaration())
        }
    }

    @Test
    func `capability declaration rejects duplicate version`() throws {
        let duplicate = try capability("engine.images")
        #expect(throws: ContainerEngineProviderIdentityError.self) {
            try declaration(capabilities: [duplicate, duplicate])
        }
    }

    private func declaration(
        version: String = "1.0.0",
        revisions: [String: String] = ["container": "one"],
        capabilities: [ContainerEngineProviderCapability]? = nil
    ) throws -> ContainerEngineProviderDeclaration {
        try ContainerEngineProviderDeclaration(
            profile: .stock,
            kind: .devcontainerStock,
            implementationVersion: version,
            runtimeRevisions: revisions,
            stateSchemaVersion: 3,
            capabilities: capabilities ?? [capability("engine.containers")]
        )
    }

    private func capability(
        _ identifier: String
    ) throws -> ContainerEngineProviderCapability {
        try ContainerEngineProviderCapability(
            identifier: identifier,
            status: .native
        )
    }
}
