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
    // Deterministic fault-injection seam for post-bind cleanup tests.
    private let startValidationHook: (@Sendable () async throws -> Void)?
    private let connections: EngineConnectionTracker
    private let bufferBudget: EngineBufferBudget
    private let lifecycleLock = NSLock()
    private var lifecycle = ServerLifecycle.initialized
    private var channel: (any Channel)?
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
        startValidationHook = nil
        connections = EngineConnectionTracker(
            maximumConnections: limits.maximumConnections
        )
        bufferBudget = EngineBufferBudget(
            maximumBytes: limits.maximumAggregateBufferedRequestBodyBytes
        )
    }

    init(
        responder: any DockerHTTPResponder,
        socketPath: String,
        logger: Logger,
        limits: ContainerUnixHTTPServerLimits,
        startValidationHook: @escaping @Sendable () async throws -> Void
    ) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.responder = responder
        self.socketPath = socketPath
        self.logger = logger
        self.limits = limits
        self.startValidationHook = startValidationHook
        connections = EngineConnectionTracker(
            maximumConnections: limits.maximumConnections
        )
        bufferBudget = EngineBufferBudget(
            maximumBytes: limits.maximumAggregateBufferedRequestBodyBytes
        )
    }

    public func start() async throws {
        try beginStart()
        var boundChannel: (any Channel)?
        do {
            try validateSocketPath()
            try prepareSocketDirectory()
            try acquireInstanceLock()
            try prepareSocketPath()
            let candidate = try await makeBootstrap()
                .bind(unixDomainSocketPath: socketPath)
                .get()
            boundChannel = candidate
            try await startValidationHook?()
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
            finishStart(channel: candidate)
        } catch {
            let failedConnections = connections.beginDraining()
            if let boundChannel {
                try? await boundChannel.close()
            }
            await closeConnectionsAndWait(failedConnections)
            connections.resumeAdmissionsAfterFailedStart()
            try? removeOwnedSocket()
            releaseInstanceLock()
            failStart()
            throw error
        }

        logger.info("Container Engine API listening", metadata: ["socket": .string(socketPath)])
    }

    public func wait() async throws {
        let channel = try runningChannel()
        try await channel.closeFuture.get()
    }

    public var activeConnectionCount: Int {
        connections.count
    }

    public var bufferedRequestBodyBytes: Int {
        bufferBudget.count
    }

    public func shutdown() async throws {
        let shutdown = try beginShutdown()
        guard shutdown.shouldRun else {
            return
        }
        defer {
            releaseInstanceLock()
            finishShutdown()
        }
        var firstError: (any Error)?
        let drainingConnections = connections.beginDraining()
        if let channel = shutdown.channel {
            do {
                try await channel.close()
            } catch {
                firstError = error
            }
        }
        for drainingConnection in drainingConnections {
            drainingConnection.channel.pipeline.fireUserInboundEventTriggered(
                DockerServerDrainEvent()
            )
        }
        await drainConnections()
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

    private func beginStart() throws {
        try lifecycleLock.withLock {
            switch lifecycle {
            case .initialized:
                lifecycle = .starting
            case .running:
                throw ContainerUnixHTTPServerError.alreadyStarted
            case .starting, .stopping:
                throw ContainerUnixHTTPServerLifecycleError.transitionInProgress
            case .stopped:
                throw ContainerUnixHTTPServerLifecycleError.oneShotServer
            }
        }
    }

    private func finishStart(channel: any Channel) {
        lifecycleLock.withLock {
            self.channel = channel
            lifecycle = .running
        }
    }

    private func failStart() {
        lifecycleLock.withLock {
            channel = nil
            lifecycle = .initialized
        }
    }

    private func runningChannel() throws -> any Channel {
        try lifecycleLock.withLock {
            guard lifecycle == .running, let channel else {
                throw ContainerUnixHTTPServerError.notStarted
            }
            return channel
        }
    }

    private func beginShutdown() throws -> ShutdownPlan {
        try lifecycleLock.withLock {
            switch lifecycle {
            case .initialized:
                lifecycle = .stopping
                return ShutdownPlan(shouldRun: true, channel: nil)
            case .running:
                lifecycle = .stopping
                let runningChannel = channel
                channel = nil
                return ShutdownPlan(
                    shouldRun: true,
                    channel: runningChannel
                )
            case .starting, .stopping:
                throw ContainerUnixHTTPServerLifecycleError.transitionInProgress
            case .stopped:
                return ShutdownPlan(shouldRun: false, channel: nil)
            }
        }
    }

    private func finishShutdown() {
        lifecycleLock.withLock {
            channel = nil
            lifecycle = .stopped
        }
    }

    private func drainConnections() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limits.gracefulDrainTimeout)
        while connections.count > 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard connections.count > 0 else {
            return
        }
        logger.warning(
            "Container Engine graceful drain deadline elapsed",
            metadata: [
                "active-connections": .stringConvertible(connections.count)
            ]
        )
        connections.forceCloseAll()
    }

    private func closeConnectionsAndWait(
        _ trackedConnections: [EngineTrackedConnection]
    ) async {
        for trackedConnection in trackedConnections {
            trackedConnection.channel.close(promise: nil)
        }
        for trackedConnection in trackedConnections {
            try? await trackedConnection.channel.closeFuture.get()
            connections.closed(trackedConnection.identifier)
        }
    }

    private func makeBootstrap() -> ServerBootstrap {
        let responder = responder
        let logger = logger
        let connections = connections
        let bufferBudget = bufferBudget
        let limits = limits
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    try DockerPeerCredentialValidator.requireCurrentUser(on: channel)
                } catch {
                    logger.warning(
                        "Rejected Container Engine peer",
                        metadata: ["error": .string(String(describing: error))]
                    )
                    return channel.eventLoop.makeFailedFuture(error)
                }
                guard let connectionID = connections.admit(channel) else {
                    logger.warning("Rejected Container Engine connection at configured ceiling")
                    return channel.close()
                }
                channel.closeFuture.whenComplete { _ in
                    connections.closed(connectionID)
                }
                let upgradeState = DockerUpgradeState()
                let deadlineHandler = DockerConnectionDeadlineHandler(
                    readTimeout: limits.requestReadTimeout.nioTimeAmount,
                    idleTimeout: limits.idleConnectionTimeout.nioTimeAmount,
                    logger: logger
                )
                let pipeline = DockerHTTPPipeline(
                    responseEncoder: HTTPResponseEncoder(),
                    requestDecoder: ByteToMessageHandler(
                        HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
                    ),
                    upgradeState: upgradeState,
                    inputCloseBarrier: DockerInputCloseBarrier(state: upgradeState),
                    deadlineHandler: deadlineHandler
                )
                let handler = DockerHTTPHandler(
                    responder: responder,
                    logger: logger,
                    bufferBudget: bufferBudget,
                    pipeline: pipeline,
                    limits: limits
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(pipeline.responseEncoder)
                    try channel.pipeline.syncOperations.addHandler(pipeline.inputCloseBarrier)
                    try channel.pipeline.syncOperations.addHandler(pipeline.deadlineHandler)
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

    private func validateSocketPath() throws {
        let components = socketPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let pathCapacity = withUnsafeBytes(of: sockaddr_un().sun_path) { $0.count }
        guard
            socketPath.hasPrefix("/"),
            !socketPath.contains("\0"),
            components.count > 1,
            components.last?.isEmpty == false,
            components.dropFirst().allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            }),
            socketPath.utf8.count < pathCapacity
        else {
            throw ContainerUnixHTTPServerSocketPathError(path: socketPath)
        }
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

private enum ServerLifecycle {
    case initialized
    case running
    case starting
    case stopped
    case stopping
}

private struct ShutdownPlan {
    let shouldRun: Bool
    let channel: (any Channel)?
}

private struct DockerServerDrainEvent: Sendable {}

enum DockerPeerCredentialValidator {
    static func requireCurrentUser(on channel: any Channel) throws {
        var peerUserID = uid_t.max
        var peerGroupID = gid_t.max
        let result = try channel.pipeline.syncOperations
            .withUnsafeTransportIfAvailable(
                of: NIOBSDSocket.Handle.self
            ) { descriptor in
                getpeereid(descriptor, &peerUserID, &peerGroupID)
            }
        guard let result else {
            throw DockerPeerCredentialError.unavailable
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try validate(peerUserID: peerUserID, expectedUserID: getuid())
    }

    static func validate(peerUserID: uid_t, expectedUserID: uid_t) throws {
        guard peerUserID == expectedUserID else {
            throw DockerPeerCredentialError.userMismatch(
                expected: expectedUserID,
                actual: peerUserID
            )
        }
    }
}

private extension Duration {
    var nioTimeAmount: TimeAmount {
        let durationComponents = components
        let (wholeNanoseconds, secondsOverflow) = durationComponents.seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else {
            return .nanoseconds(Int64.max)
        }
        let fractionalNanoseconds =
            durationComponents.attoseconds / 1_000_000_000
        let (nanoseconds, additionOverflow) = wholeNanoseconds
            .addingReportingOverflow(fractionalNanoseconds)
        return .nanoseconds(additionOverflow ? Int64.max : nanoseconds)
    }
}

public enum ContainerUnixHTTPServerError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
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

public enum ContainerUnixHTTPServerLifecycleError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case oneShotServer
    case transitionInProgress

    public var description: String {
        switch self {
        case .oneShotServer:
            "Container Engine server instances cannot restart after shutdown"
        case .transitionInProgress:
            "Container Engine server lifecycle transition is already in progress"
        }
    }
}

public struct ContainerUnixHTTPServerSocketPathError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var description: String {
        "Container Engine socket path is invalid or exceeds sockaddr_un: \(path)"
    }
}

enum DockerPeerCredentialError: Error, Equatable, CustomStringConvertible, Sendable {
    case unavailable
    case userMismatch(expected: uid_t, actual: uid_t)

    var description: String {
        switch self {
        case .unavailable:
            "Container Engine peer credentials are unavailable"
        case let .userMismatch(expected, actual):
            "Container Engine peer user \(actual) does not match server user \(expected)"
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

private final class DockerConnectionDeadlineHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer

    private enum Phase {
        case disabled
        case ready
        case reading
    }

    private let readTimeout: TimeAmount
    private let idleTimeout: TimeAmount
    private let logger: Logger
    private var phase = Phase.ready
    private var scheduled: Scheduled<Void>?

    init(
        readTimeout: TimeAmount,
        idleTimeout: TimeAmount,
        logger: Logger
    ) {
        self.readTimeout = readTimeout
        self.idleTimeout = idleTimeout
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        beginIdle(on: context.channel)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        beginRequest(on: context.channel)
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelDeadline()
        context.fireChannelInactive()
    }

    func beginRequest(on channel: any Channel) {
        guard phase == .ready else {
            return
        }
        phase = .reading
        schedule(
            timeout: readTimeout,
            reason: "request read deadline elapsed",
            on: channel
        )
    }

    func completeRequest() {
        guard phase != .disabled else {
            return
        }
        cancelDeadline()
        phase = .ready
    }

    func beginIdle(on channel: any Channel) {
        guard phase == .ready else {
            return
        }
        schedule(
            timeout: idleTimeout,
            reason: "idle connection deadline elapsed",
            on: channel
        )
    }

    func disable() {
        cancelDeadline()
        phase = .disabled
    }

    func removeHandler(
        context: ChannelHandlerContext,
        removalToken: ChannelHandlerContext.RemovalToken
    ) {
        cancelDeadline()
        context.leavePipeline(removalToken: removalToken)
    }

    private func schedule(
        timeout: TimeAmount,
        reason: String,
        on channel: any Channel
    ) {
        cancelDeadline()
        let logger = logger
        scheduled = channel.eventLoop.scheduleTask(in: timeout) {
            logger.debug(
                "Closing Container Engine connection",
                metadata: ["reason": .string(reason)]
            )
            channel.close(promise: nil)
        }
    }

    private func cancelDeadline() {
        scheduled?.cancel()
        scheduled = nil
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
    let deadlineHandler: DockerConnectionDeadlineHandler
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
    private let bufferBudget: EngineBufferBudget
    private let responseEncoder: HTTPResponseEncoder
    private let requestDecoder: ByteToMessageHandler<HTTPRequestDecoder>
    private let upgradeState: DockerUpgradeState
    private let inputCloseBarrier: DockerInputCloseBarrier
    private let deadlineHandler: DockerConnectionDeadlineHandler
    private let limits: ContainerUnixHTTPServerLimits
    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()
    private var activeRequestHead: HTTPRequestHead?
    private var activeRequestBodyBytes = 0
    private var pendingRequests = Deque<DockerHTTPPendingRequest>()
    private var retainedRequestBodyBytes = 0
    private var responseInFlight = false
    private var responseTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var closeAfterResponse = false
    private var draining = false

    init(
        responder: any DockerHTTPResponder,
        logger: Logger,
        bufferBudget: EngineBufferBudget,
        pipeline: DockerHTTPPipeline,
        limits: ContainerUnixHTTPServerLimits
    ) {
        self.responder = responder
        self.logger = logger
        self.bufferBudget = bufferBudget
        responseEncoder = pipeline.responseEncoder
        requestDecoder = pipeline.requestDecoder
        upgradeState = pipeline.upgradeState
        inputCloseBarrier = pipeline.inputCloseBarrier
        deadlineHandler = pipeline.deadlineHandler
        self.limits = limits
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        responseTask?.cancel()
        streamTask?.cancel()
        releaseActiveRequestBody()
        releaseAbandonedRequestBodies()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        if event is DockerServerDrainEvent {
            draining = true
            closeAfterResponse = true
            let hasAcceptedWork = responseInFlight || !pendingRequests.isEmpty
            guard hasAcceptedWork else {
                context.close(promise: nil)
                return
            }
            deadlineHandler.disable()
            let sendableContext = SendableChannelHandlerContext(context)
            context.channel.setOption(ChannelOptions.autoRead, value: false)
                .whenFailure { error in
                    self.logger.error(
                        "Failed to suspend Container Engine reads during drain",
                        metadata: ["error": .string(String(describing: error))]
                    )
                    sendableContext.value.close(promise: nil)
                }
            return
        }
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
        guard !draining else {
            return
        }
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
            deadlineHandler.beginRequest(on: context.channel)
            upgradeState.beginRequest(head)
            requestHead = head
            requestBody.clear()
        case var .body(buffer):
            let additionalBytes = buffer.readableBytes
            guard
                canBufferRequestBody(additionalBytes),
                bufferBudget.reserve(additionalBytes)
            else {
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
            deadlineHandler.completeRequest()
            enqueueRequest(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard !draining else {
            context.close(promise: nil)
            return
        }
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
        let responder = responder
        let eventLoop = context.eventLoop
        let channel = context.channel
        responseTask = Task {
            let response = await responder.respond(to: request)
            guard channel.isActive else {
                return
            }
            let result: Result<DockerHTTPResponse, any Error> = Task.isCancelled
                ? .failure(CancellationError())
                : .success(response)
            eventLoop.execute {
                promise.completeWith(result)
            }
        }
        promise.futureResult.whenComplete { result in
            let context = sendableContext.value
            self.responseTask = nil
            self.releaseActiveRequestBody()
            guard context.channel.isActive else {
                return
            }
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
        bufferBudget.release(activeRequestBodyBytes)
        activeRequestBodyBytes = 0
    }

    private func releaseAbandonedRequestBodies() {
        let pendingBytes = pendingRequests.reduce(0) { total, request in
            total + request.bodyBytes
        }
        let currentBytes = requestBody.readableBytes
        let releasedBytes = pendingBytes + currentBytes
        retainedRequestBodyBytes -= pendingBytes
        requestBody = ByteBuffer()
        requestHead = nil
        pendingRequests.removeAll(keepingCapacity: false)
        bufferBudget.release(releasedBytes)
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
        case let .managedStream(session):
            writeManagedStream(
                session,
                headers: &headers,
                status: status,
                context: context
            )
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

    private func writeManagedStream(
        _ session: any DockerHTTPStreamSession,
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
        managedStreamBody(session, context: context)
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
            logger: logger
        )
        let sendableContext = SendableChannelHandlerContext(context)
        let eventLoop = context.eventLoop
        headPromise.futureResult.whenComplete { result in
            eventLoop.execute {
                self.completeHijack(
                    result,
                    handler: rawHandler,
                    context: sendableContext.value
                )
            }
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
                .flatMap {
                    self.deadlineHandler.disable()
                    return pipeline.syncOperations.removeHandler(
                        self.deadlineHandler
                    )
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
        let channel = context.channel
        streamTask = Task {
            do {
                for try await data in stream {
                    guard !Task.isCancelled, channel.isActive else {
                        return
                    }
                    let bytes = data
                    channel.eventLoop.execute {
                        let context = sendableContext.value
                        guard context.channel.isActive else {
                            return
                        }
                        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        context.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))),
                            promise: nil
                        )
                    }
                }
                guard !Task.isCancelled, channel.isActive else {
                    return
                }
                channel.eventLoop.execute {
                    let context = sendableContext.value
                    guard context.channel.isActive else {
                        return
                    }
                    let promise = context.eventLoop.makePromise(of: Void.self)
                    context.writeAndFlush(
                        self.wrapOutboundOut(.end(nil)),
                        promise: promise
                    )
                    self.finishResponse(promise.futureResult, context: context)
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.logger.error(
                    "Container Engine stream failed",
                    metadata: ["error": .string(String(describing: error))]
                )
                if channel.isActive {
                    channel.close(promise: nil)
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
            self.streamTask = nil
            self.activeRequestHead = nil
            guard sendableContext.value.channel.isActive else {
                return
            }
            if self.closeAfterResponse, self.pendingRequests.isEmpty {
                sendableContext.value.close(promise: nil)
            } else {
                self.processNextRequest(context: sendableContext.value)
                if !self.responseInFlight,
                   self.pendingRequests.isEmpty,
                   self.requestHead == nil
                {
                    self.deadlineHandler.beginIdle(
                        on: sendableContext.value.channel
                    )
                }
            }
        }
    }

    private func managedStreamBody(
        _ session: any DockerHTTPStreamSession,
        context: ChannelHandlerContext
    ) {
        let sendableContext = SendableChannelHandlerContext(context)
        let channel = context.channel
        streamTask = Task {
            await withTaskCancellationHandler {
                do {
                    while let data = try await session.nextChunk() {
                        try Task.checkCancellation()
                        guard channel.isActive else {
                            await session.cancel()
                            return
                        }
                        try await self.writeManagedChunk(
                            data,
                            context: sendableContext.value
                        )
                    }
                    await session.close()
                    try Task.checkCancellation()
                    guard channel.isActive else {
                        return
                    }
                    try await self.finishManagedStream(
                        context: sendableContext.value
                    )
                } catch is CancellationError {
                    await session.cancel()
                } catch {
                    await session.cancel()
                    guard !Task.isCancelled else {
                        return
                    }
                    self.logger.error(
                        "Container Engine managed stream failed",
                        metadata: ["error": .string(String(describing: error))]
                    )
                    if channel.isActive {
                        channel.close(promise: nil)
                    }
                }
            } onCancel: {
                Task {
                    await session.cancel()
                }
            }
        }
    }

    private func writeManagedChunk(
        _ data: Data,
        context: ChannelHandlerContext
    ) async throws {
        let sendableContext = SendableChannelHandlerContext(context)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.eventLoop.execute {
            let context = sendableContext.value
            guard context.channel.isActive else {
                promise.fail(ChannelError.ioOnClosedChannel)
                return
            }
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.writeAndFlush(
                self.wrapOutboundOut(.body(.byteBuffer(buffer))),
                promise: promise
            )
        }
        try await promise.futureResult.get()
    }

    private func finishManagedStream(
        context: ChannelHandlerContext
    ) async throws {
        let sendableContext = SendableChannelHandlerContext(context)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.eventLoop.execute {
            let context = sendableContext.value
            guard context.channel.isActive else {
                promise.fail(ChannelError.ioOnClosedChannel)
                return
            }
            context.writeAndFlush(
                self.wrapOutboundOut(.end(nil)),
                promise: promise
            )
        }
        try await promise.futureResult.get()
        finishResponse(promise.futureResult, context: context)
    }
}

private final class DockerRawStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let session: any DockerHijackSession
    private let terminal: Bool
    private let logger: Logger
    private let inputPump: OrderedDockerInputPump
    private let cancellation: DockerHijackCancellation
    private var outputTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var finishedNormally = false

    init(
        session: any DockerHijackSession,
        terminal: Bool,
        logger: Logger
    ) {
        self.session = session
        self.terminal = terminal
        self.logger = logger
        let cancellation = DockerHijackCancellation(session: session)
        self.cancellation = cancellation
        inputPump = OrderedDockerInputPump(
            session: session,
            cancellation: cancellation
        )
    }

    func start(channel: any Channel) {
        outputTask = Task {
            do {
                for try await frame in session.frames {
                    try Task.checkCancellation()
                    guard channel.isActive else {
                        return
                    }
                    let data = try DockerStreamFraming.encode(frame, terminal: terminal)
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await channel.writeAndFlush(buffer).get()
                }
                try Task.checkCancellation()
                guard channel.isActive else {
                    return
                }
                _ = try await session.wait()
                try Task.checkCancellation()
                guard channel.isActive else {
                    return
                }
                stateLock.withLock {
                    finishedNormally = true
                }
                try await channel.close().get()
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                logger.error(
                    "Container Engine raw stream failed",
                    metadata: ["error": .string(String(describing: error))]
                )
                if channel.isActive {
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
        let shouldCancel = stateLock.withLock {
            !finishedNormally
        }
        if shouldCancel {
            outputTask?.cancel()
            inputPump.cancel()
            cancellation.cancel()
        } else {
            inputPump.finish()
        }
        context.fireChannelInactive()
    }
}

private final class DockerHijackCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let session: any DockerHijackSession
    private var didCancel = false

    init(session: any DockerHijackSession) {
        self.session = session
    }

    func cancel() {
        let shouldCancel = lock.withLock {
            guard !didCancel else {
                return false
            }
            didCancel = true
            return true
        }
        guard shouldCancel else {
            return
        }
        let session = session
        Task {
            await session.cancel()
        }
    }
}

private struct EngineTrackedConnection {
    let identifier: UInt64
    let channel: any Channel
}

private final class EngineConnectionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumConnections: Int
    private var accepting = true
    private var channels: [UInt64: any Channel] = [:]
    private var nextIdentifier: UInt64 = 0

    init(maximumConnections: Int) {
        self.maximumConnections = maximumConnections
    }

    var count: Int {
        lock.withLock { channels.count }
    }

    func admit(_ channel: any Channel) -> UInt64? {
        lock.withLock {
            guard accepting, channels.count < maximumConnections else {
                return nil
            }
            let identifier = nextIdentifier
            nextIdentifier &+= 1
            precondition(channels[identifier] == nil)
            channels[identifier] = channel
            return identifier
        }
    }

    func closed(_ identifier: UInt64) {
        _ = lock.withLock {
            channels.removeValue(forKey: identifier)
        }
    }

    func beginDraining() -> [EngineTrackedConnection] {
        lock.withLock {
            accepting = false
            return channels.map { identifier, channel in
                EngineTrackedConnection(
                    identifier: identifier,
                    channel: channel
                )
            }
        }
    }

    func resumeAdmissionsAfterFailedStart() {
        lock.withLock {
            precondition(channels.isEmpty)
            accepting = true
        }
    }

    func forceCloseAll() {
        let activeChannels = lock.withLock { Array(channels.values) }
        for channel in activeChannels {
            channel.close(promise: nil)
        }
    }
}

private final class EngineBufferBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var usedBytes = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var count: Int {
        lock.withLock { usedBytes }
    }

    func reserve(_ bytes: Int) -> Bool {
        guard bytes >= 0 else {
            return false
        }
        return lock.withLock {
            let (newTotal, overflow) = usedBytes.addingReportingOverflow(bytes)
            guard !overflow, newTotal <= maximumBytes else {
                return false
            }
            usedBytes = newTotal
            return true
        }
    }

    func release(_ bytes: Int) {
        guard bytes > 0 else {
            return
        }
        lock.withLock {
            precondition(bytes <= usedBytes)
            usedBytes -= bytes
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
    private let cancellation: DockerHijackCancellation
    private let stateLock = NSLock()
    private var finished = false

    convenience init(session: any DockerHijackSession) {
        self.init(
            session: session,
            cancellation: DockerHijackCancellation(session: session)
        )
    }

    fileprivate init(
        session: any DockerHijackSession,
        cancellation: DockerHijackCancellation
    ) {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        self.cancellation = cancellation
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
                cancellation.cancel()
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
            if !finished {
                finished = true
                continuation.finish()
            }
        }
        worker.cancel()
        cancellation.cancel()
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
