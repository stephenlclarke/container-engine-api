//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import ContainerEngineWire
import Foundation

public struct ContainerEngineProviderSessionClient: DockerHTTPResponder, Sendable {
    public let socketPath: String
    public let expectedFingerprint: ContainerEngineProviderFingerprint

    public init(
        socketPath: String,
        expectedFingerprint: ContainerEngineProviderFingerprint
    ) {
        self.socketPath = socketPath
        self.expectedFingerprint = expectedFingerprint
    }

    public static func probe(
        socketPath: String
    ) async throws -> ContainerEngineProviderSessionDescriptor {
        let socket = try await connect(socketPath: socketPath)
        defer { socket.close() }
        let fingerprint = try await receiveHello(on: socket, expectedDigest: nil)
        try await socket.writeFrame(ProviderSessionFrame(kind: .cancel))
        return ContainerEngineProviderSessionDescriptor(fingerprint: fingerprint)
    }

    public func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        do {
            let socket = try await Self.connect(socketPath: socketPath)
            _ = try await Self.receiveHello(
                on: socket,
                expectedDigest: expectedFingerprint.digest
            )
            var frame = ProviderSessionFrame(kind: .request)
            frame.request = ProviderSessionRequest(
                method: request.method,
                target: request.target,
                headers: Array(request.headers),
                body: request.body
            )
            try await socket.writeFrame(frame)
            let headFrame = try await socket.readFrame()
            if headFrame.kind == .failure {
                throw ContainerEngineProviderSessionError.providerFailure(
                    headFrame.message ?? "unknown provider failure"
                )
            }
            guard
                headFrame.kind == .responseHead,
                let head = headFrame.response
            else {
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "expected provider response head"
                )
            }
            switch head.bodyKind {
            case .bytes:
                let body = try await Self.readBytes(on: socket)
                socket.close()
                return DockerHTTPResponse(
                    status: head.status,
                    headers: head.headers,
                    body: .bytes(body)
                )
            case .stream:
                let session = ProviderRemoteStreamSession(socket: socket)
                return DockerHTTPResponse(
                    status: head.status,
                    headers: head.headers,
                    body: .managedStream(session)
                )
            case .hijack:
                let session = ProviderRemoteHijackSession(socket: socket)
                return DockerHTTPResponse(
                    status: head.status,
                    headers: head.headers,
                    body: .hijack(session, terminal: head.terminal ?? false)
                )
            }
        } catch {
            let envelope = DockerErrorEnvelope(
                message: "selected Engine provider unavailable: \(error)"
            )
            return (try? DockerHTTPResponse.json(envelope, status: 503))
                ?? DockerHTTPResponse(
                    status: 503,
                    headers: ["Content-Type": "application/json"],
                    body: .bytes(Data("{\"message\":\"selected Engine provider unavailable\"}".utf8))
                )
        }
    }

    private static func connect(socketPath: String) async throws -> ProviderSessionSocket {
        try await Task.detached {
            try ProviderSessionUnixSocket.connect(path: socketPath)
        }.value
    }

    private static func receiveHello(
        on socket: ProviderSessionSocket,
        expectedDigest: String?
    ) async throws -> ContainerEngineProviderFingerprint {
        let hello = try await socket.readFrame()
        guard hello.kind == .providerHello, let fingerprint = hello.fingerprint else {
            throw ContainerEngineProviderSessionError.protocolViolation(
                "provider did not send an identity hello"
            )
        }
        if let expectedDigest, expectedDigest != fingerprint.digest {
            throw ContainerEngineProviderSessionError.fingerprintMismatch(
                expected: expectedDigest,
                received: fingerprint.digest
            )
        }
        var gatewayHello = ProviderSessionFrame(kind: .gatewayHello)
        gatewayHello.expectedFingerprintDigest = fingerprint.digest
        try await socket.writeFrame(gatewayHello)
        let ready = try await socket.readFrame()
        guard ready.kind == .ready else {
            throw ContainerEngineProviderSessionError.protocolViolation(
                "provider did not accept the selected fingerprint"
            )
        }
        return fingerprint
    }

    private static func readBytes(on socket: ProviderSessionSocket) async throws -> Data {
        var body = Data()
        while true {
            let frame = try await socket.readFrame()
            switch frame.kind {
            case .responseBody:
                body.append(frame.data ?? Data())
                guard body.count <= ProviderSessionSocket.maximumBufferedBodyBytes else {
                    throw ContainerEngineProviderSessionError.bodyTooLarge(body.count)
                }
            case .responseEnd:
                return body
            case .responseChunkEnd:
                continue
            case .failure:
                throw ContainerEngineProviderSessionError.providerFailure(
                    frame.message ?? "unknown provider failure"
                )
            default:
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "unexpected byte-response frame \(frame.kind.rawValue)"
                )
            }
        }
    }
}

private actor ProviderRemoteStreamSession: DockerHTTPStreamSession {
    let socket: ProviderSessionSocket
    var finished = false

    init(socket: ProviderSessionSocket) {
        self.socket = socket
    }

    func nextChunk() async throws -> Data? {
        guard !finished else {
            return nil
        }
        try await socket.writeFrame(ProviderSessionFrame(kind: .next))
        var chunk = Data()
        while true {
            let frame = try await socket.readFrame()
            switch frame.kind {
            case .responseBody:
                chunk.append(frame.data ?? Data())
                guard chunk.count <= ProviderSessionSocket.maximumBufferedBodyBytes else {
                    throw ContainerEngineProviderSessionError.bodyTooLarge(chunk.count)
                }
            case .responseChunkEnd:
                return chunk
            case .responseEnd:
                finished = true
                socket.close()
                return nil
            case .failure:
                finished = true
                socket.close()
                throw ContainerEngineProviderSessionError.providerFailure(
                    frame.message ?? "unknown provider failure"
                )
            default:
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "unexpected stream frame \(frame.kind.rawValue)"
                )
            }
        }
    }

    func close() async {
        guard !finished else {
            return
        }
        finished = true
        try? await socket.writeFrame(ProviderSessionFrame(kind: .cancel))
        socket.close()
    }

    func cancel() async {
        await close()
    }
}

private final class ProviderRemoteHijackSession: DockerHijackSession, @unchecked Sendable {
    private let coordinator: ProviderRemoteHijackCoordinator

    init(socket: ProviderSessionSocket) {
        coordinator = ProviderRemoteHijackCoordinator(socket: socket)
    }

    var frames: AsyncThrowingStream<DockerStreamFrame, any Error> {
        let coordinator = coordinator
        return AsyncThrowingStream(unfolding: {
            try await coordinator.nextFrame()
        })
    }

    func write(_ data: Data) async throws {
        try await coordinator.write(data)
    }

    func closeStandardInput() async throws {
        try await coordinator.closeStandardInput()
    }

    func wait() async throws -> Int32 {
        try await coordinator.wait()
    }

    func cancel() async {
        await coordinator.cancel()
    }
}

private actor ProviderRemoteHijackCoordinator {
    let socket: ProviderSessionSocket
    var finished = false

    init(socket: ProviderSessionSocket) {
        self.socket = socket
    }

    func nextFrame() async throws -> DockerStreamFrame? {
        guard !finished else {
            return nil
        }
        try await socket.writeFrame(ProviderSessionFrame(kind: .next))
        var data = Data()
        var channel: DockerStreamChannel?
        while true {
            let frame = try await socket.readFrame()
            switch frame.kind {
            case .responseBody:
                data.append(frame.data ?? Data())
                channel = channel ?? frame.channel
                guard data.count <= ProviderSessionSocket.maximumBufferedBodyBytes else {
                    throw ContainerEngineProviderSessionError.bodyTooLarge(data.count)
                }
            case .responseChunkEnd:
                return DockerStreamFrame(
                    channel: channel ?? .standardOutput,
                    data: data
                )
            case .responseEnd:
                return nil
            case .failure:
                throw ContainerEngineProviderSessionError.providerFailure(
                    frame.message ?? "unknown provider failure"
                )
            default:
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "unexpected hijack frame \(frame.kind.rawValue)"
                )
            }
        }
    }

    func write(_ data: Data) async throws {
        var frame = ProviderSessionFrame(kind: .writeInput)
        frame.data = data
        try await socket.writeFrame(frame)
    }

    func closeStandardInput() async throws {
        try await socket.writeFrame(ProviderSessionFrame(kind: .closeInput))
    }

    func wait() async throws -> Int32 {
        try await socket.writeFrame(ProviderSessionFrame(kind: .wait))
        let frame = try await socket.readFrame()
        guard frame.kind == .waitResult, let exitCode = frame.exitCode else {
            throw ContainerEngineProviderSessionError.protocolViolation(
                "provider did not return hijack exit status"
            )
        }
        finished = true
        socket.close()
        return exitCode
    }

    func cancel() {
        guard !finished else {
            return
        }
        finished = true
        let socket = socket
        Task {
            try? await socket.writeFrame(ProviderSessionFrame(kind: .cancel))
            socket.close()
        }
    }
}
