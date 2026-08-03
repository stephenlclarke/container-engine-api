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

import ContainerEngineLogging
import ContainerEngineRouter
import ContainerEngineWire
import Foundation
import Testing

@Test
func `info and inspect expose only Docker logging fields and public paths`() async throws {
    let reader = FakeLogReadSession(terminal: false)
    let backend = FakeLoggingBackend(reader: reader)
    let controller = try DockerLoggingAPIController(backend: backend)

    let info = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/v1.53/info")
    )
    #expect(info.status == 200)
    #expect(info.headers["Content-Type"] == "application/json")
    #expect(try responseData(info).last == UInt8(ascii: "\n"))
    let infoPayload = try DockerJSON.decoder.decode(
        InfoPayload.self,
        from: responseData(info)
    )
    #expect(infoPayload.loggingDriver == "json-file")
    #expect(infoPayload.plugins.log == ["json-file", "local", "syslog"])

    let localInspect = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/local-container/json"
        )
    )
    let localPayload = try DockerJSON.decoder.decode(
        InspectPayload.self,
        from: responseData(localInspect)
    )
    #expect(localPayload.hostConfig.logConfig.type == "local")
    #expect(localPayload.hostConfig.logConfig.config == ["max-file": "5"])
    #expect(localPayload.logPath == "")
    #expect(localPayload.config.tty == false)

    let jsonInspect = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/v1.44/containers/json-container/json"
        )
    )
    let jsonPayload = try DockerJSON.decoder.decode(
        InspectPayload.self,
        from: responseData(jsonInspect)
    )
    #expect(jsonPayload.hostConfig.logConfig.type == "json-file")
    #expect(jsonPayload.logPath == "/private/json.log")
    #expect(jsonPayload.config.tty)
}

@Test
func `complete shared responses preserve base fields and overlay logging authority`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let shared = try FakeSharedResponseBackend(
        info: JSONSerialization.data(
            withJSONObject: completeInfoBase()
        ),
        inspect: JSONSerialization.data(
            withJSONObject: completeInspectBase()
        )
    )
    let controller = try DockerLoggingAPIController(
        backend: backend,
        sharedResponseBackend: shared
    )

    let info = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/v1.53/info")
    )
    #expect(info.status == 200)
    let infoObject = try responseJSONObject(info)
    #expect(infoObject["Containers"] as? Int == 7)
    #expect(infoObject["Driver"] as? String == "apple-container")
    #expect(infoObject["LoggingDriver"] as? String == "json-file")
    let plugins = try #require(infoObject["Plugins"] as? [String: Any])
    #expect(plugins["Volume"] as? [String] == ["local"])
    #expect(plugins["Log"] as? [String] == ["json-file", "local", "syslog"])

    let inspect = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/local-container/json"
        )
    )
    #expect(inspect.status == 200)
    let inspectObject = try responseJSONObject(inspect)
    #expect(inspectObject["Id"] as? String == "local-container")
    #expect(inspectObject["Driver"] as? String == "apple-container")
    #expect(inspectObject["LogPath"] as? String == "")
    let config = try #require(inspectObject["Config"] as? [String: Any])
    #expect(config["Hostname"] as? String == "preserved-host")
    #expect(config["Tty"] as? Bool == false)
    let hostConfig = try #require(inspectObject["HostConfig"] as? [String: Any])
    #expect(hostConfig["NetworkMode"] as? String == "default")
    let logConfig = try #require(hostConfig["LogConfig"] as? [String: Any])
    #expect(logConfig["Type"] as? String == "local")
    #expect(logConfig["Config"] as? [String: String] == ["max-file": "5"])
}

@Test
func `complete shared responses reject fragments before replacing whole routes`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let shared = FakeSharedResponseBackend(
        info: Data(#"{"Plugins":{}}"#.utf8),
        inspect: Data(#"{"Config":{},"HostConfig":{}}"#.utf8)
    )
    let controller = try DockerLoggingAPIController(
        backend: backend,
        sharedResponseBackend: shared
    )

    let info = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/info")
    )
    #expect(info.status == 500)
    #expect(
        try errorMessage(info)
            == "complete SystemInfo response is missing required fields"
    )

    let inspect = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/json"
        )
    )
    #expect(inspect.status == 500)
    #expect(
        try errorMessage(inspect)
            == "complete ContainerInspect response is missing required fields"
    )
}

@Test
func `logging routes enforce API version range and Docker error envelopes`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)

    let old = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/v1.43/info")
    )
    #expect(old.status == 400)
    #expect(
        try errorMessage(old)
            == "client version 1.43 is too old. Minimum supported API version is 1.44, please upgrade your client to a newer version"
    )

    let oldMalformedQuery = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/v1.43/info?bad=%ZZ")
    )
    #expect(oldMalformedQuery.status == 400)
    #expect(
        try errorMessage(oldMalformedQuery)
            == "client version 1.43 is too old. Minimum supported API version is 1.44, please upgrade your client to a newer version"
    )

    let new = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/v1.54/info")
    )
    #expect(new.status == 400)
    #expect(
        try errorMessage(new) == "client version 1.54 is too new. Maximum supported API version is 1.53"
    )

    let missingRoute = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/v1.53/images/json")
    )
    #expect(missingRoute.status == 404)
    #expect(try errorMessage(missingRoute) == "page not found")

    let missingContainer = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/missing/json"
        )
    )
    #expect(missingContainer.status == 404)
    #expect(try errorMessage(missingContainer) == "No such container: missing")
}

@Test
func `non-TTY logs normalize queries details timestamps and Docker framing`() async throws {
    let records = try [
        DockerLogRecord(
            source: .standardError,
            timestamp: DockerLogTimestamp(
                secondsSinceUnixEpoch: 2,
                nanoseconds: 3
            ),
            line: Data("hidden\n".utf8)
        ),
        DockerLogRecord(
            source: .standardOutput,
            timestamp: DockerLogTimestamp(
                secondsSinceUnixEpoch: 3,
                nanoseconds: 4
            ),
            line: Data("visible\n".utf8),
            attributes: [
                "z": "last",
                "a key": "x+y"
            ]
        )
    ]
    let reader = FakeLogReadSession(terminal: false, records: records)
    let backend = FakeLoggingBackend(reader: reader)
    let controller = try DockerLoggingAPIController(backend: backend)
    let response = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target:
            "/v1.53/containers/example/logs?stdout=banana&stderr=false&follow=TRUE&tail=01&since=1.5&until=2.000000003&timestamps=1&details=1"
        )
    )

    #expect(response.status == 200)
    #expect(
        response.headers["Content-Type"]
            == "application/vnd.docker.multiplexed-stream"
    )
    let stream = try managedStream(response)
    let chunk = try #require(try await stream.nextChunk())
    let frame = try decodeFrame(chunk)
    #expect(frame.channel == .standardOutput)
    #expect(
        String(decoding: frame.data, as: UTF8.self)
            == "1970-01-01T00:00:03.000000004Z a+key=x%2By,z=last visible\n"
    )
    #expect(try await stream.nextChunk() == nil)
    #expect(await reader.closeCount == 1)
    #expect(await reader.cancelCount == 0)

    let captured = try #require(backend.lastLogRequest)
    #expect(captured.stdout)
    #expect(!captured.stderr)
    #expect(captured.follow)
    #expect(captured.tail == 1)
    let expectedSince = try DockerLogTimestamp(
        secondsSinceUnixEpoch: 1,
        nanoseconds: 500_000_000
    )
    let expectedUntil = try DockerLogTimestamp(
        secondsSinceUnixEpoch: 2,
        nanoseconds: 3
    )
    #expect(captured.since == expectedSince)
    #expect(captured.until == expectedUntil)
    #expect(captured.timestamps)
    #expect(captured.details)
}

@Test
func `TTY logs remain raw and preserve merged stdout selection`() async throws {
    let record = try DockerLogRecord(
        source: .standardOutput,
        timestamp: DockerLogTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0),
        line: Data([0x00, 0xFF, UInt8(ascii: "\n")])
    )
    let reader = FakeLogReadSession(terminal: true, records: [record])
    let controller = try DockerLoggingAPIController(
        backend: FakeLoggingBackend(reader: reader)
    )
    let response = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1"
        )
    )

    #expect(response.headers["Content-Type"] == "application/vnd.docker.raw-stream")
    let stream = try managedStream(response)
    #expect(try await stream.nextChunk() == record.line)
    #expect(try await stream.nextChunk() == nil)
}

@Test
func `logs reject missing streams and malformed timestamps before opening a reader`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)

    let noStreams = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=0&stderr=none"
        )
    )
    #expect(noStreams.status == 400)
    #expect(try errorMessage(noStreams) == "Bad parameters: you must choose at least one stream")

    let malformed = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1&since=bad"
        )
    )
    #expect(malformed.status == 500)
    #expect(try errorMessage(malformed) == "strconv.ParseInt: parsing \"bad\": invalid syntax")
    #expect(backend.openLogCount == 0)

    let malformedEscape = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1&bad=%ZZ"
        )
    )
    #expect(malformedEscape.status == 400)
    #expect(try errorMessage(malformedEscape) == "invalid URL escape \"%ZZ\"")

    let semicolon = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1;stderr=1"
        )
    )
    #expect(semicolon.status == 400)
    #expect(try errorMessage(semicolon) == "invalid semicolon separator in query")
    #expect(backend.openLogCount == 0)

    let allTail = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1&tail=not-a-number"
        )
    )
    let stream = try managedStream(allTail)
    #expect(try await stream.nextChunk() == nil)
    #expect(backend.lastLogRequest?.tail == nil)
}

@Test
func `unsupported readers fail before streaming and reader errors are in band`() async throws {
    let unsupportedBackend = FakeLoggingBackend(
        reader: FakeLogReadSession(terminal: false),
        openError: .unsupportedLogReader
    )
    let unsupportedController = try DockerLoggingAPIController(
        backend: unsupportedBackend
    )
    let unsupported = await unsupportedController.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1"
        )
    )
    #expect(unsupported.status == 500)
    #expect(try errorMessage(unsupported) == "configured logging driver does not support reading")

    let failingReader = FakeLogReadSession(
        terminal: false,
        streamError: .server("corrupt log segment")
    )
    let controller = try DockerLoggingAPIController(
        backend: FakeLoggingBackend(reader: failingReader)
    )
    let response = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1"
        )
    )
    let stream = try managedStream(response)
    let errorChunk = try #require(try await stream.nextChunk())
    let frame = try decodeFrame(errorChunk)
    #expect(frame.channel == .systemError)
    #expect(
        String(decoding: frame.data, as: UTF8.self) == "Error grabbing logs: corrupt log segment\n"
    )
    #expect(try await stream.nextChunk() == nil)
    #expect(await failingReader.cancelCount == 1)
}

@Test
func `managed log cancellation reaches the exact backend reader`() async throws {
    let reader = FakeLogReadSession(terminal: false, blocksUntilCancelled: true)
    let controller = try DockerLoggingAPIController(
        backend: FakeLoggingBackend(reader: reader)
    )
    let response = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/example/logs?stdout=1&follow=1"
        )
    )
    let stream = try managedStream(response)
    let readTask = Task {
        try await stream.nextChunk()
    }
    try await Task.sleep(for: .milliseconds(10))
    readTask.cancel()
    _ = try? await readTask.value

    #expect(await eventually { await reader.cancelCount == 1 })
    #expect(await reader.closeCount == 0)
}

@Test
func `attach maps Docker booleans upgrade framing and backend errors`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)
    let upgraded = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target:
            "/v1.53/containers/example/attach?logs=yes&stream=banana&stdin=0&stdout=TRUE&stderr=no&detachKeys=ctrl-x",
            headers: DockerHTTPHeaders([
                .init(name: "Connection", value: "Upgrade"),
                .init(name: "Upgrade", value: "tcp")
            ])
        )
    )

    #expect(upgraded.status == 200)
    #expect(upgraded.headers["Connection"] == "Upgrade")
    #expect(upgraded.headers["Upgrade"] == "tcp")
    #expect(
        upgraded.headers["Content-Type"]
            == "application/vnd.docker.multiplexed-stream"
    )
    guard case let .hijack(_, terminal) = upgraded.body else {
        Issue.record("expected hijack response")
        return
    }
    #expect(!terminal)
    #expect(
        backend.lastAttachRequest
            == DockerAttachRequest(
                includeLogs: true,
                stream: true,
                stdin: false,
                stdout: true,
                stderr: false,
                detachKeys: "ctrl-x"
            )
    )

    let plain = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/example/attach?stream=1&stdout=1"
        )
    )
    #expect(plain.headers["Content-Type"] == "application/vnd.docker.raw-stream")

    let missing = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/missing/attach?stream=1&stdout=1"
        )
    )
    #expect(missing.status == 404)
    #expect(
        missing.headers["Content-Type"]
            == "application/vnd.docker.raw-stream"
    )
    #expect(
        try String(decoding: responseData(missing), as: UTF8.self)
            == "No such container: missing\r\n"
    )
}

private func responseData(_ response: DockerHTTPResponse) throws -> Data {
    guard case let .bytes(data) = response.body else {
        throw FixtureError("expected byte response")
    }
    return data
}

private func errorMessage(_ response: DockerHTTPResponse) throws -> String {
    try DockerJSON.decoder.decode(
        DockerErrorEnvelope.self,
        from: responseData(response)
    ).message
}

private func responseJSONObject(
    _ response: DockerHTTPResponse
) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: responseData(response))
    return try #require(value as? [String: Any])
}

private func completeInfoBase() -> [String: Any] {
    [
        "Architecture": "aarch64",
        "CDISpecDirs": [],
        "CPUShares": true,
        "CPUSet": true,
        "CgroupDriver": "cgroupfs",
        "ContainerdCommit": ["ID": ""],
        "Containers": 7,
        "ContainersPaused": 1,
        "ContainersRunning": 2,
        "ContainersStopped": 4,
        "CpuCfsPeriod": true,
        "CpuCfsQuota": true,
        "Debug": false,
        "DefaultRuntime": "io.container.runtime.v2.linux",
        "DockerRootDir": "/private/container",
        "Driver": "apple-container",
        "DriverStatus": [],
        "ExperimentalBuild": false,
        "GenericResources": [],
        "HttpProxy": "",
        "HttpsProxy": "",
        "ID": "authority",
        "IPv4Forwarding": true,
        "Images": 3,
        "IndexServerAddress": "https://index.docker.io/v1/",
        "InitBinary": "vminitd",
        "InitCommit": ["ID": ""],
        "Isolation": "",
        "KernelVersion": "",
        "Labels": [],
        "LiveRestoreEnabled": false,
        "LoggingDriver": "stale",
        "MemTotal": 1024,
        "MemoryLimit": true,
        "NCPU": 8,
        "NEventsListener": 0,
        "NFd": 0,
        "NGoroutines": 0,
        "Name": "test-host",
        "NoProxy": "",
        "OSType": "linux",
        "OSVersion": "",
        "OomKillDisable": false,
        "OperatingSystem": "Apple container Linux virtual machines",
        "PidsLimit": true,
        "Plugins": [
            "Authorization": [],
            "Log": ["stale"],
            "Network": ["bridge"],
            "Volume": ["local"]
        ],
        "RegistryConfig": [:],
        "RuncCommit": ["ID": ""],
        "Runtimes": ["io.container.runtime.v2.linux": [:]],
        "SecurityOptions": [],
        "ServerVersion": "test",
        "SwapLimit": true,
        "Swarm": [:],
        "SystemTime": "2026-01-01T00:00:00Z",
        "Warnings": []
    ]
}

private func completeInspectBase() -> [String: Any] {
    [
        "AppArmorProfile": "",
        "Args": ["hello"],
        "Config": [
            "Hostname": "preserved-host",
            "Tty": true
        ],
        "Created": "2026-01-01T00:00:00Z",
        "Driver": "apple-container",
        "ExecIDs": NSNull(),
        "HostConfig": [
            "LogConfig": ["Type": "stale", "Config": [:]],
            "NetworkMode": "default"
        ],
        "HostnamePath": "",
        "HostsPath": "",
        "Id": "local-container",
        "Image": "sha256:image",
        "LogPath": "/must/not/leak",
        "MountLabel": "",
        "Mounts": [],
        "Name": "/local-container",
        "NetworkSettings": [:],
        "Path": "/bin/echo",
        "Platform": "linux",
        "ProcessLabel": "",
        "ResolvConfPath": "",
        "RestartCount": 0,
        "State": ["Status": "exited"]
    ]
}

private func managedStream(
    _ response: DockerHTTPResponse
) throws -> any DockerHTTPStreamSession {
    guard case let .managedStream(stream) = response.body else {
        throw FixtureError("expected managed stream response")
    }
    return stream
}

private func decodeFrame(_ data: Data) throws -> DockerStreamFrame {
    guard data.count >= 8, let channel = DockerStreamChannel(rawValue: data[0]) else {
        throw FixtureError("invalid Docker stream frame")
    }
    let length = data[4 ..< 8].reduce(UInt32(0)) { value, byte in
        (value << 8) | UInt32(byte)
    }
    guard data.count == 8 + Int(length) else {
        throw FixtureError("invalid Docker stream frame length")
    }
    return DockerStreamFrame(channel: channel, data: Data(data.dropFirst(8)))
}

private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private struct FixtureError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private struct InfoPayload: Decodable {
    let loggingDriver: String
    let plugins: InfoPluginsPayload

    private enum CodingKeys: String, CodingKey {
        case loggingDriver = "LoggingDriver"
        case plugins = "Plugins"
    }
}

private struct InfoPluginsPayload: Decodable {
    let log: [String]

    private enum CodingKeys: String, CodingKey {
        case log = "Log"
    }
}

private struct InspectPayload: Decodable {
    let config: InspectConfigPayload
    let hostConfig: InspectHostConfigPayload
    let logPath: String

    private enum CodingKeys: String, CodingKey {
        case config = "Config"
        case hostConfig = "HostConfig"
        case logPath = "LogPath"
    }
}

private struct InspectConfigPayload: Decodable {
    let tty: Bool

    private enum CodingKeys: String, CodingKey {
        case tty = "Tty"
    }
}

private struct InspectHostConfigPayload: Decodable {
    let logConfig: InspectLogConfigPayload

    private enum CodingKeys: String, CodingKey {
        case logConfig = "LogConfig"
    }
}

private struct InspectLogConfigPayload: Decodable {
    let type: String
    let config: [String: String]

    private enum CodingKeys: String, CodingKey {
        case config = "Config"
        case type = "Type"
    }
}

private final class FakeLoggingBackend: DockerLoggingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let reader: FakeLogReadSession
    private let openError: DockerLoggingBackendError?
    private let attachSession = FakeHijackSession()
    private var capturedLogRequest: DockerLogReadRequest?
    private var capturedAttachRequest: DockerAttachRequest?
    private var openedLogs = 0

    init(
        reader: FakeLogReadSession,
        openError: DockerLoggingBackendError? = nil
    ) {
        self.reader = reader
        self.openError = openError
    }

    var lastLogRequest: DockerLogReadRequest? {
        lock.withLock { capturedLogRequest }
    }

    var lastAttachRequest: DockerAttachRequest? {
        lock.withLock { capturedAttachRequest }
    }

    var openLogCount: Int {
        lock.withLock { openedLogs }
    }

    func loggingSystemInfo() async throws -> DockerLoggingSystemInfo {
        DockerLoggingSystemInfo(
            defaultDriver: "json-file",
            registeredDrivers: ["syslog", "none", "local", "json-file", "local"]
        )
    }

    func inspectContainerLogging(
        containerID: String
    ) async throws -> DockerContainerLoggingInspection {
        switch containerID {
        case "missing":
            throw DockerLoggingBackendError.containerNotFound(containerID)
        case "json-container":
            return DockerContainerLoggingInspection(
                configuration: DockerResolvedLogConfiguration(
                    driver: "json-file",
                    options: ["max-size": "10m"]
                ),
                publicLogPath: "/private/json.log",
                terminal: true
            )
        default:
            return DockerContainerLoggingInspection(
                configuration: DockerResolvedLogConfiguration(
                    driver: "local",
                    options: ["max-file": "5"]
                ),
                publicLogPath: "/must/not/leak/local.bin",
                terminal: false
            )
        }
    }

    func openContainerLogs(
        containerID: String,
        request: DockerLogReadRequest
    ) async throws -> any DockerLogReadSession {
        if containerID == "missing" {
            throw DockerLoggingBackendError.containerNotFound(containerID)
        }
        try lock.withLock {
            openedLogs += 1
            capturedLogRequest = request
            if let openError {
                throw openError
            }
        }
        return reader
    }

    func attachContainer(
        containerID: String,
        request: DockerAttachRequest
    ) async throws -> DockerAttachConnection {
        guard containerID != "missing" else {
            throw DockerLoggingBackendError.containerNotFound(containerID)
        }
        lock.withLock {
            capturedAttachRequest = request
        }
        return DockerAttachConnection(terminal: false, session: attachSession)
    }
}

private struct FakeSharedResponseBackend: DockerLoggingSharedResponseBackend {
    let info: Data
    let inspect: Data

    func systemInfoBaseJSON() async throws -> Data {
        info
    }

    func containerInspectBaseJSON(containerID _: String) async throws -> Data {
        inspect
    }
}

private actor FakeLogReadSession: DockerLogReadSession {
    nonisolated let terminal: Bool

    private var records: [DockerLogRecord]
    private let streamError: DockerLoggingBackendError?
    private let blocksUntilCancelled: Bool
    private var didThrowStreamError = false
    private(set) var closeCount = 0
    private(set) var cancelCount = 0

    init(
        terminal: Bool,
        records: [DockerLogRecord] = [],
        streamError: DockerLoggingBackendError? = nil,
        blocksUntilCancelled: Bool = false
    ) {
        self.terminal = terminal
        self.records = records
        self.streamError = streamError
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func nextRecord() async throws -> DockerLogRecord? {
        if blocksUntilCancelled {
            try await Task.sleep(for: .seconds(60))
            return nil
        }
        if !records.isEmpty {
            return records.removeFirst()
        }
        if let streamError, !didThrowStreamError {
            didThrowStreamError = true
            throw streamError
        }
        return nil
    }

    func close() {
        closeCount += 1
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class FakeHijackSession: DockerHijackSession, @unchecked Sendable {
    let frames = AsyncThrowingStream<DockerStreamFrame, any Error> { continuation in
        continuation.finish()
    }

    func write(_: Data) async throws {
        // Input is intentionally ignored by this output-mapping fixture.
    }

    func closeStandardInput() async throws {
        // The fixture owns no input resource.
    }

    func wait() async throws -> Int32 {
        0
    }

    func cancel() async {}
}
