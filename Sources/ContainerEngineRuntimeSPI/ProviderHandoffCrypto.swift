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

public struct ProviderHandoffXChaChaSealedBox: Equatable, Sendable {
    public var ephemeralPublicKey: Data
    public var nonce: Data
    /// Ciphertext followed by the 16-byte Poly1305 tag. The nonce is separate.
    public var ciphertext: Data

    public init(ephemeralPublicKey: Data, nonce: Data, ciphertext: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

public enum ProviderHandoffCryptoError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case authenticationFailed
    case invalidDigest
    case invalidEd25519Key
    case invalidNonce
    case invalidSignature
    case invalidX25519Key
    case lowOrderX25519Key

    public var description: String {
        switch self {
        case .authenticationFailed:
            "provider handoff authentication failed"
        case .invalidDigest:
            "provider handoff digest is invalid"
        case .invalidEd25519Key:
            "provider handoff Ed25519 key is invalid"
        case .invalidNonce:
            "provider handoff XChaCha20 nonce must contain 24 bytes"
        case .invalidSignature:
            "provider handoff signature is invalid"
        case .invalidX25519Key:
            "provider handoff X25519 key is invalid"
        case .lowOrderX25519Key:
            "provider handoff X25519 key produced a low-order shared secret"
        }
    }
}

public enum ProviderHandoffCrypto {
    public static func generateEd25519PrivateKey() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    public static func ed25519PublicKey(for privateKey: Data) throws -> Data {
        do {
            return try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKey
            ).publicKey.rawRepresentation
        } catch {
            throw ProviderHandoffCryptoError.invalidEd25519Key
        }
    }

    public static func signEd25519Message(
        _ message: Data,
        privateKey: Data
    ) throws -> Data {
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        } catch {
            throw ProviderHandoffCryptoError.invalidEd25519Key
        }
        return try key.signature(for: message)
    }

    public static func verifyEd25519Message(
        _ message: Data,
        signature: Data,
        publicKey: Data
    ) throws {
        guard signature.count == 64 else {
            throw ProviderHandoffCryptoError.invalidSignature
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw ProviderHandoffCryptoError.invalidEd25519Key
        }
        guard key.isValidSignature(signature, for: message) else {
            throw ProviderHandoffCryptoError.invalidSignature
        }
    }

    public static func generateX25519PrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    public static func x25519PublicKey(for privateKey: Data) throws -> Data {
        do {
            return try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: privateKey
            ).publicKey.rawRepresentation
        } catch {
            throw ProviderHandoffCryptoError.invalidX25519Key
        }
    }

    public static func trustKeyID(
        algorithm: ProviderHandoffPublicKeyAlgorithmV1,
        role: ProviderHandoffKeyRoleV1,
        purpose: ProviderHandoffKeyPurposeV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        rawPublicKey: Data
    ) throws -> String {
        try ProviderHandoffDigest.domain(
            "container-handoff-trust-key-id-v1",
            projection: .map([
                .init("algorithm", .textString(algorithm.rawValue)),
                .init("providerFingerprint", .optional(providerFingerprint)),
                .init("purpose", .textString(purpose.rawValue)),
                .init("rawPublicKey", .byteString(rawPublicKey)),
                .init("role", .textString(role.rawValue)),
                .init("stateRootUUID", .optional(stateRootUUID)),
            ])
        )
    }

    public static func sign(
        projectionDigestSHA256: String,
        purpose: ProviderHandoffKeyPurposeV1,
        signerKeyID: String,
        signerRole: ProviderHandoffKeyRoleV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        trustRegistryRevision: UInt64,
        privateKey: Data
    ) throws -> ProviderHandoffSignatureV1 {
        let digest: Data
        do {
            digest = try ProviderHandoffDigest.parseSHA256(projectionDigestSHA256)
        } catch {
            throw ProviderHandoffCryptoError.invalidDigest
        }
        let message = try signatureMessage(
            purpose: purpose,
            signerKeyID: signerKeyID,
            signerRole: signerRole,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            trustRegistryRevision: trustRegistryRevision,
            canonicalBytesVersion: 1,
            projectionDigest: digest
        )
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        } catch {
            throw ProviderHandoffCryptoError.invalidEd25519Key
        }
        let signature = try key.signature(for: message)
        return ProviderHandoffSignatureV1(
            purpose: purpose,
            signerKeyID: signerKeyID,
            signerRole: signerRole,
            providerFingerprint: providerFingerprint,
            stateRootUUID: stateRootUUID,
            trustRegistryRevision: trustRegistryRevision,
            signedProjectionDigestSHA256: projectionDigestSHA256,
            signature: signature
        )
    }

    public static func verify(
        _ signature: ProviderHandoffSignatureV1,
        publicKey: Data
    ) throws {
        guard
            signature.algorithm == .ed25519V1,
            signature.canonicalBytesVersion == 1,
            signature.signature.count == 64
        else {
            throw ProviderHandoffCryptoError.invalidSignature
        }
        let digest: Data
        do {
            digest = try ProviderHandoffDigest.parseSHA256(
                signature.signedProjectionDigestSHA256
            )
        } catch {
            throw ProviderHandoffCryptoError.invalidDigest
        }
        let message = try signatureMessage(
            purpose: signature.purpose,
            signerKeyID: signature.signerKeyID,
            signerRole: signature.signerRole,
            providerFingerprint: signature.providerFingerprint,
            stateRootUUID: signature.stateRootUUID,
            trustRegistryRevision: signature.trustRegistryRevision,
            canonicalBytesVersion: signature.canonicalBytesVersion,
            projectionDigest: digest
        )
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw ProviderHandoffCryptoError.invalidEd25519Key
        }
        guard key.isValidSignature(signature.signature, for: message) else {
            throw ProviderHandoffCryptoError.invalidSignature
        }
    }

    /// Performs the exact X25519/HKDF-SHA256/XChaCha20-Poly1305-IETF primitive.
    ///
    /// Callers own the closed handoff salt, info and associated-data projections.
    /// The returned ciphertext excludes the nonce and ephemeral public key.
    public static func seal(
        _ plaintext: Data,
        destinationPublicKey: Data,
        nonce: Data,
        salt: Data,
        info: Data,
        associatedData: Data,
        ephemeralPrivateKey: Data? = nil
    ) throws -> ProviderHandoffXChaChaSealedBox {
        try validateX25519PublicKey(destinationPublicKey)
        guard nonce.count == 24 else {
            throw ProviderHandoffCryptoError.invalidNonce
        }
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        do {
            if let ephemeralPrivateKey {
                ephemeral = try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: ephemeralPrivateKey
                )
            } else {
                ephemeral = Curve25519.KeyAgreement.PrivateKey()
            }
        } catch {
            throw ProviderHandoffCryptoError.invalidX25519Key
        }
        let destination: Curve25519.KeyAgreement.PublicKey
        do {
            destination = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: destinationPublicKey
            )
        } catch {
            throw ProviderHandoffCryptoError.invalidX25519Key
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: destination)
        try rejectAllZero(shared)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
        let transport = try xChaChaSeal(
            plaintext,
            key: key,
            nonce: nonce,
            associatedData: associatedData
        )
        return ProviderHandoffXChaChaSealedBox(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            nonce: nonce,
            ciphertext: transport
        )
    }

    public static func open(
        _ box: ProviderHandoffXChaChaSealedBox,
        destinationPrivateKey: Data,
        salt: Data,
        info: Data,
        associatedData: Data
    ) throws -> Data {
        try validateX25519PublicKey(box.ephemeralPublicKey)
        guard box.nonce.count == 24 else {
            throw ProviderHandoffCryptoError.invalidNonce
        }
        let destination: Curve25519.KeyAgreement.PrivateKey
        let ephemeral: Curve25519.KeyAgreement.PublicKey
        do {
            destination = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: destinationPrivateKey
            )
            ephemeral = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: box.ephemeralPublicKey
            )
        } catch {
            throw ProviderHandoffCryptoError.invalidX25519Key
        }
        let shared = try destination.sharedSecretFromKeyAgreement(with: ephemeral)
        try rejectAllZero(shared)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
        do {
            return try xChaChaOpen(
                box.ciphertext,
                key: key,
                nonce: box.nonce,
                associatedData: associatedData
            )
        } catch let error as ProviderHandoffCryptoError {
            throw error
        } catch {
            throw ProviderHandoffCryptoError.authenticationFailed
        }
    }

    /// HChaCha20 from the XChaCha20 construction, exposed for fixed-vector proof.
    public static func hChaCha20(key: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 16 else {
            throw ProviderHandoffCryptoError.invalidNonce
        }
        var state: [UInt32] = [
            0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574,
        ]
        state.append(contentsOf: words(from: key))
        state.append(contentsOf: words(from: nonce))
        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }
        var output = Data()
        for index in [0, 1, 2, 3, 12, 13, 14, 15] {
            var value = state[index].littleEndian
            withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func signatureMessage(
        purpose: ProviderHandoffKeyPurposeV1,
        signerKeyID: String,
        signerRole: ProviderHandoffKeyRoleV1,
        providerFingerprint: String?,
        stateRootUUID: String?,
        trustRegistryRevision: UInt64,
        canonicalBytesVersion: UInt32,
        projectionDigest: Data
    ) throws -> Data {
        let projection: ProviderHandoffCanonicalValue = .map([
            .init("algorithm", .textString(ProviderHandoffSignatureAlgorithmV1.ed25519V1.rawValue)),
            .init("canonicalBytesVersion", .unsigned(UInt64(canonicalBytesVersion))),
            .init("providerFingerprint", .optional(providerFingerprint)),
            .init("purpose", .textString(purpose.rawValue)),
            .init("signedProjectionDigestSHA256", .byteString(projectionDigest)),
            .init("signerKeyID", .textString(signerKeyID)),
            .init("signerRole", .textString(signerRole.rawValue)),
            .init("stateRootUUID", .optional(stateRootUUID)),
            .init("trustRegistryRevision", .unsigned(trustRegistryRevision)),
        ])
        var message = Data("container-handoff-signature-v1".utf8)
        message.append(0)
        message.append(try ProviderHandoffCanonicalCBOR.encode(projection))
        return message
    }

    public static func validateX25519PublicKey(_ key: Data) throws {
        guard key.count == 32, key[31] & 0x80 == 0 else {
            throw ProviderHandoffCryptoError.invalidX25519Key
        }
        let modulus = Data([0xed] + Array(repeating: 0xff, count: 30) + [0x7f])
        var relation = 0
        for index in stride(from: 31, through: 0, by: -1) where relation == 0 {
            if key[index] < modulus[index] {
                relation = -1
            } else if key[index] > modulus[index] {
                relation = 1
            }
        }
        guard relation < 0 else {
            throw ProviderHandoffCryptoError.invalidX25519Key
        }
        let isZero = key.allSatisfy { $0 == 0 }
        let isOne = key[0] == 1 && key.dropFirst().allSatisfy { $0 == 0 }
        guard !isZero, !isOne else {
            throw ProviderHandoffCryptoError.lowOrderX25519Key
        }
    }

    private static func rejectAllZero(_ secret: SharedSecret) throws {
        let allZero = secret.withUnsafeBytes { rawBuffer in
            rawBuffer.reduce(UInt8(0), |) == 0
        }
        guard !allZero else {
            throw ProviderHandoffCryptoError.lowOrderX25519Key
        }
    }

    private static func xChaChaSeal(
        _ plaintext: Data,
        key: SymmetricKey,
        nonce: Data,
        associatedData: Data
    ) throws -> Data {
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let subkey = try hChaCha20(key: keyBytes, nonce: Data(nonce.prefix(16)))
        var ietfNonce = Data(repeating: 0, count: 4)
        ietfNonce.append(nonce.suffix(8))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: subkey),
            nonce: try ChaChaPoly.Nonce(data: ietfNonce),
            authenticating: associatedData
        )
        var transport = sealed.ciphertext
        transport.append(sealed.tag)
        return transport
    }

    private static func xChaChaOpen(
        _ transport: Data,
        key: SymmetricKey,
        nonce: Data,
        associatedData: Data
    ) throws -> Data {
        guard transport.count >= 16 else {
            throw ProviderHandoffCryptoError.authenticationFailed
        }
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let subkey = try hChaCha20(key: keyBytes, nonce: Data(nonce.prefix(16)))
        var ietfNonce = Data(repeating: 0, count: 4)
        ietfNonce.append(nonce.suffix(8))
        let ciphertext = transport.dropLast(16)
        let tag = transport.suffix(16)
        let sealed = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: ietfNonce),
            ciphertext: ciphertext,
            tag: tag
        )
        return try ChaChaPoly.open(
            sealed,
            using: SymmetricKey(data: subkey),
            authenticating: associatedData
        )
    }

    private static func words(from data: Data) -> [UInt32] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            let byte0 = UInt32(data[offset])
            let byte1 = UInt32(data[offset + 1]) << 8
            let byte2 = UInt32(data[offset + 2]) << 16
            let byte3 = UInt32(data[offset + 3]) << 24
            return byte0 | byte1 | byte2 | byte3
        }
    }

    private static func quarterRound(
        _ state: inout [UInt32],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int
    ) {
        state[a] &+= state[b]
        state[d] = rotateLeft(state[d] ^ state[a], by: 16)
        state[c] &+= state[d]
        state[b] = rotateLeft(state[b] ^ state[c], by: 12)
        state[a] &+= state[b]
        state[d] = rotateLeft(state[d] ^ state[a], by: 8)
        state[c] &+= state[d]
        state[b] = rotateLeft(state[b] ^ state[c], by: 7)
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}
