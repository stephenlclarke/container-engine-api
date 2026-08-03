//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerEngineWire
import Foundation
import Testing

@Suite(.serialized)
struct ContainerEngineProviderSessionTests {
    @Test
    func `shutdown wakes an idle provider listener`() async throws {
        try await withServer { _, _, _ in }
    }

    @Test
    func `provider ownership and handshake are exclusive`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let competing = try ContainerEngineProviderSessionServer(
                responder: TestResponder(),
                socketPath: socket,
                declaration: declaration,
                stateRootUUID: stateRoot
            )
            #expect(throws: (any Error).self) {
                try competing.start()
            }

            _ = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
        }
    }

    @Test
    func `provider forwards byte responses`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/bytes")
            )
            #expect(response.status == 200)
            if case let .bytes(data) = response.body {
                #expect(String(decoding: data, as: UTF8.self) == "provider-bytes")
            } else {
                Issue.record("expected bytes response")
            }
        }
    }

    @Test
    func `provider forwards pull based streams`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/stream")
            )
            if case let .managedStream(session) = response.body {
                #expect(try await session.nextChunk() == Data("first".utf8))
                #expect(try await session.nextChunk() == Data("second".utf8))
                #expect(try await session.nextChunk() == nil)
            } else {
                Issue.record("expected managed stream response")
            }
        }
    }

    @Test
    func `provider forwards large pull based stream chunks`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/large-stream")
            )
            if case let .managedStream(session) = response.body {
                #expect(try await session.nextChunk()?.count == 2 * 1024 * 1024 + 17)
                #expect(try await session.nextChunk() == nil)
            } else {
                Issue.record("expected large managed stream response")
            }
        }
    }

    @Test
    func `provider hijack accepts queued input`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            try await session.write(Data("queued-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `provider hijack relays queued input`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            try await session.write(Data("queued-input".utf8))
            var iterator = session.frames.makeAsyncIterator()
            let frame = try await iterator.next()
            #expect(frame?.channel == .standardOutput)
            #expect(frame?.data == Data("queued-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `provider hijack relays concurrent input`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            let output = Task {
                var iterator = session.frames.makeAsyncIterator()
                return try await iterator.next()
            }
            try await session.write(Data("concurrent-input".utf8))
            let frame = try await output.value
            #expect(frame?.channel == .standardOutput)
            #expect(frame?.data == Data("concurrent-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `provider hijack returns exit status`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            #expect(try await session.wait() == 0)
        }
    }

    @Test
    func `provider hijack relays input before returning exit status`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            do {
                let output = Task {
                    var iterator = session.frames.makeAsyncIterator()
                    return try await iterator.next()
                }
                try await session.write(Data("input-before-output".utf8))
                let frame = try await output.value
                #expect(frame?.channel == .standardOutput)
                #expect(frame?.data == Data("input-before-output".utf8))
                #expect(try await session.wait() == 0)
            } catch {
                await session.cancel()
                throw error
            }
        }
    }

    @Test
    func `provider preserves websocket response identity and duplex bytes`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/websocket")
            )
            guard case let .webSocket(session) = response.body else {
                Issue.record("expected websocket response")
                return
            }
            let output = Task {
                var iterator = session.frames.makeAsyncIterator()
                return try await iterator.next()
            }
            try await session.write(Data("websocket-input".utf8))
            let frame = try await output.value
            #expect(frame?.channel == .standardOutput)
            #expect(frame?.data == Data("websocket-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `client rejects a different selected fingerprint`() async throws {
        try await withServer { socket, _, _ in
            let other = try ContainerEngineProviderFingerprint(
                declaration: Self.declaration(version: "2.0.0"),
                stateRootUUID: UUID()
            )
            let client = ContainerEngineProviderSessionClient(
                socketPath: socket,
                expectedFingerprint: other
            )

            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/bytes")
            )
            #expect(response.status == 503)
        }
    }

    private func withServer(
        _ operation: (
            _ socket: String,
            _ declaration: ContainerEngineProviderDeclaration,
            _ stateRoot: UUID
        ) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "ceps-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("provider.sock").path
        let declaration = try Self.declaration()
        let stateRoot = UUID()
        let server = try ContainerEngineProviderSessionServer(
            responder: TestResponder(),
            socketPath: socket,
            declaration: declaration,
            stateRootUUID: stateRoot
        )
        try server.start()

        do {
            try await operation(socket, declaration, stateRoot)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    private static func client(
        socket: String,
        declaration: ContainerEngineProviderDeclaration,
        stateRoot: UUID
    ) async throws -> ContainerEngineProviderSessionClient {
        let descriptor = try await ContainerEngineProviderSessionClient.probe(
            socketPath: socket
        )
        #expect(descriptor.fingerprint.declaration == declaration)
        #expect(descriptor.fingerprint.stateRootUUID == stateRoot)
        return ContainerEngineProviderSessionClient(
            socketPath: socket,
            expectedFingerprint: descriptor.fingerprint
        )
    }

    private static func hijackSession(
        client: ContainerEngineProviderSessionClient
    ) async throws -> any DockerHijackSession {
        let response = await client.respond(
            to: DockerHTTPRequest(method: .post, target: "/hijack")
        )
        guard case let .hijack(session, terminal) = response.body else {
            throw ProviderSessionTestError.expectedHijack
        }
        #expect(!terminal)
        return session
    }

    private static func declaration(
        version: String = "1.0.0"
    ) throws -> ContainerEngineProviderDeclaration {
        try ContainerEngineProviderDeclaration(
            profile: .stock,
            kind: .devcontainerStock,
            implementationVersion: version,
            runtimeRevisions: ["runtime": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                ContainerEngineProviderCapability(
                    identifier: "engine.routes",
                    status: .native
                )
            ]
        )
    }
}

private enum ProviderSessionTestError: Error {
    case expectedHijack
}

private struct TestResponder: DockerHTTPResponder {
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        if request.target == "/hijack" {
            return DockerHTTPResponse(
                status: 101,
                body: .hijack(TestHijackSession(), terminal: false)
            )
        }
        if request.target == "/websocket" {
            return DockerHTTPResponse(
                status: 101,
                body: .webSocket(TestHijackSession())
            )
        }
        if request.target == "/large-stream" {
            return DockerHTTPResponse(
                status: 200,
                body: .managedStream(
                    TestStreamSession(
                        chunks: [Data(repeating: 0x61, count: 2 * 1024 * 1024 + 17)]
                    )
                )
            )
        }
        if request.target == "/stream" {
            return DockerHTTPResponse(
                status: 200,
                body: .managedStream(TestStreamSession())
            )
        }
        return DockerHTTPResponse.text("provider-bytes")
    }
}

private actor TestStreamSession: DockerHTTPStreamSession {
    var chunks: [Data]

    init(chunks: [Data] = [Data("first".utf8), Data("second".utf8)]) {
        self.chunks = chunks
    }

    func nextChunk() -> Data? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func close() {}
    func cancel() {}
}

private final class TestHijackSession: DockerHijackSession, @unchecked Sendable {
    private let state = TestHijackState()

    var frames: AsyncThrowingStream<DockerStreamFrame, any Error> {
        let state = state
        return AsyncThrowingStream(unfolding: {
            await state.nextFrame()
        })
    }

    func write(_ data: Data) async throws {
        await state.write(data)
    }

    func closeStandardInput() async throws {}

    func wait() async throws -> Int32 {
        0
    }

    func cancel() async {}
}

private actor TestHijackState {
    var input: Data?
    var continuation: CheckedContinuation<Data, Never>?
    var emitted = false

    func write(_ data: Data) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: data)
        } else {
            input = data
        }
    }

    func nextFrame() async -> DockerStreamFrame? {
        guard !emitted else {
            return nil
        }
        emitted = true
        let data: Data
        if let input {
            data = input
            self.input = nil
        } else {
            data = await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return DockerStreamFrame(channel: .standardOutput, data: data)
    }
}
