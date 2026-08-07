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
func `version and container list expose complete discovery documents`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)

    let version = await controller.respond(
        to: DockerHTTPRequest(method: .get, target: "/version")
    )
    #expect(version.status == 200)
    let versionObject = try responseJSONObject(version)
    #expect(versionObject["ApiVersion"] as? String == "1.53")
    #expect(versionObject["MinAPIVersion"] as? String == "1.44")

    let filters = try #require(
        #"{"label":["compose.project=fixture"],"status":{"exited":true,"running":false}}"#
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    )
    let list = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/v1.53/containers/json?all=1&limit=7&size=true&filters=\(filters)"
        )
    )
    #expect(list.status == 200)
    let listObject = try responseJSONArray(list)
    #expect(listObject.count == 1)
    #expect(listObject[0]["Id"] as? String == "fixture-id")
    #expect(
        backend.lastListRequest
            == DockerContainerListRequest(
                all: true,
                limit: 7,
                size: true,
                filters: [
                    "label": ["compose.project=fixture"],
                    "status": ["exited"]
                ]
            )
    )
}

@Test
func `container list rejects malformed queries before calling its backend`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)

    let invalidLimit = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/json?limit=-1"
        )
    )
    #expect(invalidLimit.status == 400)
    #expect(try errorMessage(invalidLimit) == "invalid limit: -1")

    let invalidFilters = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/containers/json?filters=%7B%22label%22%3A1%7D"
        )
    )
    #expect(invalidFilters.status == 400)
    #expect(try errorMessage(invalidFilters) == "invalid filters JSON")
    #expect(backend.lastListRequest == nil)
}

@Test
func `image list and inspect expose complete native discovery documents`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)
    let filters = try #require(
        #"{"reference":["alpine:3.20"],"label":{"fixture=true":true}}"#
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    )

    let list = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target:
            "/v1.53/images/json?all=1&shared-size=true&containerd-snapshotter=1&filters=\(filters)"
        )
    )
    #expect(list.status == 200)
    let listObjects = try responseJSONArray(list)
    #expect(listObjects.count == 1)
    #expect(listObjects[0]["Id"] as? String == "sha256:image-index")
    #expect(
        backend.lastImageListRequest
            == DockerImageListRequest(
                all: true,
                sharedSize: true,
                containerdSnapshotter: true,
                filters: [
                    "label": ["fixture=true"],
                    "reference": ["alpine:3.20"]
                ]
            )
    )

    let inspect = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/images/alpine:3.20/json"
        )
    )
    #expect(inspect.status == 200)
    let inspectObject = try responseJSONObject(inspect)
    #expect(inspectObject["Id"] as? String == "sha256:image-index")
    #expect(backend.lastImageInspectName == "alpine:3.20")

    let normalizedInspect = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/images/docker.io/library/alpine:3.20/json"
        )
    )
    #expect(normalizedInspect.status == 200)
    #expect(backend.lastImageInspectName == "docker.io/library/alpine:3.20")

    let missing = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/images/missing:latest/json"
        )
    )
    #expect(missing.status == 404)
    #expect(try errorMessage(missing) == "No such image: missing:latest")
}

@Test
func `image list rejects malformed filters before calling its backend`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)

    let invalid = await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target: "/images/json?filters=%7B%22reference%22%3A1%7D"
        )
    )
    #expect(invalid.status == 400)
    #expect(try errorMessage(invalid) == "invalid filter")
    #expect(backend.lastImageListRequest == nil)
}

@Test
func `image pull tag and delete use the native mutation authority`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)
    let pullRequest = try DockerHTTPRequest(
        method: .post,
        target:
        "/v1.53/images/create?fromImage=docker.io%2Flibrary%2Falpine&tag=3.20&platform=linux%2Farm64%2Fv8",
        uniqueHeaders: ["X-Registry-Auth": "e30="]
    )

    let pull = await controller.respond(to: pullRequest)
    #expect(pull.status == 200)
    #expect(pull.headers["Content-Type"] == "application/json")
    let updates = try responseData(pull)
        .split(separator: UInt8(ascii: "\n"))
        .map { try DockerJSON.decoder.decode(PullStatusPayload.self, from: Data($0)) }
    #expect(
        updates == [
            PullStatusPayload(status: "Pulling from library/alpine", id: "3.20"),
            PullStatusPayload(status: "Digest: sha256:image-index"),
            PullStatusPayload(status: "Status: Image is up to date for alpine:3.20")
        ]
    )
    #expect(
        backend.lastImagePullRequest
            == DockerImagePullRequest(
                fromImage: "docker.io/library/alpine",
                tag: "3.20",
                platform: "linux/arm64/v8",
                registryAuth: "e30="
            )
    )

    let tag = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target:
            "/images/docker.io/library/alpine:3.20/tag?repo=fixture.local%2Falpine&tag=copy"
        )
    )
    #expect(tag.status == 201)
    #expect(try responseData(tag).isEmpty)
    #expect(backend.lastImageTagName == "docker.io/library/alpine:3.20")
    #expect(
        backend.lastImageTagRequest
            == DockerImageTagRequest(repository: "fixture.local/alpine", tag: "copy")
    )

    let delete = await controller.respond(
        to: DockerHTTPRequest(
            method: .delete,
            target: "/images/fixture.local/alpine:copy?force=1&noprune=1"
        )
    )
    #expect(delete.status == 200)
    #expect(
        try DockerJSON.decoder.decode(
            [DockerImageDeleteResult].self,
            from: responseData(delete)
        ) == [DockerImageDeleteResult(untagged: "fixture.local/alpine:copy")]
    )
    #expect(backend.lastImageDeleteName == "fixture.local/alpine:copy")
    #expect(
        backend.lastImageDeleteRequest
            == DockerImageDeleteRequest(force: true, prune: false)
    )
}

@Test
func `image mutation validates queries and preserves not found errors`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)

    let missingFromImage = await controller.respond(
        to: DockerHTTPRequest(method: .post, target: "/images/create")
    )
    #expect(missingFromImage.status == 400)
    #expect(try errorMessage(missingFromImage) == "fromImage is required")
    #expect(backend.lastImagePullRequest == nil)

    let missingRepository = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/images/alpine:3.20/tag"
        )
    )
    #expect(missingRepository.status == 400)
    #expect(try errorMessage(missingRepository) == "repo is required")
    #expect(backend.lastImageTagRequest == nil)

    let missingImage = await controller.respond(
        to: DockerHTTPRequest(
            method: .delete,
            target: "/images/missing:latest"
        )
    )
    #expect(missingImage.status == 404)
    #expect(try errorMessage(missingImage) == "No such image: missing:latest")
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
        to: DockerHTTPRequest(method: .get, target: "/v1.53/not-a-docker-route")
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

@Test
func `websocket attach is binary unframed and preserves the Docker query`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)
    let response = try await controller.respond(
        to: DockerHTTPRequest(
            method: .get,
            target:
            "/v1.53/containers/example/attach/ws?logs=1&stream=true&stdin=1&stdout=1&stderr=0&detachKeys=ctrl-z",
            headers: DockerHTTPHeaders(
                uniqueFields: [
                    "Connection": "Upgrade",
                    "Upgrade": "websocket",
                    "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
                    "Sec-WebSocket-Version": "13"
                ]
            )
        )
    )

    #expect(response.status == 101)
    #expect(response.headers["Connection"] == "Upgrade")
    #expect(response.headers["Upgrade"] == "websocket")
    guard case .webSocket = response.body else {
        Issue.record("expected websocket response")
        return
    }
    #expect(
        backend.lastAttachRequest
            == DockerAttachRequest(
                includeLogs: true,
                stream: true,
                stdin: true,
                stdout: true,
                stderr: false,
                detachKeys: "ctrl-z"
            )
    )
}

@Test
func `container resize validates UInt32 dimensions before calling the provider`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)
    let resized = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/v1.53/containers/example/resize?h=48&w=132"
        )
    )
    #expect(resized.status == 200)
    #expect(backend.lastResize == DockerResizeCapture(height: 48, width: 132))

    for (target, message) in [
        (
            "/containers/example/resize?w=80",
            "invalid resize height \"\": invalid syntax"
        ),
        (
            "/containers/example/resize?h=-1&w=80",
            "invalid resize height \"-1\": value out of range"
        ),
        (
            "/containers/example/resize?h=-&w=80",
            "invalid resize height \"-\": invalid syntax"
        ),
        (
            "/containers/example/resize?h=24&w=4294967296",
            "invalid resize width \"4294967296\": value out of range"
        )
    ] {
        let response = await controller.respond(
            to: DockerHTTPRequest(method: .post, target: target)
        )
        #expect(response.status == 400)
        #expect(try errorMessage(response) == message)
    }

    let missing = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/missing/resize?h=24&w=80"
        )
    )
    #expect(missing.status == 404)
    #expect(try errorMessage(missing) == "No such container: missing")
}

@Test
func `container lifecycle routes decode typed requests and call native authority`() async throws {
    let backend = FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
    let controller = try DockerLoggingAPIController(backend: backend)
    let create = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/v1.53/containers/create?name=fixture",
            body: Data(
                #"{"Image":"alpine:latest","Cmd":["echo","hello"],"Env":["A=B"],"HostConfig":{"AutoRemove":true,"LogConfig":{"Type":"example-plugin","Config":{"token":"redacted"}}}}"#.utf8
            )
        )
    )
    #expect(create.status == 201)
    let createObject = try responseJSONObject(create)
    #expect(createObject["Id"] as? String == "fixture-id")
    #expect(backend.createdRequest?.image == "alpine:latest")
    #expect(backend.createdRequest?.command == ["echo", "hello"])
    #expect(
        backend.createdRequest?.hostConfiguration?.logConfiguration?.type
            == "example-plugin"
    )
    #expect(backend.requestedName == "fixture")

    let start = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/start"
        )
    )
    #expect(start.status == 204)

    let stop = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/stop?t=9"
        )
    )
    #expect(stop.status == 204)

    let defaultWait = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/wait"
        )
    )
    #expect(defaultWait.status == 200)
    #expect(try responseJSONObject(defaultWait)["StatusCode"] as? Int == 23)

    let wait = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/wait?condition=not-running"
        )
    )
    #expect(wait.status == 200)
    #expect(try responseJSONObject(wait)["StatusCode"] as? Int == 23)

    let nextExit = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/wait?condition=next-exit"
        )
    )
    #expect(nextExit.status == 200)

    let removed = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/wait?condition=removed"
        )
    )
    #expect(removed.status == 200)

    let invalidWait = await controller.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/wait?condition=invalid"
        )
    )
    #expect(invalidWait.status == 400)
    #expect(try errorMessage(invalidWait) == "invalid condition: \"invalid\"")

    let delete = await controller.respond(
        to: DockerHTTPRequest(
            method: .delete,
            target: "/containers/fixture-id?force=1&v=true"
        )
    )
    #expect(delete.status == 204)
    #expect(
        backend.lifecycleCalls
            == [
                "start:fixture-id",
                "stop:fixture-id:9",
                "wait:fixture-id:not-running",
                "wait:fixture-id:not-running",
                "wait:fixture-id:next-exit",
                "wait:fixture-id:removed",
                "delete:fixture-id:true:true"
            ]
    )
}

@Test
func `container wait maps backend errors and remains absent without wait authority`() async throws {
    let missingController = try DockerLoggingAPIController(
        backend: FakeLoggingBackend(
            reader: FakeLogReadSession(terminal: false),
            waitError: .containerNotFound("missing")
        )
    )
    let missing = await missingController.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/missing/wait"
        )
    )
    #expect(missing.status == 404)
    #expect(try errorMessage(missing) == "No such container: missing")

    let noWaitController = try DockerLoggingAPIController(
        backend: FakeLifecycleBackendWithoutWait(
            base: FakeLoggingBackend(reader: FakeLogReadSession(terminal: false))
        )
    )
    let unavailable = await noWaitController.respond(
        to: DockerHTTPRequest(
            method: .post,
            target: "/containers/fixture-id/wait"
        )
    )
    #expect(unavailable.status == 404)
    #expect(try errorMessage(unavailable) == "page not found")
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

private func responseJSONArray(
    _ response: DockerHTTPResponse
) throws -> [[String: Any]] {
    let value = try JSONSerialization.jsonObject(with: responseData(response))
    return try #require(value as? [[String: Any]])
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

private struct PullStatusPayload: Codable, Equatable {
    let status: String
    let id: String?

    init(status: String, id: String? = nil) {
        self.status = status
        self.id = id
    }
}

private final class FakeLoggingBackend:
    DockerLoggingBackend,
    DockerContainerLifecycleBackend,
    DockerContainerWaitBackend,
    DockerEngineDiscoveryBackend,
    DockerImageDiscoveryBackend,
    DockerImageMutationBackend,
    DockerTerminalResizeBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let reader: FakeLogReadSession
    private let openError: DockerLoggingBackendError?
    private let waitError: DockerLoggingBackendError?
    private let attachSession = FakeHijackSession()
    private var capturedLogRequest: DockerLogReadRequest?
    private var capturedAttachRequest: DockerAttachRequest?
    private var capturedResize: DockerResizeCapture?
    private var openedLogs = 0
    private var capturedCreatedRequest: DockerContainerCreateRequest?
    private var capturedRequestedName: String?
    private var capturedLifecycleCalls = [String]()
    private var capturedListRequest: DockerContainerListRequest?
    private var capturedImageListRequest: DockerImageListRequest?
    private var capturedImageInspectName: String?
    private var capturedImagePullRequest: DockerImagePullRequest?
    private var capturedImageTagName: String?
    private var capturedImageTagRequest: DockerImageTagRequest?
    private var capturedImageDeleteName: String?
    private var capturedImageDeleteRequest: DockerImageDeleteRequest?

    init(
        reader: FakeLogReadSession,
        openError: DockerLoggingBackendError? = nil,
        waitError: DockerLoggingBackendError? = nil
    ) {
        self.reader = reader
        self.openError = openError
        self.waitError = waitError
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

    var lastResize: DockerResizeCapture? {
        lock.withLock { capturedResize }
    }

    var createdRequest: DockerContainerCreateRequest? {
        lock.withLock { capturedCreatedRequest }
    }

    var requestedName: String? {
        lock.withLock { capturedRequestedName }
    }

    var lifecycleCalls: [String] {
        lock.withLock { capturedLifecycleCalls }
    }

    var lastListRequest: DockerContainerListRequest? {
        lock.withLock { capturedListRequest }
    }

    var lastImageListRequest: DockerImageListRequest? {
        lock.withLock { capturedImageListRequest }
    }

    var lastImageInspectName: String? {
        lock.withLock { capturedImageInspectName }
    }

    var lastImagePullRequest: DockerImagePullRequest? {
        lock.withLock { capturedImagePullRequest }
    }

    var lastImageTagName: String? {
        lock.withLock { capturedImageTagName }
    }

    var lastImageTagRequest: DockerImageTagRequest? {
        lock.withLock { capturedImageTagRequest }
    }

    var lastImageDeleteName: String? {
        lock.withLock { capturedImageDeleteName }
    }

    var lastImageDeleteRequest: DockerImageDeleteRequest? {
        lock.withLock { capturedImageDeleteRequest }
    }

    func systemVersionJSON() async throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "ApiVersion": "1.53",
                "Arch": "arm64",
                "BuildTime": "2026-01-01T00:00:00Z",
                "Components": [],
                "GitCommit": "fixture",
                "GoVersion": "",
                "KernelVersion": "",
                "MinAPIVersion": "1.44",
                "Os": "linux",
                "Platform": ["Name": "container"],
                "Version": "fixture"
            ]
        )
    }

    func containerListJSON(
        request: DockerContainerListRequest
    ) async throws -> Data {
        lock.withLock {
            capturedListRequest = request
        }
        return try JSONSerialization.data(
            withJSONObject: [[
                "Command": "/bin/true",
                "Created": 1_767_225_600,
                "HostConfig": ["NetworkMode": "default"],
                "Id": "fixture-id",
                "Image": "fixture:latest",
                "ImageID": "sha256:fixture",
                "Labels": ["compose.project": "fixture"],
                "Mounts": [],
                "Names": ["/fixture-id"],
                "NetworkSettings": ["Networks": [:]],
                "Ports": [],
                "State": "exited",
                "Status": "Exited (0) 1 second ago"
            ]]
        )
    }

    func imageListJSON(
        request: DockerImageListRequest
    ) async throws -> Data {
        lock.withLock {
            capturedImageListRequest = request
        }
        return try JSONSerialization.data(
            withJSONObject: [[
                "Containers": 1,
                "Created": 1_767_225_600,
                "Descriptor": [
                    "digest": "sha256:image-index",
                    "mediaType": "application/vnd.oci.image.index.v1+json",
                    "size": 512
                ],
                "Id": "sha256:image-index",
                "Labels": ["fixture": "true"],
                "ParentId": "",
                "RepoDigests": ["alpine@sha256:image-index"],
                "RepoTags": ["alpine:3.20"],
                "SharedSize": -1,
                "Size": 4_103_199
            ]]
        )
    }

    func imageInspectJSON(name: String) async throws -> Data {
        lock.withLock {
            capturedImageInspectName = name
        }
        guard name != "missing:latest" else {
            throw DockerLoggingBackendError.imageNotFound(name)
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "Architecture": "arm64",
                "Comment": "",
                "Config": ["Cmd": ["/bin/sh"]],
                "Created": "2026-01-01T00:00:00Z",
                "Descriptor": [
                    "digest": "sha256:image-index",
                    "mediaType": "application/vnd.oci.image.index.v1+json",
                    "size": 512
                ],
                "Id": "sha256:image-index",
                "Identity": ["Pull": [["Repository": "docker.io/library/alpine"]]],
                "Metadata": ["LastTagTime": "0001-01-01T00:00:00Z"],
                "Os": "linux",
                "RepoDigests": ["alpine@sha256:image-index"],
                "RepoTags": ["alpine:3.20"],
                "RootFS": ["Layers": ["sha256:layer"], "Type": "layers"],
                "Size": 4_103_199,
                "Variant": "v8"
            ]
        )
    }

    func pullImage(
        request: DockerImagePullRequest
    ) async throws -> DockerImagePullResult {
        lock.withLock {
            capturedImagePullRequest = request
        }
        return DockerImagePullResult(
            displayReference: "alpine:3.20",
            digest: "sha256:image-index",
            upToDate: true
        )
    }

    func tagImage(
        name: String,
        request: DockerImageTagRequest
    ) async throws {
        lock.withLock {
            capturedImageTagName = name
            capturedImageTagRequest = request
        }
        if name == "missing:latest" {
            throw DockerLoggingBackendError.imageNotFound(name)
        }
    }

    func deleteImage(
        name: String,
        request: DockerImageDeleteRequest
    ) async throws -> [DockerImageDeleteResult] {
        lock.withLock {
            capturedImageDeleteName = name
            capturedImageDeleteRequest = request
        }
        if name == "missing:latest" {
            throw DockerLoggingBackendError.imageNotFound(name)
        }
        return [DockerImageDeleteResult(untagged: name)]
    }

    func createContainer(
        request: DockerContainerCreateRequest,
        requestedName: String?
    ) async throws -> DockerContainerCreateResult {
        lock.withLock {
            capturedCreatedRequest = request
            capturedRequestedName = requestedName
        }
        return DockerContainerCreateResult(containerID: "fixture-id")
    }

    func startContainer(containerID: String) async throws {
        lock.withLock {
            capturedLifecycleCalls.append("start:\(containerID)")
        }
    }

    func stopContainer(
        containerID: String,
        timeoutSeconds: Int64?
    ) async throws {
        lock.withLock {
            capturedLifecycleCalls.append(
                "stop:\(containerID):\(timeoutSeconds.map(String.init) ?? "nil")"
            )
        }
    }

    func deleteContainer(
        containerID: String,
        force: Bool,
        removeVolumes: Bool
    ) async throws {
        lock.withLock {
            capturedLifecycleCalls.append(
                "delete:\(containerID):\(force):\(removeVolumes)"
            )
        }
    }

    func waitForContainer(
        containerID: String,
        condition: DockerContainerWaitCondition
    ) async throws -> DockerContainerWaitResult {
        if let waitError {
            throw waitError
        }
        lock.withLock {
            capturedLifecycleCalls.append(
                "wait:\(containerID):\(condition.rawValue)"
            )
        }
        return DockerContainerWaitResult(statusCode: 23)
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

    func resizeContainerTerminal(
        containerID: String,
        height: UInt32,
        width: UInt32
    ) async throws {
        guard containerID != "missing" else {
            throw DockerLoggingBackendError.containerNotFound(containerID)
        }
        lock.withLock {
            capturedResize = DockerResizeCapture(height: height, width: width)
        }
    }
}

/// Preserves lifecycle authority while deliberately withholding wait authority.
private struct FakeLifecycleBackendWithoutWait:
    DockerLoggingBackend,
    DockerContainerLifecycleBackend
{
    let base: FakeLoggingBackend

    func loggingSystemInfo() async throws -> DockerLoggingSystemInfo {
        try await base.loggingSystemInfo()
    }

    func inspectContainerLogging(
        containerID: String
    ) async throws -> DockerContainerLoggingInspection {
        try await base.inspectContainerLogging(containerID: containerID)
    }

    func openContainerLogs(
        containerID: String,
        request: DockerLogReadRequest
    ) async throws -> any DockerLogReadSession {
        try await base.openContainerLogs(containerID: containerID, request: request)
    }

    func attachContainer(
        containerID: String,
        request: DockerAttachRequest
    ) async throws -> DockerAttachConnection {
        try await base.attachContainer(containerID: containerID, request: request)
    }

    func createContainer(
        request: DockerContainerCreateRequest,
        requestedName: String?
    ) async throws -> DockerContainerCreateResult {
        try await base.createContainer(request: request, requestedName: requestedName)
    }

    func startContainer(containerID: String) async throws {
        try await base.startContainer(containerID: containerID)
    }

    func stopContainer(
        containerID: String,
        timeoutSeconds: Int64?
    ) async throws {
        try await base.stopContainer(
            containerID: containerID,
            timeoutSeconds: timeoutSeconds
        )
    }

    func deleteContainer(
        containerID: String,
        force: Bool,
        removeVolumes: Bool
    ) async throws {
        try await base.deleteContainer(
            containerID: containerID,
            force: force,
            removeVolumes: removeVolumes
        )
    }
}

private struct DockerResizeCapture: Equatable {
    let height: UInt32
    let width: UInt32
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
