//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// Docker-visible lifecycle states supplied by the selected runtime authority.
public enum ContainerPublicStateV2: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case running
    case paused
    case restarting
    case exited
    case removing
    case dead
}

public enum ContainerHealthStatusV2: String, Codable, Equatable, Sendable {
    case starting
    case healthy
    case unhealthy
}

public struct ContainerHealthcheckResultV2: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var exitCode: Int32
    public var output: String

    public init(startedAt: Date, finishedAt: Date, exitCode: Int32, output: String) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.output = output
    }
}

public struct ContainerHealthSnapshotV2: Codable, Equatable, Sendable {
    public var status: ContainerHealthStatusV2
    public var failingStreak: UInt64
    public var log: [ContainerHealthcheckResultV2]

    public init(
        status: ContainerHealthStatusV2,
        failingStreak: UInt64 = 0,
        log: [ContainerHealthcheckResultV2] = []
    ) {
        self.status = status
        self.failingStreak = failingStreak
        self.log = log
    }
}

/// Complete immutable view of one container lifecycle revision.
public struct ContainerLifecycleSnapshotV2: Codable, Equatable, Sendable {
    public var state: ContainerPublicStateV2
    public var running: Bool
    public var paused: Bool
    public var restarting: Bool
    public var removalInProgress: Bool
    public var dead: Bool
    public var oomKilled: Bool
    public var oomKillCountBaseline: UInt64?
    public var pid: Int32
    public var exitCode: Int32
    public var error: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var restartCount: UInt64
    public var health: ContainerHealthSnapshotV2?
    public var processGeneration: UInt64?
    public var transitionRevision: UInt64
    public var operationGeneration: UInt64

    public init(
        state: ContainerPublicStateV2,
        running: Bool = false,
        paused: Bool = false,
        restarting: Bool = false,
        removalInProgress: Bool = false,
        dead: Bool = false,
        oomKilled: Bool = false,
        oomKillCountBaseline: UInt64? = nil,
        pid: Int32 = 0,
        exitCode: Int32 = 0,
        error: String = "",
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        restartCount: UInt64 = 0,
        health: ContainerHealthSnapshotV2? = nil,
        processGeneration: UInt64? = nil,
        transitionRevision: UInt64 = 0,
        operationGeneration: UInt64 = 0
    ) {
        self.state = state
        self.running = running
        self.paused = paused
        self.restarting = restarting
        self.removalInProgress = removalInProgress
        self.dead = dead
        self.oomKilled = oomKilled
        self.oomKillCountBaseline = oomKillCountBaseline
        self.pid = pid
        self.exitCode = exitCode
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.restartCount = restartCount
        self.health = health
        self.processGeneration = processGeneration
        self.transitionRevision = transitionRevision
        self.operationGeneration = operationGeneration
    }
}

public struct ContainerLifecycleRecordV2: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt32 = 2

    public var schemaVersion: UInt32
    public var containerID: String
    public var canonicalName: String
    public var immutableBundleKey: String
    public var selectedProviderFingerprint: String
    public var intent: ContainerLifecycleIntentV2
    public var snapshot: ContainerLifecycleSnapshotV2

    public init(
        containerID: String,
        canonicalName: String,
        immutableBundleKey: String,
        selectedProviderFingerprint: String,
        intent: ContainerLifecycleIntentV2 = ContainerLifecycleIntentV2(),
        snapshot: ContainerLifecycleSnapshotV2
    ) {
        schemaVersion = Self.schemaVersion
        self.containerID = containerID
        self.canonicalName = canonicalName
        self.immutableBundleKey = immutableBundleKey
        self.selectedProviderFingerprint = selectedProviderFingerprint
        self.intent = intent
        self.snapshot = snapshot
    }
}

public struct ContainerLifecycleIntentV2: Codable, Equatable, Sendable {
    public var autoRemove: Bool
    public var restartPolicy: ContainerRestartPolicyV2
    public var removalRequested: Bool
    public var manualRestartSuppressed: Bool

    public init(
        autoRemove: Bool = false,
        restartPolicy: ContainerRestartPolicyV2 = ContainerRestartPolicyV2(),
        removalRequested: Bool = false,
        manualRestartSuppressed: Bool = false
    ) {
        self.autoRemove = autoRemove
        self.restartPolicy = restartPolicy
        self.removalRequested = removalRequested
        self.manualRestartSuppressed = manualRestartSuppressed
    }
}

public struct ContainerRestartPolicyV2: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable {
        case no
        case always
        case onFailure = "on-failure"
        case unlessStopped = "unless-stopped"
    }

    public var mode: Mode
    public var maximumRetryCount: UInt32?

    public init(mode: Mode = .no, maximumRetryCount: UInt32? = nil) {
        self.mode = mode
        self.maximumRetryCount = maximumRetryCount
    }
}

public enum ContainerSignalV2: Codable, Equatable, Sendable {
    case name(String)
    case number(Int32)
}

public struct ContainerStopOptionsV2: Codable, Equatable, Sendable {
    public var signal: ContainerSignalV2?
    public var timeoutNanoseconds: Int64?

    public init(signal: ContainerSignalV2? = nil, timeoutNanoseconds: Int64? = nil) {
        self.signal = signal
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

public struct ContainerRestartOptionsV2: Codable, Equatable, Sendable {
    public var signal: ContainerSignalV2?
    public var timeoutNanoseconds: Int64?

    public init(signal: ContainerSignalV2? = nil, timeoutNanoseconds: Int64? = nil) {
        self.signal = signal
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

public struct ContainerTerminalSizeV2: Codable, Equatable, Sendable {
    public var columns: UInt32
    public var rows: UInt32

    public init(columns: UInt32, rows: UInt32) {
        self.columns = columns
        self.rows = rows
    }
}

public struct ContainerUpdateRequestV2: Codable, Equatable, Sendable {
    public var expectedTransitionRevision: UInt64?
    public var memoryBytes: Int64?
    public var nanoCPUs: Int64?
    public var restartPolicy: ContainerRestartPolicyV2?

    public init(
        expectedTransitionRevision: UInt64? = nil,
        memoryBytes: Int64? = nil,
        nanoCPUs: Int64? = nil,
        restartPolicy: ContainerRestartPolicyV2? = nil
    ) {
        self.expectedTransitionRevision = expectedTransitionRevision
        self.memoryBytes = memoryBytes
        self.nanoCPUs = nanoCPUs
        self.restartPolicy = restartPolicy
    }
}

public enum ContainerWaitConditionV2: Codable, Equatable, Sendable {
    case processExit(generation: UInt64)
    case notRunning
    case nextExit
    case removed
}

public struct ContainerWaitResultV2: Codable, Equatable, Sendable {
    public var containerID: String
    public var processGeneration: UInt64?
    public var transitionRevision: UInt64
    public var statusCode: Int64
    public var errorMessage: String?

    public init(
        containerID: String,
        processGeneration: UInt64?,
        transitionRevision: UInt64,
        statusCode: Int64,
        errorMessage: String? = nil
    ) {
        self.containerID = containerID
        self.processGeneration = processGeneration
        self.transitionRevision = transitionRevision
        self.statusCode = statusCode
        self.errorMessage = errorMessage
    }
}

public struct ContainerAuthorityEventV2: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var timeNano: UInt64
    public var type: String
    public var action: String
    public var actorID: String
    public var attributes: [String: String]
    public var transitionRevision: UInt64
    public var operationGeneration: UInt64

    public init(
        sequence: UInt64,
        timeNano: UInt64,
        type: String = "container",
        action: String,
        actorID: String,
        attributes: [String: String] = [:],
        transitionRevision: UInt64,
        operationGeneration: UInt64
    ) {
        self.sequence = sequence
        self.timeNano = timeNano
        self.type = type
        self.action = action
        self.actorID = actorID
        self.attributes = attributes
        self.transitionRevision = transitionRevision
        self.operationGeneration = operationGeneration
    }
}

/// Complete lifecycle surface owned by exactly one selected runtime provider.
public protocol ContainerLifecycleAuthorityV2: Sendable {
    func inspectLifecycle(idOrName: String) async throws -> ContainerLifecycleRecordV2
    func startContainer(idOrName: String) async throws
    func stopContainer(idOrName: String, options: ContainerStopOptionsV2) async throws
    func killContainer(idOrName: String, signal: ContainerSignalV2) async throws
    func restartContainer(idOrName: String, options: ContainerRestartOptionsV2) async throws
    func pauseContainer(idOrName: String) async throws
    func unpauseContainer(idOrName: String) async throws
    func renameContainer(idOrName: String, newName: String) async throws
    func resizeContainer(idOrName: String, size: ContainerTerminalSizeV2) async throws
    func updateContainer(idOrName: String, request: ContainerUpdateRequestV2) async throws
        -> [String]
    func waitForContainer(idOrName: String, condition: ContainerWaitConditionV2) async throws
        -> ContainerWaitResultV2
    func removeContainer(idOrName: String, force: Bool, removeVolumes: Bool) async throws
}

/// Native event cursors use durable journal sequence numbers and explicit
/// overrun semantics. Docker's bounded timestamp replay ring remains a
/// separate projection at the HTTP boundary.
public protocol ContainerLifecycleEventSourceV2: Sendable {
    func lifecycleEvents(after sequence: UInt64?) async throws
        -> AsyncThrowingStream<ContainerAuthorityEventV2, any Error>
}

public extension ContainerEngineProviderCapability {
    static let lifecycleStateV2Identifier = "io.github.stephenlclarke.container.lifecycle-state.v2"
}
