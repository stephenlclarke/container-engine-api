// Copyright 2026 container-engine-api project authors. SPDX-License-Identifier: Apache-2.0

import ContainerEngineWire
@testable import ContainerUnixHTTPClient
import Darwin
import Foundation
import Testing

struct ClientBoundaryTests {
    @Test
    func `invalid paths and missing sockets fail before a connection exists`() async throws {
        for path in ["relative", "/nul\0socket", "/" + String(repeating: "x", count: 104)] {
            #expect(throws: ContainerUnixHTTPClientError.invalidSocketPath(path)) {
                try ContainerUnixHTTPClient(socketPath: path)
            }
        }
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_TMPDIR"]
            ?? FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("absent-\(UUID().uuidString.prefix(8))").path
        let client = try ContainerUnixHTTPClient(socketPath: path)
        await #expect(throws: POSIXError.self) { try await client.send(DockerHTTPRequest(method: .get, target: "/")) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `more concurrent clients than Swift workers still complete`() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< max(24, ProcessInfo.processInfo.activeProcessorCount * 2) {
                group.addTask {
                    let peer = try RawClientPeer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
                    do {
                        let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 5)
                        let response = try await client.send(DockerHTTPRequest(method: .get, target: "/"))
                        #expect(response.body == Data("hi".utf8))
                    } catch {
                        await peer.finish()
                        throw error
                    }
                    await peer.finish()
                }
            }
            try await group.waitForAll()
        }
    }

    @Test(arguments: [
        "not-http\r\n\r\n", "HTTP/1.1 200 OK\r\nmalformed-header\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhiWRONG\r\n"
    ])
    func `malformed and truncated replies cannot be accepted`(response: String) async throws {
        let peer = try RawClientPeer(response: response)
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.self) {
                try await client.send(DockerHTTPRequest(method: .get, target: "/"))
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `close delimited body and plain text server errors remain supported`() async throws {
        for status in [200, 500] {
            let peer = try RawClientPeer(response: "HTTP/1.1 \(status) Test\r\n\r\nplain text")
            do {
                let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
                let request = DockerHTTPRequest(method: .get, target: "/")
                if status == 200 {
                    let response = try await client.send(request)
                    #expect(response.body == Data("plain text".utf8))
                } else {
                    await #expect(throws: ContainerUnixHTTPClientError.server(status: 500, message: "plain text")) {
                        try await client.send(request)
                    }
                }
            } catch {
                await peer.finish()
                throw error
            }
            await peer.finish()
        }
    }

    @Test
    func `HEAD response does not read the content length as a body`() async throws {
        let peer = try RawClientPeer(response: "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n")
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            #expect(try await client.send(DockerHTTPRequest(method: .head, target: "/")).body.isEmpty)
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `absolute deadline stops a peer that never reaches its inactivity timeout`() async throws {
        let peer = try RawClientPeer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n", trickle: true
        )
        let start = ContinuousClock.now
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 1)
            await #expect(throws: ContainerUnixHTTPClientError.deadlineExceeded) {
                try await client.send(DockerHTTPRequest(method: .get, target: "/"))
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
        #expect(start.duration(to: .now) < .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: peer.socketPath))
    }

    @Test
    func `cancellation closes an established socket before returning`() async throws {
        let peer = try RawClientPeer(response: "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n", trickle: true)
        let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 30)
        let operation = Task { try await client.send(DockerHTTPRequest(method: .get, target: "/")) }
        do {
            try await peer.waitForConnection()
        } catch {
            operation.cancel()
            _ = await operation.result
            await peer.finish()
            throw error
        }
        let start = ContinuousClock.now
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await peer.finish()
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test(arguments: ["", "-1", "+1", "x", ";extension", "FFFFFFFFFFFFFFFFFFFFFFFF", " 1"])
    func `malformed chunk sizes throw instead of trapping`(size: String) async throws {
        let peer = try RawClientPeer(response: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(size)\r\n")
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.invalidResponse("invalid chunk size")) {
                try await client.send(DockerHTTPRequest(method: .get, target: "/"))
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test(arguments: [false, true])
    func `chunk framing lines are bounded with or without a terminator`(terminated: Bool) async throws {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(repeating: "a", count: 8193) + (terminated ? "\r\n" : "")
        let peer = try RawClientPeer(response: response)
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.responseTooLarge(8192)) {
                try await client.send(DockerHTTPRequest(method: .get, target: "/"), maximumBodyBytes: 1)
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `trailer aggregate is bounded independently of body and per line limits`() async throws {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"
            + String(repeating: "X-Trailer: " + String(repeating: "a", count: 1000) + "\r\n", count: 70) + "\r\n"
        let peer = try RawClientPeer(response: response)
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.responseTooLarge(65536)) {
                try await client.send(DockerHTTPRequest(method: .get, target: "/"), maximumBodyBytes: 1)
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `complete oversized response headers cannot bypass the header limit`() async throws {
        let response = "HTTP/1.1 200 OK\r\nX-Long: " + String(repeating: "a", count: 65536) + "\r\n\r\n"
        let peer = try RawClientPeer(response: response)
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.responseTooLarge(65536)) {
                try await client.send(DockerHTTPRequest(method: .get, target: "/"))
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `valid chunks extensions and trailers preserve bytes`() async throws {
        let peer = try RawClientPeer(response:
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;test=yes\r\nhi\r\n0\r\nX-Result: ok\r\n\r\n")
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            let result = try await client.send(DockerHTTPRequest(method: .get, target: "/"))
            #expect(result.body == Data("hi".utf8))
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `invalid bounds and already cancelled calls do not connect`() async throws {
        #expect(throws: ContainerUnixHTTPClientError.self) {
            try ContainerUnixHTTPClient(socketPath: "/missing", timeoutSeconds: Int.max)
        }
        let client = try ContainerUnixHTTPClient(socketPath: "/missing")
        await #expect(throws: ContainerUnixHTTPClientError.self) {
            try await client.send(DockerHTTPRequest(method: .get, target: "/"), maximumBodyBytes: -1)
        }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(DockerHTTPRequest(method: .get, target: "/"))
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
}
