//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineRuntimeSPI
import ContainerEngineWire
import Darwin
import Foundation

public final class ContainerEngineProviderSessionServer: @unchecked Sendable {
    public let socketPath: String
    public let fingerprint: ContainerEngineProviderFingerprint

    private let responder: any DockerHTTPResponder
    private let lock = NSLock()
    private var listener: ProviderSessionUnixSocket.Listener?
    private var acceptTask: Task<Void, Never>?
    private var connections: [ObjectIdentifier: ProviderSessionSocket] = [:]
    private var stopped = false

    public init(
        responder: any DockerHTTPResponder,
        socketPath: String,
        declaration: ContainerEngineProviderDeclaration,
        stateRootUUID: UUID
    ) throws {
        self.responder = responder
        self.socketPath = socketPath
        fingerprint = try ContainerEngineProviderFingerprint(
            declaration: declaration,
            stateRootUUID: stateRootUUID
        )
    }

    deinit {
        stopSynchronously()
    }

    public func start() throws {
        let candidate = try ProviderSessionUnixSocket.listen(path: socketPath)
        try lock.withLock {
            guard listener == nil, !stopped else {
                ProviderSessionUnixSocket.close(candidate, path: socketPath)
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "provider session server cannot be restarted"
                )
            }
            listener = candidate
            acceptTask = Task.detached { [weak self] in
                self?.acceptConnections(descriptor: candidate.descriptor)
            }
        }
    }

    public func wait() async {
        await acceptTask?.value
    }

    public func shutdown() async {
        let state = lock.withLock { () -> (Task<Void, Never>?, Bool) in
            guard !stopped else {
                return (acceptTask, false)
            }
            stopped = true
            for connection in connections.values {
                connection.close()
            }
            connections.removeAll()
            return (acceptTask, listener != nil)
        }
        if state.1, let wakeConnection = try? ProviderSessionUnixSocket.connect(
            path: socketPath
        ) {
            wakeConnection.close()
        }
        await state.0?.value
        lock.withLock {
            if let listener {
                ProviderSessionUnixSocket.close(listener, path: socketPath)
                self.listener = nil
            }
            for connection in connections.values {
                connection.close()
            }
            connections.removeAll()
        }
    }

    private func acceptConnections(descriptor: Int32) {
        while true {
            if lock.withLock({ stopped }) {
                return
            }
            let accepted = Darwin.accept(descriptor, nil, nil)
            if accepted < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            if lock.withLock({ stopped }) {
                Darwin.close(accepted)
                return
            }
            do {
                let connection = try ProviderSessionSocket(descriptor: accepted)
                let identifier = ObjectIdentifier(connection)
                lock.withLock {
                    connections[identifier] = connection
                }
                Task { [weak self] in
                    guard let self else {
                        connection.close()
                        return
                    }
                    await handle(connection)
                    connection.close()
                    _ = lock.withLock {
                        connections.removeValue(forKey: identifier)
                    }
                }
            } catch {
                Darwin.close(accepted)
            }
        }
    }

    private func handle(_ connection: ProviderSessionSocket) async {
        do {
            var hello = ProviderSessionFrame(kind: .providerHello)
            hello.fingerprint = fingerprint
            try await connection.writeFrame(hello)
            let gatewayHello = try await connection.readFrame()
            guard
                gatewayHello.kind == .gatewayHello,
                gatewayHello.expectedFingerprintDigest == fingerprint.digest
            else {
                throw ContainerEngineProviderSessionError.fingerprintMismatch(
                    expected: fingerprint.digest,
                    received: gatewayHello.expectedFingerprintDigest ?? "missing"
                )
            }
            try await connection.writeFrame(ProviderSessionFrame(kind: .ready))
            let frame = try await connection.readFrame()
            if frame.kind == .cancel {
                return
            }
            guard frame.kind == .request, let request = frame.request else {
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "expected one request after handshake"
                )
            }
            let response = await responder.respond(
                to: DockerHTTPRequest(
                    method: request.method,
                    target: request.target,
                    headers: DockerHTTPHeaders(request.headers),
                    body: request.body
                )
            )
            try await serve(response, on: connection)
        } catch is CancellationError {
            return
        } catch {
            var failure = ProviderSessionFrame(kind: .failure)
            failure.message = String(describing: error)
            try? await connection.writeFrame(failure)
        }
    }

    private func serve(
        _ response: DockerHTTPResponse,
        on connection: ProviderSessionSocket
    ) async throws {
        switch response.body {
        case let .bytes(data):
            try await writeHead(
                response,
                bodyKind: .bytes,
                terminal: nil,
                on: connection
            )
            try await writeData(data, channel: nil, on: connection)
            try await connection.writeFrame(ProviderSessionFrame(kind: .responseEnd))
        case let .managedStream(session):
            try await writeHead(
                response,
                bodyKind: .stream,
                terminal: nil,
                on: connection
            )
            try await serveManagedStream(session, on: connection)
        case let .stream(stream):
            try await writeHead(
                response,
                bodyKind: .stream,
                terminal: nil,
                on: connection
            )
            try await serveLegacyStream(stream, on: connection)
        case let .hijack(session, terminal):
            try await writeHead(
                response,
                bodyKind: .hijack,
                terminal: terminal,
                on: connection
            )
            try await serveHijack(session, on: connection)
        case let .webSocket(session):
            try await writeHead(
                response,
                bodyKind: .webSocket,
                terminal: nil,
                on: connection
            )
            try await serveHijack(session, on: connection)
        }
    }

    private func writeHead(
        _ response: DockerHTTPResponse,
        bodyKind: ProviderSessionBodyKind,
        terminal: Bool?,
        on connection: ProviderSessionSocket
    ) async throws {
        var frame = ProviderSessionFrame(kind: .responseHead)
        frame.response = ProviderSessionResponseHead(
            status: response.status,
            headers: response.headers,
            bodyKind: bodyKind,
            terminal: terminal
        )
        try await connection.writeFrame(frame)
    }

    private func writeData(
        _ data: Data,
        channel: DockerStreamChannel?,
        finishChunk: Bool = false,
        on connection: ProviderSessionSocket
    ) async throws {
        let chunkSize = 1024 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            var frame = ProviderSessionFrame(kind: .responseBody)
            frame.data = data.subdata(in: offset ..< end)
            frame.channel = channel
            try await connection.writeFrame(frame)
            offset = end
        }
        if finishChunk {
            try await connection.writeFrame(
                ProviderSessionFrame(kind: .responseChunkEnd)
            )
        }
    }

    private func serveManagedStream(
        _ session: any DockerHTTPStreamSession,
        on connection: ProviderSessionSocket
    ) async throws {
        defer { Task { await session.close() } }
        while true {
            let command = try await connection.readFrame()
            switch command.kind {
            case .next:
                if let data = try await session.nextChunk() {
                    try await writeData(
                        data,
                        channel: nil,
                        finishChunk: true,
                        on: connection
                    )
                } else {
                    try await connection.writeFrame(
                        ProviderSessionFrame(kind: .responseEnd)
                    )
                    return
                }
            case .cancel:
                await session.cancel()
                return
            default:
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "unexpected managed-stream command \(command.kind.rawValue)"
                )
            }
        }
    }

    private func serveLegacyStream(
        _ stream: AsyncThrowingStream<Data, any Error>,
        on connection: ProviderSessionSocket
    ) async throws {
        var iterator = stream.makeAsyncIterator()
        while true {
            let command = try await connection.readFrame()
            switch command.kind {
            case .next:
                if let data = try await iterator.next() {
                    try await writeData(
                        data,
                        channel: nil,
                        finishChunk: true,
                        on: connection
                    )
                } else {
                    try await connection.writeFrame(
                        ProviderSessionFrame(kind: .responseEnd)
                    )
                    return
                }
            case .cancel:
                return
            default:
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "unexpected stream command \(command.kind.rawValue)"
                )
            }
        }
    }

    private func serveHijack(
        _ session: any DockerHijackSession,
        on connection: ProviderSessionSocket
    ) async throws {
        let output = ProviderHijackOutputIterator(session.frames)
        await withTaskGroup(of: Void.self) { tasks in
            while !Task.isCancelled {
                let command: ProviderSessionFrame
                do {
                    command = try await connection.readFrame()
                } catch {
                    await session.cancel()
                    tasks.cancelAll()
                    return
                }
                switch command.kind {
                case .next:
                    tasks.addTask {
                        do {
                            if let frame = try await output.next() {
                                try await self.writeData(
                                    frame.data,
                                    channel: frame.channel,
                                    finishChunk: true,
                                    on: connection
                                )
                            } else {
                                try await connection.writeFrame(
                                    ProviderSessionFrame(kind: .responseEnd)
                                )
                            }
                        } catch {
                            await self.writeFailure(error, on: connection)
                        }
                    }
                case .writeInput:
                    tasks.addTask {
                        do {
                            try await session.write(command.data ?? Data())
                        } catch {
                            await self.writeFailure(error, on: connection)
                        }
                    }
                case .closeInput:
                    tasks.addTask {
                        do {
                            try await session.closeStandardInput()
                        } catch {
                            await self.writeFailure(error, on: connection)
                        }
                    }
                case .wait:
                    tasks.addTask {
                        do {
                            var result = ProviderSessionFrame(kind: .waitResult)
                            result.exitCode = try await session.wait()
                            try await connection.writeFrame(result)
                        } catch {
                            await self.writeFailure(error, on: connection)
                        }
                    }
                case .cancel:
                    await session.cancel()
                    tasks.cancelAll()
                    return
                default:
                    await writeFailure(
                        ContainerEngineProviderSessionError.protocolViolation(
                            "unexpected hijack command \(command.kind.rawValue)"
                        ),
                        on: connection
                    )
                }
            }
        }
    }

    private func writeFailure(
        _ error: any Error,
        on connection: ProviderSessionSocket
    ) async {
        var failure = ProviderSessionFrame(kind: .failure)
        failure.message = String(describing: error)
        try? await connection.writeFrame(failure)
    }

    private func stopSynchronously() {
        lock.withLock {
            if let listener {
                ProviderSessionUnixSocket.close(listener, path: socketPath)
                self.listener = nil
            }
            for connection in connections.values {
                connection.close()
            }
            connections.removeAll()
            stopped = true
        }
    }
}

private final class ProviderHijackOutputIterator: @unchecked Sendable {
    var iterator: AsyncThrowingStream<DockerStreamFrame, any Error>.Iterator

    init(_ stream: AsyncThrowingStream<DockerStreamFrame, any Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> DockerStreamFrame? {
        try await iterator.next()
    }
}
