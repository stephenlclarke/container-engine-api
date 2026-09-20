//===----------------------------------------------------------------------===//
// Copyright 2026 devcontainer and container-engine-api project authors.
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

import ContainerEngineWire
@testable import ContainerUnixHTTPClient
import ContainerUnixHTTPServer
import Darwin
import Foundation
import Logging
import Testing

@Suite(.serialized)
struct ContainerUnixHTTPClientTests {
    @Test
    func `HTTP failures never enter the successful streaming body callback`() async throws {
        let fixture = try ClientServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server()
        try await server.start()
        do {
            let client = try ContainerUnixHTTPClient(socketPath: fixture.socketPath)
            let chunks = LockedChunks()
            await #expect(throws: ContainerUnixHTTPClientError.server(status: 418, message: "teapot")) {
                try await client.stream(.init(method: .get, target: "/error"), onResponseHead: { _ in
                    chunks.append(Data("unexpected head".utf8))
                }, onBody: { chunks.append($0) })
            }
            #expect(chunks.data.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test(arguments: ["/fixed", "/stream"])
    func `successful head is acknowledged once before body`(_ path: String) async throws {
        let fixture = try ClientServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server()
        try await server.start()
        do {
            let client = try ContainerUnixHTTPClient(socketPath: fixture.socketPath)
            let chunks = LockedChunks()
            _ = try await client.stream(.init(method: .get, target: path), onResponseHead: { head in
                #expect(head.status == 200)
                #expect(head.body.isEmpty)
                #expect(chunks.data.isEmpty)
                chunks.append(Data("head:".utf8))
            }, onBody: { chunks.append($0) })
            #expect(chunks.data == Data((path == "/fixed" ? "head:fixed-body" : "head:first-second").utf8))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `head callback failure prevents body delivery`() async throws {
        let fixture = try ClientServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server()
        try await server.start()
        do {
            let client = try ContainerUnixHTTPClient(socketPath: fixture.socketPath)
            let chunks = LockedChunks()
            await #expect(throws: CancellationError.self) {
                try await client.stream(.init(method: .get, target: "/stream"), onResponseHead: { _ in
                    throw CancellationError()
                }, onBody: { chunks.append($0) })
            }
            #expect(chunks.data.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `duplex upgrades through the shared server and preserves multiplex frames`() async throws {
        let fixture = try ClientServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server()
        try await server.start()
        do {
            let client = try ContainerUnixHTTPClient(socketPath: fixture.socketPath, timeoutSeconds: 5)
            let connection = try await client.openDuplex(.init(method: .post, target: "/duplex"))
            defer { connection.close() }
            let payload = Data("shell command\n".utf8)
            try await connection.write(payload)
            try await connection.finishInput()
            var received = Data()
            while let bytes = try await connection.read() {
                received.append(bytes)
            }
            let expected = try DockerStreamFraming.encode(
                .init(channel: .standardOutput, data: payload),
                terminal: false
            )
                + DockerStreamFraming.encode(.init(channel: .standardError, data: Data("stderr".utf8)), terminal: false)
            #expect(received == expected)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `reads fixed and chunked responses from the real Unix server`() async throws {
        let fixture = try ClientServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server()
        try await server.start()
        do {
            let client = try ContainerUnixHTTPClient(socketPath: fixture.socketPath)
            let fixed = try await client.send(DockerHTTPRequest(method: .get, target: "/fixed"))
            #expect(fixed.status == 200)
            #expect(fixed.body == Data("fixed-body".utf8))

            let chunks = LockedChunks()
            let streamed = try await client.stream(
                DockerHTTPRequest(method: .get, target: "/stream"),
                maximumBodyBytes: 64
            ) { chunks.append($0) }
            #expect(streamed.status == 200)
            #expect(chunks.data == Data("first-second".utf8))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test
    func `rejects unsafe paths error responses and oversized bodies`() async throws {
        let fixture = try ClientServerFixture()
        defer { fixture.cleanup() }
        let regularFile = fixture.root.appendingPathComponent("not-a-socket")
        try Data().write(to: regularFile)
        let unsafeClient = try ContainerUnixHTTPClient(socketPath: regularFile.path)
        await #expect(throws: ContainerUnixHTTPClientError.self) {
            try await unsafeClient.send(DockerHTTPRequest(method: .get, target: "/"))
        }

        let server = fixture.server()
        try await server.start()
        do {
            let client = try ContainerUnixHTTPClient(socketPath: fixture.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.server(status: 418, message: "teapot")) {
                try await client.send(DockerHTTPRequest(method: .get, target: "/error"))
            }
            await #expect(throws: ContainerUnixHTTPClientError.responseTooLarge(4)) {
                try await client.send(
                    DockerHTTPRequest(method: .get, target: "/fixed"),
                    maximumBodyBytes: 4
                )
            }
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }
}

private struct ClientServerFixture {
    let root: URL
    let socketPath: String

    init() throws {
        root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_TMPDIR"]
            ?? FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("eci-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        socketPath = root.appendingPathComponent("engine.sock").path
    }

    func server() -> ContainerUnixHTTPServer {
        ContainerUnixHTTPServer(
            responder: ClientFixtureResponder(),
            socketPath: socketPath,
            logger: Logger(label: "ContainerUnixHTTPClientTests")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ClientFixtureResponder: DockerHTTPResponder {
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        switch request.target {
        case "/duplex":
            DockerHTTPResponse(
                status: 200,
                headers: [
                    "Connection": "Upgrade",
                    "Upgrade": "tcp",
                    "Content-Type": "application/vnd.docker.multiplexed-stream"
                ],
                body: .hijack(ClientEchoSession(), terminal: false)
            )
        case "/fixed":
            .text("fixed-body")
        case "/stream":
            DockerHTTPResponse(status: 200, body: .stream(AsyncThrowingStream { continuation in
                continuation.yield(Data("first-".utf8))
                continuation.yield(Data("second".utf8))
                continuation.finish()
            }))
        case "/error":
            (try? .json(DockerErrorEnvelope(message: "teapot"), status: 418))
                ?? .empty(status: 500)
        default:
            .empty(status: 404)
        }
    }
}

private actor ClientEchoSession: DockerHijackSession {
    nonisolated let frames: AsyncThrowingStream<DockerStreamFrame, any Error>
    private let continuation: AsyncThrowingStream<DockerStreamFrame, any Error>.Continuation
    private var input = Data()

    init() {
        (frames, continuation) = AsyncThrowingStream.makeStream()
    }

    func write(_ data: Data) {
        input.append(data)
    }

    func closeStandardInput() {
        continuation.yield(.init(channel: .standardOutput, data: input))
        continuation.yield(.init(channel: .standardError, data: Data("stderr".utf8)))
        continuation.finish()
    }

    func wait() -> Int32 {
        0
    }

    func cancel() {
        continuation.finish()
    }
}

private final class LockedChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.withLock { storage.append(data) }
    }

    var data: Data {
        lock.withLock { storage }
    }
}
