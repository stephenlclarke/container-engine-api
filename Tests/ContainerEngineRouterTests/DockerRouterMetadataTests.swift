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
import Testing

@Test
func `request target separates API version path parameters and repeated query values`() throws {
    let target = try DockerRequestTarget(
        "/v1.53/containers/example%2Fname/json?label=first&label=second&empty"
    )

    #expect(try target.apiVersion == DockerAPIVersion("1.53"))
    #expect(target.path == "/containers/example%2Fname/json")
    #expect(target.segments == ["containers", "example/name", "json"])
    #expect(target.query["label"] == ["first", "second"])
    #expect(target.first("empty") == "")
}

@Test
func `route ledger matches versioned and unversioned requests`() throws {
    let metadata = try DockerRouteMetadata(
        identifier: "container.inspect",
        method: .get,
        pattern: DockerRoutePattern("/containers/{identifier}/json"),
        introduced: DockerAPIVersion("1.24"),
        responseMode: .bytes,
        disposition: .implemented
    )
    let ledger = try DockerRouteLedger(
        minimumAPIVersion: DockerAPIVersion("1.24"),
        maximumAPIVersion: DockerAPIVersion("1.53"),
        routes: [metadata]
    )

    let matched = try ledger.match(
        DockerHTTPRequest(
            method: .get,
            target: "/v1.53/containers/example%2Fname/json"
        )
    )
    let versioned = try #require(matched)
    #expect(versioned.metadata.identifier == "container.inspect")
    #expect(versioned.parameters == ["identifier": "example/name"])
    #expect(
        try ledger.match(
            DockerHTTPRequest(method: .get, target: "/containers/example/json")
        )?.parameters == ["identifier": "example"]
    )
}

@Test
func `ledger rejects ambiguous metadata`() throws {
    let first = try DockerRouteMetadata(
        identifier: "container.inspect",
        method: .get,
        pattern: DockerRoutePattern("/containers/{identifier}/json"),
        introduced: DockerAPIVersion("1.24"),
        responseMode: .bytes,
        disposition: .implemented
    )
    let collision = try DockerRouteMetadata(
        identifier: "container.inspect-alias",
        method: .get,
        pattern: DockerRoutePattern("/containers/{name}/json"),
        introduced: DockerAPIVersion("1.24"),
        responseMode: .bytes,
        disposition: .implemented
    )

    #expect(throws: DockerRoutingError.self) {
        try DockerRouteLedger(
            minimumAPIVersion: DockerAPIVersion("1.24"),
            maximumAPIVersion: DockerAPIVersion("1.53"),
            routes: [first, collision]
        )
    }
    #expect(throws: DockerRoutingError.self) {
        try DockerRouteLedger(
            minimumAPIVersion: DockerAPIVersion("1.24"),
            maximumAPIVersion: DockerAPIVersion("1.53"),
            routes: [first, first]
        )
    }
}

@Test
func `literal routes win independently of declaration order`() throws {
    let parameter = try DockerRouteMetadata(
        identifier: "container.inspect",
        method: .get,
        pattern: DockerRoutePattern("/containers/{identifier}"),
        introduced: DockerAPIVersion("1.24"),
        responseMode: .bytes,
        disposition: .implemented
    )
    let literal = try DockerRouteMetadata(
        identifier: "container.list-special",
        method: .get,
        pattern: DockerRoutePattern("/containers/json"),
        introduced: DockerAPIVersion("1.24"),
        responseMode: .bytes,
        disposition: .implemented
    )
    let request = DockerHTTPRequest(method: .get, target: "/containers/json")

    for routes in [[parameter, literal], [literal, parameter]] {
        let ledger = try DockerRouteLedger(
            minimumAPIVersion: DockerAPIVersion("1.24"),
            maximumAPIVersion: DockerAPIVersion("1.53"),
            routes: routes
        )
        #expect(try ledger.match(request)?.metadata.identifier == literal.identifier)
    }
}

@Test
func `route removal is an exclusive version bound`() throws {
    let metadata = try DockerRouteMetadata(
        identifier: "legacy.inspect",
        method: .get,
        pattern: DockerRoutePattern("/legacy/{identifier}"),
        introduced: DockerAPIVersion("1.30"),
        removed: DockerAPIVersion("1.40"),
        responseMode: .bytes,
        disposition: .implemented
    )
    let ledger = try DockerRouteLedger(
        minimumAPIVersion: DockerAPIVersion("1.24"),
        maximumAPIVersion: DockerAPIVersion("1.53"),
        routes: [metadata]
    )

    #expect(try ledger.match(
        DockerHTTPRequest(method: .get, target: "/v1.29/legacy/example")
    )?.metadata.identifier == nil)
    #expect(try ledger.match(
        DockerHTTPRequest(method: .get, target: "/v1.30/legacy/example")
    )?.metadata.identifier == metadata.identifier)
    #expect(try ledger.match(
        DockerHTTPRequest(method: .get, target: "/v1.39/legacy/example")
    )?.metadata.identifier == metadata.identifier)
    #expect(try ledger.match(
        DockerHTTPRequest(method: .get, target: "/v1.40/legacy/example")
    )?.metadata.identifier == nil)
    #expect(try ledger.match(
        DockerHTTPRequest(method: .get, target: "/legacy/example")
    )?.metadata.identifier == nil)
}

@Test
func `ledger rejects empty and nonintersecting route version intervals`() throws {
    let introduced = try DockerAPIVersion("1.30")

    for removed in try [introduced, DockerAPIVersion("1.29")] {
        let metadata = try DockerRouteMetadata(
            identifier: "legacy.inspect",
            method: .get,
            pattern: DockerRoutePattern("/legacy/{identifier}"),
            introduced: introduced,
            removed: removed,
            responseMode: .bytes,
            disposition: .implemented
        )
        #expect(throws: DockerRoutingError.invalidRouteVersionInterval(
            metadata.identifier
        )) {
            try DockerRouteLedger(
                minimumAPIVersion: DockerAPIVersion("1.24"),
                maximumAPIVersion: DockerAPIVersion("1.53"),
                routes: [metadata]
            )
        }
    }

    let alreadyRemoved = try DockerRouteMetadata(
        identifier: "removed.inspect",
        method: .get,
        pattern: DockerRoutePattern("/removed/{identifier}"),
        introduced: DockerAPIVersion("1.20"),
        removed: DockerAPIVersion("1.24"),
        responseMode: .bytes,
        disposition: .implemented
    )
    #expect(throws: DockerRoutingError.routeRemovedAtOrBeforeMinimum(
        alreadyRemoved.identifier
    )) {
        try DockerRouteLedger(
            minimumAPIVersion: DockerAPIVersion("1.24"),
            maximumAPIVersion: DockerAPIVersion("1.53"),
            routes: [alreadyRemoved]
        )
    }
}

@Test
func `ledger enforces its version range and schema`() throws {
    let metadata = try DockerRouteMetadata(
        identifier: "legacy.inspect",
        method: .get,
        pattern: DockerRoutePattern("/legacy/{identifier}"),
        introduced: DockerAPIVersion("1.24"),
        removed: DockerAPIVersion("1.40"),
        responseMode: .bytes,
        disposition: .implemented
    )
    let ledger = try DockerRouteLedger(
        minimumAPIVersion: DockerAPIVersion("1.24"),
        maximumAPIVersion: DockerAPIVersion("1.53"),
        routes: [metadata]
    )

    #expect(throws: DockerRoutingError.self) {
        try ledger.match(
            DockerHTTPRequest(method: .get, target: "/v1.54/_ping")
        )
    }
    #expect(throws: DockerRoutingError.self) {
        try ledger.match(
            DockerHTTPRequest(method: .get, target: "/v1.23/_ping")
        )
    }

    let encoded = try DockerJSON.encoder.encode(ledger)
    let decoded = try DockerJSON.decoder.decode(DockerRouteLedger.self, from: encoded)
    #expect(decoded.schemaVersion == DockerRouteLedger.currentSchemaVersion)
    #expect(decoded.minimumAPIVersion == ledger.minimumAPIVersion)
    #expect(decoded.maximumAPIVersion == ledger.maximumAPIVersion)
    #expect(decoded.routes == ledger.routes)
    #expect(decoded.routes.first?.removed == metadata.removed)

    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    for schemaVersion in [1, DockerRouteLedger.currentSchemaVersion + 1] {
        object["schemaVersion"] = schemaVersion
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try DockerJSON.decoder.decode(DockerRouteLedger.self, from: unsupported)
        }
    }
}

@Test
func `invalid versions targets and patterns fail closed`() {
    #expect(throws: DockerRoutingError.self) {
        try DockerAPIVersion("1.x")
    }
    #expect(throws: DockerRoutingError.self) {
        try DockerRequestTarget("v1.53/_ping")
    }
    #expect(throws: DockerRoutingError.self) {
        try DockerRoutePattern("containers/{identifier}")
    }
    #expect(throws: DockerRoutingError.self) {
        try DockerRoutePattern("/containers/{identifier}/{identifier}")
    }
}
