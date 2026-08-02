//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineGateway
import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerUnixHTTPServer
import Darwin
import Dispatch
import Foundation
import Logging

@main
struct ContainerEngineService {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("container-engine: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) async throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        let options = try Options(arguments: arguments)
        let descriptor = try await ContainerEngineProviderSessionClient.probe(
            socketPath: options.providerSocket
        )
        let stateDirectory = URL(fileURLWithPath: options.stateDirectory, isDirectory: true)
        let selected = try ContainerEngineProviderSelectionStore(
            path: stateDirectory.appendingPathComponent("engine-provider.json")
        ).select(
            descriptor.fingerprint.declaration,
            stateRootUUID: descriptor.fingerprint.stateRootUUID
        )
        guard selected == descriptor.fingerprint else {
            throw ContainerEngineProviderIdentityError.providerMismatch(
                selected: selected.digest
            )
        }

        var logger = Logger(label: "container-engine")
        logger.logLevel = .info
        let responder = try ContainerEngineGatewayResponder(
            providerSocketPath: options.providerSocket,
            fingerprint: selected
        )
        let server = ContainerUnixHTTPServer(
            responder: responder,
            socketPath: options.socket,
            logger: logger
        )
        try await server.start()
        logger.info(
            "Engine gateway listening",
            metadata: [
                "fingerprint": .string(selected.digest),
                "profile": .string(selected.declaration.profile.rawValue),
                "socket": .string(options.socket)
            ]
        )

        let signals = terminationSignals()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.wait()
            }
            group.addTask {
                for await _ in signals {
                    return
                }
            }
            _ = try await group.next()
            try await server.shutdown()
            group.cancelAll()
            while try await group.next() != nil {}
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
    Usage: container-engine --socket PATH --provider-socket PATH --state-directory PATH

      --socket PATH           Public current-user Docker Engine Unix socket.
      --provider-socket PATH  Private socket owned by the selected provider adapter.
      --state-directory PATH  Private gateway identity and selection directory.
    """
}

private struct Options {
    var socket: String
    var providerSocket: String
    var stateDirectory: String

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard
                ["--socket", "--provider-socket", "--state-directory"].contains(name),
                index + 1 < arguments.count
            else {
                throw OptionError.invalidArgument(name)
            }
            guard values.updateValue(arguments[index + 1], forKey: name) == nil else {
                throw OptionError.duplicateArgument(name)
            }
            index += 2
        }
        socket = try Self.require("--socket", in: values)
        providerSocket = try Self.require("--provider-socket", in: values)
        stateDirectory = try Self.require("--state-directory", in: values)
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
