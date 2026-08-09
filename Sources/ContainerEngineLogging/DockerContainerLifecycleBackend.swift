//===----------------------------------------------------------------------===//
// Copyright 2026 devcontainer and container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// Docker's string-or-array command representation, normalized losslessly.
public enum DockerCommandValue: Decodable, Equatable, Sendable {
    case string(String)
    case array([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = try .array(container.decode([String].self))
        }
    }

    public var values: [String] {
        switch self {
        case let .string(value): [value]
        case let .array(values): values
        }
    }
}

public struct DockerContainerLogConfigurationRequest:
    Decodable, Equatable, Sendable
{
    public var type: String?
    public var options: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case options = "Config"
    }
}

public struct DockerContainerRestartPolicyRequest:
    Decodable, Equatable, Sendable
{
    public var name: String?
    public var maximumRetryCount: UInt32?

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maximumRetryCount = "MaximumRetryCount"
    }
}

public struct DockerContainerPortBindingRequest:
    Decodable, Equatable, Sendable
{
    public var hostIP: String?
    public var hostPort: String?

    private enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}

public struct DockerContainerHealthcheckRequest:
    Decodable, Equatable, Sendable
{
    public var test: [String]?
    public var intervalNanoseconds: Int64?
    public var timeoutNanoseconds: Int64?
    public var retries: Int?
    public var startPeriodNanoseconds: Int64?

    private enum CodingKeys: String, CodingKey {
        case test = "Test"
        case intervalNanoseconds = "Interval"
        case timeoutNanoseconds = "Timeout"
        case retries = "Retries"
        case startPeriodNanoseconds = "StartPeriod"
    }
}

public struct DockerContainerHostConfigurationRequest:
    Decodable, Equatable, Sendable
{
    public var autoRemove: Bool?
    public var binds: [String]?
    public var capabilitiesToAdd: [String]?
    public var capabilitiesToDrop: [String]?
    public var initProcess: Bool?
    public var logConfiguration: DockerContainerLogConfigurationRequest?
    public var memoryBytes: Int64?
    public var nanoCPUs: Int64?
    public var networkMode: String?
    public var portBindings: [String: [DockerContainerPortBindingRequest]]?
    public var privileged: Bool?
    public var readOnlyRootFilesystem: Bool?
    public var restartPolicy: DockerContainerRestartPolicyRequest?

    private enum CodingKeys: String, CodingKey {
        case autoRemove = "AutoRemove"
        case binds = "Binds"
        case capabilitiesToAdd = "CapAdd"
        case capabilitiesToDrop = "CapDrop"
        case initProcess = "Init"
        case logConfiguration = "LogConfig"
        case memoryBytes = "Memory"
        case nanoCPUs = "NanoCpus"
        case networkMode = "NetworkMode"
        case portBindings = "PortBindings"
        case privileged = "Privileged"
        case readOnlyRootFilesystem = "ReadonlyRootfs"
        case restartPolicy = "RestartPolicy"
    }
}

/// Typed subset shared by the Docker REST controller and native authority.
/// Unknown Docker fields remain forward-compatible and are ignored by decoding;
/// providers validate whether each represented field is natively supported.
public struct DockerContainerCreateRequest: Decodable, Equatable, Sendable {
    public var attachStandardError: Bool?
    public var attachStandardInput: Bool?
    public var attachStandardOutput: Bool?
    public var command: [String]?
    public var entrypoint: DockerCommandValue?
    public var environment: [String]?
    public var healthcheck: DockerContainerHealthcheckRequest?
    public var hostname: String?
    public var hostConfiguration: DockerContainerHostConfigurationRequest?
    public var image: String
    public var labels: [String: String]?
    public var openStandardInput: Bool?
    public var terminal: Bool?
    public var user: String?
    public var workingDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case attachStandardError = "AttachStderr"
        case attachStandardInput = "AttachStdin"
        case attachStandardOutput = "AttachStdout"
        case command = "Cmd"
        case entrypoint = "Entrypoint"
        case environment = "Env"
        case healthcheck = "Healthcheck"
        case hostname = "Hostname"
        case hostConfiguration = "HostConfig"
        case image = "Image"
        case labels = "Labels"
        case openStandardInput = "OpenStdin"
        case terminal = "Tty"
        case user = "User"
        case workingDirectory = "WorkingDir"
    }
}

public struct DockerContainerCreateResult: Equatable, Sendable {
    public var containerID: String
    public var warnings: [String]

    public init(containerID: String, warnings: [String] = []) {
        self.containerID = containerID
        self.warnings = warnings
    }
}

/// Native container lifecycle operations exposed through Docker REST without
/// shelling out to a CLI or bypassing the selected provider's authority.
public protocol DockerContainerLifecycleBackend: Sendable {
    func createContainer(
        request: DockerContainerCreateRequest,
        requestedName: String?
    ) async throws -> DockerContainerCreateResult
    func startContainer(containerID: String) async throws
    func stopContainer(containerID: String, timeoutSeconds: Int64?) async throws
    func deleteContainer(
        containerID: String,
        force: Bool,
        removeVolumes: Bool
    ) async throws
}

/// Docker Engine's supported container-wait conditions.
public enum DockerContainerWaitCondition: String, CaseIterable, Equatable, Sendable {
    /// Return when the container is not currently running.
    case notRunning = "not-running"
    /// Return after the next observed container exit.
    case nextExit = "next-exit"
    /// Return after the container has been removed.
    case removed
}

/// The Docker Engine response for a completed container wait.
public struct DockerContainerWaitResult: Encodable, Equatable, Sendable {
    /// The init process exit status observed by the selected wait condition.
    public var statusCode: Int32

    public init(statusCode: Int32) {
        self.statusCode = statusCode
    }

    private enum CodingKeys: String, CodingKey {
        case statusCode = "StatusCode"
    }
}

/// Native authority operation for Docker's container wait route.
///
/// This remains separate from the create/start/stop/delete protocol so an
/// adapter cannot advertise `ContainerWait` until it owns each requested
/// wait condition and the terminal status it returns.
public protocol DockerContainerWaitBackend: Sendable {
    /// Waits for the requested lifecycle condition after invoking
    /// `onRegistered` exactly once.
    ///
    /// The callback is invoked only after the backend has validated the
    /// container and registered a cancellation-aware waiter. Docker clients
    /// use the response headers as the acknowledgement that lets them start a
    /// newly created container, so acknowledging before registration can race
    /// a fast exit or deadlock `docker run`.
    func waitForContainer(
        containerID: String,
        condition: DockerContainerWaitCondition,
        onRegistered: @escaping @Sendable () -> Void
    ) async throws -> DockerContainerWaitResult
}

public extension DockerContainerWaitBackend {
    /// Waits without needing the HTTP acknowledgement hook.
    func waitForContainer(
        containerID: String,
        condition: DockerContainerWaitCondition
    ) async throws -> DockerContainerWaitResult {
        try await waitForContainer(
            containerID: containerID,
            condition: condition,
            onRegistered: {}
        )
    }
}
