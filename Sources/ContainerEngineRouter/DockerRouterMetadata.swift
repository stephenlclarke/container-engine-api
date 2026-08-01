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

public enum DockerRouteResponseMode: String, Codable, Sendable {
    case bytes
    case hijack
    case stream
}

public enum DockerRouteDisposition: String, Codable, Sendable {
    case implemented
    case platformUnavailable
    case unimplemented
}

public struct DockerRouteMetadata: Codable, Hashable, Sendable {
    public var identifier: String
    public var method: DockerHTTPMethod
    public var pattern: DockerRoutePattern
    public var introduced: DockerAPIVersion
    public var responseMode: DockerRouteResponseMode
    public var disposition: DockerRouteDisposition

    public init(
        identifier: String,
        method: DockerHTTPMethod,
        pattern: DockerRoutePattern,
        introduced: DockerAPIVersion,
        responseMode: DockerRouteResponseMode,
        disposition: DockerRouteDisposition
    ) {
        self.identifier = identifier
        self.method = method
        self.pattern = pattern
        self.introduced = introduced
        self.responseMode = responseMode
        self.disposition = disposition
    }
}

public struct DockerRouteMatch: Sendable {
    public let metadata: DockerRouteMetadata
    public let target: DockerRequestTarget
    public let parameters: [String: String]

    public init(
        metadata: DockerRouteMetadata,
        target: DockerRequestTarget,
        parameters: [String: String]
    ) {
        self.metadata = metadata
        self.target = target
        self.parameters = parameters
    }
}

public struct DockerRouteLedger: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let minimumAPIVersion: DockerAPIVersion
    public let maximumAPIVersion: DockerAPIVersion
    public let routes: [DockerRouteMetadata]

    public init(
        minimumAPIVersion: DockerAPIVersion,
        maximumAPIVersion: DockerAPIVersion,
        routes: [DockerRouteMetadata]
    ) throws {
        guard minimumAPIVersion <= maximumAPIVersion else {
            throw DockerRoutingError.invalidLedgerVersionRange
        }
        var identifiers: Set<String> = []
        var signatures: Set<RouteSignature> = []
        for route in routes {
            guard
                !route.identifier.isEmpty,
                route.identifier.allSatisfy({
                    $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
                })
            else {
                throw DockerRoutingError.invalidRouteIdentifier(route.identifier)
            }
            guard identifiers.insert(route.identifier).inserted else {
                throw DockerRoutingError.duplicateRouteIdentifier(route.identifier)
            }
            let signature = RouteSignature(
                method: route.method,
                path: route.pattern.signature
            )
            guard signatures.insert(signature).inserted else {
                throw DockerRoutingError.duplicateRouteSignature(
                    route.method,
                    route.pattern.signature
                )
            }
            guard route.introduced <= maximumAPIVersion else {
                throw DockerRoutingError.routeIntroducedAfterMaximum(route.identifier)
            }
        }

        schemaVersion = Self.currentSchemaVersion
        self.minimumAPIVersion = minimumAPIVersion
        self.maximumAPIVersion = maximumAPIVersion
        self.routes = routes
    }

    public func match(_ request: DockerHTTPRequest) throws -> DockerRouteMatch? {
        let target = try DockerRequestTarget(request.target)
        if let version = target.apiVersion,
           version < minimumAPIVersion || version > maximumAPIVersion
        {
            throw DockerRoutingError.unsupportedAPIVersion(version)
        }
        let requestedVersion = target.apiVersion ?? maximumAPIVersion
        for route in routes where route.method == request.method {
            guard
                route.introduced <= requestedVersion,
                let parameters = route.pattern.match(target)
            else {
                continue
            }
            return DockerRouteMatch(
                metadata: route,
                target: target,
                parameters: parameters
            )
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case maximumAPIVersion
        case minimumAPIVersion
        case routes
        case schemaVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported Docker route ledger schema \(schemaVersion)"
            )
        }
        do {
            try self.init(
                minimumAPIVersion: container.decode(
                    DockerAPIVersion.self,
                    forKey: .minimumAPIVersion
                ),
                maximumAPIVersion: container.decode(
                    DockerAPIVersion.self,
                    forKey: .maximumAPIVersion
                ),
                routes: container.decode(
                    [DockerRouteMetadata].self,
                    forKey: .routes
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .routes,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }
}

private struct RouteSignature: Hashable {
    let method: DockerHTTPMethod
    let path: String
}
