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
        case .duplicateEntryID(let identifier):
            "provider handoff payload contains duplicate entry ID \(identifier)"
        case .duplicateSource(let identifier):
            "provider handoff payload contains duplicate source \(identifier)"
        case .emptyPackage:
            "provider handoff payload requires structured evidence"
        case .invalidDescriptor:
            "provider handoff payload descriptor is invalid"
        case .invalidEntry(let identifier):
            "provider handoff payload entry is invalid: \(identifier)"
        case .invalidLineageKey(let identifier):
            "provider handoff lineage key is invalid: \(identifier)"
        case .invalidMediaType:
            "provider handoff media type is invalid"
        case .invalidPackage:
            "provider handoff package is invalid"
        case .invalidSource(let identifier):
            "provider handoff payload source is invalid: \(identifier)"
        case .nonCanonicalOrder:
            "provider handoff payload entries are not in canonical source and ID order"
        case .transportDigestMismatch:
            "provider handoff payload transport digest does not match"
        case .unexpectedKey(let key):
            "provider handoff canonical map contains unexpected key \(key)"
        }
    }
}

public enum ProviderHandoffPayloadCodec {
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
            case .array(let encodedEntries)? = map["entries"]
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
            salt: try hkdfSalt(associated),
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
            input.append(try ProviderHandoffCanonicalCBOR.encode(projection))
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
        aggregate.append(
            try ProviderHandoffCanonicalCBOR.encode(
                .array(try sourceDigests.map(sourceDigestProjection))
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
            projection: try associatedDataProjection(associatedData)
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
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
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
        .map([
            .init("authorityLineageUUID", .textString(source.authorityLineageUUID)),
            .init("lineageDigestKeyVersion", .unsigned(source.lineageDigestKeyVersion)),
            .init("orderedEntryIDs", .array(source.orderedEntryIDs.map(ProviderHandoffCanonicalValue.textString))),
            .init("sourceDigestHMACSHA256", .byteString(try ProviderHandoffDigest.parseSHA256(source.sourceDigestHMACSHA256))),
            .init("sourceStateRootUUID", .textString(source.sourceStateRootUUID)),
        ])
    }

    private static func contentDigestProjection(
        _ digest: ProviderHandoffCanonicalContentDigestV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("algorithm", .textString(digest.algorithm.rawValue)),
            .init("digest", .byteString(try ProviderHandoffDigest.parseSHA256(digest.digest))),
            .init("orderedSourceDigests", .array(try digest.orderedSourceDigests.map(sourceDigestProjection))),
            .init("scope", .textString(digest.scope.rawValue)),
        ])
    }

    private static func associatedDataProjection(
        _ value: ProviderHandoffAEADAssociatedDataV1
    ) throws -> ProviderHandoffCanonicalValue {
        .map([
            .init("authorityLineageUUID", .optional(value.authorityLineageUUID)),
            .init("canonicalContentDigest", .optional(try value.canonicalContentDigest.map(contentDigestProjection))),
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
        guard case .byteString(let canonicalRecordBytes)? = map["canonicalRecordBytes"] else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        let source = try optionalText(map["sourceStateRootUUID"])
        let version = try unsigned(map["schemaVersion"])
        guard version <= UInt32.max else {
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
        return ProviderHandoffPayloadPackageEntryV1(
            entryID: try text(map["entryID"]),
            sourceStateRootUUID: source,
            recordKind: try text(map["recordKind"]),
            schemaVersion: UInt32(version),
            canonicalRecordBytes: canonicalRecordBytes
        )
    }

    private static func exactMap(
        _ value: ProviderHandoffCanonicalValue,
        keys: Set<String>
    ) throws -> [String: ProviderHandoffCanonicalValue] {
        guard case .map(let entries) = value else {
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
        guard case .textString(let text)? = value else {
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
        case .textString(let text)?:
            return text
        default:
            throw ProviderHandoffPayloadCodecError.invalidPackage
        }
    }

    private static func unsigned(
        _ value: ProviderHandoffCanonicalValue?
    ) throws -> UInt64 {
        guard case .unsigned(let number)? = value else {
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
            byte >= 0x21 && byte <= 0x7e && byte != 0x22 && byte != 0x5c
        }
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
