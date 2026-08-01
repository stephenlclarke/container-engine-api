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

public enum DockerHTTPMethod: String, CaseIterable, Codable, Sendable {
    case delete = "DELETE"
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
}

public struct DockerHTTPRequest: Sendable {
    public var method: DockerHTTPMethod
    public var target: String
    public var headers: DockerHTTPHeaders
    public var body: Data

    public init(
        method: DockerHTTPMethod,
        target: String,
        headers: DockerHTTPHeaders = DockerHTTPHeaders(),
        body: Data = Data()
    ) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    public init(
        method: DockerHTTPMethod,
        target: String,
        uniqueHeaders: [String: String],
        body: Data = Data()
    ) throws {
        try self.init(
            method: method,
            target: target,
            headers: DockerHTTPHeaders(uniqueFields: uniqueHeaders),
            body: body
        )
    }

    public func headerValues(_ name: String) -> [String] {
        headers.values(for: name)
    }

    public func uniqueHeader(_ name: String) throws -> String? {
        try headers.uniqueValue(for: name)
    }
}

public protocol DockerHTTPResponder: Sendable {
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse
}

public enum DockerHTTPBody: Sendable {
    case bytes(Data)
    /// A pull-based stream whose producer is closed or cancelled with the HTTP request.
    case managedStream(any DockerHTTPStreamSession)
    case stream(AsyncThrowingStream<Data, any Error>)
    case hijack(any DockerHijackSession, terminal: Bool)
}

/// A bounded, cancellation-aware source for one streaming HTTP response.
///
/// The server requests at most one chunk at a time and does not request the
/// next chunk until the previous channel write completes. Implementations
/// therefore do not need an additional unbounded producer queue.
public protocol DockerHTTPStreamSession: Sendable {
    func nextChunk() async throws -> Data?
    func close() async
    func cancel() async
}

public struct DockerHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: DockerHTTPBody

    public init(
        status: Int,
        headers: [String: String] = [:],
        body: DockerHTTPBody = .bytes(Data())
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func empty(status: Int) -> DockerHTTPResponse {
        DockerHTTPResponse(status: status)
    }

    public static func text(
        _ text: String,
        status: Int = 200,
        contentType: String = "text/plain; charset=utf-8"
    ) -> DockerHTTPResponse {
        DockerHTTPResponse(
            status: status,
            headers: ["Content-Type": contentType],
            body: .bytes(Data(text.utf8))
        )
    }

    public static func json(
        _ value: some Encodable,
        status: Int = 200,
        encoder: JSONEncoder = DockerJSON.encoder
    ) throws -> DockerHTTPResponse {
        try DockerHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: .bytes(encoder.encode(value))
        )
    }
}

public struct DockerErrorEnvelope: Codable, Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public enum DockerJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum DockerStreamChannel: UInt8, Codable, Sendable {
    case standardInput = 0
    case standardOutput = 1
    case standardError = 2
    case systemError = 3
}

public struct DockerStreamFrame: Equatable, Sendable {
    public var channel: DockerStreamChannel
    public var data: Data

    public init(channel: DockerStreamChannel, data: Data) {
        self.channel = channel
        self.data = data
    }
}

public protocol DockerHijackSession: Sendable {
    var frames: AsyncThrowingStream<DockerStreamFrame, any Error> { get }

    func write(_ data: Data) async throws
    func closeStandardInput() async throws
    func wait() async throws -> Int32
    func cancel() async
}

public enum DockerStreamFraming {
    public enum FramingError: Error, Equatable, Sendable {
        case payloadTooLarge(Int)
    }

    public static func encode(
        _ frame: DockerStreamFrame,
        terminal: Bool
    ) throws -> Data {
        if terminal {
            return frame.data
        }

        guard frame.data.count <= UInt32.max else {
            throw FramingError.payloadTooLarge(frame.data.count)
        }
        var result = Data(capacity: frame.data.count + 8)
        result.append(frame.channel.rawValue)
        result.append(contentsOf: [0, 0, 0])
        var size = UInt32(frame.data.count).bigEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(frame.data)
        return result
    }
}
