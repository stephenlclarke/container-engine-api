//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineGateway
import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerEngineWire
import ContainerUnixHTTPServer
import Darwin
import Foundation
import Logging
import Testing

@Test
func `public gateway relays websocket bytes through its provider session`() async throws {
    try await withPublicGateway(
        capabilityIdentifier: "engine.route.ContainerAttachWebsocket",
        capabilityStatus: .emulated
    ) { publicSocket in
        let client = try GatewayUnixSocketClient(path: publicSocket)
        defer { client.close() }
        try client.write(
            "GET /v1.53/containers/fixture/attach/ws?stream=1&stdin=1&stdout=1&stderr=1 HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: keep-alive, Upgrade\r\n"
                + "Upgrade: websocket\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        )
        let response = try client.readUntil(Data("\r\n\r\n".utf8))
        #expect(
            String(decoding: response, as: UTF8.self)
                .contains("101 Switching Protocols")
        )

        let payload = Data("provider-gateway-websocket".utf8)
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var requestFrame = Data([0x82, 0x80 | UInt8(payload.count)])
        requestFrame.append(contentsOf: mask)
        requestFrame.append(
            contentsOf: payload.enumerated().map {
                $0.element ^ mask[$0.offset % mask.count]
            }
        )
        try client.write(requestFrame)

        var responseFrame = Data([0x82, UInt8(payload.count)])
        responseFrame.append(payload)
        _ = try client.readUntil(responseFrame)

        let closeMask: [UInt8] = [0x87, 0x65, 0x43, 0x21]
        let closePayload: [UInt8] = [0x03, 0xE8]
        var closeFrame = Data([0x88, 0x80 | UInt8(closePayload.count)])
        closeFrame.append(contentsOf: closeMask)
        closeFrame.append(
            contentsOf: closePayload.enumerated().map {
                $0.element ^ closeMask[$0.offset % closeMask.count]
            }
        )
        try client.write(closeFrame)
        _ = try client.readUntil(Data([0x88, 0x02, 0x03, 0xE8]))
    }
}

@Test
func `public gateway preserves four MiB raw duplex input`() async throws {
    try await withPublicGateway(
        capabilityIdentifier: "engine.route.ContainerAttach",
        capabilityStatus: .native
    ) { publicSocket in
        let client = try GatewayUnixSocketClient(path: publicSocket)
        defer { client.close() }
        try client.write(
            "POST /v1.53/containers/fixture/attach?logs=0&stream=1&stdin=1&stdout=1&stderr=0 HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Connection: Upgrade\r\n"
                + "Upgrade: tcp\r\n\r\n"
        )
        let response = try client.readUntil(Data("\r\n\r\n".utf8))
        #expect(
            String(decoding: response, as: UTF8.self)
                .contains("101 Switching Protocols")
        )

        let payload = Data(
            (0 ..< 4 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0) }
        )
        let writer = Task.detached {
            try client.write(payload)
            try client.closeWrite()
        }
        do {
            let output = try client.readExactly(
                payload.count,
                timeoutMilliseconds: 10000
            )
            try await writer.value
            #expect(output == payload)
        } catch {
            client.close()
            _ = try? await writer.value
            throw error
        }
    }
}

private func withPublicGateway(
    capabilityIdentifier: String,
    capabilityStatus: ContainerEngineCapabilityStatus,
    operation: (String) async throws -> Void
) async throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent(
            "ceg-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let providerSocket = root.appendingPathComponent("provider.sock").path
    let publicSocket = root.appendingPathComponent("docker.sock").path
    let fingerprint = try ContainerEngineProviderFingerprint(
        declaration: ContainerEngineProviderDeclaration(
            profile: .stock,
            kind: .devcontainerStock,
            implementationVersion: "1.0.0",
            runtimeRevisions: ["runtime": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                ContainerEngineProviderCapability(
                    identifier: capabilityIdentifier,
                    status: capabilityStatus
                )
            ]
        ),
        stateRootUUID: UUID()
    )
    let provider = try ContainerEngineProviderSessionServer(
        responder: GatewayStreamingResponder(),
        socketPath: providerSocket,
        declaration: fingerprint.declaration,
        stateRootUUID: fingerprint.stateRootUUID
    )
    try provider.start()
    let publicServer = try ContainerUnixHTTPServer(
        responder: ContainerEngineGatewayResponder(
            providerSocketPath: providerSocket,
            fingerprint: fingerprint
        ),
        socketPath: publicSocket,
        logger: Logger(label: "container-engine-gateway-tests")
    )
    do {
        try await publicServer.start()
        try await operation(publicSocket)
        try await publicServer.shutdown()
        await provider.shutdown()
    } catch {
        try? await publicServer.shutdown()
        await provider.shutdown()
        throw error
    }

    #expect(!FileManager.default.fileExists(atPath: publicSocket))
    #expect(!FileManager.default.fileExists(atPath: providerSocket))
}

private struct GatewayStreamingResponder: DockerHTTPResponder {
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        if
            request.method == .get,
            request.target
            == "/v1.53/containers/fixture/attach/ws?stream=1&stdin=1&stdout=1&stderr=1"
        {
            return DockerHTTPResponse(
                status: 101,
                body: .webSocket(GatewayEchoSession())
            )
        }
        if
            request.method == .post,
            request.target
            == "/v1.53/containers/fixture/attach?logs=0&stream=1&stdin=1&stdout=1&stderr=0"
        {
            return DockerHTTPResponse(
                status: 101,
                body: .hijack(
                    GatewayEchoSession(writeDelay: .milliseconds(2)),
                    terminal: true
                )
            )
        }
        return .text("unexpected provider request", status: 400)
    }
}

private final class GatewayEchoSession: DockerHijackSession, @unchecked Sendable {
    let frames: AsyncThrowingStream<DockerStreamFrame, any Error>

    private let writeDelay: Duration?
    private let continuation:
        AsyncThrowingStream<DockerStreamFrame, any Error>.Continuation
    private let completion: Task<Int32, Never>
    private let completionContinuation: AsyncStream<Int32>.Continuation

    init(writeDelay: Duration? = nil) {
        self.writeDelay = writeDelay
        (frames, continuation) = AsyncThrowingStream.makeStream()
        let (statuses, completionContinuation) = AsyncStream<Int32>.makeStream()
        self.completionContinuation = completionContinuation
        completion = Task {
            for await status in statuses {
                return status
            }
            return 255
        }
    }

    func write(_ data: Data) async throws {
        if let writeDelay {
            try await Task.sleep(for: writeDelay)
        }
        continuation.yield(
            DockerStreamFrame(channel: .standardOutput, data: data)
        )
    }

    func closeStandardInput() {
        continuation.finish()
        completionContinuation.yield(0)
        completionContinuation.finish()
    }

    func wait() async -> Int32 {
        await completion.value
    }

    func cancel() {
        continuation.finish()
        completionContinuation.finish()
    }
}

private final class GatewayUnixSocketClient: @unchecked Sendable {
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
        let deadline = ContinuousClock.now
            + .milliseconds(Int64(timeoutMilliseconds))
        while result.range(of: marker) == nil, ContinuousClock.now < deadline {
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
            throw GatewayWebSocketTestError(
                "socket response did not contain the expected marker"
            )
        }
        return result
    }

    func readExactly(
        _ byteCount: Int,
        timeoutMilliseconds: Int32
    ) throws -> Data {
        var result = Data()
        let deadline = ContinuousClock.now
            + .milliseconds(Int64(timeoutMilliseconds))
        while result.count < byteCount, ContinuousClock.now < deadline {
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
            guard ready > 0 else {
                continue
            }
            var bytes = [UInt8](
                repeating: 0,
                count: min(64 * 1024, byteCount - result.count)
            )
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else {
                break
            }
            result.append(contentsOf: bytes.prefix(count))
        }
        guard result.count == byteCount else {
            throw GatewayWebSocketTestError(
                "socket returned \(result.count) of \(byteCount) expected bytes"
            )
        }
        return result
    }

    func closeWrite() throws {
        guard shutdown(descriptor, SHUT_WR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func close() {
        guard descriptor >= 0 else {
            return
        }
        Darwin.close(descriptor)
        descriptor = -1
    }
}

private struct GatewayWebSocketTestError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
