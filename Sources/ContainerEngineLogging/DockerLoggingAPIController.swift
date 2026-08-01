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

import ContainerEngineRouter
import ContainerEngineWire
import Foundation

/// Docker Engine logging routes for API versions 1.44 through 1.53.
public struct DockerLoggingAPIController: DockerHTTPResponder, Sendable {
    public let minimumAPIVersion: DockerAPIVersion
    public let maximumAPIVersion: DockerAPIVersion
    public let routeLedger: DockerRouteLedger

    private let backend: any DockerLoggingBackend

    public init(backend: any DockerLoggingBackend) throws {
        minimumAPIVersion = try DockerAPIVersion("1.44")
        maximumAPIVersion = try DockerAPIVersion("1.53")
        routeLedger = try Self.makeRouteLedger(
            minimum: minimumAPIVersion,
            maximum: maximumAPIVersion
        )
        self.backend = backend
    }

    public func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        await responseIfHandled(to: request)
            ?? Self.errorResponse(
                status: 404,
                message: "page not found"
            )
    }

    /// Returns `nil` only when a supported-version request is not a logging route.
    ///
    /// A gateway can use this method to compose logging with other Engine API
    /// controllers while preserving one global API-version rejection policy.
    public func responseIfHandled(
        to request: DockerHTTPRequest
    ) async -> DockerHTTPResponse? {
        let queryMarker = request.target.firstIndex(of: "?")
        let pathOnlyTarget = String(
            request.target[..<(queryMarker ?? request.target.endIndex)]
        )
        let pathTarget: DockerRequestTarget
        do {
            pathTarget = try DockerRequestTarget(pathOnlyTarget)
        } catch {
            return Self.errorResponse(
                status: 400,
                message: "invalid request target"
            )
        }

        if let version = pathTarget.apiVersion {
            if version < minimumAPIVersion {
                return Self.errorResponse(
                    status: 400,
                    message:
                    "client version \(version) is too old. Minimum supported API version is \(minimumAPIVersion), please upgrade your client to a newer version"
                )
            }
            if version > maximumAPIVersion {
                return Self.errorResponse(
                    status: 400,
                    message:
                    "client version \(version) is too new. Maximum supported API version is \(maximumAPIVersion)"
                )
            }
        }

        do {
            _ = try DockerRequestTarget(request.target)
        } catch let error as DockerRoutingError {
            if case let .invalidQuery(message) = error {
                return Self.errorResponse(status: 400, message: message)
            }
            return Self.errorResponse(
                status: 400,
                message: "invalid request target"
            )
        } catch {
            return Self.errorResponse(
                status: 400,
                message: "invalid request target"
            )
        }

        let match: DockerRouteMatch?
        do {
            match = try routeLedger.match(request)
        } catch {
            return Self.errorResponse(status: 400, message: String(describing: error))
        }
        guard let match else {
            return nil
        }

        switch match.metadata.identifier {
        case RouteIdentifier.info:
            return await infoResponse()
        case RouteIdentifier.inspect:
            return await inspectResponse(
                containerID: match.parameters["id"] ?? ""
            )
        case RouteIdentifier.logs:
            return await logsResponse(
                containerID: match.parameters["id"] ?? "",
                target: match.target
            )
        case RouteIdentifier.attach:
            return await attachResponse(
                request: request,
                containerID: match.parameters["id"] ?? "",
                target: match.target
            )
        default:
            return Self.errorResponse(status: 500, message: "server error")
        }
    }

    private func infoResponse() async -> DockerHTTPResponse {
        do {
            let info = try await backend.loggingSystemInfo()
            let drivers = Array(
                Set(info.registeredDrivers.filter { !$0.isEmpty && $0 != "none" })
            ).sorted(by: Self.utf8Less)
            return Self.jsonLineResponse(
                InfoResponse(
                    loggingDriver: info.defaultDriver,
                    plugins: InfoPlugins(log: drivers)
                )
            )
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func inspectResponse(containerID: String) async -> DockerHTTPResponse {
        do {
            let inspection = try await backend.inspectContainerLogging(
                containerID: containerID
            )
            let configuration = inspection.configuration
            return Self.jsonLineResponse(
                InspectResponse(
                    config: InspectConfig(tty: inspection.terminal),
                    hostConfig: InspectHostConfig(
                        logConfig: InspectLogConfig(
                            type: configuration.driver,
                            config: configuration.options
                        )
                    ),
                    logPath: configuration.driver == "json-file"
                        ? inspection.publicLogPath ?? ""
                        : ""
                )
            )
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func logsResponse(
        containerID: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        let query: DockerLogReadRequest
        do {
            query = try Self.logReadRequest(target: target)
        } catch let error as QueryError {
            return Self.errorResponse(status: error.status, message: error.message)
        } catch {
            return Self.errorResponse(status: 500, message: "server error")
        }

        do {
            let reader = try await backend.openContainerLogs(
                containerID: containerID,
                request: query
            )
            return DockerHTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": reader.terminal
                        ? "application/vnd.docker.raw-stream"
                        : "application/vnd.docker.multiplexed-stream"
                ],
                body: .managedStream(
                    DockerLogHTTPStream(
                        reader: reader,
                        request: query
                    )
                )
            )
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func attachResponse(
        request: DockerHTTPRequest,
        containerID: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        let query = DockerAttachRequest(
            includeLogs: Self.boolValue(target.first("logs")),
            stream: Self.boolValue(target.first("stream")),
            stdin: Self.boolValue(target.first("stdin")),
            stdout: Self.boolValue(target.first("stdout")),
            stderr: Self.boolValue(target.first("stderr")),
            detachKeys: target.first("detachKeys")
        )
        do {
            let connection = try await backend.attachContainer(
                containerID: containerID,
                request: query
            )
            let requestedUpgrade = !request.headerValues("Upgrade").isEmpty
            var headers = [
                "Content-Type": requestedUpgrade && !connection.terminal
                    ? "application/vnd.docker.multiplexed-stream"
                    : "application/vnd.docker.raw-stream"
            ]
            if requestedUpgrade {
                headers["Connection"] = "Upgrade"
                headers["Upgrade"] = "tcp"
            }
            return DockerHTTPResponse(
                status: 200,
                headers: headers,
                body: .hijack(connection.session, terminal: connection.terminal)
            )
        } catch {
            return Self.attachBackendErrorResponse(error)
        }
    }

    private static func logReadRequest(
        target: DockerRequestTarget
    ) throws -> DockerLogReadRequest {
        let stdout = boolValue(target.first("stdout"))
        let stderr = boolValue(target.first("stderr"))
        guard stdout || stderr else {
            throw QueryError(
                status: 400,
                message: "Bad parameters: you must choose at least one stream"
            )
        }
        return try DockerLogReadRequest(
            stdout: stdout,
            stderr: stderr,
            follow: boolValue(target.first("follow")),
            tail: tailValue(target.first("tail")),
            since: timestampValue(target.first("since"), zeroMeansUnset: false),
            until: timestampValue(target.first("until"), zeroMeansUnset: true),
            timestamps: boolValue(target.first("timestamps")),
            details: boolValue(target.first("details"))
        )
    }

    private static func boolValue(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" {
        case "", "0", "no", "false", "none":
            false
        default:
            true
        }
    }

    private static func tailValue(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value), parsed >= 0 else {
            return nil
        }
        return parsed
    }

    private static func timestampValue(
        _ value: String?,
        zeroMeansUnset: Bool
    ) throws -> DockerLogTimestamp? {
        guard let value, !value.isEmpty, !(zeroMeansUnset && value == "0") else {
            return nil
        }
        let parts = value.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let seconds = Int64(parts[0]) else {
            throw timestampParseError(String(parts[0]))
        }
        var nanoseconds: Int64 = 0
        if parts.count == 2 {
            let fraction = String(parts[1])
            guard let parsedFraction = Int64(fraction) else {
                throw timestampParseError(fraction)
            }
            let digitCount = fraction.count
            if digitCount <= 9 {
                nanoseconds = parsedFraction * powerOfTen(9 - digitCount)
            } else {
                nanoseconds = parsedFraction / powerOfTen(digitCount - 9)
            }
        }

        let secondAdjustment = nanoseconds / 1_000_000_000
        let (adjustedSeconds, overflow) = seconds.addingReportingOverflow(
            secondAdjustment
        )
        guard !overflow else {
            throw timestampRangeError(value)
        }
        var normalizedSeconds = adjustedSeconds
        var normalizedNanoseconds = nanoseconds % 1_000_000_000
        if normalizedNanoseconds < 0 {
            let (earlierSecond, underflow) = normalizedSeconds.subtractingReportingOverflow(1)
            guard !underflow else {
                throw timestampRangeError(value)
            }
            normalizedSeconds = earlierSecond
            normalizedNanoseconds += 1_000_000_000
        }
        return try DockerLogTimestamp(
            secondsSinceUnixEpoch: normalizedSeconds,
            nanoseconds: UInt32(normalizedNanoseconds)
        )
    }

    private static func timestampParseError(_ value: String) -> QueryError {
        let signedDigits =
            value.first == "+" || value.first == "-"
                ? value.dropFirst()
                : value[...]
        let reason =
            !signedDigits.isEmpty && signedDigits.allSatisfy(\.isNumber)
                ? "value out of range"
                : "invalid syntax"
        return QueryError(
            status: 500,
            message: "strconv.ParseInt: parsing \"\(value)\": \(reason)"
        )
    }

    private static func timestampRangeError(_ value: String) -> QueryError {
        QueryError(
            status: 500,
            message: "strconv.ParseInt: parsing \"\(value)\": value out of range"
        )
    }

    private static func powerOfTen(_ exponent: Int) -> Int64 {
        guard exponent > 0 else {
            return 1
        }
        return (0 ..< exponent).reduce(1) { value, _ in value * 10 }
    }

    private static func backendErrorResponse(_ error: any Error) -> DockerHTTPResponse {
        guard let error = error as? DockerLoggingBackendError else {
            return errorResponse(status: 500, message: "server error")
        }
        switch error {
        case .containerNotFound:
            return errorResponse(status: 404, message: error.message)
        case .conflict:
            return errorResponse(status: 409, message: error.message)
        case .invalidParameter:
            return errorResponse(status: 400, message: error.message)
        case .server, .unsupportedLogReader:
            return errorResponse(status: 500, message: error.message)
        }
    }

    private static func attachBackendErrorResponse(
        _ error: any Error
    ) -> DockerHTTPResponse {
        let status: Int
        let message: String
        if let error = error as? DockerLoggingBackendError {
            message = error.message
            switch error {
            case .containerNotFound:
                status = 404
            case .conflict:
                status = 409
            case .invalidParameter:
                status = 400
            case .server, .unsupportedLogReader:
                status = 500
            }
        } else {
            status = 500
            message = "server error"
        }
        return DockerHTTPResponse.text(
            message + "\r\n",
            status: status,
            contentType: "application/vnd.docker.raw-stream"
        )
    }

    private static func errorResponse(status: Int, message: String) -> DockerHTTPResponse {
        jsonLineResponse(DockerErrorEnvelope(message: message), status: status)
    }

    private static func jsonLineResponse(
        _ value: some Encodable,
        status: Int = 200
    ) -> DockerHTTPResponse {
        do {
            var data = try DockerJSON.encoder.encode(value)
            data.append(UInt8(ascii: "\n"))
            return DockerHTTPResponse(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: .bytes(data)
            )
        } catch {
            return DockerHTTPResponse.text(
                #"{"message":"server error"}"# + "\n",
                status: 500,
                contentType: "application/json"
            )
        }
    }

    private static func makeRouteLedger(
        minimum: DockerAPIVersion,
        maximum: DockerAPIVersion
    ) throws -> DockerRouteLedger {
        try DockerRouteLedger(
            minimumAPIVersion: minimum,
            maximumAPIVersion: maximum,
            routes: [
                DockerRouteMetadata(
                    identifier: RouteIdentifier.info,
                    method: .get,
                    pattern: DockerRoutePattern("/info"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.inspect,
                    method: .get,
                    pattern: DockerRoutePattern("/containers/{id}/json"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.logs,
                    method: .get,
                    pattern: DockerRoutePattern("/containers/{id}/logs"),
                    introduced: minimum,
                    responseMode: .stream,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.attach,
                    method: .post,
                    pattern: DockerRoutePattern("/containers/{id}/attach"),
                    introduced: minimum,
                    responseMode: .hijack,
                    disposition: .implemented
                )
            ]
        )
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private enum RouteIdentifier {
    static let attach = "container.attach"
    static let info = "system.info"
    static let inspect = "container.inspect"
    static let logs = "container.logs"
}

private struct QueryError: Error {
    let status: Int
    let message: String
}

private struct InfoResponse: Encodable {
    let loggingDriver: String
    let plugins: InfoPlugins

    private enum CodingKeys: String, CodingKey {
        case loggingDriver = "LoggingDriver"
        case plugins = "Plugins"
    }
}

private struct InfoPlugins: Encodable {
    let log: [String]

    private enum CodingKeys: String, CodingKey {
        case log = "Log"
    }
}

private struct InspectResponse: Encodable {
    let config: InspectConfig
    let hostConfig: InspectHostConfig
    let logPath: String

    private enum CodingKeys: String, CodingKey {
        case config = "Config"
        case hostConfig = "HostConfig"
        case logPath = "LogPath"
    }
}

private struct InspectConfig: Encodable {
    let tty: Bool

    private enum CodingKeys: String, CodingKey {
        case tty = "Tty"
    }
}

private struct InspectHostConfig: Encodable {
    let logConfig: InspectLogConfig

    private enum CodingKeys: String, CodingKey {
        case logConfig = "LogConfig"
    }
}

private struct InspectLogConfig: Encodable {
    let type: String
    let config: [String: String]

    private enum CodingKeys: String, CodingKey {
        case config = "Config"
        case type = "Type"
    }
}
