//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import Foundation
import Testing

@Suite("Container resource intent v2 wire contract")
struct ContainerResourceIntentV2Tests {
    @Test
    func `engine API socket intent has the Docker-visible canonical path`() throws {
        let intent = try InboundUnixSocketIntentV1.engineAPI()

        #expect(intent.kind == .engineAPI)
        #expect(intent.target.value == "/var/run/docker.sock")
        #expect(intent.inspectSource == "/var/run/docker.sock")
        #expect(
            ContainerEngineProviderCapability.inboundUnixSocketV1Identifier
                == "io.github.stephenlclarke.container.inbound-unix-socket.v1"
        )
    }

    @Test
    func `engine API socket intent round trips without a host broker path`() throws {
        let intent = try InboundUnixSocketIntentV1.engineAPI()
        let data = try JSONEncoder().encode(intent)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(try JSONDecoder().decode(InboundUnixSocketIntentV1.self, from: data) == intent)
        #expect(object["target"] as? String == "/var/run/docker.sock")
        #expect(object["inspectSource"] as? String == "/var/run/docker.sock")
        #expect(object.values.allSatisfy { !(($0 as? String)?.contains("/tmp/") ?? false) })
    }

    @Test(
        arguments: [
            "",
            "/",
            "var/run/docker.sock",
            "/var//run/docker.sock",
            "/var/./run/docker.sock",
            "/var/lib/../run/docker.sock",
            "/var/run/docker.sock/",
            "/var/run/docker.sock\u{0}ignored"
        ]
    )
    func `absolute guest paths reject aliases and unsafe encodings`(_ value: String) {
        #expect(throws: ContainerResourceIntentError.self) {
            try AbsoluteGuestPath(value)
        }
    }

    @Test
    func `engine API projection rejects a caller-selected path`() throws {
        #expect(throws: ContainerResourceIntentError.self) {
            try InboundUnixSocketIntentV1(
                kind: .engineAPI,
                target: AbsoluteGuestPath("/run/private.sock"),
                inspectSource: "/run/private.sock"
            )
        }
    }

    @Test
    func `decoder enforces the same canonical engine projection`() {
        let data = Data(
            #"{"kind":"engineAPI","target":"/run/private.sock","inspectSource":"/run/private.sock"}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(InboundUnixSocketIntentV1.self, from: data)
        }
    }
}
