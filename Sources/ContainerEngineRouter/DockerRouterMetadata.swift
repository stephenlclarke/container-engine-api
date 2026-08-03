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
    /// The first API version where the route is no longer available.
    public var removed: DockerAPIVersion?
    public var responseMode: DockerRouteResponseMode
    public var disposition: DockerRouteDisposition

    public init(
        identifier: String,
        method: DockerHTTPMethod,
        pattern: DockerRoutePattern,
        introduced: DockerAPIVersion,
        removed: DockerAPIVersion? = nil,
        responseMode: DockerRouteResponseMode,
        disposition: DockerRouteDisposition
    ) {
        self.identifier = identifier
        self.method = method
        self.pattern = pattern
        self.introduced = introduced
        self.removed = removed
        self.responseMode = responseMode
        self.disposition = disposition
    }

    public func isAvailable(in version: DockerAPIVersion) -> Bool {
        introduced <= version && removed.map { version < $0 } != false
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
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let minimumAPIVersion: DockerAPIVersion
    public let maximumAPIVersion: DockerAPIVersion
    public let routes: [DockerRouteMetadata]
    private let matchingRouteIndexes: [Int]

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
            if let removed = route.removed {
                guard route.introduced < removed else {
                    throw DockerRoutingError.invalidRouteVersionInterval(
                        route.identifier
                    )
                }
                guard removed > minimumAPIVersion else {
                    throw DockerRoutingError.routeRemovedAtOrBeforeMinimum(
                        route.identifier
                    )
                }
            }
        }

        schemaVersion = Self.currentSchemaVersion
        self.minimumAPIVersion = minimumAPIVersion
        self.maximumAPIVersion = maximumAPIVersion
        self.routes = routes
        matchingRouteIndexes = routes.indices.sorted { lhs, rhs in
            Self.hasMatchingPriority(routes[lhs], over: routes[rhs])
        }
    }

    public func match(_ request: DockerHTTPRequest) throws -> DockerRouteMatch? {
        let target = try DockerRequestTarget(request.target)
        let candidates: [(DockerRouteMetadata, [String: String])] = matchingRouteIndexes
            .compactMap { index in
                let route = routes[index]
                guard
                    route.method == request.method,
                    let parameters = route.pattern.match(target)
                else {
                    return nil
                }
                return (route, parameters)
            }
        guard !candidates.isEmpty else {
            return nil
        }
        if let version = target.apiVersion,
           version < minimumAPIVersion || version > maximumAPIVersion
        {
            throw DockerRoutingError.unsupportedAPIVersion(version)
        }
        let requestedVersion = target.apiVersion ?? maximumAPIVersion
        for (route, parameters) in candidates {
            guard route.isAvailable(in: requestedVersion) else {
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

    private static func hasMatchingPriority(
        _ candidate: DockerRouteMetadata,
        over other: DockerRouteMetadata
    ) -> Bool {
        if candidate.pattern.isMoreSpecific(than: other.pattern) {
            return true
        }
        if other.pattern.isMoreSpecific(than: candidate.pattern) {
            return false
        }
        if candidate.method != other.method {
            return candidate.method.rawValue < other.method.rawValue
        }
        if candidate.pattern.template != other.pattern.template {
            return candidate.pattern.template < other.pattern.template
        }
        return candidate.identifier < other.identifier
    }
}

private struct RouteSignature: Hashable {
    let method: DockerHTTPMethod
    let path: String
}
