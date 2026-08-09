//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Darwin
import Foundation

enum ProviderHandoffPayloadPackageFileDecoder {
    static func decode(
        canonicalFileURL: URL,
        recordDirectoryURL: URL,
        expectedPartKind: ProviderHandoffPartKindV1,
        maximumCollectionEntries: Int,
        maximumCanonicalRecordBytes: Int
    ) throws -> ProviderHandoffPayloadPackageSourceV2 {
        guard
            canonicalFileURL.isFileURL,
            recordDirectoryURL.isFileURL,
            maximumCollectionEntries > 0,
            maximumCanonicalRecordBytes > 0
        else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let reader = try Reader(url: canonicalFileURL)
        defer { try? reader.close() }
        var recordURLs: [URL] = []
        var completed = false
        defer {
            if !completed {
                for url in recordURLs {
                    _ = url.path.withCString(Darwin.unlink)
                }
            }
        }

        guard try reader.argument(major: 5) == 3 else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        try reader.requireText("entries")
        let entryCount = try reader.boundedCount(
            major: 4,
            maximum: maximumCollectionEntries
        )
        guard entryCount > 0 else {
            throw ProviderHandoffPayloadCodecError.emptyPackage
        }
        var entries: [ProviderHandoffPayloadPackageEntrySourceV2] = []
        entries.reserveCapacity(entryCount)
        for index in 0 ..< entryCount {
            guard try reader.argument(major: 5) == 5 else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            try reader.requireText("entryID")
            let entryID = try reader.text()
            try reader.requireText("recordKind")
            let recordKind = try reader.text()
            try reader.requireText("schemaVersion")
            let encodedSchemaVersion = try reader.argument(major: 0)
            guard let schemaVersion = UInt32(exactly: encodedSchemaVersion) else {
                throw ProviderHandoffPayloadCodecError.invalidEntry(entryID)
            }
            try reader.requireText("sourceStateRootUUID")
            let sourceStateRootUUID = try reader.optionalText()
            try reader.requireText("canonicalRecordBytes")
            let byteLength = try reader.argument(major: 2)
            guard
                byteLength <= UInt64(maximumCanonicalRecordBytes),
                let recordLength = Int(exactly: byteLength)
            else {
                throw ProviderHandoffCanonicalCBORError.boundsExceeded
            }
            let recordURL = recordDirectoryURL.appendingPathComponent(
                String(format: "record-%08d-%@.cbor", index, UUID().uuidString),
                isDirectory: false
            )
            try reader.copy(count: recordLength, to: recordURL)
            recordURLs.append(recordURL)
            entries.append(
                ProviderHandoffPayloadPackageEntrySourceV2(
                    entryID: entryID,
                    sourceStateRootUUID: sourceStateRootUUID,
                    recordKind: recordKind,
                    schemaVersion: schemaVersion,
                    canonicalRecord: .file(
                        url: recordURL,
                        byteLength: byteLength
                    )
                )
            )
        }
        try reader.requireText("partKind")
        guard try reader.text() == expectedPartKind.rawValue else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        try reader.requireText("schemaVersion")
        guard
            try reader.argument(major: 0)
            == UInt64(ProviderHandoffPayloadPackageV1.currentSchemaVersion),
            try reader.isAtEnd()
        else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        completed = true
        return ProviderHandoffPayloadPackageSourceV2(
            partKind: expectedPartKind,
            entries: entries
        )
    }

    private final class Reader {
        private static let copyChunkBytes = 64 * 1024
        private static let maximumTextBytes = 1024 * 1024

        private let handle: FileHandle

        init(url: URL) throws {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            var metadata = stat()
            guard
                Darwin.fstat(descriptor, &metadata) == 0,
                (metadata.st_mode & S_IFMT) == S_IFREG,
                metadata.st_nlink == 1
            else {
                Darwin.close(descriptor)
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        func close() throws {
            try handle.close()
        }

        func isAtEnd() throws -> Bool {
            try handle.read(upToCount: 1)?.isEmpty != false
        }

        func requireText(_ expected: String) throws {
            guard try text() == expected else {
                throw ProviderHandoffPayloadCodecError.unexpectedKey(expected)
            }
        }

        func text() throws -> String {
            let length = try argument(major: 3)
            guard
                length <= UInt64(Self.maximumTextBytes),
                let count = Int(exactly: length),
                let value = try String(data: readExactly(count), encoding: .utf8),
                value.precomposedStringWithCanonicalMapping == value
            else {
                throw ProviderHandoffCanonicalCBORError.invalidText
            }
            return value
        }

        func optionalText() throws -> String? {
            let initial = try byte()
            if initial == 0xF6 {
                return nil
            }
            let length = try argument(initial: initial, major: 3)
            guard
                length <= UInt64(Self.maximumTextBytes),
                let count = Int(exactly: length),
                let value = try String(data: readExactly(count), encoding: .utf8),
                value.precomposedStringWithCanonicalMapping == value
            else {
                throw ProviderHandoffCanonicalCBORError.invalidText
            }
            return value
        }

        func boundedCount(major: UInt8, maximum: Int) throws -> Int {
            let value = try argument(major: major)
            guard value <= UInt64(maximum), let count = Int(exactly: value) else {
                throw ProviderHandoffCanonicalCBORError.boundsExceeded
            }
            return count
        }

        func argument(major: UInt8) throws -> UInt64 {
            try argument(initial: byte(), major: major)
        }

        func copy(count: Int, to url: URL) throws {
            let descriptor = url.path.withCString {
                Darwin.open(
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            let output = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: true
            )
            var completed = false
            defer {
                try? output.close()
                if !completed {
                    _ = url.path.withCString(Darwin.unlink)
                }
            }
            var remaining = count
            while remaining > 0 {
                let chunk = try readExactly(
                    min(Self.copyChunkBytes, remaining)
                )
                try output.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            try output.synchronize()
            try output.close()
            completed = true
        }

        private func argument(initial: UInt8, major: UInt8) throws -> UInt64 {
            guard initial >> 5 == major else {
                throw ProviderHandoffCanonicalCBORError.malformed
            }
            let additional = initial & 0x1F
            switch additional {
            case 0 ..< 24:
                return UInt64(additional)
            case 24:
                let value = try UInt64(byte())
                guard value >= 24 else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            case 25:
                let value = try UInt64(integer(UInt16.self))
                guard value > UInt8.max else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            case 26:
                let value = try UInt64(integer(UInt32.self))
                guard value > UInt16.max else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            case 27:
                let value = try integer(UInt64.self)
                guard value > UInt32.max else {
                    throw ProviderHandoffCanonicalCBORError.nonCanonical
                }
                return value
            default:
                throw ProviderHandoffCanonicalCBORError
                    .invalidAdditionalInformation(additional)
            }
        }

        private func byte() throws -> UInt8 {
            try readExactly(1)[0]
        }

        private func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let bytes = try readExactly(MemoryLayout<T>.size)
            return bytes.withUnsafeBytes { raw in
                raw.loadUnaligned(as: T.self).bigEndian
            }
        }

        private func readExactly(_ count: Int) throws -> Data {
            guard count >= 0 else {
                throw ProviderHandoffCanonicalCBORError.malformed
            }
            var output = Data()
            output.reserveCapacity(count)
            while output.count < count {
                let chunk = try handle.read(
                    upToCount: count - output.count
                ) ?? Data()
                guard !chunk.isEmpty else {
                    throw ProviderHandoffCanonicalCBORError.malformed
                }
                output.append(chunk)
            }
            return output
        }
    }
}
