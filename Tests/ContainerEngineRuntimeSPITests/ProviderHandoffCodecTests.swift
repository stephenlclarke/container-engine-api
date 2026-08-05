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

import ContainerEngineRuntimeSPI
import Foundation
import Testing

struct ProviderHandoffCodecTests {
    @Test
    func `deterministic CBOR uses canonical key and integer encoding`() throws {
        let value: ProviderHandoffCanonicalValue = .map([
            .init("bb", .textString("x")),
            .init("a", .unsigned(1)),
        ])
        let encoded = try ProviderHandoffCanonicalCBOR.encode(value)

        #expect(ProviderHandoffDigest.hex(encoded) == "a26161016262626178")
        #expect(
            try ProviderHandoffCanonicalCBOR.encode(
                ProviderHandoffCanonicalCBOR.decode(encoded)
            ) == encoded
        )
        #expect(throws: ProviderHandoffCanonicalCBORError.nonCanonical) {
            try ProviderHandoffCanonicalCBOR.decode(Data([0x18, 0x17]))
        }
        #expect(throws: ProviderHandoffCanonicalCBORError.self) {
            try ProviderHandoffCanonicalCBOR.decode(
                Data([0xA2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02])
            )
        }
    }

    @Test
    func `deterministic CBOR rejects caller text that is not NFC`() {
        let decomposed = "e\u{301}"
        #expect(
            Data(decomposed.precomposedStringWithCanonicalMapping.utf8)
                != Data(decomposed.utf8)
        )
        #expect(throws: ProviderHandoffCanonicalCBORError.self) {
            try ProviderHandoffCanonicalCBOR.encode(.textString(decomposed))
        }
    }

    @Test
    func `HChaCha20 matches the published fixed vector`() throws {
        let key = Data((0x00...0x1F).map(UInt8.init))
        let nonce = try #require(
            data(hex: "000000090000004a0000000031415927")
        )
        let expected = "82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc"

        #expect(
            try ProviderHandoffDigest.hex(
                ProviderHandoffCrypto.hChaCha20(key: key, nonce: nonce)
            ) == expected
        )
    }

    @Test
    func `Ed25519 signature binds every signature projection field`() throws {
        let privateKey = ProviderHandoffCrypto.generateEd25519PrivateKey()
        let publicKey = try ProviderHandoffCrypto.ed25519PublicKey(for: privateKey)
        let digest = ProviderHandoffDigest.sha256(Data("manifest".utf8))
        let keyID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .ed25519V1,
            role: .gatewayCoordinator,
            purpose: .coordinatorManifestSigning,
            providerFingerprint: nil,
            stateRootUUID: nil,
            rawPublicKey: publicKey
        )
        let signature = try ProviderHandoffCrypto.sign(
            projectionDigestSHA256: digest,
            purpose: .coordinatorManifestSigning,
            signerKeyID: keyID,
            signerRole: .gatewayCoordinator,
            providerFingerprint: nil,
            stateRootUUID: nil,
            trustRegistryRevision: 7,
            privateKey: privateKey
        )

        try ProviderHandoffCrypto.verify(signature, publicKey: publicKey)
        var changed = signature
        changed.trustRegistryRevision += 1
        #expect(throws: ProviderHandoffCryptoError.invalidSignature) {
            try ProviderHandoffCrypto.verify(changed, publicKey: publicKey)
        }
    }

    @Test
    func `authenticated payload has one content addressed canonical object`() throws {
        let package = try ProviderHandoffPayloadPackageV1(
            partKind: .logging,
            entries: [evidenceEntry(identifier: "public-evidence", source: nil)]
        )
        let payload = try ProviderHandoffPayloadCodec.prepareAuthenticated(
            package,
            mediaType: "application/vnd.io.github.stephenlclarke.container.handoff-logging.v1+cbor"
        )

        #expect(payload.descriptor.bundleObjectID.hasPrefix("sha256:"))
        #expect(payload.descriptor.destinationEncryption == nil)
        #expect(
            try ProviderHandoffPayloadCodec.openAuthenticated(
                payload,
                expectedPartKind: .logging
            ) == package
        )
    }

    @Test
    func `sealed payload round trips and binds token manifest and ciphertext`() throws {
        let source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let lineage = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let destination = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let package = try ProviderHandoffPayloadPackageV1(
            partKind: .logging,
            entries: [evidenceEntry(identifier: "protected-option", source: source)]
        )
        let lineageKey = ProviderHandoffLineageKeyV1(
            sourceStateRootUUID: source,
            authorityLineageUUID: lineage,
            keyVersion: 4,
            rawHMACSHA256Key: Data(repeating: 0x44, count: 32)
        )
        let destinationPrivateKey = ProviderHandoffCrypto.generateX25519PrivateKey()
        let destinationPublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: destinationPrivateKey
        )
        let destinationKeyID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .x25519V1,
            role: .destinationProvider,
            purpose: .destinationPayloadEncryption,
            providerFingerprint: "sha256:destination",
            stateRootUUID: destination,
            rawPublicKey: destinationPublicKey
        )
        let payload = try ProviderHandoffPayloadCodec.prepareSealed(
            package,
            mediaType: "application/vnd.io.github.stephenlclarke.container.handoff-logging.v1+cbor",
            tokenID: "token-1",
            manifestID: "manifest-1",
            sourceOrder: [source],
            lineageKeys: [lineageKey],
            destinationProviderFingerprint: "sha256:destination",
            destinationStateRootUUID: destination,
            destinationKeyID: destinationKeyID,
            destinationPublicKey: destinationPublicKey,
            nonce: Data((0x00...0x17).map(UInt8.init))
        )

        #expect(payload.descriptor.canonicalContentDigest.digest != payload.descriptor.transportDigestSHA256)
        #expect(payload.transportBytes.range(of: Data("protected-option".utf8)) == nil)
        #expect(
            try ProviderHandoffPayloadCodec.openSealed(
                payload,
                expectedPartKind: .logging,
                tokenID: "token-1",
                manifestID: "manifest-1",
                sourceOrder: [source],
                lineageKeys: [lineageKey],
                destinationProviderFingerprint: "sha256:destination",
                destinationStateRootUUID: destination,
                destinationPrivateKey: destinationPrivateKey
            ) == package
        )
        #expect(throws: (any Error).self) {
            try ProviderHandoffPayloadCodec.openSealed(
                payload,
                expectedPartKind: .logging,
                tokenID: "token-1",
                manifestID: "other-manifest",
                sourceOrder: [source],
                lineageKeys: [lineageKey],
                destinationProviderFingerprint: "sha256:destination",
                destinationStateRootUUID: destination,
                destinationPrivateKey: destinationPrivateKey
            )
        }
        var tampered = payload
        tampered.transportBytes[tampered.transportBytes.startIndex] ^= 0x01
        #expect(throws: ProviderHandoffPayloadCodecError.transportDigestMismatch) {
            try ProviderHandoffPayloadCodec.openSealed(
                tampered,
                expectedPartKind: .logging,
                tokenID: "token-1",
                manifestID: "manifest-1",
                sourceOrder: [source],
                lineageKeys: [lineageKey],
                destinationProviderFingerprint: "sha256:destination",
                destinationStateRootUUID: destination,
                destinationPrivateKey: destinationPrivateKey
            )
        }
    }

    @Test
    func `framed sealed file round trips across bounded windows`() throws {
        let source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let lineage = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let destination = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let record = try ProviderHandoffCanonicalCBOR.encode(
            .byteString(
                Data(
                    repeating: 0x5A,
                    count:
                        ProviderHandoffPayloadCodec
                        .maximumSealedFramePlaintextBytes + 1024
                )
            )
        )
        let package = ProviderHandoffPayloadPackageV1(
            partKind: .logging,
            entries: [
                ProviderHandoffPayloadPackageEntryV1(
                    entryID: "large-history",
                    sourceStateRootUUID: source,
                    recordKind: "test-evidence",
                    schemaVersion: 1,
                    canonicalRecordBytes: record
                )
            ]
        )
        let lineageKey = ProviderHandoffLineageKeyV1(
            sourceStateRootUUID: source,
            authorityLineageUUID: lineage,
            keyVersion: 4,
            rawHMACSHA256Key: Data(repeating: 0x44, count: 32)
        )
        let destinationPrivateKey = ProviderHandoffCrypto.generateX25519PrivateKey()
        let destinationPublicKey = try ProviderHandoffCrypto.x25519PublicKey(
            for: destinationPrivateKey
        )
        let destinationKeyID = try ProviderHandoffCrypto.trustKeyID(
            algorithm: .x25519V1,
            role: .destinationProvider,
            purpose: .destinationPayloadEncryption,
            providerFingerprint: "sha256:destination",
            stateRootUUID: destination,
            rawPublicKey: destinationPublicKey
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-handoff-framed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let recordURL = root.appendingPathComponent("record")
        try record.write(to: recordURL, options: .withoutOverwriting)
        let transportURL = root.appendingPathComponent("transport")
        let canonicalURL = root.appendingPathComponent("canonical")
        let payload = try ProviderHandoffPayloadCodec.prepareSealedFile(
            ProviderHandoffPayloadPackageSourceV2(
                partKind: .logging,
                entries: [
                    ProviderHandoffPayloadPackageEntrySourceV2(
                        entryID: "large-history",
                        sourceStateRootUUID: source,
                        recordKind: "test-evidence",
                        schemaVersion: 1,
                        canonicalRecord: .file(
                            url: recordURL,
                            byteLength: UInt64(record.count)
                        )
                    )
                ]
            ),
            transportFileURL: transportURL,
            mediaType:
                "application/vnd.io.github.stephenlclarke.container.handoff-logging.v1+cbor",
            tokenID: "token-1",
            manifestID: "manifest-1",
            sourceOrder: [source],
            lineageKeys: [lineageKey],
            destinationProviderFingerprint: "sha256:destination",
            destinationStateRootUUID: destination,
            destinationKeyID: destinationKeyID,
            destinationPublicKey: destinationPublicKey,
            nonce: Data((0x00...0x17).map(UInt8.init))
        )

        #expect(
            payload.descriptor.protection
                == .destinationSealedFramedX25519HKDFSHA256XChaCha20Poly1305V2
        )
        #expect(
            payload.descriptor.transportByteLength
                == payload.descriptor.canonicalPlaintextByteLength + 32
        )
        let transport = try Data(contentsOf: transportURL, options: .mappedIfSafe)
        #expect(transport.range(of: Data(repeating: 0x5A, count: 64)) == nil)
        #expect(
            try ProviderHandoffPayloadCodec.openSealedFile(
                payload,
                canonicalFileURL: canonicalURL,
                expectedPartKind: .logging,
                tokenID: "token-1",
                manifestID: "manifest-1",
                sourceOrder: [source],
                lineageKeys: [lineageKey],
                destinationProviderFingerprint: "sha256:destination",
                destinationStateRootUUID: destination,
                destinationPrivateKey: destinationPrivateKey
            ) == package
        )
        let recordDirectory = root.appendingPathComponent(
            "opened-records",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recordDirectory,
            withIntermediateDirectories: false
        )
        let opened = try ProviderHandoffPayloadCodec.openSealedFileSource(
            payload,
            canonicalFileURL: root.appendingPathComponent("canonical-source"),
            recordDirectoryURL: recordDirectory,
            expectedPartKind: .logging,
            tokenID: "token-1",
            manifestID: "manifest-1",
            sourceOrder: [source],
            lineageKeys: [lineageKey],
            destinationProviderFingerprint: "sha256:destination",
            destinationStateRootUUID: destination,
            destinationPrivateKey: destinationPrivateKey
        )
        #expect(opened.entries.count == 1)
        guard
            case let .file(openedRecordURL, openedByteLength) =
                opened.entries[0].canonicalRecord
        else {
            Issue.record("expected a file-backed canonical record")
            return
        }
        #expect(openedByteLength == UInt64(record.count))
        #expect(try Data(contentsOf: openedRecordURL) == record)
    }

    @Test
    func `payload rejects entries outside canonical source and identifier order`() throws {
        let source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let package = try ProviderHandoffPayloadPackageV1(
            partKind: .logging,
            entries: [
                evidenceEntry(identifier: "z", source: source),
                evidenceEntry(identifier: "a", source: source),
            ]
        )

        #expect(throws: ProviderHandoffPayloadCodecError.nonCanonicalOrder) {
            try ProviderHandoffPayloadCodec.encode(package, sourceOrder: [source])
        }
    }

    private func evidenceEntry(
        identifier: String,
        source: String?
    ) throws -> ProviderHandoffPayloadPackageEntryV1 {
        try ProviderHandoffPayloadPackageEntryV1(
            entryID: identifier,
            sourceStateRootUUID: source,
            recordKind: "test-evidence",
            schemaVersion: 1,
            canonicalRecordBytes: ProviderHandoffCanonicalCBOR.encode(
                .map([.init("value", .textString("secret"))])
            )
        )
    }

    private func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var output = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        return output
    }
}
