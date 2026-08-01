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
import Darwin
import DequeModule
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix

public final class ContainerUnixHTTPServer: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let responder: any DockerHTTPResponder
    private let socketPath: String
    private let logger: Logger
    private let limits: ContainerUnixHTTPServerLimits
    private let connections = EngineConnectionTracker()
    private var channel: Channel?
    private var lockFileDescriptor: Int32 = -1
    private var boundSocketIdentity: SocketIdentity?

    public init(
        responder: any DockerHTTPResponder,
        socketPath: String,
        logger: Logger,
        limits: ContainerUnixHTTPServerLimits = .production
    ) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.responder = responder
        self.socketPath = socketPath
        self.logger = logger
        self.limits = limits
    }

    public func start() async throws {
        guard channel == nil, boundSocketIdentity == nil else {
            throw ContainerUnixHTTPServerError.alreadyStarted
        }
        try prepareSocketDirectory()
        try acquireInstanceLock()
        do {
            try prepareSocketPath()
        } catch {
            releaseInstanceLock()
            throw error
        }

        let boundChannel: any Channel
        do {
            boundChannel = try await makeBootstrap()
                .bind(unixDomainSocketPath: socketPath)
                .get()
        } catch {
            releaseInstanceLock()
            throw error
        }
        channel = boundChannel

        do {
            boundSocketIdentity = try socketIdentity(at: socketPath)
            guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let securedIdentity = try socketIdentity(at: socketPath)
            guard securedIdentity == boundSocketIdentity else {
                throw ContainerUnixHTTPServerError.socketIdentityChanged(socketPath)
            }
            var status = stat()
            guard
                lstat(socketPath, &status) == 0,
                status.st_mode & (S_IRWXG | S_IRWXO) == 0
            else {
                throw ContainerUnixHTTPServerError.unsafeExistingSocket(socketPath)
            }
        } catch {
            try? await boundChannel.close()
            try? removeOwnedSocket()
            channel = nil
            releaseInstanceLock()
            throw error
        }

        logger.info("Container Engine API listening", metadata: ["socket": .string(socketPath)])
    }

    public func wait() async throws {
        guard let channel else {
            throw ContainerUnixHTTPServerError.notStarted
        }
        try await channel.closeFuture.get()
    }

    public var activeConnectionCount: Int {
        connections.count
    }

    public func shutdown() async throws {
        defer { releaseInstanceLock() }
        var firstError: (any Error)?
        if let channel {
            do {
                try await channel.close()
            } catch {
                firstError = error
            }
            self.channel = nil
        }
        do {
            try await group.shutdownGracefully()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        do {
            try removeOwnedSocket()
        } catch {
            // Prefer the path-identity failure: it is the security-relevant
            // reason cleanup deliberately left the replacement untouched.
            firstError = error
        }
        if let firstError {
            throw firstError
        }
    }

    private func makeBootstrap() -> ServerBootstrap {
        let responder = responder
        let logger = logger
        let connections = connections
        let limits = limits
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgradeState = DockerUpgradeState()
                let pipeline = DockerHTTPPipeline(
                    responseEncoder: HTTPResponseEncoder(),
                    requestDecoder: ByteToMessageHandler(
                        HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
                    ),
                    upgradeState: upgradeState,
                    inputCloseBarrier: DockerInputCloseBarrier(state: upgradeState)
                )
                let handler = DockerHTTPHandler(
                    responder: responder,
                    logger: logger,
                    connections: connections,
                    pipeline: pipeline,
                    limits: limits
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(pipeline.responseEncoder)
                    try channel.pipeline.syncOperations.addHandler(pipeline.inputCloseBarrier)
                    try channel.pipeline.syncOperations.addHandler(pipeline.requestDecoder)
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(
                ChannelOptions.recvAllocator,
                value: AdaptiveRecvByteBufferAllocator()
            )
    }

    private func prepareSocketDirectory() throws {
        let url = URL(fileURLWithPath: socketPath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var parentStatus = stat()
        guard
            lstat(parent.path, &parentStatus) == 0,
            parentStatus.st_uid == getuid(),
            parentStatus.st_mode & S_IFMT == S_IFDIR,
            parentStatus.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw ContainerUnixHTTPServerError.unsafeSocketDirectory(parent.path)
        }
        guard chmod(parent.path, S_IRWXU) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func prepareSocketPath() throws {
        var status = stat()
        if lstat(socketPath, &status) == 0 {
            guard
                status.st_uid == getuid(),
                status.st_mode & S_IFMT == S_IFSOCK
            else {
                throw ContainerUnixHTTPServerError.unsafeExistingSocket(socketPath)
            }
            try FileManager.default.removeItem(atPath: socketPath)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func acquireInstanceLock() throws {
        let lockPath = socketPath + ".lock"
        let descriptor = open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var status = stat()
        guard
            fstat(descriptor, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1,
            fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            close(descriptor)
            throw ContainerUnixHTTPServerError.unsafeInstanceLock(lockPath)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw ContainerUnixHTTPServerError.alreadyRunning
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        lockFileDescriptor = descriptor
    }

    private func releaseInstanceLock() {
        guard lockFileDescriptor >= 0 else {
            return
        }
        _ = flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func socketIdentity(at path: String) throws -> SocketIdentity {
        var status = stat()
        guard
            lstat(path, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFSOCK
        else {
            throw ContainerUnixHTTPServerError.unsafeExistingSocket(path)
        }
        return SocketIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func removeOwnedSocket() throws {
        guard let boundSocketIdentity else {
            return
        }
        var status = stat()
        guard lstat(socketPath, &status) == 0 else {
            if errno == ENOENT {
                self.boundSocketIdentity = nil
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let current = SocketIdentity(device: status.st_dev, inode: status.st_ino)
        guard
            current == boundSocketIdentity,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFSOCK
        else {
            throw ContainerUnixHTTPServerError.socketIdentityChanged(socketPath)
        }
        try FileManager.default.removeItem(atPath: socketPath)
        self.boundSocketIdentity = nil
    }
}

public enum ContainerUnixHTTPServerError: Error, CustomStringConvertible, Sendable {
    case alreadyRunning
    case alreadyStarted
    case notStarted
    case socketIdentityChanged(String)
    case unsafeExistingSocket(String)
    case unsafeInstanceLock(String)
    case unsafeSocketDirectory(String)

    public var description: String {
        switch self {
        case .alreadyRunning:
            "another Container Engine server owns this socket"
        case .alreadyStarted:
            "Container Engine server is already started"
        case .notStarted:
            "Container Engine server is not started"
        case let .socketIdentityChanged(path):
            "refusing to remove replaced Container Engine socket at \(path)"
        case let .unsafeExistingSocket(path):
            "refusing to replace non-owned or non-socket path at \(path)"
        case let .unsafeInstanceLock(path):
            "instance lock is not a safe current-user regular file: \(path)"
        case let .unsafeSocketDirectory(path):
            "socket directory must be owned by the current user and not group/world writable: \(path)"
        }
    }
}

private struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private final class DockerUpgradeState: @unchecked Sendable {
    var upgradeCandidate = false
    var inputClosed = false

    func beginRequest(_ head: HTTPRequestHead) {
        upgradeCandidate = head.headers.contains(name: "Upgrade")
    }
}

private final class DockerInputCloseBarrier:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private let state: DockerUpgradeState

    init(state: DockerUpgradeState) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if let channelEvent = event as? ChannelEvent,
           channelEvent == .inputClosed,
           state.upgradeCandidate
        {
            state.inputClosed = true
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func removeHandler(
        context: ChannelHandlerContext,
        removalToken: ChannelHandlerContext.RemovalToken
    ) {
        context.leavePipeline(removalToken: removalToken)
    }
}

private struct DockerHTTPPendingRequest {
    let head: HTTPRequestHead
    let request: DockerHTTPRequest?
    let bodyBytes: Int
}

private struct DockerHTTPPipeline {
    let responseEncoder: HTTPResponseEncoder
    let requestDecoder: ByteToMessageHandler<HTTPRequestDecoder>
    let upgradeState: DockerUpgradeState
    let inputCloseBarrier: DockerInputCloseBarrier
}

private final class DockerHTTPHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responder: any DockerHTTPResponder
    private let logger: Logger
    private let connections: EngineConnectionTracker
    private let responseEncoder: HTTPResponseEncoder
    private let requestDecoder: ByteToMessageHandler<HTTPRequestDecoder>
    private let upgradeState: DockerUpgradeState
    private let inputCloseBarrier: DockerInputCloseBarrier
    private let limits: ContainerUnixHTTPServerLimits
    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()
    private var activeRequestHead: HTTPRequestHead?
    private var activeRequestBodyBytes = 0
    private var pendingRequests = Deque<DockerHTTPPendingRequest>()
    private var retainedRequestBodyBytes = 0
    private var responseInFlight = false
    private var closeAfterResponse = false

    init(
        responder: any DockerHTTPResponder,
        logger: Logger,
        connections: EngineConnectionTracker,
        pipeline: DockerHTTPPipeline,
        limits: ContainerUnixHTTPServerLimits
    ) {
        self.responder = responder
        self.logger = logger
        self.connections = connections
        responseEncoder = pipeline.responseEncoder
        requestDecoder = pipeline.requestDecoder
        upgradeState = pipeline.upgradeState
        inputCloseBarrier = pipeline.inputCloseBarrier
        self.limits = limits
    }

    func channelActive(context: ChannelHandlerContext) {
        connections.opened()
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        connections.closed()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if let channelEvent = event as? ChannelEvent,
           channelEvent == .inputClosed
        {
            if responseInFlight || !pendingRequests.isEmpty {
                closeAfterResponse = true
            } else {
                context.close(promise: nil)
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            guard requestHead == nil else {
                context.close(promise: nil)
                return
            }
            if responseInFlight,
               activeRequestHead?.headers.contains(name: "Upgrade") == true
            {
                context.close(promise: nil)
                return
            }
            if head.headers.contains(name: "Upgrade"),
               responseInFlight || !pendingRequests.isEmpty
            {
                context.close(promise: nil)
                return
            }
            upgradeState.beginRequest(head)
            requestHead = head
            requestBody.clear()
        case var .body(buffer):
            guard canBufferRequestBody(buffer.readableBytes) else {
                guard !responseInFlight, pendingRequests.isEmpty else {
                    context.close(promise: nil)
                    return
                }
                writeError(
                    context: context,
                    status: .payloadTooLarge,
                    message: "request body exceeds the configured buffering limit"
                )
                context.close(promise: nil)
                return
            }
            requestBody.writeBuffer(&buffer)
        case .end:
            enqueueRequest(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        logger.error(
            "Container Engine connection failed",
            metadata: ["error": .string(String(describing: error))]
        )
        context.close(promise: nil)
    }

    private func enqueueRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else {
            context.close(promise: nil)
            return
        }
        guard pendingRequests.count < limits.maximumPendingRequests else {
            context.close(promise: nil)
            return
        }
        let bodyBytes = requestBody.readableBytes
        let body = requestBody.readData(
            length: bodyBytes,
            byteTransferStrategy: .noCopy
        ) ?? Data()
        requestBody = ByteBuffer()
        retainedRequestBodyBytes += body.count
        let headers = DockerHTTPHeaders(
            head.headers.map {
                DockerHTTPHeaders.Field(name: $0.name, value: $0.value)
            }
        )
        let request = DockerHTTPMethod(rawValue: head.method.rawValue).map {
            DockerHTTPRequest(
                method: $0,
                target: head.uri,
                headers: headers,
                body: body
            )
        }
        requestHead = nil
        pendingRequests.append(
            DockerHTTPPendingRequest(
                head: head,
                request: request,
                bodyBytes: body.count
            )
        )
        processNextRequest(context: context)
    }

    private func canBufferRequestBody(_ additionalBytes: Int) -> Bool {
        let (requestBytes, requestOverflow) = requestBody.readableBytes
            .addingReportingOverflow(additionalBytes)
        guard
            !requestOverflow,
            requestBytes <= limits.maximumRequestBodyBytes
        else {
            return false
        }
        let (totalBytes, totalOverflow) = retainedRequestBodyBytes
            .addingReportingOverflow(requestBytes)
        return !totalOverflow
            && totalBytes <= limits.maximumBufferedRequestBodyBytes
    }

    private func processNextRequest(context: ChannelHandlerContext) {
        guard !responseInFlight, let pending = pendingRequests.popFirst() else {
            return
        }
        responseInFlight = true
        activeRequestHead = pending.head
        activeRequestBodyBytes = pending.bodyBytes
        upgradeState.beginRequest(pending.head)
        guard let request = pending.request else {
            releaseActiveRequestBody()
            writeError(
                context: context,
                status: .methodNotAllowed,
                message: "unsupported HTTP method"
            )
            return
        }
        let promise = context.eventLoop.makePromise(of: DockerHTTPResponse.self)
        let sendableContext = SendableChannelHandlerContext(context)
        promise.completeWithTask {
            await self.responder.respond(to: request)
        }
        promise.futureResult.whenComplete { result in
            let context = sendableContext.value
            self.releaseActiveRequestBody()
            switch result {
            case let .success(response):
                self.write(response, context: context)
            case let .failure(error):
                self.writeError(
                    context: context,
                    status: .internalServerError,
                    message: "Engine request failed: \(error)"
                )
            }
        }
    }

    private func releaseActiveRequestBody() {
        retainedRequestBodyBytes -= activeRequestBodyBytes
        activeRequestBodyBytes = 0
    }

    private func write(
        _ response: DockerHTTPResponse,
        context: ChannelHandlerContext
    ) {
        closeAfterResponse = closeAfterResponse || upgradeState.inputClosed
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        let status = HTTPResponseStatus(statusCode: response.status)
        switch response.body {
        case let .bytes(data):
            writeBytes(data, headers: &headers, status: status, context: context)
        case let .stream(stream):
            writeStream(stream, headers: &headers, status: status, context: context)
        case let .hijack(session, terminal):
            writeHijack(
                session: session,
                terminal: terminal,
                headers: &headers,
                context: context
            )
        }
    }

    private func writeBytes(
        _ data: Data,
        headers: inout HTTPHeaders,
        status: HTTPResponseStatus,
        context: ChannelHandlerContext
    ) {
        headers.remove(name: "Transfer-Encoding")
        headers.replaceOrAdd(name: "Content-Length", value: String(data.count))
        context.write(
            wrapOutboundOut(
                .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))
            ),
            promise: nil
        )
        if !data.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        finishResponse(promise.futureResult, context: context)
    }

    private func writeStream(
        _ stream: AsyncThrowingStream<Data, any Error>,
        headers: inout HTTPHeaders,
        status: HTTPResponseStatus,
        context: ChannelHandlerContext
    ) {
        headers.remove(name: "Content-Length")
        headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        context.writeAndFlush(
            wrapOutboundOut(
                .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))
            ),
            promise: nil
        )
        streamBody(stream, context: context)
    }

    private func writeHijack(
        session: any DockerHijackSession,
        terminal: Bool,
        headers: inout HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        let requestedUpgrade = activeRequestHead?.headers.contains(name: "Upgrade") ?? false
        logger.debug(
            "Container Engine connection takeover requested",
            metadata: [
                "request-target": .string(activeRequestHead?.uri ?? "unknown"),
                "upgrade": .stringConvertible(requestedUpgrade)
            ]
        )
        if !requestedUpgrade {
            headers.replaceOrAdd(name: "Connection", value: "close")
            headers.remove(name: "Upgrade")
            headers.remove(name: "Transfer-Encoding")
            headers.remove(name: "Content-Length")
        }
        let headPromise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(
            wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: requestedUpgrade ? .http1_1 : .http1_0,
                        status: requestedUpgrade ? .switchingProtocols : .ok,
                        headers: headers
                    )
                )
            ),
            promise: headPromise
        )
        let rawHandler = DockerRawStreamHandler(
            session: session,
            terminal: terminal,
            logger: logger,
            connections: connections
        )
        let sendableContext = SendableChannelHandlerContext(context)
        headPromise.futureResult.whenComplete { result in
            self.completeHijack(
                result,
                handler: rawHandler,
                context: sendableContext.value
            )
        }
    }

    private func completeHijack(
        _ result: Result<Void, any Error>,
        handler: DockerRawStreamHandler,
        context: ChannelHandlerContext
    ) {
        do {
            try result.get()
            try context.pipeline.syncOperations.addHandler(handler)
            let pipeline = context.pipeline
            let sendableContext = SendableChannelHandlerContext(context)
            pipeline.syncOperations.removeHandler(self)
                .flatMap {
                    pipeline.syncOperations.removeHandler(self.requestDecoder)
                }
                .flatMap {
                    pipeline.syncOperations.removeHandler(self.responseEncoder)
                }
                .flatMap {
                    pipeline.syncOperations.removeHandler(self.inputCloseBarrier)
                }
                .whenComplete { removal in
                    let context = sendableContext.value
                    switch removal {
                    case .success:
                        handler.start(channel: context.channel)
                        if self.closeAfterResponse || self.upgradeState.inputClosed {
                            handler.closeInput()
                        }
                    case let .failure(error):
                        self.logger.error(
                            "Container Engine connection takeover failed",
                            metadata: ["error": .string(String(describing: error))]
                        )
                        context.close(promise: nil)
                    }
                }
        } catch {
            logger.error(
                "Container Engine connection takeover failed",
                metadata: ["error": .string(String(describing: error))]
            )
            context.close(promise: nil)
        }
    }

    private func streamBody(
        _ stream: AsyncThrowingStream<Data, any Error>,
        context: ChannelHandlerContext
    ) {
        let sendableContext = SendableChannelHandlerContext(context)
        Task {
            do {
                for try await data in stream {
                    let bytes = data
                    sendableContext.value.eventLoop.execute {
                        let context = sendableContext.value
                        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        context.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))),
                            promise: nil
                        )
                    }
                }
                sendableContext.value.eventLoop.execute {
                    let context = sendableContext.value
                    let promise = context.eventLoop.makePromise(of: Void.self)
                    context.writeAndFlush(
                        self.wrapOutboundOut(.end(nil)),
                        promise: promise
                    )
                    self.finishResponse(promise.futureResult, context: context)
                }
            } catch {
                self.logger.error(
                    "Container Engine stream failed",
                    metadata: ["error": .string(String(describing: error))]
                )
                sendableContext.value.eventLoop.execute {
                    sendableContext.value.close(promise: nil)
                }
            }
        }
    }

    private func writeError(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        message: String
    ) {
        let data = (try? DockerJSON.encoder.encode(DockerErrorEnvelope(message: message)))
            ?? Data(#"{"message":"Engine request failed"}"#.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(data.count))
        context.write(
            wrapOutboundOut(
                .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))
            ),
            promise: nil
        )
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        finishResponse(promise.futureResult, context: context)
    }

    private func finishResponse(
        _ future: EventLoopFuture<Void>,
        context: ChannelHandlerContext
    ) {
        let sendableContext = SendableChannelHandlerContext(context)
        future.whenComplete { _ in
            self.responseInFlight = false
            self.activeRequestHead = nil
            if self.closeAfterResponse, self.pendingRequests.isEmpty {
                sendableContext.value.close(promise: nil)
            } else {
                self.processNextRequest(context: sendableContext.value)
            }
        }
    }
}

private final class DockerRawStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let session: any DockerHijackSession
    private let terminal: Bool
    private let logger: Logger
    private let connections: EngineConnectionTracker
    private let inputPump: OrderedDockerInputPump
    private var outputTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var finishedNormally = false

    init(
        session: any DockerHijackSession,
        terminal: Bool,
        logger: Logger,
        connections: EngineConnectionTracker
    ) {
        self.session = session
        self.terminal = terminal
        self.logger = logger
        self.connections = connections
        inputPump = OrderedDockerInputPump(session: session)
    }

    func start(channel: any Channel) {
        outputTask = Task {
            do {
                for try await frame in session.frames {
                    let data = try DockerStreamFraming.encode(frame, terminal: terminal)
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await channel.writeAndFlush(buffer).get()
                }
                _ = try await session.wait()
                stateLock.withLock {
                    finishedNormally = true
                }
                try await channel.close().get()
            } catch {
                logger.error(
                    "Container Engine raw stream failed",
                    metadata: ["error": .string(String(describing: error))]
                )
                channel.eventLoop.execute {
                    channel.close(promise: nil)
                }
            }
        }
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        guard !bytes.isEmpty else {
            return
        }
        inputPump.write(Data(bytes))
    }

    func closeInput() {
        inputPump.close()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            closeInput()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        connections.closed()
        let shouldCancel = stateLock.withLock {
            !finishedNormally
        }
        if shouldCancel {
            outputTask?.cancel()
            inputPump.cancel()
        } else {
            inputPump.finish()
        }
        context.fireChannelInactive()
    }
}

private final class EngineConnectionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0

    var count: Int {
        lock.withLock { active }
    }

    func opened() {
        lock.withLock {
            active += 1
        }
    }

    func closed() {
        lock.withLock {
            active = max(0, active - 1)
        }
    }
}

final class OrderedDockerInputPump: @unchecked Sendable {
    private enum Event: Sendable {
        case data(Data)
        case close
    }

    private let continuation: AsyncStream<Event>.Continuation
    private let worker: Task<Void, Never>
    private let stateLock = NSLock()
    private var finished = false

    init(session: any DockerHijackSession) {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        worker = Task {
            do {
                for await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case let .data(data):
                        try await session.write(data)
                    case .close:
                        try await session.closeStandardInput()
                    }
                }
            } catch {
                await session.cancel()
            }
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        stateLock.withLock {
            guard !finished else {
                return
            }
            continuation.yield(.data(data))
        }
    }

    func close() {
        stateLock.withLock {
            guard !finished else {
                return
            }
            finished = true
            continuation.yield(.close)
            continuation.finish()
        }
    }

    func finish() {
        stateLock.withLock {
            guard !finished else {
                return
            }
            finished = true
            continuation.finish()
        }
    }

    func cancel() {
        stateLock.withLock {
            guard !finished else {
                return
            }
            finished = true
            continuation.finish()
            worker.cancel()
        }
    }

    func wait() async {
        await worker.value
    }
}

private struct SendableChannelHandlerContext: @unchecked Sendable {
    let value: ChannelHandlerContext

    init(_ value: ChannelHandlerContext) {
        self.value = value
    }
}
