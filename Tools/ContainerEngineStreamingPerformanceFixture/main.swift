//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineGateway
import ContainerEngineLogging
import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerEngineWire
import ContainerUnixHTTPServer
import Darwin
import Dispatch
import Foundation
import Logging

@main
struct ContainerEngineStreamingPerformanceFixture {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("performance fixture: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) async throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        let options = try Options(arguments: arguments)
        let declaration = try ContainerEngineProviderDeclaration(
            profile: .enhanced,
            kind: .containerAuthority,
            implementationVersion: "performance-fixture-v1",
            runtimeRevisions: ["fixture": "echo-v1"],
            stateSchemaVersion: 1,
            capabilities: [
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerAttachWebsocket",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerResize",
                    status: .native
                )
            ]
        )
        let provider = try ContainerEngineProviderSessionServer(
            responder: DockerLoggingAPIController(
                backend: PerformanceLoggingBackend()
            ),
            socketPath: options.providerSocket,
            declaration: declaration,
            stateRootUUID: UUID()
        )
        try provider.start()

        var logger = Logger(label: "container-engine-streaming-performance")
        logger.logLevel = .warning
        let publicServer = try ContainerUnixHTTPServer(
            responder: ContainerEngineGatewayResponder(
                providerSocketPath: options.providerSocket,
                fingerprint: provider.fingerprint
            ),
            socketPath: options.publicSocket,
            logger: logger
        )

        do {
            try await publicServer.start()
            print("ready")
            fflush(stdout)
            let signals = terminationSignals()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await publicServer.wait()
                }
                group.addTask {
                    for await _ in signals {
                        return
                    }
                }
                _ = try await group.next()
                try await publicServer.shutdown()
                await provider.shutdown()
                group.cancelAll()
                while try await group.next() != nil {}
            }
        } catch {
            try? await publicServer.shutdown()
            await provider.shutdown()
            throw error
        }
    }

    private static func terminationSignals() -> AsyncStream<Int32> {
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        return AsyncStream { continuation in
            let interrupt = DispatchSource.makeSignalSource(
                signal: SIGINT,
                queue: .global()
            )
            let terminate = DispatchSource.makeSignalSource(
                signal: SIGTERM,
                queue: .global()
            )
            interrupt.setEventHandler { continuation.yield(SIGINT) }
            terminate.setEventHandler { continuation.yield(SIGTERM) }
            continuation.onTermination = { _ in
                interrupt.cancel()
                terminate.cancel()
            }
            interrupt.resume()
            terminate.resume()
        }
    }

    private static let usage = """
    Usage: ContainerEngineStreamingPerformanceFixture \
      --public-socket PATH --provider-socket PATH

      --public-socket PATH    Public Docker-compatible Unix socket.
      --provider-socket PATH  Private provider-session Unix socket.
    """
}

private struct Options {
    var publicSocket: String
    var providerSocket: String

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard
                ["--public-socket", "--provider-socket"].contains(name),
                index + 1 < arguments.count
            else {
                throw OptionError.invalidArgument(name)
            }
            guard values.updateValue(arguments[index + 1], forKey: name) == nil else {
                throw OptionError.duplicateArgument(name)
            }
            index += 2
        }
        publicSocket = try Self.require("--public-socket", in: values)
        providerSocket = try Self.require("--provider-socket", in: values)
    }

    private static func require(
        _ name: String,
        in values: [String: String]
    ) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw OptionError.missingArgument(name)
        }
        return value
    }
}

private enum OptionError: Error, CustomStringConvertible {
    case duplicateArgument(String)
    case invalidArgument(String)
    case missingArgument(String)

    var description: String {
        switch self {
        case let .duplicateArgument(name):
            "duplicate argument \(name)"
        case let .invalidArgument(name):
            "invalid argument \(name)"
        case let .missingArgument(name):
            "missing required argument \(name)"
        }
    }
}

private struct PerformanceLoggingBackend:
    DockerLoggingBackend,
    DockerTerminalResizeBackend
{
    func loggingSystemInfo() async throws -> DockerLoggingSystemInfo {
        DockerLoggingSystemInfo(
            defaultDriver: "json-file",
            registeredDrivers: ["json-file"]
        )
    }

    func inspectContainerLogging(
        containerID: String
    ) async throws -> DockerContainerLoggingInspection {
        try requireFixture(containerID)
        return DockerContainerLoggingInspection(
            configuration: DockerResolvedLogConfiguration(driver: "json-file"),
            publicLogPath: "",
            terminal: true
        )
    }

    func openContainerLogs(
        containerID _: String,
        request _: DockerLogReadRequest
    ) async throws -> any DockerLogReadSession {
        throw DockerLoggingBackendError.unsupportedLogReader
    }

    func attachContainer(
        containerID: String,
        request _: DockerAttachRequest
    ) async throws -> DockerAttachConnection {
        try requireFixture(containerID)
        return DockerAttachConnection(
            terminal: true,
            session: EchoHijackSession()
        )
    }

    func resizeContainerTerminal(
        containerID: String,
        height _: UInt32,
        width _: UInt32
    ) async throws {
        try requireFixture(containerID)
    }

    private func requireFixture(_ containerID: String) throws {
        guard containerID == "fixture" else {
            throw DockerLoggingBackendError.containerNotFound(containerID)
        }
    }
}

private final class EchoHijackSession: DockerHijackSession, @unchecked Sendable {
    let frames: AsyncThrowingStream<DockerStreamFrame, any Error>

    private let continuation:
        AsyncThrowingStream<DockerStreamFrame, any Error>.Continuation
    private let completion: Task<Int32, Never>
    private let completionContinuation: AsyncStream<Int32>.Continuation

    init() {
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

    func write(_ data: Data) {
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
