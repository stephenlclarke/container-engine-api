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
@testable import ContainerUnixHTTPServer
import Darwin
import Foundation
import Logging
import Testing

@Suite(.serialized)
struct ContainerUnixHTTPServerTests {
    @Test
    func `server exposes bytes streams and a half-close safe hijack`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = EchoHijackSession()
        let managedStream = ManagedFixtureStream(chunks: ["managed-", "stream"])
        let server = fixture.server(
            responder: FixtureResponder(
                session: session,
                managedStream: managedStream
            )
        )
        try await server.start()

        do {
            let ping = try fixture.curl("/_ping")
            #expect(ping.status == 200)
            #expect(ping.body == "OK")

            let streamed = try fixture.curl("/stream")
            #expect(streamed.status == 200)
            #expect(streamed.body == "first-second")

            let managed = try fixture.curl("/managed-stream")
            #expect(managed.status == 200)
            #expect(managed.body == "managed-stream")
            #expect(await managedStream.closeCount == 1)
            #expect(await managedStream.cancelCount == 0)

            let echo = try fixture.curl(
                "/echo",
                method: "POST",
                body: "request-body"
            )
            #expect(echo.status == 200)
            #expect(echo.body == "request-body")
            #expect(server.bufferedRequestBodyBytes == 0)

            let unsupported = try fixture.curl("/_ping", method: "OPTIONS")
            #expect(unsupported.status == 405)
            #expect(unsupported.body.contains("unsupported HTTP method"))

            let payload = Data("input-before-upgrade".utf8)
            let process = try fixture.startEarlyHalfClose(payload: payload)
            defer { stop(process) }
            for _ in 0 ..< 100 where !session.inputClosed {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(session.inputClosed)
            #expect(session.input == payload)

            for _ in 0 ..< 100 where server.activeConnectionCount != 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(server.activeConnectionCount == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    @Test
    func `server performs a binary websocket handshake and forwards unframed bytes`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = EchoHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session)
        )
        try await server.start()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "GET /websocket HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: keep-alive, Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        )
        let response = try client.readUntil(Data("\r\n\r\n".utf8))
        let responseText = String(decoding: response, as: UTF8.self)
        #expect(responseText.contains("101 Switching Protocols"))
        #expect(
            responseText.contains(
                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
            )
        )

        let payload = Data("websocket-input".utf8)
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var frame = Data([0x82, 0x80 | UInt8(payload.count)])
        frame.append(contentsOf: mask)
        frame.append(
            contentsOf: payload.enumerated().map {
                $0.element ^ mask[$0.offset % mask.count]
            }
        )
        try client.write(frame)
        try client.closeWrite()

        var expected = Data([0x82, UInt8(payload.count)])
        expected.append(payload)
        _ = try client.readUntil(expected)
        #expect(session.input == payload)
        #expect(session.inputClosed)

        try await server.shutdown()
    }

    @Test
    func `server reassembles independently masked websocket fragments`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = EchoHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session)
        )
        try await server.start()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "GET /websocket HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        )
        _ = try client.readUntil(Data("\r\n\r\n".utf8))

        let firstPayload = Data("fragmented-".utf8)
        let finalPayload = Data("input".utf8)
        let firstMask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        let finalMask: [UInt8] = [0x87, 0x65, 0x43, 0x21]
        var firstFrame = Data([0x02, 0x80 | UInt8(firstPayload.count)])
        firstFrame.append(contentsOf: firstMask)
        firstFrame.append(
            contentsOf: firstPayload.enumerated().map {
                $0.element ^ firstMask[$0.offset % firstMask.count]
            }
        )
        var finalFrame = Data([0x80, 0x80 | UInt8(finalPayload.count)])
        finalFrame.append(contentsOf: finalMask)
        finalFrame.append(
            contentsOf: finalPayload.enumerated().map {
                $0.element ^ finalMask[$0.offset % finalMask.count]
            }
        )
        try client.write(firstFrame + finalFrame)
        try client.closeWrite()

        let payload = firstPayload + finalPayload
        var expected = Data([0x82, UInt8(payload.count)])
        expected.append(payload)
        _ = try client.readUntil(expected)
        #expect(session.input == payload)
        #expect(session.inputClosed)

        try await server.shutdown()
    }

    @Test
    func `server emits Docker websocket handshake errors and cancels its session`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = CancellableHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session)
        )
        try await server.start()
        for (request, expected, expectedHeader) in [
            (
                "GET /websocket HTTP/1.1\r\nHost: localhost\r\n\r\n",
                "not websocket protocol",
                nil
            ),
            (
                "GET /websocket HTTP/1.1\r\nHost: localhost\r\n"
                    + "Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n",
                "mismatch challenge/response",
                nil
            ),
            (
                "GET /websocket HTTP/1.1\r\nHost: localhost\r\n"
                    + "Connection: Upgrade\r\nUpgrade: websocket\r\n"
                    + "Sec-WebSocket-Key: key\r\n"
                    + "Sec-WebSocket-Version: 12\r\n\r\n",
                "missing or bad WebSocket Version",
                "Sec-WebSocket-Version: 13"
            )
        ] as [(String, String, String?)] {
            let client = try UnixSocketClient(path: fixture.socketPath)
            try client.write(request)
            let response = try client.readUntil(Data(expected.utf8))
            let responseText = String(decoding: response, as: UTF8.self)
            #expect(responseText.contains("400 Bad Request"))
            if let expectedHeader {
                #expect(responseText.contains(expectedHeader))
            }
            client.close()
        }
        #expect(await eventually { session.cancelled })
        try await server.shutdown()
    }

    @Test
    func `server accepts Docker websocket keys without RFC nonce decoding`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = CancellableHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session)
        )
        try await server.start()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "GET /websocket HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: bad\r\n\r\n"
        )
        let response = try client.readUntil(Data("\r\n\r\n".utf8))
        let responseText = String(decoding: response, as: UTF8.self)
        #expect(responseText.contains("101 Switching Protocols"))
        #expect(
            responseText.contains(
                "Sec-WebSocket-Accept: 2T5rb/2MG3XPa/8Yciq6PesMZgc="
            )
        )
        let mask: [UInt8] = [0x87, 0x65, 0x43, 0x21]
        let payload: [UInt8] = [0x03, 0xE8]
        var closeFrame = Data([0x88, 0x80 | UInt8(payload.count)])
        closeFrame.append(contentsOf: mask)
        closeFrame.append(
            contentsOf: payload.enumerated().map {
                $0.element ^ mask[$0.offset % mask.count]
            }
        )
        try client.write(closeFrame)
        _ = try client.readUntil(Data([0x88, 0x02, 0x03, 0xE8]))
        client.close()
        #expect(await eventually { session.cancelled })
        try await server.shutdown()
    }

    @Test
    func `server rejects unmasked websocket client frames`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = CancellableHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session)
        )
        try await server.start()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "GET /websocket HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        )
        _ = try client.readUntil(Data("\r\n\r\n".utf8))
        try client.write(Data([0x82, 0x01, 0x41]))

        _ = try client.readUntil(Data([0x88, 0x02, 0x03, 0xEA]))
        #expect(session.input.isEmpty)
        #expect(await eventually { session.cancelled })
        try await server.shutdown()
    }

    @Test
    func `server rejects fragmented websocket control frames with a protocol close`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = CancellableHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session)
        )
        try await server.start()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "GET /websocket HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        )
        _ = try client.readUntil(Data("\r\n\r\n".utf8))
        try client.write(Data([0x09, 0x80, 0x12, 0x34, 0x56, 0x78]))

        _ = try client.readUntil(Data([0x88, 0x02, 0x03, 0xEA]))
        #expect(session.input.isEmpty)
        #expect(await eventually { session.cancelled })
        try await server.shutdown()
    }

    @Test
    func `server rejects oversized websocket frames with a message-too-large close`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = CancellableHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session)
        )
        try await server.start()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "GET /websocket HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        )
        _ = try client.readUntil(Data("\r\n\r\n".utf8))
        var frame = Data([0x82, 0xFF])
        var declaredLength = UInt64(16 * 1024 * 1024 + 1).bigEndian
        withUnsafeBytes(of: &declaredLength) { frame.append(contentsOf: $0) }
        try client.write(frame)

        _ = try client.readUntil(Data([0x88, 0x02, 0x03, 0xF1]))
        #expect(session.input.isEmpty)
        #expect(await eventually { session.cancelled })
        try await server.shutdown()
    }

    @Test
    func `managed stream cancels its source when its connection is forced closed`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let managedStream = ManagedFixtureStream(blocks: true)
        let server = fixture.server(
            responder: FixtureResponder(managedStream: managedStream),
            limits: testLimits(
                aggregateBytes: 256,
                gracefulDrainTimeout: .milliseconds(20)
            )
        )
        try await server.start()

        let client = try UnixSocketClient(path: fixture.socketPath)
        try client.write("GET /managed-stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(await eventuallyAsync { await managedStream.started })
        try await server.shutdown()
        #expect(await eventuallyAsync { await managedStream.cancelCount == 1 })
        #expect(await managedStream.closeCount == 0)
        client.close()
    }

    @Test
    func `server serializes pipelined responses`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(responder: FixtureResponder())
        try await server.start()

        do {
            let response = try fixture.pipelined(
                "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n"
                    + "GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n"
            )
            let slow = try #require(response.range(of: "slow-response"))
            let fast = try #require(response.range(of: "fast-response"))
            #expect(slow.lowerBound < fast.lowerBound)
            #expect(response.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test
    func `server preserves duplicate request header spelling and order`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(responder: FixtureResponder())
        try await server.start()

        do {
            let response = try fixture.pipelined(
                "GET /headers HTTP/1.1\r\n"
                    + "Host: localhost\r\n"
                    + "X-Order: first\r\n"
                    + "x-order: second\r\n\r\n"
            )
            #expect(response.contains("\r\n\r\nX-Order=first\nx-order=second"))
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test
    func `server bounds request and pipeline buffering`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let limits = ContainerUnixHTTPServerLimits(
            maximumRequestBodyBytes: 64,
            maximumBufferedRequestBodyBytes: 64,
            maximumPendingRequests: 1
        )
        let server = fixture.server(
            responder: FixtureResponder(),
            limits: limits
        )
        try await server.start()

        do {
            let oversized = try fixture.curl(
                "/echo",
                method: "POST",
                body: String(repeating: "x", count: 65)
            )
            #expect(oversized.status == 413)

            let body = String(repeating: "x", count: 40)
            let boundedBodies = try fixture.pipelined(
                "POST /hold HTTP/1.1\r\n"
                    + "Host: localhost\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n\r\n"
                    + body
                    + "POST /hold HTTP/1.1\r\n"
                    + "Host: localhost\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n\r\n"
                    + body
            )
            #expect(boundedBodies.components(separatedBy: "HTTP/1.1").count < 3)

            let boundedQueue = try fixture.pipelined(
                "GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n"
                    + "GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n"
                    + "GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n"
            )
            #expect(boundedQueue.components(separatedBy: "HTTP/1.1").count < 4)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test
    func `server rejects unsafe paths and concurrent ownership`() async throws {
        let unsafeFixture = try ServerFixture()
        defer { unsafeFixture.cleanup() }
        try Data("not a socket".utf8).write(
            to: URL(fileURLWithPath: unsafeFixture.socketPath)
        )
        let unsafeServer = unsafeFixture.server(responder: FixtureResponder())
        await #expect(throws: ContainerUnixHTTPServerError.self) {
            try await unsafeServer.start()
        }
        try await unsafeServer.shutdown()

        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let first = fixture.server(responder: FixtureResponder())
        let second = fixture.server(responder: FixtureResponder())
        let abandoned = fixture.server(responder: FixtureResponder())
        try await first.start()
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.root.path
        )
        let lockAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.socketPath + ".lock"
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((lockAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await #expect(throws: ContainerUnixHTTPServerError.self) {
            try await second.start()
        }
        await #expect(throws: ContainerUnixHTTPServerError.self) {
            try await abandoned.start()
        }
        try await abandoned.shutdown()
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))
        try await first.shutdown()
        try await second.start()
        try await second.shutdown()
    }

    @Test
    func `shutdown never unlinks a replaced socket inode`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(responder: FixtureResponder())
        try await server.start()

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.socketPath
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let displaced = fixture.root.appendingPathComponent("displaced.sock").path
        guard rename(fixture.socketPath, displaced) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let replacement = Data("replacement".utf8)
        try replacement.write(to: URL(fileURLWithPath: fixture.socketPath))

        await #expect(throws: ContainerUnixHTTPServerError.self) {
            try await server.shutdown()
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.socketPath)) == replacement)
    }

    @Test
    func `socket paths are validated against raw components and sockaddr capacity`() async throws {
        let overlong = "/tmp/" + String(repeating: "é", count: 50) + "/engine.sock"
        let invalidPaths = [
            "",
            "relative/engine.sock",
            "/",
            "/tmp/",
            "/tmp//engine.sock",
            "/tmp/./engine.sock",
            "/tmp/../engine.sock",
            "/tmp/engine\0.sock",
            overlong
        ]

        for path in invalidPaths {
            let server = ContainerUnixHTTPServer(
                responder: FixtureResponder(),
                socketPath: path,
                logger: Logger(label: "container-engine-api-tests")
            )
            await #expect(throws: ContainerUnixHTTPServerSocketPathError(path: path)) {
                try await server.start()
            }
            try await server.shutdown()
        }

        let prefix = "cea-\(UUID().uuidString.prefix(8))-"
        let rootName = prefix + String(repeating: "a", count: 86 - prefix.count)
        let exactRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(rootName, isDirectory: true)
        let fixture = try ServerFixture(root: exactRoot)
        defer { fixture.cleanup() }
        #expect(fixture.socketPath.utf8.count == 103)
        let server = fixture.server(responder: FixtureResponder())
        try await server.start()
        try await server.shutdown()
    }

    @Test
    func `legacy limits initializer safely derives its aggregate budget`() {
        let bufferedBytes = 3_000_000_000
        let limits = ContainerUnixHTTPServerLimits(
            maximumRequestBodyBytes: 1,
            maximumBufferedRequestBodyBytes: bufferedBytes,
            maximumPendingRequests: 1
        )

        #expect(limits.maximumAggregateBufferedRequestBodyBytes >= bufferedBytes)
    }

    @Test
    func `server never changes caller owned parent permissions`() async throws {
        let fixture = try ServerFixture(directoryMode: 0o755)
        defer { fixture.cleanup() }
        let server = fixture.server(responder: FixtureResponder())

        try await server.start()
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.root.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        try await server.shutdown()
    }

    @Test
    func `same-user credential policy fails closed on a mismatched uid`() {
        #expect(throws: DockerPeerCredentialError.userMismatch(
            expected: 501,
            actual: 502
        )) {
            try DockerPeerCredentialValidator.validate(
                peerUserID: 502,
                expectedUserID: 501
            )
        }
    }

    @Test
    func `concurrent starts admit exactly one lifecycle transition`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let server = fixture.server(responder: FixtureResponder())

        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 2 {
                group.addTask {
                    do {
                        try await server.start()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        #expect(outcomes.filter(\.self).count == 1)
        #expect(try fixture.curl("/_ping").status == 200)
        try await server.shutdown()
    }

    @Test
    func `failed post-bind start drains children and budgets before retry`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let gate = StartFailureGate()
        let limits = testLimits(
            maximumConnections: 1,
            aggregateBytes: 64
        )
        let server = ContainerUnixHTTPServer(
            responder: FixtureResponder(),
            socketPath: fixture.socketPath,
            logger: Logger(label: "container-engine-api-tests"),
            limits: limits,
            startValidationHook: {
                try await gate.failFirstStartAfterBind()
            }
        )
        let startTask = Task {
            try await server.start()
        }
        await gate.waitUntilBound()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "POST /hold HTTP/1.1\r\nHost: localhost\r\n"
                + "Content-Length: 10\r\n\r\npart"
        )
        #expect(await eventually {
            server.activeConnectionCount == 1
                && server.bufferedRequestBodyBytes == 4
        })

        gate.releaseFailure()
        await #expect(throws: FixtureError.self) {
            try await startTask.value
        }
        #expect(server.activeConnectionCount == 0)
        #expect(server.bufferedRequestBodyBytes == 0)

        try await server.start()
        #expect(try fixture.curl("/_ping").status == 200)
        try await server.shutdown()
    }

    @Test
    func `server enforces the global connection ceiling`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let limits = testLimits(
            maximumConnections: 1,
            aggregateBytes: 128
        )
        let server = fixture.server(
            responder: FixtureResponder(),
            limits: limits
        )
        try await server.start()
        let first = try UnixSocketClient(path: fixture.socketPath)
        defer { first.close() }
        #expect(await eventually { server.activeConnectionCount == 1 })

        let rejected: Bool
        do {
            _ = try fixture.curl("/_ping")
            rejected = false
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(server.activeConnectionCount == 1)

        first.close()
        #expect(await eventually { server.activeConnectionCount == 0 })
        try await server.shutdown()
    }

    @Test
    func `aggregate body budget spans connections and releases on close`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let limits = testLimits(
            maximumConnections: 2,
            aggregateBytes: 64
        )
        let server = fixture.server(
            responder: FixtureResponder(),
            limits: limits
        )
        try await server.start()
        let first = try UnixSocketClient(path: fixture.socketPath)
        defer { first.close() }
        try first.write(
            "POST /hold HTTP/1.1\r\nHost: localhost\r\nContent-Length: 60\r\n\r\n"
                + String(repeating: "a", count: 40)
        )
        #expect(await eventually { server.bufferedRequestBodyBytes == 40 })

        let second = try UnixSocketClient(path: fixture.socketPath)
        defer { second.close() }
        try second.write(
            "POST /hold HTTP/1.1\r\nHost: localhost\r\nContent-Length: 30\r\n\r\n"
                + String(repeating: "b", count: 30)
        )
        #expect(await eventually {
            server.activeConnectionCount == 1
                && server.bufferedRequestBodyBytes == 40
        })

        first.close()
        #expect(await eventually { server.bufferedRequestBodyBytes == 0 })
        try await server.shutdown()
    }

    @Test
    func `idle and partial-request deadlines close only stalled clients`() async throws {
        let idleFixture = try ServerFixture()
        defer { idleFixture.cleanup() }
        let idleServer = idleFixture.server(
            responder: FixtureResponder(),
            limits: testLimits(
                aggregateBytes: 128,
                readTimeout: .milliseconds(100),
                idleTimeout: .milliseconds(100)
            )
        )
        try await idleServer.start()
        let idleClient = try UnixSocketClient(path: idleFixture.socketPath)
        defer { idleClient.close() }
        #expect(await eventually { idleServer.activeConnectionCount == 1 })
        #expect(await eventually { idleServer.activeConnectionCount == 0 })
        try await idleServer.shutdown()

        let readFixture = try ServerFixture()
        defer { readFixture.cleanup() }
        let readServer = readFixture.server(
            responder: FixtureResponder(),
            limits: testLimits(
                aggregateBytes: 128,
                readTimeout: .milliseconds(100),
                idleTimeout: .seconds(1)
            )
        )
        try await readServer.start()
        let partialClient = try UnixSocketClient(path: readFixture.socketPath)
        defer { partialClient.close() }
        try partialClient.write("GET /_ping HTTP/1.1\r\nHost:")
        #expect(await eventually { readServer.activeConnectionCount == 1 })
        #expect(await eventually { readServer.activeConnectionCount == 0 })
        let completed = try readFixture.curl("/hold")
        #expect(completed.status == 200)
        #expect(completed.body == "held-response")
        try await readServer.shutdown()
    }

    @Test
    func `graceful drain completes an active response`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let responder = SlowResponder(delay: .milliseconds(100))
        let server = fixture.server(
            responder: responder,
            limits: testLimits(
                aggregateBytes: 128,
                gracefulDrainTimeout: .seconds(1)
            )
        )
        try await server.start()
        let responseTask = Task.detached {
            try fixture.curl("/slow-drain")
        }
        #expect(await eventually { responder.started })

        try await server.shutdown()
        let response = try await responseTask.value
        #expect(response.status == 200)
        #expect(response.body == "drained-response")
        #expect(server.activeConnectionCount == 0)
    }

    @Test
    func `drain preserves accepted work ahead of a partial pipelined request`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let responder = SlowResponder(delay: .milliseconds(150))
        let server = fixture.server(
            responder: responder,
            limits: testLimits(
                aggregateBytes: 128,
                readTimeout: .milliseconds(50),
                gracefulDrainTimeout: .seconds(1)
            )
        )
        try await server.start()
        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "GET /slow-drain HTTP/1.1\r\nHost: localhost\r\n\r\n"
                + "POST /hold HTTP/1.1\r\nHost: localhost\r\n"
                + "Content-Length: 10\r\n\r\npart"
        )
        #expect(await eventually { responder.started })
        #expect(await eventually { server.bufferedRequestBodyBytes == 4 })

        try await server.shutdown()
        let response = try client.readUntil(Data("drained-response".utf8))
        #expect(String(decoding: response, as: UTF8.self).contains("drained-response"))
        #expect(server.bufferedRequestBodyBytes == 0)
    }

    @Test
    func `drain deadline cancels a cooperative active responder`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let responder = SlowResponder(delay: .seconds(10))
        let server = fixture.server(
            responder: responder,
            limits: testLimits(
                aggregateBytes: 128,
                gracefulDrainTimeout: .milliseconds(100)
            )
        )
        try await server.start()
        let responseTask = Task.detached {
            try fixture.curl("/slow-drain")
        }
        #expect(await eventually { responder.started })

        let clock = ContinuousClock()
        let started = clock.now
        try await server.shutdown()
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(server.activeConnectionCount == 0)
        do {
            _ = try await responseTask.value
            Issue.record("forced drain unexpectedly completed the HTTP response")
        } catch {
            // The forced close is the expected client-visible outcome.
        }
    }

    @Test
    func `drain deadline force closes hijacks and lifecycle is one shot`() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let session = CancellableHijackSession()
        let server = fixture.server(
            responder: FixtureResponder(session: session),
            limits: testLimits(
                aggregateBytes: 128,
                gracefulDrainTimeout: .milliseconds(100)
            )
        )
        try await server.start()
        await #expect(throws: ContainerUnixHTTPServerError.alreadyStarted) {
            try await server.start()
        }

        let client = try UnixSocketClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            "POST /hijack HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: tcp\r\n"
                + "Content-Length: 0\r\n\r\n"
        )
        let upgrade = try client.readUntil(Data("\r\n\r\n".utf8))
        #expect(String(decoding: upgrade, as: UTF8.self).contains("101 Switching Protocols"))
        try await Task.sleep(for: .milliseconds(20))
        try client.closeWrite()
        #expect(await eventually { session.inputClosed })

        let clock = ContinuousClock()
        let started = clock.now
        let shutdownTask = Task {
            try await server.shutdown()
        }
        try await Task.sleep(for: .milliseconds(20))
        await #expect(
            throws: ContainerUnixHTTPServerLifecycleError.transitionInProgress
        ) {
            try await server.shutdown()
        }
        try await shutdownTask.value
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(server.activeConnectionCount == 0)
        #expect(await eventually { session.cancelled })

        try await server.shutdown()
        await #expect(throws: ContainerUnixHTTPServerLifecycleError.oneShotServer) {
            try await server.start()
        }
        await #expect(throws: ContainerUnixHTTPServerError.notStarted) {
            try await server.wait()
        }
    }
}

private final class SlowResponder: DockerHTTPResponder, @unchecked Sendable {
    private let delay: Duration
    private let lock = NSLock()
    private var didStart = false

    init(delay: Duration) {
        self.delay = delay
    }

    var started: Bool {
        lock.withLock { didStart }
    }

    func respond(to _: DockerHTTPRequest) async -> DockerHTTPResponse {
        lock.withLock {
            didStart = true
        }
        try? await Task.sleep(for: delay)
        return .text("drained-response")
    }
}

private final class StartFailureGate: @unchecked Sendable {
    private let boundEvents: AsyncStream<Void>
    private let boundContinuation: AsyncStream<Void>.Continuation
    private let releaseEvents: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var shouldFail = true

    init() {
        (boundEvents, boundContinuation) = AsyncStream.makeStream()
        (releaseEvents, releaseContinuation) = AsyncStream.makeStream()
    }

    func failFirstStartAfterBind() async throws {
        let mustFail = lock.withLock {
            guard shouldFail else {
                return false
            }
            shouldFail = false
            return true
        }
        guard mustFail else {
            return
        }
        boundContinuation.yield()
        boundContinuation.finish()
        for await _ in releaseEvents {
            break
        }
        throw FixtureError("injected post-bind validation failure")
    }

    func waitUntilBound() async {
        for await _ in boundEvents {
            return
        }
    }

    func releaseFailure() {
        releaseContinuation.yield()
        releaseContinuation.finish()
    }
}

private struct FixtureResponder: DockerHTTPResponder {
    let session: any DockerHijackSession
    let managedStream: any DockerHTTPStreamSession

    init(
        session: any DockerHijackSession = EchoHijackSession(),
        managedStream: any DockerHTTPStreamSession = ManagedFixtureStream()
    ) {
        self.session = session
        self.managedStream = managedStream
    }

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        switch request.target {
        case "/_ping":
            .text("OK")
        case "/echo":
            DockerHTTPResponse(
                status: 200,
                body: .bytes(request.body)
            )
        case "/fast":
            .text("fast-response")
        case "/hijack":
            DockerHTTPResponse(
                status: 200,
                headers: [
                    "Connection": "Upgrade",
                    "Content-Type": "application/vnd.docker.multiplexed-stream",
                    "Upgrade": "tcp"
                ],
                body: .hijack(session, terminal: false)
            )
        case "/websocket":
            DockerHTTPResponse(
                status: 101,
                body: .webSocket(session)
            )
        case "/headers":
            .text(
                request.headers
                    .filter { $0.name.lowercased() == "x-order" }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "\n")
            )
        case "/hold":
            await delayed("held-response", milliseconds: 100)
        case "/slow":
            await delayed("slow-response", milliseconds: 40)
        case "/stream":
            DockerHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: .stream(
                    AsyncThrowingStream { continuation in
                        continuation.yield(Data("first-".utf8))
                        continuation.yield(Data("second".utf8))
                        continuation.finish()
                    }
                )
            )
        case "/managed-stream":
            DockerHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: .managedStream(managedStream)
            )
        default:
            (try? .json(DockerErrorEnvelope(message: "page not found"), status: 404))
                ?? .text("page not found", status: 404)
        }
    }

    private func delayed(
        _ value: String,
        milliseconds: Int64
    ) async -> DockerHTTPResponse {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        return .text(value)
    }
}

private actor ManagedFixtureStream: DockerHTTPStreamSession {
    private var chunks: [Data]
    private let blocks: Bool
    private(set) var started = false
    private(set) var closeCount = 0
    private(set) var cancelCount = 0

    init(chunks: [String] = [], blocks: Bool = false) {
        self.chunks = chunks.map { Data($0.utf8) }
        self.blocks = blocks
    }

    func nextChunk() async throws -> Data? {
        started = true
        if blocks {
            try await Task.sleep(for: .seconds(60))
            return nil
        }
        guard !chunks.isEmpty else {
            return nil
        }
        return chunks.removeFirst()
    }

    func close() {
        closeCount += 1
    }

    func cancel() {
        guard cancelCount == 0 else {
            return
        }
        cancelCount = 1
    }
}

private struct ServerFixture {
    let root: URL
    let socketPath: String

    init(directoryMode: mode_t = 0o700) throws {
        try self.init(
            root: URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent(
                    "cea-\(UUID().uuidString.prefix(8))",
                    isDirectory: true
                ),
            directoryMode: directoryMode
        )
    }

    init(root: URL, directoryMode: mode_t = 0o700) throws {
        self.root = root
        socketPath = root.appendingPathComponent("engine.sock").path
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: directoryMode]
        )
        guard chmod(root.path, directoryMode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func server(
        responder: any DockerHTTPResponder,
        limits: ContainerUnixHTTPServerLimits = .production
    ) -> ContainerUnixHTTPServer {
        ContainerUnixHTTPServer(
            responder: responder,
            socketPath: socketPath,
            logger: Logger(label: "container-engine-api-tests"),
            limits: limits
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func curl(
        _ path: String,
        method: String = "GET",
        body: String? = nil
    ) throws -> (status: Int, body: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = [
            "--silent",
            "--show-error",
            "--unix-socket",
            socketPath,
            "--request",
            method,
            "--header",
            "Content-Type: application/json"
        ]
        if let body {
            arguments.append(contentsOf: ["--data-binary", body])
        }
        arguments.append(contentsOf: [
            "--write-out",
            "\n%{http_code}",
            "http://localhost\(path)"
        ])
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let standardOutput = try output.fileHandleForReading.readToEnd() ?? Data()
        let standardError = try error.fileHandleForReading.readToEnd() ?? Data()
        guard process.terminationStatus == 0 else {
            throw FixtureError(
                "\(method) \(path): "
                    + (
                        String(data: standardError, encoding: .utf8)
                            ?? "non-UTF-8 curl diagnostic"
                    )
            )
        }
        let value = String(data: standardOutput, encoding: .utf8)
            ?? "non-UTF-8 curl response"
        let components = value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let statusText = components.last, let status = Int(statusText) else {
            throw FixtureError("curl did not emit an HTTP status: \(value)")
        }
        return (
            status,
            components.dropLast().joined(separator: "\n")
        )
    }

    func pipelined(_ request: String) throws -> String {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", socketPath]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(request.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let standardOutput = try output.fileHandleForReading.readToEnd() ?? Data()
        let standardError = try error.fileHandleForReading.readToEnd() ?? Data()
        guard process.terminationStatus == 0 else {
            throw FixtureError(
                "pipelined request: "
                    + (
                        String(data: standardError, encoding: .utf8)
                            ?? "non-UTF-8 nc diagnostic"
                    )
            )
        }
        return String(data: standardOutput, encoding: .utf8)
            ?? "non-UTF-8 pipelined response"
    }

    func startEarlyHalfClose(payload: Data) throws -> Process {
        let headers = Data(
            (
                "POST /hijack HTTP/1.1\r\n"
                    + "Host: localhost\r\n"
                    + "Connection: Upgrade\r\n"
                    + "Upgrade: tcp\r\n"
                    + "Content-Length: 0\r\n\r\n"
            ).utf8
        )
        var request = headers
        request.append(payload)

        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", socketPath]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(request)
        try input.fileHandleForWriting.close()
        return process
    }
}

private final class UnixSocketClient {
    private var descriptor: Int32

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                path.withCString { value in
                    bytes.copyMemory(
                        from: UnsafeRawBufferPointer(
                            start: value,
                            count: path.utf8.count + 1
                        )
                    )
                }
            }
            let result = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func write(_ value: String) throws {
        try write(Data(value.utf8))
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }

    func readUntil(
        _ marker: Data,
        timeoutMilliseconds: Int32 = 1000
    ) throws -> Data {
        var result = Data()
        var elapsed: Int32 = 0
        while result.range(of: marker) == nil, elapsed < timeoutMilliseconds {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let interval: Int32 = 50
            let ready = poll(&pollDescriptor, 1, interval)
            guard ready >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            elapsed += interval
            guard ready > 0 else {
                continue
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else {
                break
            }
            result.append(contentsOf: bytes.prefix(count))
        }
        guard result.range(of: marker) != nil else {
            throw FixtureError("socket response did not contain the expected marker")
        }
        return result
    }

    func close() {
        guard descriptor >= 0 else {
            return
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func closeWrite() throws {
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class EchoHijackSession: DockerHijackSession, @unchecked Sendable {
    let frames: AsyncThrowingStream<DockerStreamFrame, any Error>

    private let frameContinuation:
        AsyncThrowingStream<DockerStreamFrame, any Error>.Continuation
    private let completionTask: Task<Int32, Never>
    private let completionContinuation: AsyncStream<Int32>.Continuation
    private let lock = NSLock()
    private var bytes = Data()
    private var closed = false

    init() {
        (frames, frameContinuation) = AsyncThrowingStream.makeStream()
        let (completion, continuation) = AsyncStream<Int32>.makeStream()
        completionContinuation = continuation
        completionTask = Task {
            for await status in completion {
                return status
            }
            return 255
        }
    }

    var input: Data {
        lock.withLock { bytes }
    }

    var inputClosed: Bool {
        lock.withLock { closed }
    }

    func write(_ data: Data) {
        lock.withLock {
            bytes.append(data)
        }
    }

    func closeStandardInput() {
        let output: Data? = lock.withLock {
            guard !closed else {
                return nil
            }
            closed = true
            return bytes
        }
        guard let output else {
            return
        }
        frameContinuation.yield(
            DockerStreamFrame(channel: .standardOutput, data: output)
        )
        frameContinuation.finish()
        completionContinuation.yield(0)
        completionContinuation.finish()
    }

    func wait() async -> Int32 {
        await completionTask.value
    }

    func cancel() {
        frameContinuation.finish()
        completionContinuation.finish()
    }
}

private final class CancellableHijackSession: DockerHijackSession, @unchecked Sendable {
    let frames: AsyncThrowingStream<DockerStreamFrame, any Error>

    private let frameContinuation:
        AsyncThrowingStream<DockerStreamFrame, any Error>.Continuation
    private let completionTask: Task<Int32, Never>
    private let completionContinuation: AsyncStream<Int32>.Continuation
    private let lock = NSLock()
    private var bytes = Data()
    private var didCloseInput = false
    private var didCancel = false

    init() {
        (frames, frameContinuation) = AsyncThrowingStream.makeStream()
        let (completion, completionContinuation) = AsyncStream<Int32>.makeStream()
        self.completionContinuation = completionContinuation
        completionTask = Task {
            for await status in completion {
                return status
            }
            return 255
        }
    }

    var inputClosed: Bool {
        lock.withLock { didCloseInput }
    }

    var input: Data {
        lock.withLock { bytes }
    }

    var cancelled: Bool {
        lock.withLock { didCancel }
    }

    func write(_ data: Data) {
        lock.withLock {
            bytes.append(data)
        }
    }

    func closeStandardInput() {
        lock.withLock {
            didCloseInput = true
        }
    }

    func wait() async -> Int32 {
        await completionTask.value
    }

    func cancel() {
        lock.withLock {
            didCancel = true
        }
        frameContinuation.finish()
        completionContinuation.finish()
    }
}

private struct FixtureError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private func testLimits(
    maximumConnections: Int = 4,
    aggregateBytes: Int,
    readTimeout: Duration = .seconds(1),
    idleTimeout: Duration = .seconds(1),
    gracefulDrainTimeout: Duration = .milliseconds(500)
) -> ContainerUnixHTTPServerLimits {
    ContainerUnixHTTPServerLimits(
        maximumRequestBodyBytes: 64,
        maximumBufferedRequestBodyBytes: 64,
        maximumPendingRequests: 2,
        maximumConnections: maximumConnections,
        maximumAggregateBufferedRequestBodyBytes: aggregateBytes,
        requestReadTimeout: readTimeout,
        idleConnectionTimeout: idleTimeout,
        gracefulDrainTimeout: gracefulDrainTimeout
    )
}

private func eventually(
    timeout: Duration = .seconds(2),
    condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func eventuallyAsync(
    timeout: Duration = .seconds(2),
    condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func stop(_ process: Process) {
    guard process.isRunning else {
        return
    }
    process.terminate()
    process.waitUntilExit()
}
