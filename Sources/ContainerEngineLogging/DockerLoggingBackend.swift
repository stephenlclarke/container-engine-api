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
import Foundation

/// The resolved, immutable logging configuration exposed by Docker inspect.
public struct DockerResolvedLogConfiguration: Equatable, Sendable {
    public var driver: String
    public var options: [String: String]

    public init(driver: String, options: [String: String] = [:]) {
        self.driver = driver
        self.options = options
    }
}

/// The logging-specific fields projected onto `GET /info`.
public struct DockerLoggingSystemInfo: Equatable, Sendable {
    public var defaultDriver: String
    public var registeredDrivers: [String]

    public init(defaultDriver: String, registeredDrivers: [String]) {
        self.defaultDriver = defaultDriver
        self.registeredDrivers = registeredDrivers
    }
}

/// The logging-specific fields projected onto container inspect.
public struct DockerContainerLoggingInspection: Equatable, Sendable {
    public var configuration: DockerResolvedLogConfiguration
    public var publicLogPath: String?
    public var terminal: Bool

    public init(
        configuration: DockerResolvedLogConfiguration,
        publicLogPath: String?,
        terminal: Bool
    ) {
        self.configuration = configuration
        self.publicLogPath = publicLogPath
        self.terminal = terminal
    }
}

/// A lossless wall-clock timestamp for log filtering and rendering.
public struct DockerLogTimestamp: Comparable, Equatable, Sendable {
    public let secondsSinceUnixEpoch: Int64
    public let nanoseconds: UInt32

    public init(secondsSinceUnixEpoch: Int64, nanoseconds: UInt32) throws {
        guard nanoseconds < 1_000_000_000 else {
            throw DockerLoggingContractError.nanosecondsOutOfRange(nanoseconds)
        }
        self.secondsSinceUnixEpoch = secondsSinceUnixEpoch
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.secondsSinceUnixEpoch != rhs.secondsSinceUnixEpoch {
            return lhs.secondsSinceUnixEpoch < rhs.secondsSinceUnixEpoch
        }
        return lhs.nanoseconds < rhs.nanoseconds
    }
}

/// The normalized Docker logs query passed to the one authoritative reader.
public struct DockerLogReadRequest: Equatable, Sendable {
    public var stdout: Bool
    public var stderr: Bool
    public var follow: Bool
    /// `nil` means Docker's `all` behavior; zero means return no records.
    public var tail: Int?
    public var since: DockerLogTimestamp?
    public var until: DockerLogTimestamp?
    public var timestamps: Bool
    public var details: Bool

    public init(
        stdout: Bool,
        stderr: Bool,
        follow: Bool,
        tail: Int?,
        since: DockerLogTimestamp?,
        until: DockerLogTimestamp?,
        timestamps: Bool,
        details: Bool
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.follow = follow
        self.tail = tail
        self.since = since
        self.until = until
        self.timestamps = timestamps
        self.details = details
    }
}

/// The source attached to one Docker-compatible log record.
public enum DockerLogRecordSource: String, Equatable, Sendable {
    case standardOutput = "stdout"
    case standardError = "stderr"
}

/// One backend record before Docker timestamp/detail/framing presentation.
///
/// `line` is the exact binary-safe line exposed by Docker, including any line
/// feed retained by the selected driver's reader.
public struct DockerLogRecord: Equatable, Sendable {
    public static let maximumLineBytes = 16 * 1024 * 1024
    public static let maximumAttributeCount = 128
    public static let maximumAttributeBytes = 64 * 1024

    public var source: DockerLogRecordSource
    public var timestamp: DockerLogTimestamp
    public var line: Data
    public var attributes: [String: String]

    public init(
        source: DockerLogRecordSource,
        timestamp: DockerLogTimestamp,
        line: Data,
        attributes: [String: String] = [:]
    ) throws {
        guard line.count <= Self.maximumLineBytes else {
            throw DockerLoggingContractError.lineTooLarge(
                maximumBytes: Self.maximumLineBytes
            )
        }
        guard attributes.count <= Self.maximumAttributeCount else {
            throw DockerLoggingContractError.tooManyAttributes(
                maximumCount: Self.maximumAttributeCount
            )
        }
        var attributeBytes = 0
        for (key, value) in attributes {
            let (entryBytes, entryOverflow) = key.utf8.count.addingReportingOverflow(
                value.utf8.count
            )
            let (totalBytes, totalOverflow) = attributeBytes.addingReportingOverflow(
                entryBytes
            )
            guard
                !entryOverflow,
                !totalOverflow,
                totalBytes <= Self.maximumAttributeBytes
            else {
                throw DockerLoggingContractError.attributesTooLarge(
                    maximumBytes: Self.maximumAttributeBytes
                )
            }
            attributeBytes = totalBytes
        }
        self.source = source
        self.timestamp = timestamp
        self.line = line
        self.attributes = attributes
    }
}

/// A pull-based reader with an explicit terminal close and cancellation path.
public protocol DockerLogReadSession: Sendable {
    var terminal: Bool { get }

    func nextRecord() async throws -> DockerLogRecord?
    func close() async
    func cancel() async
}

/// Supplies complete non-logging JSON documents for Engine routes shared by
/// multiple domain controllers.
///
/// The logging controller validates these documents and overlays only the
/// fields owned by `DockerLoggingBackend`. A provider must not use the
/// logging-only fragments as complete `/info` or inspect responses.
public protocol DockerLoggingSharedResponseBackend: Sendable {
    func systemInfoBaseJSON() async throws -> Data
    func containerInspectBaseJSON(containerID: String) async throws -> Data
}

/// The normalized Docker attach query passed to the live-output controller.
public struct DockerAttachRequest: Equatable, Sendable {
    public var includeLogs: Bool
    public var stream: Bool
    public var stdin: Bool
    public var stdout: Bool
    public var stderr: Bool
    public var detachKeys: String?

    public init(
        includeLogs: Bool,
        stream: Bool,
        stdin: Bool,
        stdout: Bool,
        stderr: Bool,
        detachKeys: String?
    ) {
        self.includeLogs = includeLogs
        self.stream = stream
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.detachKeys = detachKeys
    }
}

/// A live attach session and its TTY framing mode.
public struct DockerAttachConnection: Sendable {
    public var terminal: Bool
    public var session: any DockerHijackSession

    public init(terminal: Bool, session: any DockerHijackSession) {
        self.terminal = terminal
        self.session = session
    }
}

/// The sole adapter boundary between Docker HTTP presentation and runtime state.
///
/// An adopter implements this protocol over the same controller used by native
/// clients. The HTTP package does not open log files or provider sessions itself.
public protocol DockerLoggingBackend: Sendable {
    func loggingSystemInfo() async throws -> DockerLoggingSystemInfo
    func inspectContainerLogging(
        containerID: String
    ) async throws -> DockerContainerLoggingInspection
    func openContainerLogs(
        containerID: String,
        request: DockerLogReadRequest
    ) async throws -> any DockerLogReadSession
    func attachContainer(
        containerID: String,
        request: DockerAttachRequest
    ) async throws -> DockerAttachConnection
}

/// The container-init terminal resize operation shared by Docker attach
/// clients. It is separate from exec resize and preserves Docker's UInt32
/// query contract until the selected runtime validates its terminal range.
public protocol DockerTerminalResizeBackend: Sendable {
    func resizeContainerTerminal(
        containerID: String,
        height: UInt32,
        width: UInt32
    ) async throws
}

/// Safe backend failures with Docker-compatible HTTP mappings.
public enum DockerLoggingBackendError: Error, Equatable, Sendable {
    case containerNotFound(String)
    case imageNotFound(String)
    case conflict(String)
    case invalidParameter(String)
    case server(String)
    case unsupportedLogReader

    public var message: String {
        switch self {
        case let .containerNotFound(identifier):
            "No such container: \(identifier)"
        case let .imageNotFound(identifier):
            "No such image: \(identifier)"
        case let .conflict(message), let .invalidParameter(message), let .server(message):
            message
        case .unsupportedLogReader:
            "configured logging driver does not support reading"
        }
    }
}

/// Validation failures for bounded public logging values.
public enum DockerLoggingContractError: Error, Equatable, Sendable {
    case attributesTooLarge(maximumBytes: Int)
    case lineTooLarge(maximumBytes: Int)
    case nanosecondsOutOfRange(UInt32)
    case tooManyAttributes(maximumCount: Int)
}
