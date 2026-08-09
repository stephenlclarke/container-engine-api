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
    private let discoveryBackend: (any DockerEngineDiscoveryBackend)?
    private let imageDiscoveryBackend: (any DockerImageDiscoveryBackend)?
    private let imageMutationBackend: (any DockerImageMutationBackend)?
    private let volumeBackend: (any DockerVolumeBackend)?
    private let lifecycleBackend: (any DockerContainerLifecycleBackend)?
    private let waitBackend: (any DockerContainerWaitBackend)?
    private let sharedResponseBackend: (any DockerLoggingSharedResponseBackend)?
    private let terminalResizeBackend: (any DockerTerminalResizeBackend)?

    public init(
        backend: any DockerLoggingBackend,
        sharedResponseBackend: (any DockerLoggingSharedResponseBackend)? = nil,
        volumeBackend: (any DockerVolumeBackend)? = nil
    ) throws {
        minimumAPIVersion = try DockerAPIVersion("1.44")
        maximumAPIVersion = try DockerAPIVersion("1.53")
        let lifecycleBackend = backend as? any DockerContainerLifecycleBackend
        let waitBackend = backend as? any DockerContainerWaitBackend
        let discoveryBackend = backend as? any DockerEngineDiscoveryBackend
        let imageDiscoveryBackend = backend as? any DockerImageDiscoveryBackend
        let imageMutationBackend = backend as? any DockerImageMutationBackend
        let volumeBackend = volumeBackend ?? (backend as? any DockerVolumeBackend)
        routeLedger = try Self.makeRouteLedger(
            minimum: minimumAPIVersion,
            maximum: maximumAPIVersion,
            includesLifecycle: lifecycleBackend != nil,
            includesWait: waitBackend != nil,
            includesDiscovery: discoveryBackend != nil,
            includesImageDiscovery: imageDiscoveryBackend != nil,
            includesImageMutation: imageMutationBackend != nil,
            includesVolumeCreate: volumeBackend != nil
        )
        self.backend = backend
        self.discoveryBackend = discoveryBackend
        self.imageDiscoveryBackend = imageDiscoveryBackend
        self.imageMutationBackend = imageMutationBackend
        self.volumeBackend = volumeBackend
        self.lifecycleBackend = lifecycleBackend
        self.waitBackend = waitBackend
        self.sharedResponseBackend = sharedResponseBackend
        terminalResizeBackend = backend as? any DockerTerminalResizeBackend
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
        case RouteIdentifier.version:
            return await versionResponse()
        case RouteIdentifier.list:
            return await listResponse(target: match.target)
        case RouteIdentifier.imageList:
            return await imageListResponse(target: match.target)
        case RouteIdentifier.imageInspect:
            return await imageInspectResponse(
                name: match.parameters["name"] ?? ""
            )
        case RouteIdentifier.imagePull:
            return await imagePullResponse(request: request, target: match.target)
        case RouteIdentifier.imageTag:
            return await imageTagResponse(
                name: match.parameters["name"] ?? "",
                target: match.target
            )
        case RouteIdentifier.imageDelete:
            return await imageDeleteResponse(
                name: match.parameters["name"] ?? "",
                target: match.target
            )
        case RouteIdentifier.volumeCreate:
            return await volumeCreateResponse(request: request)
        case RouteIdentifier.create:
            return await createResponse(request: request, target: match.target)
        case RouteIdentifier.start:
            return await startResponse(
                containerID: match.parameters["id"] ?? ""
            )
        case RouteIdentifier.stop:
            return await stopResponse(
                containerID: match.parameters["id"] ?? "",
                target: match.target
            )
        case RouteIdentifier.wait:
            return await waitResponse(
                containerID: match.parameters["id"] ?? "",
                target: match.target
            )
        case RouteIdentifier.delete:
            return await deleteResponse(
                containerID: match.parameters["id"] ?? "",
                target: match.target
            )
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
        case RouteIdentifier.attachWebSocket:
            return await attachWebSocketResponse(
                request: request,
                containerID: match.parameters["id"] ?? "",
                target: match.target
            )
        case RouteIdentifier.resize:
            return await resizeResponse(
                containerID: match.parameters["id"] ?? "",
                target: match.target
            )
        default:
            return Self.errorResponse(status: 500, message: "server error")
        }
    }

    private func versionResponse() async -> DockerHTTPResponse {
        guard let discoveryBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            let data = try await discoveryBackend.systemVersionJSON()
            let object = try Self.completeJSONObject(
                data,
                route: "SystemVersion",
                requiredKeys: Self.systemVersionRequiredKeys
            )
            return try Self.jsonObjectLineResponse(object)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func listResponse(
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let discoveryBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        let request: DockerContainerListRequest
        do {
            request = try Self.containerListRequest(target: target)
        } catch let error as QueryError {
            return Self.errorResponse(status: error.status, message: error.message)
        } catch {
            return Self.errorResponse(status: 500, message: "server error")
        }
        do {
            let data = try await discoveryBackend.containerListJSON(request: request)
            let objects = try Self.completeJSONArray(
                data,
                route: "ContainerList",
                requiredKeys: Self.containerListRequiredKeys
            )
            return try Self.jsonArrayLineResponse(objects)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func imageListResponse(
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let imageDiscoveryBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        let request: DockerImageListRequest
        do {
            request = try Self.imageListRequest(target: target)
        } catch let error as QueryError {
            return Self.errorResponse(status: error.status, message: error.message)
        } catch {
            return Self.errorResponse(status: 500, message: "server error")
        }
        do {
            let data = try await imageDiscoveryBackend.imageListJSON(request: request)
            let objects = try Self.completeJSONArray(
                data,
                route: "ImageList",
                requiredKeys: Self.imageListRequiredKeys
            )
            return try Self.jsonArrayLineResponse(objects)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func imageInspectResponse(name: String) async -> DockerHTTPResponse {
        guard let imageDiscoveryBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            let data = try await imageDiscoveryBackend.imageInspectJSON(name: name)
            let object = try Self.completeJSONObject(
                data,
                route: "ImageInspect",
                requiredKeys: Self.imageInspectRequiredKeys
            )
            return try Self.jsonObjectLineResponse(object)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func imagePullResponse(
        request: DockerHTTPRequest,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let imageMutationBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            let pullRequest = try Self.imagePullRequest(
                request: request,
                target: target
            )
            let result = try await imageMutationBackend.pullImage(
                request: pullRequest
            )
            return Self.imagePullResponse(result)
        } catch let error as QueryError {
            return Self.errorResponse(status: error.status, message: error.message)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func imageTagResponse(
        name: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let imageMutationBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            try await imageMutationBackend.tagImage(
                name: name,
                request: Self.imageTagRequest(target: target)
            )
            return .empty(status: 201)
        } catch let error as QueryError {
            return Self.errorResponse(status: error.status, message: error.message)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func imageDeleteResponse(
        name: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let imageMutationBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            let results = try await imageMutationBackend.deleteImage(
                name: name,
                request: DockerImageDeleteRequest(
                    force: Self.boolValue(target.first("force")),
                    prune: !Self.boolValue(target.first("noprune"))
                )
            )
            return Self.jsonLineResponse(results)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func volumeCreateResponse(
        request: DockerHTTPRequest
    ) async -> DockerHTTPResponse {
        guard let volumeBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            let decoded = try DockerJSON.decoder.decode(
                DockerVolumeCreateRequest.self,
                from: request.body
            )
            let result = try await volumeBackend.createVolume(request: decoded)
            return Self.jsonLineResponse(result, status: 201)
        } catch is DecodingError {
            return Self.errorResponse(
                status: 400,
                message: "invalid volume create request"
            )
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func createResponse(
        request: DockerHTTPRequest,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let lifecycleBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            let decoded = try DockerJSON.decoder.decode(
                DockerContainerCreateRequest.self,
                from: request.body
            )
            let result = try await lifecycleBackend.createContainer(
                request: decoded,
                requestedName: target.first("name")
            )
            return Self.jsonLineResponse(
                CreateResponse(
                    id: result.containerID,
                    warnings: result.warnings
                ),
                status: 201
            )
        } catch is DecodingError {
            return Self.errorResponse(
                status: 400,
                message: "invalid container create request"
            )
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func startResponse(containerID: String) async -> DockerHTTPResponse {
        guard let lifecycleBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            try await lifecycleBackend.startContainer(containerID: containerID)
            return .empty(status: 204)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func stopResponse(
        containerID: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let lifecycleBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        let rawTimeout = target.first("t") ?? target.first("timeout")
        let timeout: Int64?
        if let rawTimeout {
            guard let value = Int64(rawTimeout), value >= -1 else {
                return Self.errorResponse(
                    status: 400,
                    message: "invalid stop timeout"
                )
            }
            timeout = value
        } else {
            timeout = nil
        }
        do {
            try await lifecycleBackend.stopContainer(
                containerID: containerID,
                timeoutSeconds: timeout
            )
            return .empty(status: 204)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func deleteResponse(
        containerID: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let lifecycleBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            try await lifecycleBackend.deleteContainer(
                containerID: containerID,
                force: Self.boolValue(target.first("force")),
                removeVolumes: Self.boolValue(target.first("v"))
            )
            return .empty(status: 204)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func waitResponse(
        containerID: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        guard let waitBackend else {
            return Self.errorResponse(status: 404, message: "page not found")
        }
        do {
            let condition = try Self.containerWaitCondition(target)
            let startGate = DockerContainerWaitStartGate()
            let waitTask = Task {
                do {
                    let result = try await waitBackend.waitForContainer(
                        containerID: containerID,
                        condition: condition,
                        onRegistered: {
                            startGate.registered()
                        }
                    )
                    startGate.completed(with: Self.jsonLineResponse(result))
                    return result
                } catch {
                    startGate.completed(with: Self.backendErrorResponse(error))
                    throw error
                }
            }
            return await withTaskCancellationHandler {
                switch await startGate.waitForOutcome() {
                case .registered:
                    return DockerHTTPResponse(
                        status: 200,
                        headers: ["Content-Type": "application/json"],
                        body: .managedStream(
                            DockerContainerWaitHTTPStream(
                                waitForCompletion: {
                                    try await waitTask.value
                                },
                                cancelWait: {
                                    waitTask.cancel()
                                }
                            )
                        )
                    )
                case let .terminal(response):
                    _ = await waitTask.result
                    return response
                }
            } onCancel: {
                waitTask.cancel()
            }
        } catch let error as QueryError {
            return Self.errorResponse(status: error.status, message: error.message)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func infoResponse() async -> DockerHTTPResponse {
        do {
            let info = try await backend.loggingSystemInfo()
            let drivers = Array(
                Set(info.registeredDrivers.filter { !$0.isEmpty && $0 != "none" })
            ).sorted(by: Self.utf8Less)
            if let sharedResponseBackend {
                let base = try await sharedResponseBackend.systemInfoBaseJSON()
                return try Self.completeInfoResponse(
                    base: base,
                    loggingDriver: info.defaultDriver,
                    logPlugins: drivers
                )
            }
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
            if let sharedResponseBackend {
                let base = try await sharedResponseBackend.containerInspectBaseJSON(
                    containerID: containerID
                )
                return try Self.completeInspectResponse(
                    base: base,
                    inspection: inspection
                )
            }
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

    private static func completeInfoResponse(
        base: Data,
        loggingDriver: String,
        logPlugins: [String]
    ) throws -> DockerHTTPResponse {
        var object = try completeJSONObject(
            base,
            route: "SystemInfo",
            requiredKeys: systemInfoRequiredKeys
        )
        guard var plugins = object["Plugins"] as? [String: Any] else {
            throw DockerLoggingBackendError.server(
                "complete SystemInfo response has invalid Plugins"
            )
        }
        plugins["Log"] = logPlugins
        object["Plugins"] = plugins
        object["LoggingDriver"] = loggingDriver
        return try jsonObjectLineResponse(object)
    }

    private static func completeInspectResponse(
        base: Data,
        inspection: DockerContainerLoggingInspection
    ) throws -> DockerHTTPResponse {
        var object = try completeJSONObject(
            base,
            route: "ContainerInspect",
            requiredKeys: containerInspectRequiredKeys
        )
        guard
            var config = object["Config"] as? [String: Any],
            var hostConfig = object["HostConfig"] as? [String: Any]
        else {
            throw DockerLoggingBackendError.server(
                "complete ContainerInspect response has invalid Config or HostConfig"
            )
        }
        config["Tty"] = inspection.terminal
        hostConfig["LogConfig"] = [
            "Type": inspection.configuration.driver,
            "Config": inspection.configuration.options
        ]
        object["Config"] = config
        object["HostConfig"] = hostConfig
        object["LogPath"] =
            inspection.configuration.driver == "json-file"
                ? inspection.publicLogPath ?? ""
                : ""
        return try jsonObjectLineResponse(object)
    }

    private static func completeJSONObject(
        _ data: Data,
        route: String,
        requiredKeys: Set<String>
    ) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw DockerLoggingBackendError.server(
                "complete \(route) response is not valid JSON"
            )
        }
        guard let object = value as? [String: Any] else {
            throw DockerLoggingBackendError.server(
                "complete \(route) response is not a JSON object"
            )
        }
        let missing = requiredKeys.subtracting(object.keys)
        guard missing.isEmpty else {
            throw DockerLoggingBackendError.server(
                "complete \(route) response is missing required fields"
            )
        }
        return object
    }

    private static func completeJSONArray(
        _ data: Data,
        route: String,
        requiredKeys: Set<String>
    ) throws -> [[String: Any]] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw DockerLoggingBackendError.server(
                "complete \(route) response is not valid JSON"
            )
        }
        guard let objects = value as? [[String: Any]] else {
            throw DockerLoggingBackendError.server(
                "complete \(route) response is not a JSON array"
            )
        }
        guard objects.allSatisfy({ requiredKeys.isSubset(of: $0.keys) }) else {
            throw DockerLoggingBackendError.server(
                "complete \(route) response is missing required fields"
            )
        }
        return objects
    }

    private static func jsonObjectLineResponse(
        _ object: [String: Any]
    ) throws -> DockerHTTPResponse {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DockerLoggingBackendError.server(
                "complete Engine response is not JSON encodable"
            )
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(UInt8(ascii: "\n"))
        return DockerHTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: .bytes(data)
        )
    }

    private static func jsonArrayLineResponse(
        _ objects: [[String: Any]]
    ) throws -> DockerHTTPResponse {
        guard JSONSerialization.isValidJSONObject(objects) else {
            throw DockerLoggingBackendError.server(
                "complete Engine response is not JSON encodable"
            )
        }
        var data = try JSONSerialization.data(
            withJSONObject: objects,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(UInt8(ascii: "\n"))
        return DockerHTTPResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: .bytes(data)
        )
    }

    private static let systemVersionRequiredKeys: Set<String> = [
        "ApiVersion", "Arch", "BuildTime", "Components", "GitCommit",
        "GoVersion", "KernelVersion", "MinAPIVersion", "Os", "Platform",
        "Version"
    ]

    private static let containerListRequiredKeys: Set<String> = [
        "Command", "Created", "HostConfig", "Id", "Image", "ImageID",
        "Labels", "Mounts", "Names", "NetworkSettings", "Ports", "State",
        "Status"
    ]

    private static let imageListRequiredKeys: Set<String> = [
        "Containers", "Created", "Descriptor", "Id", "Labels", "ParentId",
        "RepoDigests", "RepoTags", "SharedSize", "Size"
    ]

    private static let imageInspectRequiredKeys: Set<String> = [
        "Architecture", "Comment", "Config", "Created", "Descriptor", "Id",
        "Identity", "Metadata", "Os", "RepoDigests", "RepoTags", "RootFS",
        "Size", "Variant"
    ]

    private static let systemInfoRequiredKeys: Set<String> = [
        "Architecture", "CDISpecDirs", "CPUShares", "CPUSet", "CgroupDriver",
        "ContainerdCommit", "Containers", "ContainersPaused", "ContainersRunning",
        "ContainersStopped", "CpuCfsPeriod", "CpuCfsQuota", "Debug",
        "DefaultRuntime", "DockerRootDir", "Driver", "DriverStatus",
        "ExperimentalBuild", "GenericResources", "HttpProxy", "HttpsProxy", "ID",
        "IPv4Forwarding", "Images", "IndexServerAddress", "InitBinary", "InitCommit",
        "Isolation", "KernelVersion", "Labels", "LiveRestoreEnabled", "LoggingDriver",
        "MemTotal", "MemoryLimit", "NCPU", "NEventsListener", "NFd", "NGoroutines",
        "Name", "NoProxy", "OSType", "OSVersion", "OomKillDisable",
        "OperatingSystem", "PidsLimit", "Plugins", "RegistryConfig", "RuncCommit",
        "Runtimes", "SecurityOptions", "ServerVersion", "SwapLimit", "Swarm",
        "SystemTime", "Warnings"
    ]

    private static let containerInspectRequiredKeys: Set<String> = [
        "AppArmorProfile", "Args", "Config", "Created", "Driver", "ExecIDs",
        "HostConfig", "HostnamePath", "HostsPath", "Id", "Image", "LogPath",
        "MountLabel", "Mounts", "Name", "NetworkSettings", "Path", "Platform",
        "ProcessLabel", "ResolvConfPath", "RestartCount", "State"
    ]

    private static func containerListRequest(
        target: DockerRequestTarget
    ) throws -> DockerContainerListRequest {
        let limit: Int?
        if let rawLimit = target.first("limit"), !rawLimit.isEmpty {
            guard let parsed = Int(rawLimit), parsed >= 0 else {
                throw QueryError(
                    status: 400,
                    message: "invalid limit: \(rawLimit)"
                )
            }
            limit = parsed
        } else {
            limit = nil
        }
        return try DockerContainerListRequest(
            all: boolValue(target.first("all")),
            limit: limit,
            size: boolValue(target.first("size")),
            filters: containerListFilters(target.first("filters"))
        )
    }

    private static func containerWaitCondition(
        _ target: DockerRequestTarget
    ) throws -> DockerContainerWaitCondition {
        guard let rawCondition = target.first("condition") else {
            return .notRunning
        }
        guard let condition = DockerContainerWaitCondition(rawValue: rawCondition) else {
            throw QueryError(
                status: 400,
                message: "invalid condition: \"\(rawCondition)\""
            )
        }
        return condition
    }

    private static func containerListFilters(
        _ raw: String?
    ) throws -> [String: [String]] {
        guard let raw, !raw.isEmpty else {
            return [:]
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        } catch {
            throw QueryError(status: 400, message: "invalid filters JSON")
        }
        guard let object = value as? [String: Any] else {
            throw QueryError(status: 400, message: "invalid filters JSON")
        }
        var result = [String: [String]]()
        for (name, values) in object {
            if let strings = values as? [String] {
                result[name] = strings
            } else if let flags = values as? [String: Bool] {
                result[name] = flags.compactMap { $0.value ? $0.key : nil }
                    .sorted(by: utf8Less)
            } else {
                throw QueryError(status: 400, message: "invalid filters JSON")
            }
        }
        return result
    }

    private static func imageListRequest(
        target: DockerRequestTarget
    ) throws -> DockerImageListRequest {
        try DockerImageListRequest(
            all: boolValue(target.first("all")),
            sharedSize: boolValue(target.first("shared-size")),
            containerdSnapshotter: boolValue(
                target.first("containerd-snapshotter")
            ),
            filters: imageListFilters(target.first("filters"))
        )
    }

    private static func imagePullRequest(
        request: DockerHTTPRequest,
        target: DockerRequestTarget
    ) throws -> DockerImagePullRequest {
        guard let fromImage = target.first("fromImage"), !fromImage.isEmpty else {
            throw QueryError(status: 400, message: "fromImage is required")
        }
        let registryAuth: String?
        do {
            registryAuth = try request.uniqueHeader("X-Registry-Auth")
        } catch {
            throw QueryError(
                status: 400,
                message: "X-Registry-Auth must occur at most once"
            )
        }
        return DockerImagePullRequest(
            fromImage: fromImage,
            tag: target.first("tag").flatMap { $0.isEmpty ? nil : $0 },
            platform: target.first("platform").flatMap { $0.isEmpty ? nil : $0 },
            registryAuth: registryAuth
        )
    }

    private static func imageTagRequest(
        target: DockerRequestTarget
    ) throws -> DockerImageTagRequest {
        guard let repository = target.first("repo"), !repository.isEmpty else {
            throw QueryError(status: 400, message: "repo is required")
        }
        return DockerImageTagRequest(
            repository: repository,
            tag: target.first("tag").flatMap { $0.isEmpty ? nil : $0 }
                ?? "latest"
        )
    }

    private static func imageListFilters(
        _ raw: String?
    ) throws -> [String: [String]] {
        guard let raw, !raw.isEmpty else {
            return [:]
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        } catch {
            throw QueryError(status: 400, message: "invalid filter")
        }
        guard let object = value as? [String: Any] else {
            throw QueryError(status: 400, message: "invalid filter")
        }
        var result = [String: [String]]()
        for (name, values) in object {
            if let strings = values as? [String] {
                result[name] = strings
            } else if let flags = values as? [String: Bool] {
                result[name] = flags.compactMap { $0.value ? $0.key : nil }
                    .sorted(by: utf8Less)
            } else {
                throw QueryError(status: 400, message: "invalid filter")
            }
        }
        return result
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

    private func attachWebSocketResponse(
        request _: DockerHTTPRequest,
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
            return DockerHTTPResponse(
                status: 101,
                headers: [
                    "Connection": "Upgrade",
                    "Upgrade": "websocket"
                ],
                body: .webSocket(connection.session)
            )
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private func resizeResponse(
        containerID: String,
        target: DockerRequestTarget
    ) async -> DockerHTTPResponse {
        let height: UInt32
        let width: UInt32
        do {
            height = try Self.resizeValue(
                target.first("h"),
                dimension: "height"
            )
            width = try Self.resizeValue(
                target.first("w"),
                dimension: "width"
            )
        } catch let error as QueryError {
            return Self.errorResponse(status: error.status, message: error.message)
        } catch {
            return Self.errorResponse(status: 500, message: "server error")
        }
        guard let terminalResizeBackend else {
            return Self.errorResponse(
                status: 501,
                message: "container terminal resize is not implemented by the selected provider"
            )
        }
        do {
            try await terminalResizeBackend.resizeContainerTerminal(
                containerID: containerID,
                height: height,
                width: width
            )
            return .empty(status: 200)
        } catch {
            return Self.backendErrorResponse(error)
        }
    }

    private static func resizeValue(
        _ value: String?,
        dimension: String
    ) throws -> UInt32 {
        let raw = value ?? ""
        let magnitude = raw.first == "-" ? String(raw.dropFirst()) : raw
        let isDecimal = !magnitude.isEmpty && magnitude.allSatisfy(\.isNumber)
        guard
            !raw.isEmpty,
            raw.first != "+",
            raw.first != "-",
            isDecimal,
            let parsed = UInt64(raw),
            parsed <= UInt32.max
        else {
            let reason = raw.first == "-" && isDecimal
                || isDecimal && UInt64(magnitude).map { $0 > UInt32.max } == true
                ? "value out of range"
                : "invalid syntax"
            throw QueryError(
                status: 400,
                message: "invalid resize \(dimension) \"\(raw)\": \(reason)"
            )
        }
        return UInt32(parsed)
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
        case .containerNotFound, .imageNotFound, .volumeDriverNotFound:
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
            case .containerNotFound, .imageNotFound, .volumeDriverNotFound:
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

    private static func imagePullResponse(
        _ result: DockerImagePullResult
    ) -> DockerHTTPResponse {
        let components = imageReferenceComponents(result.displayReference)
        let pullRepository = components.repository.contains("/")
            ? components.repository
            : "library/\(components.repository)"
        let finalStatus = result.upToDate
            ? "Image is up to date for \(result.displayReference)"
            : "Downloaded newer image for \(result.displayReference)"
        let updates = [
            ImagePullProgress(
                status: "Pulling from \(pullRepository)",
                id: components.tag
            ),
            ImagePullProgress(status: "Digest: \(result.digest)"),
            ImagePullProgress(status: "Status: \(finalStatus)")
        ]
        do {
            var data = Data()
            for update in updates {
                try data.append(DockerJSON.encoder.encode(update))
                data.append(UInt8(ascii: "\n"))
            }
            return DockerHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: .bytes(data)
            )
        } catch {
            return errorResponse(status: 500, message: "server error")
        }
    }

    private static func imageReferenceComponents(
        _ reference: String
    ) -> (repository: String, tag: String?) {
        let withoutDigest = reference.split(separator: "@", maxSplits: 1)
            .first.map(String.init) ?? reference
        let slash = withoutDigest.lastIndex(of: "/")
        let suffixStart = slash.map { withoutDigest.index(after: $0) }
            ?? withoutDigest.startIndex
        let suffix = withoutDigest[suffixStart...]
        guard let colon = suffix.lastIndex(of: ":") else {
            return (withoutDigest, nil)
        }
        let absoluteColon = withoutDigest.index(
            suffixStart,
            offsetBy: suffix.distance(from: suffix.startIndex, to: colon)
        )
        return (
            String(withoutDigest[..<absoluteColon]),
            String(withoutDigest[withoutDigest.index(after: absoluteColon)...])
        )
    }

    private static func makeRouteLedger(
        minimum: DockerAPIVersion,
        maximum: DockerAPIVersion,
        includesLifecycle: Bool,
        includesWait: Bool,
        includesDiscovery: Bool,
        includesImageDiscovery: Bool,
        includesImageMutation: Bool,
        includesVolumeCreate: Bool
    ) throws -> DockerRouteLedger {
        var routes = try [
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
            ),
            DockerRouteMetadata(
                identifier: RouteIdentifier.attachWebSocket,
                method: .get,
                pattern: DockerRoutePattern("/containers/{id}/attach/ws"),
                introduced: minimum,
                responseMode: .hijack,
                disposition: .implemented
            ),
            DockerRouteMetadata(
                identifier: RouteIdentifier.resize,
                method: .post,
                pattern: DockerRoutePattern("/containers/{id}/resize"),
                introduced: minimum,
                responseMode: .bytes,
                disposition: .implemented
            )
        ]
        if includesLifecycle {
            try routes.append(contentsOf: [
                DockerRouteMetadata(
                    identifier: RouteIdentifier.create,
                    method: .post,
                    pattern: DockerRoutePattern("/containers/create"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.start,
                    method: .post,
                    pattern: DockerRoutePattern("/containers/{id}/start"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.stop,
                    method: .post,
                    pattern: DockerRoutePattern("/containers/{id}/stop"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.delete,
                    method: .delete,
                    pattern: DockerRoutePattern("/containers/{id}"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                )
            ])
            if includesWait {
                try routes.append(
                    DockerRouteMetadata(
                        identifier: RouteIdentifier.wait,
                        method: .post,
                        pattern: DockerRoutePattern("/containers/{id}/wait"),
                        introduced: minimum,
                        responseMode: .bytes,
                        disposition: .implemented
                    )
                )
            }
        }
        if includesDiscovery {
            try routes.append(contentsOf: [
                DockerRouteMetadata(
                    identifier: RouteIdentifier.version,
                    method: .get,
                    pattern: DockerRoutePattern("/version"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.list,
                    method: .get,
                    pattern: DockerRoutePattern("/containers/json"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                )
            ])
        }
        if includesImageDiscovery {
            try routes.append(contentsOf: [
                DockerRouteMetadata(
                    identifier: RouteIdentifier.imageList,
                    method: .get,
                    pattern: DockerRoutePattern("/images/json"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.imageInspect,
                    method: .get,
                    pattern: DockerRoutePattern("/images/{name...}/json"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                )
            ])
        }
        if includesImageMutation {
            try routes.append(contentsOf: [
                DockerRouteMetadata(
                    identifier: RouteIdentifier.imagePull,
                    method: .post,
                    pattern: DockerRoutePattern("/images/create"),
                    introduced: minimum,
                    responseMode: .stream,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.imageTag,
                    method: .post,
                    pattern: DockerRoutePattern("/images/{name...}/tag"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                ),
                DockerRouteMetadata(
                    identifier: RouteIdentifier.imageDelete,
                    method: .delete,
                    pattern: DockerRoutePattern("/images/{name...}"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                )
            ])
        }
        if includesVolumeCreate {
            try routes.append(
                DockerRouteMetadata(
                    identifier: RouteIdentifier.volumeCreate,
                    method: .post,
                    pattern: DockerRoutePattern("/volumes/create"),
                    introduced: minimum,
                    responseMode: .bytes,
                    disposition: .implemented
                )
            )
        }
        return try DockerRouteLedger(
            minimumAPIVersion: minimum,
            maximumAPIVersion: maximum,
            routes: routes
        )
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private enum RouteIdentifier {
    static let attach = "container.attach"
    static let attachWebSocket = "container.attach.websocket"
    static let info = "system.info"
    static let create = "container.create"
    static let start = "container.start"
    static let stop = "container.stop"
    static let wait = "container.wait"
    static let delete = "container.delete"
    static let inspect = "container.inspect"
    static let logs = "container.logs"
    static let resize = "container.resize"
    static let list = "container.list"
    static let version = "system.version"
    static let imageList = "image.list"
    static let imageInspect = "image.inspect"
    static let imagePull = "image.pull"
    static let imageTag = "image.tag"
    static let imageDelete = "image.delete"
    static let volumeCreate = "volume.create"
}

private struct ImagePullProgress: Encodable {
    let status: String
    let id: String?

    init(status: String, id: String? = nil) {
        self.status = status
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case id
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(id, forKey: .id)
    }
}

private struct CreateResponse: Encodable {
    let id: String
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case warnings = "Warnings"
    }
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
