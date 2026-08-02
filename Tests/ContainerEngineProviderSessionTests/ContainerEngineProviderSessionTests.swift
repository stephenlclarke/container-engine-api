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
    func `provider handshake forwards bytes and pull based streams`() async throws {
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
        let competing = try ContainerEngineProviderSessionServer(
            responder: TestResponder(),
            socketPath: socket,
            declaration: declaration,
            stateRootUUID: stateRoot
        )
        #expect(throws: (any Error).self) {
            try competing.start()
        }

        do {
            let descriptor = try await ContainerEngineProviderSessionClient.probe(
                socketPath: socket
            )
            #expect(descriptor.fingerprint.declaration == declaration)
            #expect(descriptor.fingerprint.stateRootUUID == stateRoot)
            let client = ContainerEngineProviderSessionClient(
                socketPath: socket,
                expectedFingerprint: descriptor.fingerprint
            )
            let bytes = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/bytes")
            )
            #expect(bytes.status == 200)
            if case let .bytes(data) = bytes.body {
                #expect(String(decoding: data, as: UTF8.self) == "provider-bytes")
            } else {
                Issue.record("expected bytes response")
            }

            let streamed = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/stream")
            )
            if case let .managedStream(session) = streamed.body {
                #expect(try await session.nextChunk() == Data("first".utf8))
                #expect(try await session.nextChunk() == Data("second".utf8))
                #expect(try await session.nextChunk() == nil)
            } else {
                Issue.record("expected managed stream response")
            }

            let largeStream = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/large-stream")
            )
            if case let .managedStream(session) = largeStream.body {
                #expect(try await session.nextChunk()?.count == 2 * 1024 * 1024 + 17)
                #expect(try await session.nextChunk() == nil)
            } else {
                Issue.record("expected large managed stream response")
            }

            let hijacked = await client.respond(
                to: DockerHTTPRequest(method: .post, target: "/hijack")
            )
            if case let .hijack(session, terminal) = hijacked.body {
                #expect(!terminal)
                let output = Task {
                    var iterator = session.frames.makeAsyncIterator()
                    return try await iterator.next()
                }
                try await session.write(Data("input-before-output".utf8))
                let frame = try await output.value
                #expect(frame?.channel == .standardOutput)
                #expect(frame?.data == Data("input-before-output".utf8))
                #expect(try await session.wait() == 0)
            } else {
                Issue.record("expected hijack response")
            }
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    @Test
    func `client rejects a different selected fingerprint`() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "ceps-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("provider.sock").path
        let server = try ContainerEngineProviderSessionServer(
            responder: TestResponder(),
            socketPath: socket,
            declaration: Self.declaration(),
            stateRootUUID: UUID()
        )
        try server.start()
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
        await server.shutdown()
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

private struct TestResponder: DockerHTTPResponder {
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        if request.target == "/hijack" {
            return DockerHTTPResponse(
                status: 101,
                body: .hijack(TestHijackSession(), terminal: false)
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
