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
import Darwin
import Foundation

public struct ProviderHandoffLineageKeyV1: Equatable, Sendable {
    public var sourceStateRootUUID: String
    public var authorityLineageUUID: String
    public var keyVersion: UInt64
    public var rawHMACSHA256Key: Data

    public init(
        sourceStateRootUUID: String,
        authorityLineageUUID: String,
        keyVersion: UInt64,
        rawHMACSHA256Key: Data
    ) {
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.keyVersion = keyVersion
        self.rawHMACSHA256Key = rawHMACSHA256Key
    }
}

public struct ProviderHandoffPreparedPayloadV1: Equatable, Sendable {
    public var descriptor: ProviderHandoffPayloadDescriptorV1
    public var transportBytes: Data

    public init(descriptor: ProviderHandoffPayloadDescriptorV1, transportBytes: Data) {
        self.descriptor = descriptor
        self.transportBytes = transportBytes
    }
}

/// A prepared payload whose transport bytes remain file-backed. Framed v2
/// sealing bounds encryption and publication memory independently of the
/// aggregate payload size.
public struct ProviderHandoffPreparedPayloadFileV2: Equatable, Sendable {
    public var descriptor: ProviderHandoffPayloadDescriptorV1
    public var transportFileURL: URL

    public init(
        descriptor: ProviderHandoffPayloadDescriptorV1,
        transportFileURL: URL
    ) {
        self.descriptor = descriptor
        self.transportFileURL = transportFileURL.standardizedFileURL
    }
}

public enum ProviderHandoffPayloadRecordSourceV2: Equatable, Sendable {
    case data(Data)
    case file(url: URL, byteLength: UInt64)
}

public struct ProviderHandoffPayloadPackageEntrySourceV2: Equatable, Sendable {
    public var entryID: String
    public var sourceStateRootUUID: String?
    public var recordKind: String
    public var schemaVersion: UInt32
    public var canonicalRecord: ProviderHandoffPayloadRecordSourceV2

    public init(
        entryID: String,
        sourceStateRootUUID: String?,
        recordKind: String,
        schemaVersion: UInt32,
        canonicalRecord: ProviderHandoffPayloadRecordSourceV2
    ) {
        self.entryID = entryID
        self.sourceStateRootUUID = sourceStateRootUUID
        self.recordKind = recordKind
        self.schemaVersion = schemaVersion
        self.canonicalRecord = canonicalRecord
    }

    public init(_ entry: ProviderHandoffPayloadPackageEntryV1) {
        self.init(
            entryID: entry.entryID,
            sourceStateRootUUID: entry.sourceStateRootUUID,
            recordKind: entry.recordKind,
            schemaVersion: entry.schemaVersion,
            canonicalRecord: .data(entry.canonicalRecordBytes)
        )
    }
}

public struct ProviderHandoffPayloadPackageSourceV2: Equatable, Sendable {
    public var schemaVersion: UInt32
    public var partKind: ProviderHandoffPartKindV1
    public var entries: [ProviderHandoffPayloadPackageEntrySourceV2]

    public init(
        schemaVersion: UInt32 = ProviderHandoffPayloadPackageV1.currentSchemaVersion,
        partKind: ProviderHandoffPartKindV1,
        entries: [ProviderHandoffPayloadPackageEntrySourceV2]
    ) {
        self.schemaVersion = schemaVersion
        self.partKind = partKind
        self.entries = entries
    }

    public init(_ package: ProviderHandoffPayloadPackageV1) {
        self.init(
            schemaVersion: package.schemaVersion,
            partKind: package.partKind,
            entries: package.entries.map(
                ProviderHandoffPayloadPackageEntrySourceV2.init
            )
        )
    }
}

public enum ProviderHandoffPayloadCodecError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case contentDigestMismatch
    case duplicateEntryID(String)
    case duplicateSource(String)
    case emptyPackage
    case invalidDescriptor
    case invalidEntry(String)
    case invalidLineageKey(String)
    case invalidMediaType
    case invalidPackage
    case invalidSource(String)
    case nonCanonicalOrder
    case transportDigestMismatch
    case unexpectedKey(String)

    public var description: String {
        switch self {
        case .contentDigestMismatch:
            "provider handoff payload content digest does not match"
        case let .duplicateEntryID(identifier):
            "provider handoff payload contains duplicate entry ID \(identifier)"
        case let .duplicateSource(identifier):
            "provider handoff payload contains duplicate source \(identifier)"
        case .emptyPackage:
            "provider handoff payload requires structured evidence"
        case .invalidDescriptor:
            "provider handoff payload descriptor is invalid"
        case let .invalidEntry(identifier):
            "provider handoff payload entry is invalid: \(identifier)"
        case let .invalidLineageKey(identifier):
            "provider handoff lineage key is invalid: \(identifier)"
        case .invalidMediaType:
            "provider handoff media type is invalid"
        case .invalidPackage:
            "provider handoff package is invalid"
        case let .invalidSource(identifier):
            "provider handoff payload source is invalid: \(identifier)"
        case .nonCanonicalOrder:
            "provider handoff payload entries are not in canonical source and ID order"
        case .transportDigestMismatch:
            "provider handoff payload transport digest does not match"
        case let .unexpectedKey(key):
            "provider handoff canonical map contains unexpected key \(key)"
        }
    }
}

public enum ProviderHandoffPayloadCodec {
    /// Framed sealing authenticates each bounded plaintext window separately.
    /// The descriptor commits to the aggregate plaintext length, so frame
    /// count and every frame boundary are deterministic and truncation-safe.
    public static let maximumSealedFramePlaintextBytes = 4 * 1024 * 1024

    public static func encode(
        _ package: ProviderHandoffPayloadPackageV1,
        sourceOrder: [String]
    ) throws -> Data {
        try validate(package, sourceOrder: sourceOrder)
        return try ProviderHandoffCanonicalCBOR.encode(packageProjection(package))
    }

    public static func decode(
        _ data: Data,
        expectedPartKind: ProviderHandoffPartKindV1,
        sourceOrder: [String]
    ) throws -> ProviderHandoffPayloadPackageV1 {
        let canonical = try ProviderHandoffCanonicalCBOR.decode(data)
        let map = try exactMap(canonical, keys: ["entries", "partKind", "schemaVersion"])
        guard
            try unsigned(map["schemaVersion"]) == UInt64(ProviderHandoffPayloadPackageV1.currentSchemaVersion),
            try text(map["partKind"]) == expectedPartKind.rawValue,
            case let .array(encodedEntries)? = map["entries"]
        else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let entries = try encodedEntries.map(decodeEntry)
        let package = ProviderHandoffPayloadPackageV1(
            partKind: expectedPartKind,
            entries: entries
        )
        try validate(package, sourceOrder: sourceOrder)
        return package
    }

    public static func prepareAuthenticated(
        _ package: ProviderHandoffPayloadPackageV1,
        mediaType: String,
        sourceOrder: [String] = []
    ) throws -> ProviderHandoffPreparedPayloadV1 {
        guard validMediaType(mediaType) else {
            throw ProviderHandoffPayloadCodecError.invalidMediaType
        }
        let canonical = try encode(package, sourceOrder: sourceOrder)
        let digest = try publicContentDigest(package, sourceOrder: sourceOrder)
        let transportDigest = ProviderHandoffDigest.sha256(canonical)
        let descriptor = ProviderHandoffPayloadDescriptorV1(
            bundleObjectID: "sha256:\(transportDigest)",
            mediaType: mediaType,
            schemaVersion: package.schemaVersion,
            canonicalEncoding: .deterministicCBORV1,
            canonicalPlaintextByteLength: UInt64(canonical.count),
            transportByteLength: UInt64(canonical.count),
            canonicalContentDigest: digest,
            transportDigestSHA256: transportDigest,
            protection: .authenticatedPlaintext,
            destinationEncryption: nil
        )
        return ProviderHandoffPreparedPayloadV1(
            descriptor: descriptor,
            transportBytes: canonical
        )
    }

    public static func prepareSealed(
        _ package: ProviderHandoffPayloadPackageV1,
        mediaType: String,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1],
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce suppliedNonce: Data? = nil,
        ephemeralPrivateKey suppliedEphemeralPrivateKey: Data? = nil
    ) throws -> ProviderHandoffPreparedPayloadV1 {
        guard
            validMediaType(mediaType),
            !tokenID.isEmpty,
            !manifestID.isEmpty,
            !destinationProviderFingerprint.isEmpty,
            canonicalUUID(destinationStateRootUUID) != nil,
            !destinationKeyID.isEmpty
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let canonical = try encode(package, sourceOrder: sourceOrder)
        let contentDigest = try sealedContentDigest(
            package,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: sourceOrder,
            lineageKeys: lineageKeys
        )
        let ephemeralPrivateKey =
            suppliedEphemeralPrivateKey
            ?? ProviderHandoffCrypto.generateX25519PrivateKey()
        let ephemeralPublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: ephemeralPrivateKey
        )
        let nonce = suppliedNonce ?? randomBytes(count: 24)
        let associated = ProviderHandoffAEADAssociatedDataV1(
            objectKind: .partPayload,
            tokenID: tokenID,
            manifestID: manifestID,
            objectLocalID: "part:\(package.partKind.rawValue)",
            partKind: package.partKind,
            mediaType: mediaType,
            payloadSchemaVersion: package.schemaVersion,
            canonicalPlaintextByteLength: UInt64(canonical.count),
            canonicalContentDigest: contentDigest,
            sourceStateRootUUID: nil,
            authorityLineageUUID: nil,
            lineageDigestKeyVersion: nil,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: .destinationPayloadEncryption,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce
        )
        try validatePartPayloadAssociatedData(associated)
        let associatedData = try associatedDataDigest(associated)
        let salt = try hkdfSalt(associated)
        let info = hkdfInfo(associatedData)
        let box = try ProviderHandoffCrypto.seal(
            canonical,
            destinationPublicKey: destinationPublicKey,
            nonce: nonce,
            salt: salt,
            info: info,
            associatedData: associatedData,
            ephemeralPrivateKey: ephemeralPrivateKey
        )
        guard box.ephemeralPublicKey == ephemeralPublicKey else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let associatedDigest = ProviderHandoffDigest.hex(associatedData)
        let transportDigest = ProviderHandoffDigest.sha256(box.ciphertext)
        let encryption = ProviderHandoffPayloadEncryptionV1(
            encryptionAlgorithm: .x25519HKDFSHA256XChaCha20Poly1305V1,
            destinationKeyPurpose: .destinationPayloadEncryption,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            associatedDataDigestSHA256: associatedDigest
        )
        let descriptor = ProviderHandoffPayloadDescriptorV1(
            bundleObjectID: "sha256:\(transportDigest)",
            mediaType: mediaType,
            schemaVersion: package.schemaVersion,
            canonicalEncoding: .deterministicCBORV1,
            canonicalPlaintextByteLength: UInt64(canonical.count),
            transportByteLength: UInt64(box.ciphertext.count),
            canonicalContentDigest: contentDigest,
            transportDigestSHA256: transportDigest,
            protection: .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1,
            destinationEncryption: encryption
        )
        return ProviderHandoffPreparedPayloadV1(
            descriptor: descriptor,
            transportBytes: box.ciphertext
        )
    }

    /// Seals the canonical v1 package into a file using independently
    /// authenticated bounded frames. This preserves deterministic CBOR and
    /// lineage content digests while avoiding an aggregate ciphertext buffer.
    public static func prepareSealedFile(
        _ package: ProviderHandoffPayloadPackageV1,
        transportFileURL: URL,
        mediaType: String,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1],
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce suppliedNonce: Data? = nil,
        ephemeralPrivateKey suppliedEphemeralPrivateKey: Data? = nil
    ) throws -> ProviderHandoffPreparedPayloadFileV2 {
        guard
            validMediaType(mediaType),
            !tokenID.isEmpty,
            !manifestID.isEmpty,
            !destinationProviderFingerprint.isEmpty,
            canonicalUUID(destinationStateRootUUID) != nil,
            !destinationKeyID.isEmpty
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let canonical = try encode(package, sourceOrder: sourceOrder)
        let canonicalLength = UInt64(canonical.count)
        let contentDigest = try sealedContentDigest(
            package,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: sourceOrder,
            lineageKeys: lineageKeys
        )
        let ephemeralPrivateKey =
            suppliedEphemeralPrivateKey
            ?? ProviderHandoffCrypto.generateX25519PrivateKey()
        let ephemeralPublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: ephemeralPrivateKey
        )
        let nonce = suppliedNonce ?? randomBytes(count: 24)
        let associated = ProviderHandoffAEADAssociatedDataV1(
            objectKind: .partPayload,
            tokenID: tokenID,
            manifestID: manifestID,
            objectLocalID: "part:\(package.partKind.rawValue)",
            partKind: package.partKind,
            mediaType: mediaType,
            payloadSchemaVersion: package.schemaVersion,
            canonicalPlaintextByteLength: canonicalLength,
            canonicalContentDigest: contentDigest,
            sourceStateRootUUID: nil,
            authorityLineageUUID: nil,
            lineageDigestKeyVersion: nil,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: .destinationPayloadEncryption,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce
        )
        try validatePartPayloadAssociatedData(associated)
        let associatedData = try associatedDataDigest(associated)
        let salt = try hkdfSalt(associated)
        let info = hkdfInfo(associatedData)
        let frameCount = try sealedFrameCount(canonicalPlaintextByteLength: canonicalLength)
        let expectedTransportLength = try sealedTransportByteLength(
            canonicalPlaintextByteLength: canonicalLength,
            frameCount: frameCount
        )
        let output = try createExclusiveFile(at: transportFileURL)
        var completed = false
        defer {
            try? output.close()
            if !completed {
                _ = transportFileURL.path.withCString(Darwin.unlink)
            }
        }
        var transportHash = SHA256()
        var transportLength: UInt64 = 0
        for frameIndex in 0..<frameCount {
            let lower = Int(frameIndex) * maximumSealedFramePlaintextBytes
            let upper = min(canonical.count, lower + maximumSealedFramePlaintextBytes)
            let plaintext = canonical.subdata(in: lower..<upper)
            let frameAssociatedData = framedAssociatedData(
                baseAssociatedData: associatedData,
                frameIndex: frameIndex,
                frameCount: frameCount,
                canonicalPlaintextByteLength: canonicalLength,
                framePlaintextByteLength: UInt64(plaintext.count)
            )
            let box = try ProviderHandoffCrypto.seal(
                plaintext,
                destinationPublicKey: destinationPublicKey,
                nonce: framedNonce(base: nonce, frameIndex: frameIndex),
                salt: salt,
                info: info,
                associatedData: frameAssociatedData,
                ephemeralPrivateKey: ephemeralPrivateKey
            )
            guard box.ephemeralPublicKey == ephemeralPublicKey else {
                throw ProviderHandoffPayloadCodecError.invalidDescriptor
            }
            try output.write(contentsOf: box.ciphertext)
            transportHash.update(data: box.ciphertext)
            transportLength += UInt64(box.ciphertext.count)
        }
        guard transportLength == expectedTransportLength else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        try output.synchronize()
        let transportDigest = ProviderHandoffDigest.hex(Data(transportHash.finalize()))
        let descriptor = ProviderHandoffPayloadDescriptorV1(
            bundleObjectID: "sha256:\(transportDigest)",
            mediaType: mediaType,
            schemaVersion: package.schemaVersion,
            canonicalEncoding: .deterministicCBORV1,
            canonicalPlaintextByteLength: canonicalLength,
            transportByteLength: transportLength,
            canonicalContentDigest: contentDigest,
            transportDigestSHA256: transportDigest,
            protection:
                .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2,
            destinationEncryption: ProviderHandoffPayloadEncryptionV1(
                encryptionAlgorithm:
                    .x25519HKDFSHA256XChaCha20Poly1305FramedV2,
                destinationKeyPurpose: .destinationPayloadEncryption,
                destinationKeyID: destinationKeyID,
                ephemeralPublicKey: ephemeralPublicKey,
                nonce: nonce,
                associatedDataDigestSHA256:
                    ProviderHandoffDigest.hex(associatedData)
            )
        )
        completed = true
        return ProviderHandoffPreparedPayloadFileV2(
            descriptor: descriptor,
            transportFileURL: transportFileURL
        )
    }

    /// File-backed package variant. Each canonical record is validated and
    /// streamed independently, so aggregate history bytes are never collected
    /// in a package-wide `Data` value.
    public static func prepareSealedFile(
        _ package: ProviderHandoffPayloadPackageSourceV2,
        transportFileURL: URL,
        mediaType: String,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1],
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce suppliedNonce: Data? = nil,
        ephemeralPrivateKey suppliedEphemeralPrivateKey: Data? = nil
    ) throws -> ProviderHandoffPreparedPayloadFileV2 {
        guard
            validMediaType(mediaType),
            !tokenID.isEmpty,
            !manifestID.isEmpty,
            !destinationProviderFingerprint.isEmpty,
            canonicalUUID(destinationStateRootUUID) != nil,
            !destinationKeyID.isEmpty
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        try validate(package, sourceOrder: sourceOrder)
        let canonicalFileURL = transportFileURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".provider-handoff-canonical-\(UUID().uuidString)",
                isDirectory: false
            )
        let canonicalOutput = try createExclusiveFile(at: canonicalFileURL)
        var canonicalCompleted = false
        defer {
            try? canonicalOutput.close()
            _ = canonicalFileURL.path.withCString { Darwin.unlink($0) }
        }
        var canonicalLength: UInt64 = 0
        try streamPackage(package) { bytes in
            let (next, overflow) = canonicalLength.addingReportingOverflow(
                UInt64(bytes.count)
            )
            guard !overflow else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            try canonicalOutput.write(contentsOf: bytes)
            canonicalLength = next
        }
        try canonicalOutput.synchronize()
        try canonicalOutput.close()
        canonicalCompleted = true
        guard canonicalCompleted, canonicalLength > 0 else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let contentDigest = try sealedContentDigest(
            package,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: sourceOrder,
            lineageKeys: lineageKeys
        )
        let canonical = try Data(
            contentsOf: canonicalFileURL,
            options: .mappedIfSafe
        )
        guard UInt64(canonical.count) == canonicalLength else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        return try prepareSealedCanonicalBytes(
            canonical,
            schemaVersion: package.schemaVersion,
            partKind: package.partKind,
            contentDigest: contentDigest,
            transportFileURL: transportFileURL,
            mediaType: mediaType,
            tokenID: tokenID,
            manifestID: manifestID,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyID: destinationKeyID,
            destinationPublicKey: destinationPublicKey,
            nonce: suppliedNonce,
            ephemeralPrivateKey: suppliedEphemeralPrivateKey
        )
    }

    /// Opens a framed payload through bounded authenticated windows. The
    /// canonical bytes remain file-backed until the existing v1 package
    /// decoder is invoked; callers may retain the file for a streaming entry
    /// decoder or remove it after this compatibility return path.
    public static func openSealedFile(
        _ payload: ProviderHandoffPreparedPayloadFileV2,
        canonicalFileURL: URL,
        expectedPartKind: ProviderHandoffPartKindV1,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1],
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationPrivateKey: Data
    ) throws -> ProviderHandoffPayloadPackageV1 {
        let descriptor = payload.descriptor
        guard
            descriptor.canonicalEncoding == .deterministicCBORV1,
            validMediaType(descriptor.mediaType),
            descriptor.bundleObjectID
                == "sha256:\(descriptor.transportDigestSHA256)",
            descriptor.protection
                == .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2,
            descriptor.schemaVersion
                == ProviderHandoffPayloadPackageV1.currentSchemaVersion,
            let encryption = descriptor.destinationEncryption,
            encryption.encryptionAlgorithm
                == .x25519HKDFSHA256XChaCha20Poly1305FramedV2,
            encryption.destinationKeyPurpose == .destinationPayloadEncryption
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let input = try openVerifiedRegularFile(
            at: payload.transportFileURL,
            expectedByteLength: descriptor.transportByteLength,
            expectedSHA256: descriptor.transportDigestSHA256
        )
        defer { try? input.close() }
        let associated = ProviderHandoffAEADAssociatedDataV1(
            objectKind: .partPayload,
            tokenID: tokenID,
            manifestID: manifestID,
            objectLocalID: "part:\(expectedPartKind.rawValue)",
            partKind: expectedPartKind,
            mediaType: descriptor.mediaType,
            payloadSchemaVersion: descriptor.schemaVersion,
            canonicalPlaintextByteLength:
                descriptor.canonicalPlaintextByteLength,
            canonicalContentDigest: descriptor.canonicalContentDigest,
            sourceStateRootUUID: nil,
            authorityLineageUUID: nil,
            lineageDigestKeyVersion: nil,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: encryption.destinationKeyPurpose,
            destinationKeyID: encryption.destinationKeyID,
            ephemeralPublicKey: encryption.ephemeralPublicKey,
            nonce: encryption.nonce
        )
        try validatePartPayloadAssociatedData(associated)
        let associatedData = try associatedDataDigest(associated)
        guard
            ProviderHandoffDigest.hex(associatedData)
                == encryption.associatedDataDigestSHA256
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let salt = try hkdfSalt(associated)
        let info = hkdfInfo(associatedData)
        let frameCount = try sealedFrameCount(
            canonicalPlaintextByteLength:
                descriptor.canonicalPlaintextByteLength
        )
        guard
            try sealedTransportByteLength(
                canonicalPlaintextByteLength:
                    descriptor.canonicalPlaintextByteLength,
                frameCount: frameCount
            ) == descriptor.transportByteLength
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let output = try createExclusiveFile(at: canonicalFileURL)
        var completed = false
        defer {
            try? output.close()
            if !completed {
                _ = canonicalFileURL.path.withCString(Darwin.unlink)
            }
        }
        var remainingPlaintext = descriptor.canonicalPlaintextByteLength
        for frameIndex in 0..<frameCount {
            let plaintextLength = min(
                UInt64(maximumSealedFramePlaintextBytes),
                remainingPlaintext
            )
            guard let ciphertextLength = Int(exactly: plaintextLength + 16) else {
                throw ProviderHandoffPayloadCodecError.invalidDescriptor
            }
            let ciphertext = try readExactly(input, count: ciphertextLength)
            let frameAssociatedData = framedAssociatedData(
                baseAssociatedData: associatedData,
                frameIndex: frameIndex,
                frameCount: frameCount,
                canonicalPlaintextByteLength:
                    descriptor.canonicalPlaintextByteLength,
                framePlaintextByteLength: plaintextLength
            )
            let plaintext = try ProviderHandoffCrypto.open(
                ProviderHandoffXChaChaSealedBox(
                    ephemeralPublicKey: encryption.ephemeralPublicKey,
                    nonce: framedNonce(
                        base: encryption.nonce,
                        frameIndex: frameIndex
                    ),
                    ciphertext: ciphertext
                ),
                destinationPrivateKey: destinationPrivateKey,
                salt: salt,
                info: info,
                associatedData: frameAssociatedData
            )
            guard UInt64(plaintext.count) == plaintextLength else {
                throw ProviderHandoffPayloadCodecError.invalidDescriptor
            }
            try output.write(contentsOf: plaintext)
            remainingPlaintext -= plaintextLength
        }
        guard
            remainingPlaintext == 0,
            try input.read(upToCount: 1)?.isEmpty != false
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        try output.synchronize()
        completed = true
        let canonical = try Data(
            contentsOf: canonicalFileURL,
            options: .mappedIfSafe
        )
        let package = try decode(
            canonical,
            expectedPartKind: expectedPartKind,
            sourceOrder: sourceOrder
        )
        let digest = try sealedContentDigest(
            package,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: sourceOrder,
            lineageKeys: lineageKeys
        )
        guard digest == descriptor.canonicalContentDigest else {
            throw ProviderHandoffPayloadCodecError.contentDigestMismatch
        }
        return package
    }

    public static func openAuthenticated(
        _ payload: ProviderHandoffPreparedPayloadV1,
        expectedPartKind: ProviderHandoffPartKindV1,
        sourceOrder: [String] = []
    ) throws -> ProviderHandoffPayloadPackageV1 {
        try validateTransport(payload)
        let descriptor = payload.descriptor
        guard
            descriptor.protection == .authenticatedPlaintext,
            descriptor.destinationEncryption == nil,
            descriptor.canonicalPlaintextByteLength == descriptor.transportByteLength,
            descriptor.schemaVersion == ProviderHandoffPayloadPackageV1.currentSchemaVersion
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let package = try decode(
            payload.transportBytes,
            expectedPartKind: expectedPartKind,
            sourceOrder: sourceOrder
        )
        let digest = try publicContentDigest(package, sourceOrder: sourceOrder)
        guard digest == descriptor.canonicalContentDigest else {
            throw ProviderHandoffPayloadCodecError.contentDigestMismatch
        }
        return package
    }

    public static func openSealed(
        _ payload: ProviderHandoffPreparedPayloadV1,
        expectedPartKind: ProviderHandoffPartKindV1,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1],
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationPrivateKey: Data
    ) throws -> ProviderHandoffPayloadPackageV1 {
        try validateTransport(payload)
        let descriptor = payload.descriptor
        guard
            descriptor.protection
                == .destinationSealedX25519HKDFSHA256XChaCha20Poly1305V1,
            descriptor.schemaVersion == ProviderHandoffPayloadPackageV1.currentSchemaVersion,
            let encryption = descriptor.destinationEncryption,
            encryption.encryptionAlgorithm
                == .x25519HKDFSHA256XChaCha20Poly1305V1,
            encryption.destinationKeyPurpose == .destinationPayloadEncryption
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let associated = ProviderHandoffAEADAssociatedDataV1(
            objectKind: .partPayload,
            tokenID: tokenID,
            manifestID: manifestID,
            objectLocalID: "part:\(expectedPartKind.rawValue)",
            partKind: expectedPartKind,
            mediaType: descriptor.mediaType,
            payloadSchemaVersion: descriptor.schemaVersion,
            canonicalPlaintextByteLength: descriptor.canonicalPlaintextByteLength,
            canonicalContentDigest: descriptor.canonicalContentDigest,
            sourceStateRootUUID: nil,
            authorityLineageUUID: nil,
            lineageDigestKeyVersion: nil,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: encryption.destinationKeyPurpose,
            destinationKeyID: encryption.destinationKeyID,
            ephemeralPublicKey: encryption.ephemeralPublicKey,
            nonce: encryption.nonce
        )
        try validatePartPayloadAssociatedData(associated)
        let associatedData = try associatedDataDigest(associated)
        guard
            ProviderHandoffDigest.hex(associatedData)
                == encryption.associatedDataDigestSHA256
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let canonical = try ProviderHandoffCrypto.open(
            ProviderHandoffXChaChaSealedBox(
                ephemeralPublicKey: encryption.ephemeralPublicKey,
                nonce: encryption.nonce,
                ciphertext: payload.transportBytes
            ),
            destinationPrivateKey: destinationPrivateKey,
            salt: hkdfSalt(associated),
            info: hkdfInfo(associatedData),
            associatedData: associatedData
        )
        guard UInt64(canonical.count) == descriptor.canonicalPlaintextByteLength else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let package = try decode(
            canonical,
            expectedPartKind: expectedPartKind,
            sourceOrder: sourceOrder
        )
        let digest = try sealedContentDigest(
            package,
            tokenID: tokenID,
            manifestID: manifestID,
            sourceOrder: sourceOrder,
            lineageKeys: lineageKeys
        )
        guard digest == descriptor.canonicalContentDigest else {
            throw ProviderHandoffPayloadCodecError.contentDigestMismatch
        }
        return package
    }

    public static func publicContentDigest(
        _ package: ProviderHandoffPayloadPackageV1,
        sourceOrder: [String] = []
    ) throws -> ProviderHandoffCanonicalContentDigestV1 {
        let canonical = try encode(package, sourceOrder: sourceOrder)
        var input = Data("container-handoff-public-content-v1".utf8)
        input.append(0)
        input.append(canonical)
        return ProviderHandoffCanonicalContentDigestV1(
            algorithm: .sha256,
            scope: .publicSHA256V1,
            orderedSourceDigests: [],
            digest: ProviderHandoffDigest.sha256(input)
        )
    }

    public static func sealedContentDigest(
        _ package: ProviderHandoffPayloadPackageV1,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1]
    ) throws -> ProviderHandoffCanonicalContentDigestV1 {
        try validate(package, sourceOrder: sourceOrder)
        guard package.entries.allSatisfy({ $0.sourceStateRootUUID != nil }) else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let keyBySource = try lineageKeyMap(lineageKeys, sourceOrder: sourceOrder)
        var sourceDigests: [ProviderHandoffContentSourceDigestV1] = []
        for source in sourceOrder {
            let entries = package.entries.filter { $0.sourceStateRootUUID == source }
            guard !entries.isEmpty else { continue }
            guard let key = keyBySource[source] else {
                throw ProviderHandoffPayloadCodecError.invalidLineageKey(source)
            }
            let projection: ProviderHandoffCanonicalValue = .map([
                .init("authorityLineageUUID", .textString(key.authorityLineageUUID)),
                .init("lineageDigestKeyVersion", .unsigned(key.keyVersion)),
                .init("manifestID", .textString(manifestID)),
                .init("orderedCompleteEntries", .array(entries.map(entryProjection))),
                .init("packageSchemaVersion", .unsigned(UInt64(package.schemaVersion))),
                .init("partKind", .textString(package.partKind.rawValue)),
                .init("sourceStateRootUUID", .textString(source)),
                .init("tokenID", .textString(tokenID)),
            ])
            var input = Data("container-handoff-source-content-v1".utf8)
            input.append(0)
            try input.append(ProviderHandoffCanonicalCBOR.encode(projection))
            sourceDigests.append(
                ProviderHandoffContentSourceDigestV1(
                    sourceStateRootUUID: source,
                    authorityLineageUUID: key.authorityLineageUUID,
                    lineageDigestKeyVersion: key.keyVersion,
                    orderedEntryIDs: entries.map(\.entryID),
                    sourceDigestHMACSHA256: ProviderHandoffDigest.hmacSHA256(
                        key: key.rawHMACSHA256Key,
                        data: input
                    )
                )
            )
        }
        guard !sourceDigests.isEmpty else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        if sourceDigests.count == 1 {
            return ProviderHandoffCanonicalContentDigestV1(
                algorithm: .lineageHMACSHA256V1,
                scope: .singleSourceLineageHMACSHA256V1,
                orderedSourceDigests: sourceDigests,
                digest: sourceDigests[0].sourceDigestHMACSHA256
            )
        }
        var aggregate = Data("container-handoff-multi-source-content-v1".utf8)
        aggregate.append(0)
        try aggregate.append(
            ProviderHandoffCanonicalCBOR.encode(
                .array(sourceDigests.map(sourceDigestProjection))
            )
        )
        return ProviderHandoffCanonicalContentDigestV1(
            algorithm: .orderedLineageHMACSHA256AggregateV1,
            scope: .multiSourceLineageHMACSHA256AggregateV1,
            orderedSourceDigests: sourceDigests,
            digest: ProviderHandoffDigest.sha256(aggregate)
        )
    }

    public static func associatedDataDigest(
        _ associatedData: ProviderHandoffAEADAssociatedDataV1
    ) throws -> Data {
        try ProviderHandoffDigest.domainBytes(
            "container-handoff-aead-associated-data-v1",
            projection: associatedDataProjection(associatedData)
        )
    }

    private static func validate(
        _ package: ProviderHandoffPayloadPackageV1,
        sourceOrder: [String]
    ) throws {
        guard
            package.schemaVersion == ProviderHandoffPayloadPackageV1.currentSchemaVersion,
            !package.entries.isEmpty
        else {
            throw package.entries.isEmpty
                ? ProviderHandoffPayloadCodecError.emptyPackage
                : ProviderHandoffPayloadCodecError.invalidPackage
        }
        let canonicalSources = try validatedSourceOrder(sourceOrder)
        let sourceIndexes = Dictionary(
            uniqueKeysWithValues: canonicalSources.enumerated().map { ($1, $0) }
        )
        var seenEntries = Set<String>()
        for entry in package.entries {
            guard
                !entry.entryID.isEmpty,
                !entry.recordKind.isEmpty,
                entry.schemaVersion > 0,
                entry.entryID.precomposedStringWithCanonicalMapping == entry.entryID,
                entry.recordKind.precomposedStringWithCanonicalMapping == entry.recordKind
            else {
                throw ProviderHandoffPayloadCodecError.invalidEntry(entry.entryID)
            }
            guard seenEntries.insert(entry.entryID).inserted else {
                throw ProviderHandoffPayloadCodecError.duplicateEntryID(entry.entryID)
            }
            _ = try ProviderHandoffCanonicalCBOR.decode(entry.canonicalRecordBytes)
            if let source = entry.sourceStateRootUUID {
                guard canonicalUUID(source) != nil, sourceIndexes[source] != nil else {
                    throw ProviderHandoffPayloadCodecError.invalidSource(source)
                }
            }
        }
        let sorted = package.entries.sorted { lhs, rhs in
            let lhsIndex = lhs.sourceStateRootUUID.flatMap { sourceIndexes[$0] } ?? Int.max
            let rhsIndex = rhs.sourceStateRootUUID.flatMap { sourceIndexes[$0] } ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.entryID.utf8.lexicographicallyPrecedes(rhs.entryID.utf8)
        }
        guard sorted == package.entries else {
            throw ProviderHandoffPayloadCodecError.nonCanonicalOrder
        }
    }

    private static func validateTransport(_ payload: ProviderHandoffPreparedPayloadV1) throws {
        let descriptor = payload.descriptor
        guard
            descriptor.canonicalEncoding == .deterministicCBORV1,
            validMediaType(descriptor.mediaType),
            UInt64(payload.transportBytes.count) == descriptor.transportByteLength,
            descriptor.bundleObjectID == "sha256:\(descriptor.transportDigestSHA256)"
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        guard
            ProviderHandoffDigest.sha256(payload.transportBytes)
                == descriptor.transportDigestSHA256
        else {
            throw ProviderHandoffPayloadCodecError.transportDigestMismatch
        }
    }

    private static func validatePartPayloadAssociatedData(
        _ value: ProviderHandoffAEADAssociatedDataV1
    ) throws {
        guard
            value.schemaVersion == 1,
            value.objectKind == .partPayload,
            let partKind = value.partKind,
            value.objectLocalID == "part:\(partKind.rawValue)",
            value.mediaType.map(validMediaType) == true,
            value.payloadSchemaVersion == 1,
            value.canonicalContentDigest != nil,
            value.sourceStateRootUUID == nil,
            value.authorityLineageUUID == nil,
            value.lineageDigestKeyVersion == nil,
            value.destinationKeyPurpose == .destinationPayloadEncryption,
            value.ephemeralPublicKey.count == 32,
            value.nonce.count == 24
        else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
    }

    private static func packageProjection(
        _ package: ProviderHandoffPayloadPackageV1
    ) -> ProviderHandoffCanonicalValue {
        .map([
            .init("entries", .array(package.entries.map(entryProjection))),
            .init("partKind", .textString(package.partKind.rawValue)),
            .init("schemaVersion", .unsigned(UInt64(package.schemaVersion))),
        ])
    }

    private static func entryProjection(
        _ entry: ProviderHandoffPayloadPackageEntryV1
    ) -> ProviderHandoffCanonicalValue {
        .map([
            .init("canonicalRecordBytes", .byteString(entry.canonicalRecordBytes)),
            .init("entryID", .textString(entry.entryID)),
            .init("recordKind", .textString(entry.recordKind)),
            .init("schemaVersion", .unsigned(UInt64(entry.schemaVersion))),
            .init("sourceStateRootUUID", .optional(entry.sourceStateRootUUID)),
        ])
    }

    private static func sourceDigestProjection(
        _ source: ProviderHandoffContentSourceDigestV1
    ) throws -> ProviderHandoffCanonicalValue {
        try .map([
            .init("authorityLineageUUID", .textString(source.authorityLineageUUID)),
            .init("lineageDigestKeyVersion", .unsigned(source.lineageDigestKeyVersion)),
            .init("orderedEntryIDs", .array(source.orderedEntryIDs.map(ProviderHandoffCanonicalValue.textString))),
            .init("sourceDigestHMACSHA256", .byteString(ProviderHandoffDigest.parseSHA256(source.sourceDigestHMACSHA256))),
            .init("sourceStateRootUUID", .textString(source.sourceStateRootUUID)),
        ])
    }

    private static func contentDigestProjection(
        _ digest: ProviderHandoffCanonicalContentDigestV1
    ) throws -> ProviderHandoffCanonicalValue {
        try .map([
            .init("algorithm", .textString(digest.algorithm.rawValue)),
            .init("digest", .byteString(ProviderHandoffDigest.parseSHA256(digest.digest))),
            .init("orderedSourceDigests", .array(digest.orderedSourceDigests.map(sourceDigestProjection))),
            .init("scope", .textString(digest.scope.rawValue)),
        ])
    }

    private static func associatedDataProjection(
        _ value: ProviderHandoffAEADAssociatedDataV1
    ) throws -> ProviderHandoffCanonicalValue {
        try .map([
            .init("authorityLineageUUID", .optional(value.authorityLineageUUID)),
            .init("canonicalContentDigest", .optional(value.canonicalContentDigest.map(contentDigestProjection))),
            .init("canonicalPlaintextByteLength", .unsigned(value.canonicalPlaintextByteLength)),
            .init("destinationKeyID", .textString(value.destinationKeyID)),
            .init("destinationKeyPurpose", .textString(value.destinationKeyPurpose.rawValue)),
            .init("destinationProviderFingerprint", .textString(value.destinationProviderFingerprint)),
            .init("destinationStateRootUUID", .textString(value.destinationStateRootUUID)),
            .init("ephemeralPublicKey", .byteString(value.ephemeralPublicKey)),
            .init("lineageDigestKeyVersion", .optional(value.lineageDigestKeyVersion)),
            .init("manifestID", .textString(value.manifestID)),
            .init("mediaType", .optional(value.mediaType)),
            .init("nonce", .byteString(value.nonce)),
            .init("objectKind", .textString(value.objectKind.rawValue)),
            .init("objectLocalID", .textString(value.objectLocalID)),
            .init("partKind", .optional(value.partKind.map { .textString($0.rawValue) })),
            .init("payloadSchemaVersion", .optional(value.payloadSchemaVersion.map { .unsigned(UInt64($0)) })),
            .init("schemaVersion", .unsigned(UInt64(value.schemaVersion))),
            .init("sourceStateRootUUID", .optional(value.sourceStateRootUUID)),
            .init("tokenID", .textString(value.tokenID)),
        ])
    }

    private static func hkdfSalt(
        _ associated: ProviderHandoffAEADAssociatedDataV1
    ) throws -> Data {
        try ProviderHandoffDigest.domainBytes(
            "container-handoff-hkdf-salt-v1",
            projection: .map([
                .init("destinationKeyID", .textString(associated.destinationKeyID)),
                .init("destinationKeyPurpose", .textString(associated.destinationKeyPurpose.rawValue)),
                .init("destinationProviderFingerprint", .textString(associated.destinationProviderFingerprint)),
                .init("destinationStateRootUUID", .textString(associated.destinationStateRootUUID)),
                .init("manifestID", .textString(associated.manifestID)),
                .init("objectKind", .textString(associated.objectKind.rawValue)),
                .init("objectLocalID", .textString(associated.objectLocalID)),
                .init("tokenID", .textString(associated.tokenID)),
            ])
        )
    }

    private static func hkdfInfo(_ associatedDataDigest: Data) -> Data {
        var info = Data("container-handoff-x25519-xchacha20poly1305-key-v1".utf8)
        info.append(0)
        info.append(associatedDataDigest)
        return info
    }

    private static func decodeEntry(
        _ value: ProviderHandoffCanonicalValue
    ) throws -> ProviderHandoffPayloadPackageEntryV1 {
        let map = try exactMap(
            value,
            keys: [
                "canonicalRecordBytes",
                "entryID",
                "recordKind",
                "schemaVersion",
                "sourceStateRootUUID",
            ]
        )
        guard case let .byteString(canonicalRecordBytes)? = map["canonicalRecordBytes"] else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let source = try optionalText(map["sourceStateRootUUID"])
        let version = try unsigned(map["schemaVersion"])
        guard version <= UInt32.max else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        return try ProviderHandoffPayloadPackageEntryV1(
            entryID: text(map["entryID"]),
            sourceStateRootUUID: source,
            recordKind: text(map["recordKind"]),
            schemaVersion: UInt32(version),
            canonicalRecordBytes: canonicalRecordBytes
        )
    }

    private static func exactMap(
        _ value: ProviderHandoffCanonicalValue,
        keys: Set<String>
    ) throws -> [String: ProviderHandoffCanonicalValue] {
        guard case let .map(entries) = value else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let actual = Set(entries.map(\.key))
        guard actual == keys else {
            if let unexpected = actual.subtracting(keys).sorted().first {
                throw ProviderHandoffPayloadCodecError.unexpectedKey(unexpected)
            }
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
    }

    private static func text(_ value: ProviderHandoffCanonicalValue?) throws -> String {
        guard case let .textString(text)? = value else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        return text
    }

    private static func optionalText(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> String? {
        switch value {
        case .null?:
            return nil
        case let .textString(text)?:
            return text
        default:
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
    }

    private static func unsigned(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> UInt64 {
        guard case let .unsigned(number)? = value else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        return number
    }

    private static func validatedSourceOrder(_ sourceOrder: [String]) throws -> [String] {
        var seen = Set<String>()
        for source in sourceOrder {
            guard canonicalUUID(source) != nil else {
                throw ProviderHandoffPayloadCodecError.invalidSource(source)
            }
            guard seen.insert(source).inserted else {
                throw ProviderHandoffPayloadCodecError.duplicateSource(source)
            }
        }
        return sourceOrder
    }

    private static func lineageKeyMap(
        _ keys: [ProviderHandoffLineageKeyV1],
        sourceOrder: [String]
    ) throws -> [String: ProviderHandoffLineageKeyV1] {
        _ = try validatedSourceOrder(sourceOrder)
        var result: [String: ProviderHandoffLineageKeyV1] = [:]
        for key in keys {
            guard
                sourceOrder.contains(key.sourceStateRootUUID),
                canonicalUUID(key.sourceStateRootUUID) != nil,
                canonicalUUID(key.authorityLineageUUID) != nil,
                key.keyVersion > 0,
                key.rawHMACSHA256Key.count == 32,
                result[key.sourceStateRootUUID] == nil
            else {
                throw ProviderHandoffPayloadCodecError.invalidLineageKey(
                    key.sourceStateRootUUID
                )
            }
            result[key.sourceStateRootUUID] = key
        }
        return result
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard
            let identifier = UUID(uuidString: value),
            identifier.uuidString.lowercased() == value
        else {
            return nil
        }
        return identifier
    }

    private static func validMediaType(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value == value.lowercased() else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return value.utf8.allSatisfy { byte in
            byte >= 0x21 && byte <= 0x7E && byte != 0x22 && byte != 0x5C
        }
    }

    private static func sealedFrameCount(
        canonicalPlaintextByteLength: UInt64
    ) throws -> UInt64 {
        guard canonicalPlaintextByteLength > 0 else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let frameBytes = UInt64(maximumSealedFramePlaintextBytes)
        return ((canonicalPlaintextByteLength - 1) / frameBytes) + 1
    }

    private static func sealedTransportByteLength(
        canonicalPlaintextByteLength: UInt64,
        frameCount: UInt64
    ) throws -> UInt64 {
        let (tagBytes, tagOverflow) = frameCount.multipliedReportingOverflow(by: 16)
        let (total, totalOverflow) =
            canonicalPlaintextByteLength
            .addingReportingOverflow(tagBytes)
        guard !tagOverflow, !totalOverflow else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        return total
    }

    private typealias ByteSink = (Data) throws -> Void

    private static func prepareSealedCanonicalBytes(
        _ canonical: Data,
        schemaVersion: UInt32,
        partKind: ProviderHandoffPartKindV1,
        contentDigest: ProviderHandoffCanonicalContentDigestV1,
        transportFileURL: URL,
        mediaType: String,
        tokenID: String,
        manifestID: String,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        destinationKeyID: String,
        destinationPublicKey: Data,
        nonce suppliedNonce: Data?,
        ephemeralPrivateKey suppliedEphemeralPrivateKey: Data?
    ) throws -> ProviderHandoffPreparedPayloadFileV2 {
        let canonicalLength = UInt64(canonical.count)
        let ephemeralPrivateKey =
            suppliedEphemeralPrivateKey
            ?? ProviderHandoffCrypto.generateX25519PrivateKey()
        let ephemeralPublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: ephemeralPrivateKey
        )
        let nonce = suppliedNonce ?? randomBytes(count: 24)
        let associated = ProviderHandoffAEADAssociatedDataV1(
            objectKind: .partPayload,
            tokenID: tokenID,
            manifestID: manifestID,
            objectLocalID: "part:\(partKind.rawValue)",
            partKind: partKind,
            mediaType: mediaType,
            payloadSchemaVersion: schemaVersion,
            canonicalPlaintextByteLength: canonicalLength,
            canonicalContentDigest: contentDigest,
            sourceStateRootUUID: nil,
            authorityLineageUUID: nil,
            lineageDigestKeyVersion: nil,
            destinationProviderFingerprint: destinationProviderFingerprint,
            destinationStateRootUUID: destinationStateRootUUID,
            destinationKeyPurpose: .destinationPayloadEncryption,
            destinationKeyID: destinationKeyID,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce
        )
        try validatePartPayloadAssociatedData(associated)
        let associatedData = try associatedDataDigest(associated)
        let salt = try hkdfSalt(associated)
        let info = hkdfInfo(associatedData)
        let frameCount = try sealedFrameCount(
            canonicalPlaintextByteLength: canonicalLength
        )
        let expectedTransportLength = try sealedTransportByteLength(
            canonicalPlaintextByteLength: canonicalLength,
            frameCount: frameCount
        )
        let output = try createExclusiveFile(at: transportFileURL)
        var completed = false
        defer {
            try? output.close()
            if !completed {
                _ = transportFileURL.path.withCString { Darwin.unlink($0) }
            }
        }
        var transportHash = SHA256()
        var transportLength: UInt64 = 0
        for frameIndex in 0..<frameCount {
            let lower = Int(frameIndex) * maximumSealedFramePlaintextBytes
            let upper = min(
                canonical.count,
                lower + maximumSealedFramePlaintextBytes
            )
            let plaintext = canonical.subdata(in: lower..<upper)
            let frameAssociatedData = framedAssociatedData(
                baseAssociatedData: associatedData,
                frameIndex: frameIndex,
                frameCount: frameCount,
                canonicalPlaintextByteLength: canonicalLength,
                framePlaintextByteLength: UInt64(plaintext.count)
            )
            let box = try ProviderHandoffCrypto.seal(
                plaintext,
                destinationPublicKey: destinationPublicKey,
                nonce: framedNonce(base: nonce, frameIndex: frameIndex),
                salt: salt,
                info: info,
                associatedData: frameAssociatedData,
                ephemeralPrivateKey: ephemeralPrivateKey
            )
            guard box.ephemeralPublicKey == ephemeralPublicKey else {
                throw ProviderHandoffPayloadCodecError.invalidDescriptor
            }
            try output.write(contentsOf: box.ciphertext)
            transportHash.update(data: box.ciphertext)
            transportLength += UInt64(box.ciphertext.count)
        }
        guard transportLength == expectedTransportLength else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        try output.synchronize()
        let transportDigest = ProviderHandoffDigest.hex(
            Data(transportHash.finalize())
        )
        completed = true
        return ProviderHandoffPreparedPayloadFileV2(
            descriptor: ProviderHandoffPayloadDescriptorV1(
                bundleObjectID: "sha256:\(transportDigest)",
                mediaType: mediaType,
                schemaVersion: schemaVersion,
                canonicalEncoding: .deterministicCBORV1,
                canonicalPlaintextByteLength: canonicalLength,
                transportByteLength: transportLength,
                canonicalContentDigest: contentDigest,
                transportDigestSHA256: transportDigest,
                protection:
                    .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2,
                destinationEncryption: ProviderHandoffPayloadEncryptionV1(
                    encryptionAlgorithm:
                        .x25519HKDFSHA256XChaCha20Poly1305FramedV2,
                    destinationKeyPurpose: .destinationPayloadEncryption,
                    destinationKeyID: destinationKeyID,
                    ephemeralPublicKey: ephemeralPublicKey,
                    nonce: nonce,
                    associatedDataDigestSHA256:
                        ProviderHandoffDigest.hex(associatedData)
                )
            ),
            transportFileURL: transportFileURL
        )
    }

    private static func validate(
        _ package: ProviderHandoffPayloadPackageSourceV2,
        sourceOrder: [String]
    ) throws {
        guard
            package.schemaVersion
                == ProviderHandoffPayloadPackageV1.currentSchemaVersion,
            !package.entries.isEmpty
        else {
            throw package.entries.isEmpty
                ? ProviderHandoffPayloadCodecError.emptyPackage
                : ProviderHandoffPayloadCodecError.invalidPackage
        }
        let canonicalSources = try validatedSourceOrder(sourceOrder)
        let sourceIndexes = Dictionary(
            uniqueKeysWithValues: canonicalSources.enumerated().map { ($1, $0) }
        )
        var seenEntries = Set<String>()
        for entry in package.entries {
            guard
                !entry.entryID.isEmpty,
                !entry.recordKind.isEmpty,
                entry.schemaVersion > 0,
                entry.entryID.precomposedStringWithCanonicalMapping
                    == entry.entryID,
                entry.recordKind.precomposedStringWithCanonicalMapping
                    == entry.recordKind
            else {
                throw ProviderHandoffPayloadCodecError.invalidEntry(entry.entryID)
            }
            guard seenEntries.insert(entry.entryID).inserted else {
                throw ProviderHandoffPayloadCodecError.duplicateEntryID(
                    entry.entryID
                )
            }
            _ = try ProviderHandoffCanonicalCBOR.decode(
                mappedRecordData(entry.canonicalRecord)
            )
            if let source = entry.sourceStateRootUUID {
                guard canonicalUUID(source) != nil, sourceIndexes[source] != nil else {
                    throw ProviderHandoffPayloadCodecError.invalidSource(source)
                }
            }
        }
        let sorted = package.entries.sorted { lhs, rhs in
            let lhsIndex =
                lhs.sourceStateRootUUID.flatMap { sourceIndexes[$0] }
                ?? Int.max
            let rhsIndex =
                rhs.sourceStateRootUUID.flatMap { sourceIndexes[$0] }
                ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.entryID.utf8.lexicographicallyPrecedes(rhs.entryID.utf8)
        }
        guard sorted == package.entries else {
            throw ProviderHandoffPayloadCodecError.nonCanonicalOrder
        }
    }

    private static func streamPackage(
        _ package: ProviderHandoffPayloadPackageSourceV2,
        to sink: ByteSink
    ) throws {
        try streamMap(
            [
                (
                    "entries",
                    { entrySink in
                        try entrySink(cborMajor(4, value: UInt64(package.entries.count)))
                        for entry in package.entries {
                            try streamEntry(entry, to: entrySink)
                        }
                    }
                ),
                ("partKind", { try $0(cborText(package.partKind.rawValue)) }),
                (
                    "schemaVersion",
                    {
                        try $0(cborMajor(0, value: UInt64(package.schemaVersion)))
                    }
                ),
            ],
            to: sink
        )
    }

    private static func streamEntry(
        _ entry: ProviderHandoffPayloadPackageEntrySourceV2,
        to sink: ByteSink
    ) throws {
        try streamMap(
            [
                (
                    "canonicalRecordBytes",
                    { recordSink in
                        try recordSink(
                            cborMajor(
                                2,
                                value: recordByteLength(entry.canonicalRecord)
                            )
                        )
                        try streamRecord(entry.canonicalRecord, to: recordSink)
                    }
                ),
                ("entryID", { try $0(cborText(entry.entryID)) }),
                ("recordKind", { try $0(cborText(entry.recordKind)) }),
                (
                    "schemaVersion",
                    {
                        try $0(cborMajor(0, value: UInt64(entry.schemaVersion)))
                    }
                ),
                (
                    "sourceStateRootUUID",
                    {
                        if let source = entry.sourceStateRootUUID {
                            try $0(cborText(source))
                        } else {
                            try $0(Data([0xF6]))
                        }
                    }
                ),
            ],
            to: sink
        )
    }

    private static func sealedContentDigest(
        _ package: ProviderHandoffPayloadPackageSourceV2,
        tokenID: String,
        manifestID: String,
        sourceOrder: [String],
        lineageKeys: [ProviderHandoffLineageKeyV1]
    ) throws -> ProviderHandoffCanonicalContentDigestV1 {
        try validate(package, sourceOrder: sourceOrder)
        guard package.entries.allSatisfy({ $0.sourceStateRootUUID != nil }) else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let keyBySource = try lineageKeyMap(
            lineageKeys,
            sourceOrder: sourceOrder
        )
        var sourceDigests: [ProviderHandoffContentSourceDigestV1] = []
        for source in sourceOrder {
            let entries = package.entries.filter {
                $0.sourceStateRootUUID == source
            }
            guard !entries.isEmpty else { continue }
            guard let key = keyBySource[source] else {
                throw ProviderHandoffPayloadCodecError.invalidLineageKey(source)
            }
            var authentication = HMAC<SHA256>(
                key: SymmetricKey(data: key.rawHMACSHA256Key)
            )
            authentication.update(
                data: Data("container-handoff-source-content-v1\0".utf8)
            )
            try streamMap(
                [
                    (
                        "authorityLineageUUID",
                        {
                            try $0(cborText(key.authorityLineageUUID))
                        }
                    ),
                    (
                        "lineageDigestKeyVersion",
                        {
                            try $0(cborMajor(0, value: key.keyVersion))
                        }
                    ),
                    ("manifestID", { try $0(cborText(manifestID)) }),
                    (
                        "orderedCompleteEntries",
                        { entrySink in
                            try entrySink(
                                cborMajor(4, value: UInt64(entries.count))
                            )
                            for entry in entries {
                                try streamEntry(entry, to: entrySink)
                            }
                        }
                    ),
                    (
                        "packageSchemaVersion",
                        {
                            try $0(
                                cborMajor(0, value: UInt64(package.schemaVersion))
                            )
                        }
                    ),
                    (
                        "partKind",
                        {
                            try $0(cborText(package.partKind.rawValue))
                        }
                    ),
                    ("sourceStateRootUUID", { try $0(cborText(source)) }),
                    ("tokenID", { try $0(cborText(tokenID)) }),
                ],
                to: { authentication.update(data: $0) }
            )
            sourceDigests.append(
                ProviderHandoffContentSourceDigestV1(
                    sourceStateRootUUID: source,
                    authorityLineageUUID: key.authorityLineageUUID,
                    lineageDigestKeyVersion: key.keyVersion,
                    orderedEntryIDs: entries.map(\.entryID),
                    sourceDigestHMACSHA256: ProviderHandoffDigest.hex(
                        Data(authentication.finalize())
                    )
                )
            )
        }
        guard !sourceDigests.isEmpty else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        if sourceDigests.count == 1 {
            return ProviderHandoffCanonicalContentDigestV1(
                algorithm: .lineageHMACSHA256V1,
                scope: .singleSourceLineageHMACSHA256V1,
                orderedSourceDigests: sourceDigests,
                digest: sourceDigests[0].sourceDigestHMACSHA256
            )
        }
        var aggregate = Data("container-handoff-multi-source-content-v1".utf8)
        aggregate.append(0)
        try aggregate.append(
            ProviderHandoffCanonicalCBOR.encode(
                .array(sourceDigests.map(sourceDigestProjection))
            )
        )
        return ProviderHandoffCanonicalContentDigestV1(
            algorithm: .orderedLineageHMACSHA256AggregateV1,
            scope: .multiSourceLineageHMACSHA256AggregateV1,
            orderedSourceDigests: sourceDigests,
            digest: ProviderHandoffDigest.sha256(aggregate)
        )
    }

    private static func streamMap(
        _ fields: [(String, (ByteSink) throws -> Void)],
        to sink: ByteSink
    ) throws {
        let ordered = try fields.map { field in
            try (field.0, field.1, cborText(field.0))
        }.sorted { lhs, rhs in
            if lhs.2.count != rhs.2.count {
                return lhs.2.count < rhs.2.count
            }
            return lhs.2.lexicographicallyPrecedes(rhs.2)
        }
        try sink(cborMajor(5, value: UInt64(ordered.count)))
        for field in ordered {
            try sink(field.2)
            try field.1(sink)
        }
    }

    private static func cborText(_ value: String) throws -> Data {
        try ProviderHandoffCanonicalCBOR.encode(.textString(value))
    }

    private static func cborMajor(_ major: UInt8, value: UInt64) -> Data {
        var output = Data()
        let prefix = major << 5
        switch value {
        case 0..<24:
            output.append(prefix | UInt8(value))
        case 24...UInt64(UInt8.max):
            output.append(prefix | 24)
            output.append(UInt8(value))
        case 0...UInt64(UInt16.max):
            output.append(prefix | 25)
            appendBigEndian(UInt16(value), to: &output)
        case 0...UInt64(UInt32.max):
            output.append(prefix | 26)
            appendBigEndian(UInt32(value), to: &output)
        default:
            output.append(prefix | 27)
            appendBigEndian(value, to: &output)
        }
        return output
    }

    private static func recordByteLength(
        _ source: ProviderHandoffPayloadRecordSourceV2
    ) throws -> UInt64 {
        switch source {
        case let .data(bytes):
            return UInt64(bytes.count)
        case let .file(_, byteLength):
            guard byteLength > 0 else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            return byteLength
        }
    }

    private static func streamRecord(
        _ source: ProviderHandoffPayloadRecordSourceV2,
        to sink: ByteSink
    ) throws {
        switch source {
        case let .data(bytes):
            try sink(bytes)
        case let .file(url, byteLength):
            let handle = try openRegularFile(
                at: url,
                expectedByteLength: byteLength
            )
            defer { try? handle.close() }
            var remaining = byteLength
            while remaining > 0 {
                let count = min(
                    UInt64(ProviderHandoffBundleObjectStore.maximumChunkBytes),
                    remaining
                )
                guard let exactCount = Int(exactly: count) else {
                    throw ProviderHandoffPayloadCodecError.invalidPackage
                }
                let bytes = try readExactly(handle, count: exactCount)
                try sink(bytes)
                remaining -= count
            }
            guard try handle.read(upToCount: 1)?.isEmpty != false else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
        }
    }

    private static func mappedRecordData(
        _ source: ProviderHandoffPayloadRecordSourceV2
    ) throws -> Data {
        switch source {
        case let .data(bytes):
            return bytes
        case let .file(url, byteLength):
            guard
                byteLength > 0,
                let count = Int(exactly: byteLength)
            else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            var metadata = stat()
            guard
                Darwin.fstat(descriptor, &metadata) == 0,
                (metadata.st_mode & S_IFMT) == S_IFREG,
                metadata.st_nlink == 1,
                metadata.st_size == off_t(byteLength)
            else {
                Darwin.close(descriptor)
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            let mapped = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0)
            Darwin.close(descriptor)
            guard mapped != MAP_FAILED, let mapped else {
                throw ProviderHandoffPayloadCodecError.invalidPackage
            }
            return Data(
                bytesNoCopy: mapped,
                count: count,
                deallocator: .custom { pointer, byteCount in
                    _ = munmap(pointer, byteCount)
                }
            )
        }
    }

    private static func framedAssociatedData(
        baseAssociatedData: Data,
        frameIndex: UInt64,
        frameCount: UInt64,
        canonicalPlaintextByteLength: UInt64,
        framePlaintextByteLength: UInt64
    ) -> Data {
        var input = Data("container-handoff-part-payload-frame-v2".utf8)
        input.append(0)
        input.append(baseAssociatedData)
        appendBigEndian(frameIndex, to: &input)
        appendBigEndian(frameCount, to: &input)
        appendBigEndian(canonicalPlaintextByteLength, to: &input)
        appendBigEndian(framePlaintextByteLength, to: &input)
        return Data(SHA256.hash(data: input))
    }

    private static func framedNonce(
        base: Data,
        frameIndex: UInt64
    ) throws -> Data {
        guard base.count == 24 else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        var result = base
        var index = frameIndex.bigEndian
        withUnsafeBytes(of: &index) { bytes in
            for offset in 0..<bytes.count {
                result[result.startIndex + 16 + offset] ^= bytes[offset]
            }
        }
        return result
    }

    private static func appendBigEndian(
        _ value: some FixedWidthInteger,
        to output: inout Data
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { output.append(contentsOf: $0) }
    }

    private static func createExclusiveFile(at url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func openRegularFile(
        at url: URL,
        expectedByteLength: UInt64
    ) throws -> FileHandle {
        guard expectedByteLength <= UInt64(Int64.max) else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_nlink == 1,
            metadata.st_size == off_t(expectedByteLength)
        else {
            try? handle.close()
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        return handle
    }

    private static func openVerifiedRegularFile(
        at url: URL,
        expectedByteLength: UInt64,
        expectedSHA256: String
    ) throws -> FileHandle {
        guard expectedByteLength <= UInt64(Int64.max) else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var metadata = stat()
            guard
                Darwin.fstat(descriptor, &metadata) == 0,
                (metadata.st_mode & S_IFMT) == S_IFREG,
                metadata.st_nlink == 1,
                metadata.st_size == off_t(expectedByteLength)
            else {
                throw ProviderHandoffPayloadCodecError.invalidDescriptor
            }
            var digest = SHA256()
            while let bytes = try handle.read(
                upToCount: ProviderHandoffBundleObjectStore.maximumChunkBytes
            ), !bytes.isEmpty {
                digest.update(data: bytes)
            }
            guard
                ProviderHandoffDigest.hex(Data(digest.finalize()))
                    == expectedSHA256
            else {
                throw ProviderHandoffPayloadCodecError.transportDigestMismatch
            }
            try handle.seek(toOffset: 0)
            return handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func readExactly(
        _ handle: FileHandle,
        count: Int
    ) throws -> Data {
        guard count > 0 else {
            throw ProviderHandoffPayloadCodecError.invalidDescriptor
        }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard
                let bytes = try handle.read(upToCount: count - result.count),
                !bytes.isEmpty
            else {
                throw ProviderHandoffPayloadCodecError.invalidDescriptor
            }
            result.append(bytes)
        }
        return result
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
