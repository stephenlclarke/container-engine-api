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
import Foundation
import Testing

@Test
func `request headers preserve order spelling and case-insensitive duplicates`() throws {
    let request = DockerHTTPRequest(
        method: .get,
        target: "/_ping",
        headers: DockerHTTPHeaders([
            .init(name: "X-Registry-Auth", value: "first"),
            .init(name: "x-registry-auth", value: "second"),
            .init(name: "X-Other", value: "fixture")
        ])
    )

    #expect(request.headers.map(\.name) == [
        "X-Registry-Auth",
        "x-registry-auth",
        "X-Other"
    ])
    #expect(request.headerValues("X-REGISTRY-AUTH") == ["first", "second"])
    #expect(throws: DockerHTTPHeaderError.ambiguousValue(
        name: "x-registry-auth",
        count: 2
    )) {
        try request.uniqueHeader("x-registry-auth")
    }
    #expect(try request.uniqueHeader("x-other") == "fixture")
    #expect(try request.uniqueHeader("missing") == nil)
}

@Test
func `dictionary header convenience rejects case-insensitive duplicates`() throws {
    #expect(throws: DockerHTTPHeaderError.duplicateUniqueName("x-request-id")) {
        try DockerHTTPHeaders(uniqueFields: [
            "X-Request-ID": "first",
            "x-request-id": "second"
        ])
    }

    let request = try DockerHTTPRequest(
        method: .get,
        target: "/_ping",
        uniqueHeaders: [
            "X-Zeta": "last",
            "X-Alpha": "first"
        ]
    )
    #expect(request.headers.map(\.name) == ["X-Alpha", "X-Zeta"])
}

@Test
func `Docker JSON output is stable and does not escape slashes`() throws {
    struct Payload: Encodable {
        let z = 1
        let path = "/containers/example"
    }

    let response = try DockerHTTPResponse.json(Payload())
    #expect(response.status == 200)
    #expect(response.headers["Content-Type"] == "application/json")
    guard case let .bytes(data) = response.body else {
        Issue.record("expected byte response")
        return
    }
    #expect(String(decoding: data, as: UTF8.self) == #"{"path":"/containers/example","z":1}"#)
}

@Test
func `non-terminal frames use Docker multiplex headers`() throws {
    let payload = Data("error".utf8)
    let framed = try DockerStreamFraming.encode(
        DockerStreamFrame(channel: .standardError, data: payload),
        terminal: false
    )

    #expect(Array(framed.prefix(4)) == [2, 0, 0, 0])
    #expect(Array(framed[4 ..< 8]) == [0, 0, 0, 5])
    #expect(Data(framed.dropFirst(8)) == payload)
}

@Test
func `terminal frames remain raw`() throws {
    let payload = Data("raw".utf8)

    #expect(
        try DockerStreamFraming.encode(
            DockerStreamFrame(channel: .standardOutput, data: payload),
            terminal: true
        ) == payload
    )
}
