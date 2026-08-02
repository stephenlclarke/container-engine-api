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

public enum DockerHTTPHeaderError: Error, Equatable, Sendable {
    case ambiguousValue(name: String, count: Int)
    case duplicateUniqueName(String)
}

/// Runtime-neutral HTTP fields that preserve wire spelling, order, and duplicates.
public struct DockerHTTPHeaders: Equatable, RandomAccessCollection, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    private var storage: [Field]

    public init(_ fields: [Field] = []) {
        storage = fields
    }

    /// Convenience for callers that already have unique fields.
    ///
    /// A dictionary cannot express repeated fields or their wire order. This
    /// initializer rejects names that collide case-insensitively and sorts the
    /// remaining fields for deterministic construction.
    public init(uniqueFields: [String: String]) throws {
        var normalizedNames: Set<String> = []
        for name in uniqueFields.keys {
            let normalized = Self.normalized(name)
            guard normalizedNames.insert(normalized).inserted else {
                throw DockerHTTPHeaderError.duplicateUniqueName(normalized)
            }
        }
        storage = uniqueFields
            .map(Field.init(name:value:))
            .sorted { lhs, rhs in
                let lhsName = Self.normalized(lhs.name)
                let rhsName = Self.normalized(rhs.name)
                return lhsName == rhsName ? lhs.name < rhs.name : lhsName < rhsName
            }
    }

    public var startIndex: Int {
        storage.startIndex
    }

    public var endIndex: Int {
        storage.endIndex
    }

    public subscript(position: Int) -> Field {
        storage[position]
    }

    public func index(after index: Int) -> Int {
        storage.index(after: index)
    }

    public func index(before index: Int) -> Int {
        storage.index(before: index)
    }

    public mutating func append(name: String, value: String) {
        storage.append(Field(name: name, value: value))
    }

    /// Returns every case-insensitive match in its original wire order.
    public func values(for name: String) -> [String] {
        let normalized = Self.normalized(name)
        return storage.compactMap { field in
            Self.normalized(field.name) == normalized ? field.value : nil
        }
    }

    /// Returns a value only when the field is absent or appears exactly once.
    ///
    /// Security-sensitive consumers should use this API instead of selecting
    /// the first or last value from ``values(for:)``.
    public func uniqueValue(for name: String) throws -> String? {
        let matches = values(for: name)
        guard matches.count <= 1 else {
            throw DockerHTTPHeaderError.ambiguousValue(
                name: name,
                count: matches.count
            )
        }
        return matches.first
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
    }
}
