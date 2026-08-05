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

import Foundation

/// Docker's public image-pull query after HTTP parsing and validation.
public struct DockerImagePullRequest: Equatable, Sendable {
    public var fromImage: String
    public var tag: String?
    public var platform: String?
    public var registryAuth: String?

    public init(
        fromImage: String,
        tag: String? = nil,
        platform: String? = nil,
        registryAuth: String? = nil
    ) {
        self.fromImage = fromImage
        self.tag = tag
        self.platform = platform
        self.registryAuth = registryAuth
    }
}

/// Authority result used to render Docker's newline-delimited pull status.
public struct DockerImagePullResult: Equatable, Sendable {
    public var displayReference: String
    public var digest: String
    public var upToDate: Bool

    public init(
        displayReference: String,
        digest: String,
        upToDate: Bool
    ) {
        self.displayReference = displayReference
        self.digest = digest
        self.upToDate = upToDate
    }
}

/// Docker's image-tag query after HTTP parsing and validation.
public struct DockerImageTagRequest: Equatable, Sendable {
    public var repository: String
    public var tag: String

    public init(repository: String, tag: String = "latest") {
        self.repository = repository
        self.tag = tag
    }
}

/// Docker's image-delete query after HTTP parsing and validation.
public struct DockerImageDeleteRequest: Equatable, Sendable {
    public var force: Bool
    public var prune: Bool

    public init(force: Bool = false, prune: Bool = true) {
        self.force = force
        self.prune = prune
    }
}

/// One Docker image-delete result object. Exactly one field is populated.
public struct DockerImageDeleteResult: Codable, Equatable, Sendable {
    public var deleted: String?
    public var untagged: String?

    public init(deleted: String? = nil, untagged: String? = nil) {
        self.deleted = deleted
        self.untagged = untagged
    }

    private enum CodingKeys: String, CodingKey {
        case deleted = "Deleted"
        case untagged = "Untagged"
    }
}

/// Mutates images through the same authority used by native clients.
public protocol DockerImageMutationBackend: Sendable {
    func pullImage(
        request: DockerImagePullRequest
    ) async throws -> DockerImagePullResult
    func tagImage(
        name: String,
        request: DockerImageTagRequest
    ) async throws
    func deleteImage(
        name: String,
        request: DockerImageDeleteRequest
    ) async throws -> [DockerImageDeleteResult]
}
