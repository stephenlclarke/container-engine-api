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
    public let codeIdentity: ProviderHandoffCodeIdentityV1

    private let responder: any DockerHTTPResponder
    private let handoffControlResponder: (any ContainerEngineProviderHandoffControlResponder)?
    private let lock = NSLock()
    private var listener: ProviderSessionUnixSocket.Listener?
    private var acceptTask: Task<Void, Never>?
    private var connections: [ObjectIdentifier: ProviderSessionSocket] = [:]
    private var stopped = false

    public init(
        responder: any DockerHTTPResponder,
        handoffControlResponder:
            (any ContainerEngineProviderHandoffControlResponder)? = nil,
        socketPath: String,
        declaration: ContainerEngineProviderDeclaration,
        stateRootUUID: UUID
    ) throws {
        self.responder = responder
        self.handoffControlResponder = handoffControlResponder
        self.socketPath = socketPath
        fingerprint = try ContainerEngineProviderFingerprint(
            declaration: declaration,
            stateRootUUID: stateRootUUID
        )
        codeIdentity = try ProviderHandoffCodeIdentity.current()
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
        if state.1,
            let wakeConnection = try? ProviderSessionUnixSocket.connect(
                path: socketPath
            )
        {
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
            hello.codeIdentity = codeIdentity
            try await connection.writeFrame(hello)
            let gatewayHello = try await connection.readFrame()
            guard
                gatewayHello.kind == .gatewayHello,
                gatewayHello.expectedFingerprintDigest == fingerprint.digest,
                let claimedGatewayIdentity = gatewayHello.codeIdentity,
                claimedGatewayIdentity == (try connection.peerCodeIdentity())
            else {
                if gatewayHello.expectedFingerprintDigest != fingerprint.digest {
                    throw ContainerEngineProviderSessionError.fingerprintMismatch(
                        expected: fingerprint.digest,
                        received: gatewayHello.expectedFingerprintDigest ?? "missing"
                    )
                }
                throw ContainerEngineProviderSessionError.codeIdentityMismatch
            }
            try await connection.writeFrame(ProviderSessionFrame(kind: .ready))
            let frame = try await connection.readFrame()
            if frame.kind == .cancel {
                return
            }
            if frame.kind == .controlRequest,
                let request = frame.controlRequest
            {
                try await serveControl(
                    request,
                    body: try await readRequestBody(
                        on: connection,
                        maximumBytes:
                            ContainerEngineProviderHandoffControlRequestV1
                            .maximumBodyBytes
                    ),
                    context: ContainerEngineProviderHandoffControlContextV1(
                        providerFingerprint: fingerprint,
                        authenticatedGatewayCodeIdentity:
                            claimedGatewayIdentity
                    ),
                    on: connection
                )
                return
            }
            guard frame.kind == .request, let request = frame.request else {
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "expected one Docker or handoff-control request after handshake"
                )
            }
            let body = try await readRequestBody(on: connection)
            let response = await responder.respond(
                to: DockerHTTPRequest(
                    method: request.method,
                    target: request.target,
                    headers: DockerHTTPHeaders(request.headers),
                    body: body
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

    private func readRequestBody(
        on connection: ProviderSessionSocket,
        maximumBytes: Int = ProviderSessionSocket.maximumBufferedRequestBodyBytes
    ) async throws -> Data {
        var accumulator = ProviderRequestBodyAccumulator(
            maximumBytes: maximumBytes
        )
        while true {
            let frame = try await connection.readFrame()
            if let body = try accumulator.consume(frame) {
                return body
            }
        }
    }

    private func serveControl(
        _ request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context: ContainerEngineProviderHandoffControlContextV1,
        on connection: ProviderSessionSocket
    ) async throws {
        try request.validate(body: body)
        guard let handoffControlResponder else {
            throw ContainerEngineProviderSessionError.providerFailure(
                "selected provider does not support handoff control"
            )
        }
        let result = await handoffControlResponder.respond(
            to: request,
            body: body,
            context: context
        )
        guard result.response.requestID == request.requestID else {
            throw ContainerEngineProviderSessionError.invalidControlMessage
        }
        try result.response.validate(body: result.body)
        var frame = ProviderSessionFrame(kind: .controlResponse)
        frame.controlResponse = result.response
        try await connection.writeFrame(frame)
        try await writeData(result.body, channel: nil, on: connection)
        try await connection.writeFrame(ProviderSessionFrame(kind: .responseEnd))
    }

    private func serve(
        _ response: DockerHTTPResponse,
        on connection: ProviderSessionSocket
    ) async throws {
        switch response.body {
        case .bytes(let data):
            try await writeHead(
                response,
                bodyKind: .bytes,
                terminal: nil,
                on: connection
            )
            try await writeData(data, channel: nil, on: connection)
            try await connection.writeFrame(ProviderSessionFrame(kind: .responseEnd))
        case .managedStream(let session):
            try await writeHead(
                response,
                bodyKind: .stream,
                terminal: nil,
                on: connection
            )
            try await serveManagedStream(session, on: connection)
        case .stream(let stream):
            try await writeHead(
                response,
                bodyKind: .stream,
                terminal: nil,
                on: connection
            )
            try await serveLegacyStream(stream, on: connection)
        case .hijack(let session, let terminal):
            try await writeHead(
                response,
                bodyKind: .hijack,
                terminal: terminal,
                on: connection
            )
            try await serveHijack(session, on: connection)
        case .webSocket(let session):
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
            frame.data = data.subdata(in: offset..<end)
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
                guard let data = try await session.nextChunk() else {
                    try await connection.writeFrame(
                        ProviderSessionFrame(kind: .responseEnd)
                    )
                    return
                }
                try await writeData(
                    data,
                    channel: nil,
                    finishChunk: true,
                    on: connection
                )
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
                guard let data = try await iterator.next() else {
                    try await connection.writeFrame(
                        ProviderSessionFrame(kind: .responseEnd)
                    )
                    return
                }
                try await writeData(
                    data,
                    channel: nil,
                    finishChunk: true,
                    on: connection
                )
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
        let input = ProviderHijackInputRelay(
            session: session,
            failureHandler: { [weak self] error in
                await self?.writeFailure(error, on: connection)
            }
        )
        await withTaskGroup(of: Void.self) { tasks in
            while !Task.isCancelled {
                let command: ProviderSessionFrame
                do {
                    command = try await connection.readFrame()
                } catch {
                    await input.cancel()
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
                    await input.write(command.data ?? Data())
                case .closeInput:
                    await input.closeStandardInput()
                case .wait:
                    tasks.addTask {
                        guard await input.finish() else {
                            return
                        }
                        do {
                            var result = ProviderSessionFrame(kind: .waitResult)
                            result.exitCode = try await session.wait()
                            try await connection.writeFrame(result)
                        } catch {
                            await self.writeFailure(error, on: connection)
                        }
                    }
                case .cancel:
                    await input.cancel()
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

struct ProviderRequestBodyAccumulator {
    let maximumBytes: Int
    private var body = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func consume(_ frame: ProviderSessionFrame) throws -> Data? {
        switch frame.kind {
        case .requestBody:
            guard let data = frame.data else {
                throw ContainerEngineProviderSessionError.protocolViolation(
                    "request body frame omitted its data"
                )
            }
            let (size, overflow) = body.count.addingReportingOverflow(data.count)
            guard !overflow else {
                throw ContainerEngineProviderSessionError.requestBodyTooLarge(
                    Int.max
                )
            }
            guard size <= maximumBytes else {
                throw ContainerEngineProviderSessionError.requestBodyTooLarge(
                    size
                )
            }
            body.append(data)
            return nil
        case .requestEnd:
            return body
        default:
            throw ContainerEngineProviderSessionError.protocolViolation(
                "expected request body data or end, received \(frame.kind.rawValue)"
            )
        }
    }
}

private actor ProviderHijackInputRelay {
    private static let maximumPendingBytes = 4 * 1024 * 1024

    private let session: any DockerHijackSession
    private let failureHandler: @Sendable (any Error) async -> Void
    private var pendingBytes = 0
    private var tail: Task<Bool, Never>?

    init(
        session: any DockerHijackSession,
        failureHandler: @escaping @Sendable (any Error) async -> Void
    ) {
        self.session = session
        self.failureHandler = failureHandler
    }

    func write(_ data: Data) async {
        await enqueue(byteCount: data.count) { [session] in
            try await session.write(data)
        }
    }

    func closeStandardInput() async {
        await enqueue { [session] in
            try await session.closeStandardInput()
        }
    }

    func finish() async -> Bool {
        await tail?.value ?? true
    }

    func cancel() async {
        let pending = tail
        pending?.cancel()
        await session.cancel()
        _ = await pending?.value
    }

    private func enqueue(
        byteCount: Int = 0,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        if pendingBytes + byteCount > Self.maximumPendingBytes, let tail {
            _ = await tail.value
        }
        let previous = tail
        pendingBytes += byteCount
        tail = Task { [weak self, failureHandler] in
            let priorSucceeded = await previous?.value ?? true
            guard priorSucceeded, !Task.isCancelled else {
                await self?.complete(byteCount: byteCount)
                return false
            }
            do {
                try await operation()
                await self?.complete(byteCount: byteCount)
                return true
            } catch {
                await failureHandler(error)
                await self?.complete(byteCount: byteCount)
                return false
            }
        }
    }

    private func complete(byteCount: Int) {
        pendingBytes -= byteCount
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
