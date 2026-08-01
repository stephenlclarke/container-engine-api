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

public struct DockerAPIVersion:
    Codable,
    Comparable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) throws {
        guard major >= 0, minor >= 0 else {
            throw DockerRoutingError.invalidAPIVersion("\(major).\(minor)")
        }
        self.major = major
        self.minor = minor
    }

    public init(_ value: String) throws {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard
            components.count == 2,
            components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
            let major = Int(components[0]),
            let minor = Int(components[1])
        else {
            throw DockerRoutingError.invalidAPIVersion(value)
        }
        try self.init(major: major, minor: minor)
    }

    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: DockerAPIVersion, rhs: DockerAPIVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid Docker API version \(value)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct DockerRequestTarget: Equatable, Sendable {
    public let original: String
    public let apiVersion: DockerAPIVersion?
    public let path: String
    public let segments: [String]
    public let query: [String: [String]]

    public init(_ target: String) throws {
        let queryMarker = target.firstIndex(of: "?")
        let rawPath = String(target[..<(queryMarker ?? target.endIndex)])
        guard
            target.hasPrefix("/"),
            let components = URLComponents(string: target),
            components.scheme == nil,
            components.host == nil,
            components.fragment == nil,
            !components.percentEncodedPath.isEmpty,
            Self.invalidPercentEscape(in: rawPath) == nil
        else {
            throw DockerRoutingError.invalidRequestTarget(target)
        }

        original = target
        let encodedSegments = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        var routeSegments = encodedSegments
        if let first = routeSegments.first,
           first.hasPrefix("v"),
           first.dropFirst().contains(".")
        {
            apiVersion = try DockerAPIVersion(String(first.dropFirst()))
            routeSegments.removeFirst()
        } else {
            apiVersion = nil
        }

        path = routeSegments.isEmpty ? "/" : "/" + routeSegments.joined(separator: "/")
        segments = try routeSegments.map { value in
            guard let decoded = value.removingPercentEncoding else {
                throw DockerRoutingError.invalidRequestTarget(target)
            }
            return decoded
        }
        let encodedQuery = queryMarker.map { queryMarker in
            String(target[target.index(after: queryMarker)...])
        }
        query = try Self.parseFormQuery(encodedQuery)
    }

    public func first(_ name: String) -> String? {
        query[name]?.first
    }

    private static func parseFormQuery(
        _ encodedQuery: String?
    ) throws -> [String: [String]] {
        guard let encodedQuery, !encodedQuery.isEmpty else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for field in encodedQuery.split(
            separator: "&",
            omittingEmptySubsequences: true
        ) {
            guard !field.contains(";") else {
                throw DockerRoutingError.invalidQuery(
                    "invalid semicolon separator in query"
                )
            }
            let parts = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let name = try formDecode(String(parts[0]))
            let value = try formDecode(parts.count == 2 ? String(parts[1]) : "")
            result[name, default: []].append(value)
        }
        return result
    }

    private static func formDecode(_ value: String) throws -> String {
        if let escape = invalidPercentEscape(in: value) {
            throw DockerRoutingError.invalidQuery(
                "invalid URL escape \"\(escape)\""
            )
        }
        guard
            let decoded = value.replacingOccurrences(
                of: "+",
                with: " "
            ).removingPercentEncoding
        else {
            throw DockerRoutingError.invalidQuery("invalid UTF-8 in query")
        }
        return decoded
    }

    private static func invalidPercentEscape(in value: String) -> String? {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard
                    index + 2 < bytes.count,
                    isHexadecimal(bytes[index + 1]),
                    isHexadecimal(bytes[index + 2])
                else {
                    let end = min(index + 3, bytes.count)
                    return String(decoding: bytes[index ..< end], as: UTF8.self)
                }
                index += 3
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func isHexadecimal(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "A") ... UInt8(ascii: "F"),
             UInt8(ascii: "a") ... UInt8(ascii: "f"):
            true
        default:
            false
        }
    }
}

public struct DockerRoutePattern: Codable, Hashable, Sendable {
    private enum Segment: Hashable, Sendable {
        case literal(String)
        case parameter(String)
    }

    public let template: String
    private let segments: [Segment]

    public init(_ template: String) throws {
        guard template.hasPrefix("/"), !template.contains("?") else {
            throw DockerRoutingError.invalidRoutePattern(template)
        }
        let values = template.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        var names: Set<String> = []
        var parsed: [Segment] = []
        for value in values {
            if value.hasPrefix("{"), value.hasSuffix("}") {
                let name = String(value.dropFirst().dropLast())
                guard
                    !name.isEmpty,
                    !name.contains("{"),
                    !name.contains("}"),
                    names.insert(name).inserted
                else {
                    throw DockerRoutingError.invalidRoutePattern(template)
                }
                parsed.append(.parameter(name))
            } else {
                guard
                    !value.contains("{"),
                    !value.contains("}"),
                    let decoded = value.removingPercentEncoding
                else {
                    throw DockerRoutingError.invalidRoutePattern(template)
                }
                parsed.append(.literal(decoded))
            }
        }
        self.template = template
        segments = parsed
    }

    public var signature: String {
        guard !segments.isEmpty else {
            return "/"
        }
        return "/" + segments.map { segment in
            switch segment {
            case let .literal(value):
                value
            case .parameter:
                "{}"
            }
        }.joined(separator: "/")
    }

    public func match(_ target: DockerRequestTarget) -> [String: String]? {
        guard target.segments.count == segments.count else {
            return nil
        }
        var parameters: [String: String] = [:]
        for (pattern, actual) in zip(segments, target.segments) {
            switch pattern {
            case let .literal(expected):
                guard expected == actual else {
                    return nil
                }
            case let .parameter(name):
                parameters[name] = actual
            }
        }
        return parameters
    }

    func isMoreSpecific(than other: DockerRoutePattern) -> Bool {
        for (candidate, current) in zip(segments, other.segments) {
            switch (candidate, current) {
            case (.literal, .parameter):
                return true
            case (.parameter, .literal):
                return false
            case (.literal, .literal), (.parameter, .parameter):
                continue
            }
        }
        return segments.count > other.segments.count
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid Docker route pattern \(value)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(template)
    }
}

public enum DockerRoutingError: Error, Equatable, CustomStringConvertible, Sendable {
    case duplicateRouteIdentifier(String)
    case duplicateRouteSignature(DockerHTTPMethod, String)
    case invalidAPIVersion(String)
    case invalidLedgerVersionRange
    case invalidQuery(String)
    case invalidRequestTarget(String)
    case invalidRouteIdentifier(String)
    case invalidRoutePattern(String)
    case invalidRouteVersionInterval(String)
    case routeIntroducedAfterMaximum(String)
    case routeRemovedAtOrBeforeMinimum(String)
    case unsupportedAPIVersion(DockerAPIVersion)

    public var description: String {
        switch self {
        case let .duplicateRouteIdentifier(identifier):
            "duplicate Docker route identifier \(identifier)"
        case let .duplicateRouteSignature(method, path):
            "duplicate Docker route signature \(method.rawValue) \(path)"
        case let .invalidAPIVersion(value):
            "invalid Docker API version \(value)"
        case .invalidLedgerVersionRange:
            "Docker route ledger minimum version exceeds its maximum version"
        case let .invalidQuery(message):
            message
        case let .invalidRequestTarget(target):
            "invalid Docker request target \(target)"
        case let .invalidRouteIdentifier(identifier):
            "invalid Docker route identifier \(identifier)"
        case let .invalidRoutePattern(pattern):
            "invalid Docker route pattern \(pattern)"
        case let .invalidRouteVersionInterval(identifier):
            "Docker route \(identifier) has an empty or reversed API version interval"
        case let .routeIntroducedAfterMaximum(identifier):
            "Docker route \(identifier) was introduced after the ledger maximum version"
        case let .routeRemovedAtOrBeforeMinimum(identifier):
            "Docker route \(identifier) was removed at or before the ledger minimum version"
        case let .unsupportedAPIVersion(version):
            "unsupported Docker API version \(version)"
        }
    }
}
