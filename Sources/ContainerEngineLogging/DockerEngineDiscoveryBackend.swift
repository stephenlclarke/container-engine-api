//===----------------------------------------------------------------------===//
// Copyright 2026 devcontainer and container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// A normalized `GET /containers/json` request.
public struct DockerContainerListRequest: Equatable, Sendable {
    public var all: Bool
    public var limit: Int?
    public var size: Bool
    public var filters: [String: [String]]

    public init(
        all: Bool = false,
        limit: Int? = nil,
        size: Bool = false,
        filters: [String: [String]] = [:]
    ) {
        self.all = all
        self.limit = limit
        self.size = size
        self.filters = filters
    }
}

/// Supplies complete Docker discovery documents from the selected native
/// container authority.
///
/// The controller validates both documents before exposing them. Providers
/// must derive the list from the same catalog used by native lifecycle and
/// inspect operations; a second Docker-only inventory is not permitted.
public protocol DockerEngineDiscoveryBackend: Sendable {
    func systemVersionJSON() async throws -> Data
    func containerListJSON(request: DockerContainerListRequest) async throws -> Data
}
