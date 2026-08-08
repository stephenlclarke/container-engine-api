//===----------------------------------------------------------------------===//
// Copyright 2026 devcontainer and container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// Docker's `POST /volumes/create` payload after HTTP decoding.
///
/// The authority receives the requested driver unchanged so it can resolve an
/// omitted or empty driver to its built-in provider, and reject an unavailable
/// provider before it creates any volume state.
public struct DockerVolumeCreateRequest: Decodable, Equatable, Sendable {
    public var name: String
    public var driver: String?
    public var driverOptions: [String: String]?
    public var labels: [String: String]?

    public init(
        name: String,
        driver: String? = nil,
        driverOptions: [String: String]? = nil,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.driver = driver
        self.driverOptions = driverOptions
        self.labels = labels
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case driverOptions = "DriverOpts"
        case labels = "Labels"
    }
}

/// The complete Docker volume document returned from a successful create.
public struct DockerVolumeCreateResult: Codable, Equatable, Sendable {
    public var name: String
    public var driver: String
    public var mountpoint: String
    public var createdAt: String
    public var labels: [String: String]
    public var options: [String: String]
    public var scope: String

    public init(
        name: String,
        driver: String,
        mountpoint: String,
        createdAt: String,
        labels: [String: String] = [:],
        options: [String: String] = [:],
        scope: String = "local"
    ) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.createdAt = createdAt
        self.labels = labels
        self.options = options
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
        case createdAt = "CreatedAt"
        case labels = "Labels"
        case options = "Options"
        case scope = "Scope"
    }
}

/// Creates Docker volumes through the same resource authority as native
/// clients. The HTTP controller never opens a separate volume store.
public protocol DockerVolumeBackend: Sendable {
    func createVolume(
        request: DockerVolumeCreateRequest
    ) async throws -> DockerVolumeCreateResult
}
