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
        root = URL(fileURLWithPath: "/private/tmp")
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
