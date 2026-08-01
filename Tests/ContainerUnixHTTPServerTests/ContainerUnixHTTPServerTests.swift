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
import ContainerUnixHTTPServer
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
        let server = fixture.server(responder: FixtureResponder(session: session))
        try await server.start()

        do {
            let ping = try fixture.curl("/_ping")
            #expect(ping.status == 200)
            #expect(ping.body == "OK")

            let streamed = try fixture.curl("/stream")
            #expect(streamed.status == 200)
            #expect(streamed.body == "first-second")

            let echo = try fixture.curl(
                "/echo",
                method: "POST",
                body: "request-body"
            )
            #expect(echo.status == 200)
            #expect(echo.body == "request-body")

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
        try await second.shutdown()
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))
        try await first.shutdown()
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
}

private struct FixtureResponder: DockerHTTPResponder {
    let session: EchoHijackSession

    init(session: EchoHijackSession = EchoHijackSession()) {
        self.session = session
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

private struct ServerFixture {
    let root: URL
    let socketPath: String

    init() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cea-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        socketPath = root.appendingPathComponent("engine.sock").path
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
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

private struct FixtureError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private func stop(_ process: Process) {
    guard process.isRunning else {
        return
    }
    process.terminate()
    process.waitUntilExit()
}
