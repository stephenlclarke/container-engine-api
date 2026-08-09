//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
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

import CryptoKit
import Foundation

public struct ProviderHandoffCanonicalMapEntry: Equatable, Sendable {
    public var key: String
    public var value: ProviderHandoffCanonicalValue

    public init(_ key: String, _ value: ProviderHandoffCanonicalValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum ProviderHandoffCanonicalValue: Equatable, Sendable {
    case unsigned(UInt64)
    /// Stores CBOR's encoded magnitude, where zero represents -1.
    case negative(UInt64)
    case byteString(Data)
    case textString(String)
    case array([ProviderHandoffCanonicalValue])
    case map([ProviderHandoffCanonicalMapEntry])
    case boolean(Bool)
    case null

    public static func optional(_ value: String?) -> Self {
        value.map(textString) ?? .null
    }

    public static func optional(_ value: UInt64?) -> Self {
        value.map(unsigned) ?? .null
    }

    public static func optional(_ value: ProviderHandoffCanonicalValue?) -> Self {
        value ?? .null
    }
}

public struct ProviderHandoffCBORLimits: Equatable, Sendable {
    public var maximumDepth: Int
    public var maximumCollectionEntries: Int
    public var maximumByteStringBytes: Int
    public var maximumTextStringBytes: Int

    public init(
        maximumDepth: Int = 64,
        maximumCollectionEntries: Int = 1_000_000,
        maximumByteStringBytes: Int = 64 * 1024 * 1024,
        maximumTextStringBytes: Int = 1024 * 1024
    ) {
        self.maximumDepth = maximumDepth
        self.maximumCollectionEntries = maximumCollectionEntries
        self.maximumByteStringBytes = maximumByteStringBytes
        self.maximumTextStringBytes = maximumTextStringBytes
    }
}

public enum ProviderHandoffCanonicalCBORError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case boundsExceeded
    case duplicateMapKey(String)
    case invalidAdditionalInformation(UInt8)
    case invalidMapKey
    case invalidText
    case malformed
    case nonCanonical
    case nonNFCText(String)
    case trailingBytes
    case unsupportedType(UInt8)

    public var description: String {
        switch self {
        case .boundsExceeded:
            "deterministic CBOR value exceeds its configured bound"
        case let .duplicateMapKey(key):
            "deterministic CBOR map contains duplicate key \(key)"
        case let .invalidAdditionalInformation(value):
            "deterministic CBOR contains invalid additional information \(value)"
        case .invalidMapKey:
            "deterministic CBOR maps require text-string keys"
        case .invalidText:
            "deterministic CBOR contains invalid UTF-8"
        case .malformed:
            "deterministic CBOR is malformed"
        case .nonCanonical:
            "CBOR input is not the deterministic v1 representation"
        case let .nonNFCText(value):
            "deterministic CBOR text is not NFC: \(value)"
        case .trailingBytes:
            "deterministic CBOR contains trailing bytes"
        case let .unsupportedType(value):
            "deterministic CBOR contains unsupported major type \(value)"
        }
    }
}

public enum ProviderHandoffCanonicalCBOR {
    public static func encode(_ value: ProviderHandoffCanonicalValue) throws -> Data {
        var output = Data()
        try append(value, to: &output, depth: 0)
        return output
    }

    public static func decode(
        _ data: Data,
        limits: ProviderHandoffCBORLimits = ProviderHandoffCBORLimits()
    ) throws -> ProviderHandoffCanonicalValue {
        var decoder = Decoder(data: data, limits: limits)
        let value = try decoder.decode(depth: 0)
        guard decoder.isAtEnd else {
            throw ProviderHandoffCanonicalCBORError.trailingBytes
        }
        guard try encode(value) == data else {
            throw ProviderHandoffCanonicalCBORError.nonCanonical
        }
        return value
    }

    private static func append(
        _ value: ProviderHandoffCanonicalValue,
        to output: inout Data,
        depth: Int
    ) throws {
        guard depth <= 64 else {
            throw ProviderHandoffCanonicalCBORError.boundsExceeded
        }
        switch value {
        case let .unsigned(number):
            appendMajor(0, value: number, to: &output)
        case let .negative(magnitude):
            appendMajor(1, value: magnitude, to: &output)
        case let .byteString(bytes):
            appendMajor(2, value: UInt64(bytes.count), to: &output)
            output.append(bytes)
        case let .textString(text):
            try validate(text)
            let bytes = Data(text.utf8)
            appendMajor(3, value: UInt64(bytes.count), to: &output)
            output.append(bytes)
        case let .array(values):
            appendMajor(4, value: UInt64(values.count), to: &output)
            for item in values {
                try append(item, to: &output, depth: depth + 1)
            }
        case let .map(entries):
            let sorted = try canonicalEntries(entries)
            appendMajor(5, value: UInt64(sorted.count), to: &output)
            for item in sorted {
                try append(.textString(item.entry.key), to: &output, depth: depth + 1)
                try append(item.entry.value, to: &output, depth: depth + 1)
            }
        case let .boolean(value):
            output.append(value ? 0xF5 : 0xF4)
        case .null:
            output.append(0xF6)
        }
    }

    private static func canonicalEntries(
        _ entries: [ProviderHandoffCanonicalMapEntry]
    ) throws -> [(entry: ProviderHandoffCanonicalMapEntry, encodedKey: Data)] {
        var seen = Set<String>()
        var encoded: [(ProviderHandoffCanonicalMapEntry, Data)] = []
        encoded.reserveCapacity(entries.count)
        for entry in entries {
            try validate(entry.key)
            guard seen.insert(entry.key).inserted else {
                throw ProviderHandoffCanonicalCBORError.duplicateMapKey(entry.key)
            }
            var keyBytes = Data()
            try append(.textString(entry.key), to: &keyBytes, depth: 0)
            encoded.append((entry, keyBytes))
        }
        return encoded.sorted { lhs, rhs in
            if lhs.1.count != rhs.1.count {
                return lhs.1.count < rhs.1.count
            }
            return lhs.1.lexicographicallyPrecedes(rhs.1)
        }
    }

    private static func validate(_ text: String) throws {
        guard
            Data(text.precomposedStringWithCanonicalMapping.utf8)
            == Data(text.utf8)
        else {
            throw ProviderHandoffCanonicalCBORError.nonNFCText(text)
        }
    }

    private static func appendMajor(_ major: UInt8, value: UInt64, to output: inout Data) {
        let prefix = major << 5
        switch value {
        case 0 ..< 24:
            output.append(prefix | UInt8(value))
        case 24 ... UInt64(UInt8.max):
            output.append(prefix | 24)
            output.append(UInt8(value))
        case 0 ... UInt64(UInt16.max):
            output.append(prefix | 25)
            appendBigEndian(UInt16(value), to: &output)
        case 0 ... UInt64(UInt32.max):
            output.append(prefix | 26)
            appendBigEndian(UInt32(value), to: &output)
        default:
            output.append(prefix | 27)
            appendBigEndian(value, to: &output)
        }
    }

    private static func appendBigEndian(_ value: some FixedWidthInteger, to output: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
    }

    private struct Decoder {
        let data: Data
        let limits: ProviderHandoffCBORLimits
        var offset = 0
        var totalCollectionEntries = 0

        var isAtEnd: Bool {
            offset == data.count
        }

        mutating func decode(depth: Int) throws -> ProviderHandoffCanonicalValue {
            guard depth <= limits.maximumDepth else {
                throw ProviderHandoffCanonicalCBORError.boundsExceeded
            }
            let initial = try readByte()
            let major = initial >> 5
            let additional = initial & 0x1F
            switch major {
            case 0:
                return try .unsigned(readArgument(additional))
            case 1:
                return try .negative(readArgument(additional))
            case 2:
                let count = try boundedCount(
                    readArgument(additional),
                    maximum: limits.maximumByteStringBytes
                )
                return try .byteString(read(count))
            case 3:
                let count = try boundedCount(
                    readArgument(additional),
                    maximum: limits.maximumTextStringBytes
                )
                let bytes = try read(count)
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw ProviderHandoffCanonicalCBORError.invalidText
                }
                try ProviderHandoffCanonicalCBOR.validate(text)
                return .textString(text)
            case 4:
                let count = try collectionCount(readArgument(additional))
                var values: [ProviderHandoffCanonicalValue] = []
                values.reserveCapacity(count)
                for _ in 0 ..< count {
                    try values.append(decode(depth: depth + 1))
                }
                return .array(values)
            case 5:
                let count = try collectionCount(readArgument(additional))
                var entries: [ProviderHandoffCanonicalMapEntry] = []
                entries.reserveCapacity(count)
                var seen = Set<String>()
                for _ in 0 ..< count {
                    guard case let .textString(key) = try decode(depth: depth + 1) else {
                        throw ProviderHandoffCanonicalCBORError.invalidMapKey
                    }
                    guard seen.insert(key).inserted else {
                        throw ProviderHandoffCanonicalCBORError.duplicateMapKey(key)
                    }
                    try entries.append(
                        ProviderHandoffCanonicalMapEntry(
                            key,
                            decode(depth: depth + 1)
                        )
                    )
                }
                return .map(entries)
            case 7:
                switch additional {
                case 20:
                    return .boolean(false)
                case 21:
                    return .boolean(true)
                case 22:
                    return .null
                default:
                    throw ProviderHandoffCanonicalCBORError.unsupportedType(initial)
                }
            default:
                throw ProviderHandoffCanonicalCBORError.unsupportedType(initial)
            }
        }

        private mutating func readArgument(_ additional: UInt8) throws -> UInt64 {
            switch additional {
            case 0 ..< 24:
                return UInt64(additional)
            case 24:
                let value = try UInt64(readByte())
                guard value >= 24 else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            case 25:
                let value = try UInt64(readInteger(UInt16.self))
                guard value > UInt8.max else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            case 26:
                let value = try UInt64(readInteger(UInt32.self))
                guard value > UInt16.max else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            case 27:
                let value = try readInteger(UInt64.self)
                guard value > UInt32.max else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            default:
                throw ProviderHandoffCanonicalCBORError.invalidAdditionalInformation(additional)
            }
        }

        private mutating func collectionCount(_ value: UInt64) throws -> Int {
            let count = try boundedCount(value, maximum: limits.maximumCollectionEntries)
            guard totalCollectionEntries <= limits.maximumCollectionEntries - count else {
                throw ProviderHandoffCanonicalCBORError.boundsExceeded
            }
            totalCollectionEntries += count
            return count
        }

        private func boundedCount(_ value: UInt64, maximum: Int) throws -> Int {
            guard value <= UInt64(maximum), value <= UInt64(Int.max) else {
                throw ProviderHandoffCanonicalCBORError.boundsExceeded
            }
            return Int(value)
        }

        private mutating func readByte() throws -> UInt8 {
            guard offset < data.count else {
                throw ProviderHandoffCanonicalCBORError.malformed
            }
            defer { offset += 1 }
            return data[offset]
        }

        private mutating func read(_ count: Int) throws -> Data {
            guard count >= 0, offset <= data.count - count else {
                throw ProviderHandoffCanonicalCBORError.malformed
            }
            defer { offset += count }
            return data.subdata(in: offset ..< (offset + count))
        }

        private mutating func readInteger<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let bytes = try read(MemoryLayout<T>.size)
            return bytes.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(as: T.self).bigEndian
            }
        }
    }
}

public enum ProviderHandoffDigest {
    public static func sha256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    public static func domain(
        _ domain: String,
        projection: ProviderHandoffCanonicalValue
    ) throws -> String {
        try hex(domainBytes(domain, projection: projection))
    }

    public static func domainBytes(
        _ domain: String,
        projection: ProviderHandoffCanonicalValue
    ) throws -> Data {
        guard domain.unicodeScalars.allSatisfy(\.isASCII) else {
            throw ProviderHandoffCanonicalCBORError.invalidText
        }
        var data = Data(domain.utf8)
        data.append(0)
        try data.append(ProviderHandoffCanonicalCBOR.encode(projection))
        return Data(SHA256.hash(data: data))
    }

    public static func hmacSHA256(key: Data, data: Data) -> String {
        let authentication = HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: key)
        )
        return hex(Data(authentication))
    }

    public static func parseSHA256(_ value: String) throws -> Data {
        guard value.count == 64, value == value.lowercased() else {
            throw ProviderHandoffCanonicalCBORError.malformed
        }
        var bytes = Data()
        bytes.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0 ..< 32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else {
                throw ProviderHandoffCanonicalCBORError.malformed
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
