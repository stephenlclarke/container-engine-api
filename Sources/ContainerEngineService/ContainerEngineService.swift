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

public enum ContainerEngineServiceRunner {
    public static func run(arguments: [String]) async throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        let runtime = try await start(
            options: ContainerEngineServiceOptions(arguments: arguments)
        )
        let signals = terminationSignals()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await runtime.wait()
            }
            group.addTask {
                for await _ in signals {
                    return
                }
            }
            _ = try await group.next()
            try await runtime.shutdown()
            group.cancelAll()
            while try await group.next() != nil {}
        }
    }

    public static func start(
        options: ContainerEngineServiceOptions
    ) async throws -> ContainerEngineServiceRuntime {
        try await start(
            options: options,
            trustConfiguration: .production
        )
    }

    static func start(
        options: ContainerEngineServiceOptions,
        trustConfiguration: ContainerEngineServiceTrustConfiguration
    ) async throws -> ContainerEngineServiceRuntime {
        let descriptor = try await ContainerEngineProviderSessionClient.probe(
            socketPath: options.providerSocket
        )
        let stateDirectory = URL(fileURLWithPath: options.stateDirectory, isDirectory: true)
        let handoffTrust = try await prepareProviderHandoffTrust(
            descriptor: descriptor,
            providerSocket: options.providerSocket,
            configuration: trustConfiguration
        )
        let trustRegistryRevision = handoffTrust.registryRevision
        let handoffStore = ProviderHandoffGatewayStore(
            root: stateDirectory.appendingPathComponent("provider-handoff", isDirectory: true)
        )
        let loadedGatewayState = try handoffStore.loadOrCreate(
            initial: initialGatewayState(
                descriptor: descriptor,
                stateDirectory: stateDirectory,
                trustRegistryRevision: trustRegistryRevision
            )
        )
        let gatewayState: ProviderHandoffGatewayStateV1 = if loadedGatewayState.providerSelection.trustRegistryRevision
            == trustRegistryRevision
        {
            loadedGatewayState
        } else {
            try handoffStore.update(
                expectedStoreRevision: loadedGatewayState.storeRevision
            ) {
                try ProviderHandoffGatewayStateMachine
                    .adoptTrustRegistryRevision(
                        trustRegistryRevision,
                        in: &$0,
                        expectedStoreRevision:
                        loadedGatewayState.storeRevision
                    )
            }
        }
        guard
            gatewayState.providerSelection.selectedProviderFingerprint
            == descriptor.fingerprint.digest,
            gatewayState.providerSelection.selectedStateRootUUID
            == descriptor.fingerprint.stateRootUUID.uuidString.lowercased(),
            gatewayState.socketDiscovery.selectedProviderFingerprint
            == descriptor.fingerprint.digest,
            gatewayState.socketDiscovery.selectedStateRootUUID
            == descriptor.fingerprint.stateRootUUID.uuidString.lowercased()
        else {
            throw ContainerEngineProviderIdentityError.providerMismatch(
                selected: gatewayState.providerSelection.selectedProviderFingerprint
                    ?? "unselected"
            )
        }
        let selected = descriptor.fingerprint
        let configuredNow = trustConfiguration.nowUnixSeconds
        let handoffCoordinator = handoffTrust.gatewayIdentity.map {
            ProviderHandoffGatewayCoordinator(
                store: handoffStore,
                bootstrap: $0.bootstrap,
                manifestAuthority:
                ProviderHandoffGatewayManifestAuthorityV1(
                    gatewayIdentity: $0,
                    trustRegistryStore:
                    trustConfiguration.trustRegistryStore,
                    possessionProofStore:
                    ProviderHandoffPossessionProofStore(
                        root: stateDirectory
                            .appendingPathComponent(
                                "provider-handoff",
                                isDirectory: true
                            )
                            .appendingPathComponent(
                                "possession-proofs",
                                isDirectory: true
                            )
                    ),
                    nowUnixSeconds: {
                        if let configuredNow {
                            return configuredNow
                        }
                        return try currentUnixSeconds()
                    }
                )
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
        return ContainerEngineServiceRuntime(
            server: server,
            fingerprint: selected,
            socketPath: options.socket,
            handoffStore: handoffStore,
            handoffCoordinator: handoffCoordinator
        )
    }

    private static func initialGatewayState(
        descriptor: ContainerEngineProviderSessionDescriptor,
        stateDirectory: URL,
        trustRegistryRevision: UInt64
    ) throws -> ProviderHandoffGatewayStateV1 {
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
        let registrationDigest =
            selected.digest.hasPrefix("sha256:")
                ? String(selected.digest.dropFirst("sha256:".count))
                : selected.digest
        return try ProviderHandoffGatewayStateMachine.initialState(
            providerSelection: ProviderHandoffProviderSelectionRecordV1(
                selectionRevision: 1,
                selectedProviderFingerprint: selected.digest,
                selectedStateRootUUID: selected.stateRootUUID.uuidString.lowercased(),
                providerRegistrationDigestSHA256: registrationDigest,
                trustRegistryRevision: trustRegistryRevision
            ),
            socketDiscovery: ProviderHandoffSocketDiscoveryRecordV1(
                discoveryRevision: 1,
                socketInstanceUUID: UUID().uuidString.lowercased(),
                ownerUID: UInt32(getuid()),
                minimumEngineAPIVersion: "1.44",
                maximumEngineAPIVersion: "1.53",
                selectedProviderFingerprint: selected.digest,
                selectedStateRootUUID: selected.stateRootUUID.uuidString.lowercased()
            )
        )
    }

    private static func prepareProviderHandoffTrust(
        descriptor: ContainerEngineProviderSessionDescriptor,
        providerSocket: String,
        configuration: ContainerEngineServiceTrustConfiguration
    ) async throws -> PreparedProviderHandoffTrust {
        guard
            descriptor.fingerprint.declaration.capabilities.contains(where: {
                $0.identifier == "engine.handoff.provider-key-enrollment.v1"
                    && $0.status == .native
            })
        else {
            return PreparedProviderHandoffTrust(
                registryRevision: 0,
                gatewayIdentity: nil
            )
        }
        let now = try configuration.nowUnixSeconds ?? currentUnixSeconds()
        let gatewayCodeIdentity = try ProviderHandoffCodeIdentity.current()
        let gatewayIdentity = try configuration.gatewayKeyStore.loadOrCreate(
            context: ProviderHandoffGatewayKeyEnrollmentContextV1(
                owningBundleIdentifier:
                gatewayCodeIdentity.signingIdentifier,
                codeRequirementDigestSHA256:
                gatewayCodeIdentity.designatedRequirementDigestSHA256,
                teamIdentifier: gatewayCodeIdentity.teamIdentifier,
                gatewayRegistrationDigestSHA256:
                ProviderHandoffGatewayKeyEnrollmentContextV1
                    .registrationDigest(codeIdentity: gatewayCodeIdentity),
                enrolledAtUnixSeconds: now,
                notBeforeUnixSeconds: now,
                notAfterUnixSeconds: UInt64.max
            )
        )
        let expectedRoot = descriptor.fingerprint.stateRootUUID.uuidString
            .lowercased()
        let requestBody =
            try ProviderHandoffProviderKeyControlCodec
                .encodeSnapshotRequest(
                    ProviderHandoffProviderKeySnapshotRequestV1(
                        expectedProviderFingerprint:
                        descriptor.fingerprint.digest,
                        expectedStateRootUUID: expectedRoot
                    )
                )
        let request = try ContainerEngineProviderHandoffControlRequestV1(
            requestID: "provider-key-snapshot-\(UUID().uuidString.lowercased())",
            operation: .destinationKeySnapshot,
            bodyMediaType: ProviderHandoffProviderKeyControlCodec
                .snapshotRequestMediaType,
            body: requestBody
        )
        let result = try await ContainerEngineProviderSessionClient(
            socketPath: providerSocket,
            expectedFingerprint: descriptor.fingerprint
        ).performHandoffControl(request, body: requestBody)
        guard
            result.response.disposition == .completed,
            result.response.bodyMediaType
            == ProviderHandoffProviderKeyControlCodec.snapshotMediaType
        else {
            throw ContainerEngineProviderSessionError.providerFailure(
                result.response.message
                    ?? "provider rejected handoff key enrollment"
            )
        }
        let snapshot = try ProviderHandoffProviderKeyControlCodec.decodeSnapshot(
            result.body
        )
        let registrationDigest = String(
            descriptor.fingerprint.digest.dropFirst("sha256:".count)
        )
        let providerKeys =
            try ProviderHandoffProviderKeySnapshotValidator
                .validate(
                    snapshot,
                    expectedProviderFingerprint: descriptor.fingerprint.digest,
                    expectedStateRootUUID: expectedRoot,
                    peerCodeIdentity: descriptor.codeIdentity,
                    providerRegistrationDigestSHA256: registrationDigest,
                    atUnixSeconds: now
                )
        let store = configuration.trustRegistryStore
        do {
            let existing = try store.load(bootstrap: gatewayIdentity.bootstrap)
            let expectedKeys = gatewayIdentity.trustKeys + providerKeys
            guard
                expectedKeys.allSatisfy({ expected in
                    existing.registry.keys.contains(expected)
                })
            else {
                throw ProviderHandoffTrustError.invalidRegistry
            }
            return PreparedProviderHandoffTrust(
                registryRevision: existing.registry.registryRevision,
                gatewayIdentity: gatewayIdentity
            )
        } catch ProviderHandoffTrustRegistryStoreError.notFound {
            let registry = try gatewayIdentity.makeTrustRegistry(
                providerKeys: providerKeys,
                registryRevision: 1,
                issuedAtUnixSeconds: now
            )
            let installed = try store.install(
                registry.registry,
                bootstrap: gatewayIdentity.bootstrap
            )
            return PreparedProviderHandoffTrust(
                registryRevision: installed.registry.registryRevision,
                gatewayIdentity: gatewayIdentity
            )
        }
    }

    private static func currentUnixSeconds() throws -> UInt64 {
        let value = Date().timeIntervalSince1970
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else {
            throw ProviderHandoffGatewayStateError.invalidState
        }
        return UInt64(value.rounded(.down))
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

    public static let usage = """
    Usage: container-engine --socket PATH --provider-socket PATH --state-directory PATH

      --socket PATH           Public current-user Docker Engine Unix socket.
      --provider-socket PATH  Private socket owned by the selected provider adapter.
      --state-directory PATH  Private gateway identity and selection directory.
    """
}

private struct PreparedProviderHandoffTrust: Sendable {
    var registryRevision: UInt64
    var gatewayIdentity: ProviderHandoffGatewayIdentityV1?
}

struct ContainerEngineServiceTrustConfiguration: Sendable {
    var gatewayKeyStore: ProviderHandoffGatewayKeyStore
    var trustRegistryStore: ProviderHandoffTrustRegistryStore
    var nowUnixSeconds: UInt64?

    static let production = ContainerEngineServiceTrustConfiguration(
        gatewayKeyStore: ProviderHandoffGatewayKeyStore(),
        trustRegistryStore: ProviderHandoffTrustRegistryStore(),
        nowUnixSeconds: nil
    )
}

public final class ContainerEngineServiceRuntime: @unchecked Sendable {
    public let fingerprint: ContainerEngineProviderFingerprint
    public let handoffCoordinator: ProviderHandoffGatewayCoordinator?
    public let handoffStore: ProviderHandoffGatewayStore
    public let socketPath: String

    private let server: ContainerUnixHTTPServer

    fileprivate init(
        server: ContainerUnixHTTPServer,
        fingerprint: ContainerEngineProviderFingerprint,
        socketPath: String,
        handoffStore: ProviderHandoffGatewayStore,
        handoffCoordinator: ProviderHandoffGatewayCoordinator?
    ) {
        self.server = server
        self.fingerprint = fingerprint
        self.socketPath = socketPath
        self.handoffStore = handoffStore
        self.handoffCoordinator = handoffCoordinator
    }

    public func wait() async throws {
        try await server.wait()
    }

    public func shutdown() async throws {
        try await server.shutdown()
    }
}

public struct ContainerEngineServiceOptions: Equatable, Sendable {
    public var socket: String
    public var providerSocket: String
    public var stateDirectory: String

    public init(
        socket: String,
        providerSocket: String,
        stateDirectory: String
    ) throws {
        guard !socket.isEmpty else {
            throw ContainerEngineServiceOptionError.missingArgument("--socket")
        }
        guard !providerSocket.isEmpty else {
            throw ContainerEngineServiceOptionError.missingArgument(
                "--provider-socket"
            )
        }
        guard !stateDirectory.isEmpty else {
            throw ContainerEngineServiceOptionError.missingArgument(
                "--state-directory"
            )
        }
        self.socket = socket
        self.providerSocket = providerSocket
        self.stateDirectory = stateDirectory
    }

    public init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard
                ["--socket", "--provider-socket", "--state-directory"].contains(name),
                index + 1 < arguments.count
            else {
                throw ContainerEngineServiceOptionError.invalidArgument(name)
            }
            guard values.updateValue(arguments[index + 1], forKey: name) == nil else {
                throw ContainerEngineServiceOptionError.duplicateArgument(name)
            }
            index += 2
        }
        try self.init(
            socket: Self.require("--socket", in: values),
            providerSocket: Self.require("--provider-socket", in: values),
            stateDirectory: Self.require("--state-directory", in: values)
        )
    }

    private static func require(
        _ name: String,
        in values: [String: String]
    ) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw ContainerEngineServiceOptionError.missingArgument(name)
        }
        return value
    }
}

public enum ContainerEngineServiceOptionError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case duplicateArgument(String)
    case invalidArgument(String)
    case missingArgument(String)

    public var description: String {
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
