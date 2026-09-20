// Copyright 2026 container-engine-api project authors. SPDX-License-Identifier: Apache-2.0

import ContainerEngineWire
@testable import ContainerUnixHTTPClient
import Darwin
import Foundation
import Testing

struct ClientDuplexTests {
    private static let upgrade = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"

    @Test
    func `synchronous deadline observation shuts down a blocked sibling before timer delivery`() async throws {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        guard sockets[0] >= 0, sockets[1] >= 0 else { throw POSIXError(.EIO) }
        let lifetime = ClientRequestLifetime(timeoutSeconds: 1)
        try lifetime.register(sockets[0])
        defer { lifetime.closeConnection(); Darwin.close(sockets[1]) }
        let reader = try lifetime.duplicateDescriptor()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            var byte: UInt8 = 0
            _ = Darwin.read(reader, &byte, 1)
            Darwin.close(reader)
            finished.signal()
        }
        #expect(await wait(started, seconds: 1) == .success)
        // Deliberately no timer: the read-side deadline check must unblock the
        // other direction itself, even when timer delivery is delayed.
        try await Task.sleep(for: .milliseconds(1050))
        #expect(throws: ContainerUnixHTTPClientError.deadlineExceeded) { try lifetime.check() }
        let result = await wait(finished, seconds: 0.25)
        lifetime.closeConnection()
        if result != .success {
            _ = await wait(finished, seconds: 1)
        }
        #expect(result == .success)
    }

    @Test
    func `raw upgrade preserves head-adjacent bytes and half closes stdin only`() async throws {
        let peer = try RawClientPeer(response: Self.upgrade + "ready", echoUntilEOF: true)
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 5)
            let connection = try await client.openDuplex(DockerHTTPRequest(
                method: .post,
                target: "/exec/example/start"
            ))
            defer { connection.close() }
            let payload = Data(repeating: 97, count: 1024 * 1024)
            async let output = collect(connection)
            try await connection.write(Data())
            try await connection.write(payload)
            try await connection.finishInput()
            try await connection.finishInput()
            #expect(try await output == Data("ready".utf8) + payload + Data("after-stdin-eof".utf8))
            await #expect(throws: ContainerUnixHTTPClientError.invalidResponse("connection input is closed")) {
                try await connection.write(Data("late".utf8))
            }
            connection.close()
            connection.close()
            await #expect(throws: ContainerUnixHTTPClientError.invalidResponse("connection is closed")) {
                try await connection.read()
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
        #expect(!FileManager.default.fileExists(atPath: peer.socketPath))
    }

    @Test(arguments: [
        "Connection: close\r\nUpgrade: tcp\r\n", "Connection: upgrade\r\nUpgrade: websocket\r\n",
        "Connection: upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n",
        "Connection: upgrade\r\nUpgrade: tcp\r\nTransfer-Encoding: chunked\r\n"
    ])
    func `malformed upgrade responses cannot become raw connections`(headers: String) async throws {
        let peer = try RawClientPeer(response: "HTTP/1.1 101 Switching Protocols\r\n\(headers)\r\n")
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.invalidResponse("invalid Engine upgrade response")) {
                try await client.openDuplex(DockerHTTPRequest(method: .post, target: "/exec/example/start"))
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `upgrade retains bounded server error response`() async throws {
        let peer =
            try RawClientPeer(response: "HTTP/1.1 404 Not Found\r\nContent-Length: 21\r\n\r\n{\"message\":\"missing\"}")
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath)
            await #expect(throws: ContainerUnixHTTPClientError.server(status: 404, message: "missing")) {
                try await client.openDuplex(DockerHTTPRequest(method: .post, target: "/exec/missing/start"))
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `upgrade rejects caller supplied connection headers before transport`() async throws {
        let client = try ContainerUnixHTTPClient(socketPath: "/not-a-real-socket")
        for name in ["Connection", "Upgrade"] {
            let request = DockerHTTPRequest(
                method: .post,
                target: "/",
                headers: .init([.init(name: name, value: "bad")])
            )
            await #expect(throws: ContainerUnixHTTPClientError
                .invalidResponse("upgrade headers are owned by openDuplex"))
            {
                try await client.openDuplex(request)
            }
        }
    }

    @Test
    func `absolute deadline covers an upgraded trickling connection`() async throws {
        let peer = try RawClientPeer(response: Self.upgrade, trickle: true)
        let start = ContinuousClock.now
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 1)
            let connection = try await client.openDuplex(DockerHTTPRequest(
                method: .post,
                target: "/exec/example/start"
            ))
            defer { connection.close() }
            await #expect(throws: ContainerUnixHTTPClientError.deadlineExceeded) { try await collect(connection) }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test
    func `cancellation interrupts a pending read and invalidates subsequent writes`() async throws {
        let peer = try RawClientPeer(response: Self.upgrade, echoUntilEOF: true)
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 10)
            let connection = try await client.openDuplex(DockerHTTPRequest(
                method: .post,
                target: "/exec/example/start"
            ))
            defer { connection.close() }
            let read = Task { try await connection.read() }
            try await Task.sleep(for: .milliseconds(30))
            read.cancel()
            await #expect(throws: CancellationError.self) { try await read.value }
            await #expect(throws: CancellationError.self) { try await connection.write(Data("late".utf8)) }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    @Test
    func `cancellation during upgrade interrupts incomplete response headers`() async throws {
        let peer = try RawClientPeer(response: "HTTP/1.1 101 Switching", trickle: true)
        let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 10)
        let operation = Task { try await client.openDuplex(DockerHTTPRequest(
            method: .post,
            target: "/exec/example/start"
        )) }
        do {
            try await peer.waitForConnection()
        } catch {
            operation.cancel()
            _ = await operation.result
            await peer.finish()
            throw error
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await peer.finish()
    }

    @Test
    func `closing a connection interrupts in flight reading without fd reuse`() async throws {
        let peer = try RawClientPeer(response: Self.upgrade, echoUntilEOF: true)
        do {
            let client = try ContainerUnixHTTPClient(socketPath: peer.socketPath, timeoutSeconds: 5)
            let connection = try await client.openDuplex(DockerHTTPRequest(
                method: .post,
                target: "/exec/example/start"
            ))
            defer { connection.close() }
            let operation = Task { try await connection.read() }
            try await Task.sleep(for: .milliseconds(30))
            connection.close()
            // A read already in flight sees EOF; one not yet started rejects the closed connection.
            switch await operation.result {
            case let .success(bytes): #expect(bytes == nil)
            case let .failure(error):
                #expect(error as? ContainerUnixHTTPClientError == .invalidResponse("connection is closed"))
            }
            await #expect(throws: ContainerUnixHTTPClientError.invalidResponse("connection is closed")) {
                try await connection.finishInput()
            }
        } catch {
            await peer.finish()
            throw error
        }
        await peer.finish()
    }

    private func collect(_ connection: ContainerUnixHTTPConnection) async throws -> Data {
        var output = Data()
        while let chunk = try await connection.read() {
            #expect(chunk.count <= 64 * 1024)
            output.append(chunk)
        }
        return output
    }

    private func wait(_ semaphore: DispatchSemaphore, seconds: Double) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds))
            }
        }
    }
}
