//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation
import Security

public struct ProviderHandoffGatewayTransactionSecretBindingV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var tokenID: String
    public var manifestID: String
    public var trustRegistryRevision: UInt64
    public var destinationProviderFingerprint: String
    public var destinationStateRootUUID: String
    public var resultingAuthorityLineageUUID: String
    public var resultingLineageDigestKeyVersion: UInt64

    public init(
        tokenID: String,
        manifestID: String,
        trustRegistryRevision: UInt64,
        destinationProviderFingerprint: String,
        destinationStateRootUUID: String,
        resultingAuthorityLineageUUID: String,
        resultingLineageDigestKeyVersion: UInt64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.tokenID = tokenID
        self.manifestID = manifestID
        self.trustRegistryRevision = trustRegistryRevision
        self.destinationProviderFingerprint = destinationProviderFingerprint
        self.destinationStateRootUUID = destinationStateRootUUID
        self.resultingAuthorityLineageUUID = resultingAuthorityLineageUUID
        self.resultingLineageDigestKeyVersion =
            resultingLineageDigestKeyVersion
    }
}

public struct ProviderHandoffGatewayTransactionSecretV1:
    Equatable,
    Sendable
{
    public let binding: ProviderHandoffGatewayTransactionSecretBindingV1
    package let rawDerivationKey: Data

    package init(
        binding: ProviderHandoffGatewayTransactionSecretBindingV1,
        rawDerivationKey: Data
    ) {
        self.binding = binding
        self.rawDerivationKey = rawDerivationKey
    }

    /// Derives one bounded, domain-separated transaction value. Callers use
    /// distinct domains for lineage material, possession challenges, nonces,
    /// and ephemeral X25519 keys, making every crash replay byte-exact without
    /// persisting those individual values.
    package func derive(
        domain: String,
        discriminator: String = "",
        count: Int
    ) throws -> Data {
        guard
            !domain.isEmpty,
            !domain.utf8.contains(0),
            !discriminator.utf8.contains(0),
            domain.utf8.count <= 256,
            discriminator.utf8.count <= 1024,
            count > 0,
            count <= 32,
            rawDerivationKey.count == 32
        else {
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .invalidRecord
        }
        let digest = ProviderHandoffDigest.hmacSHA256(
            key: rawDerivationKey,
            data: Data("\(domain)\u{0}\(discriminator)".utf8)
        )
        return try Data(
            ProviderHandoffDigest.parseSHA256(digest).prefix(count)
        )
    }
}

public enum ProviderHandoffGatewayTransactionSecretStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case bindingMismatch
    case invalidEncoding
    case invalidRecord
    case keychain(OSStatus)
    case notFound

    public var description: String {
        switch self {
        case .bindingMismatch:
            "provider handoff gateway transaction secret binding changed"
        case .invalidEncoding:
            "provider handoff gateway transaction secret encoding is invalid"
        case .invalidRecord:
            "provider handoff gateway transaction secret record is invalid"
        case let .keychain(status):
            "provider handoff gateway transaction secret Keychain operation failed with status \(status)"
        case .notFound:
            "provider handoff gateway transaction secret does not exist"
        }
    }
}

/// Durable current-user seed for every secret the gateway creates within one
/// token/manifest transaction.
///
/// One immutable, non-synchronizing, device-only Keychain item makes
/// possession challenges and the resulting lineage key byte-identical after a
/// process crash. A changed destination, trust revision, lineage, or key
/// version necessarily addresses a different item and cannot adopt old bytes.
public struct ProviderHandoffGatewayTransactionSecretStore: Sendable {
    public static let maximumRecordBytes = 4 * 1024

    public let service: String
    public let accountPrefix: String
    public let accessGroup: String?

    public init(
        service: String =
            "io.github.stephenlclarke.container-engine.provider-handoff",
        accountPrefix: String = "gateway-transaction-secret-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accountPrefix = accountPrefix
        self.accessGroup = accessGroup
    }

    public func loadOrCreate(
        binding: ProviderHandoffGatewayTransactionSecretBindingV1
    ) throws -> ProviderHandoffGatewayTransactionSecretV1 {
        try Self.validate(binding)
        do {
            return try load(binding: binding)
        } catch ProviderHandoffGatewayTransactionSecretStoreError.notFound {
            let stored = StoredSecretV1(
                schemaVersion: StoredSecretV1.currentSchemaVersion,
                binding: binding,
                rawDerivationKey: Self.randomKey()
            )
            let encoded = try Self.encode(stored)
            do {
                try add(encoded, account: account(for: binding))
                return try Self.secret(stored, expectedBinding: binding)
            } catch ProviderHandoffGatewayTransactionSecretStoreError
                .keychain(errSecDuplicateItem)
            {
                return try load(binding: binding)
            }
        }
    }

    public func load(
        binding: ProviderHandoffGatewayTransactionSecretBindingV1
    ) throws -> ProviderHandoffGatewayTransactionSecretV1 {
        try Self.validate(binding)
        return try Self.secret(
            Self.decode(read(account: account(for: binding))),
            expectedBinding: binding
        )
    }

    private func add(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        query[kSecValueData] = data
        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .keychain(status)
        }
    }

    private func read(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let interactionStatus =
            ProviderHandoffKeychainQuery.disableAuthenticationUI(in: &query)
        guard interactionStatus == errSecSuccess else {
            throw ProviderHandoffGatewayTransactionSecretStoreError.keychain(
                interactionStatus
            )
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                data.count <= Self.maximumRecordBytes
            else {
                throw ProviderHandoffGatewayTransactionSecretStoreError
                    .invalidEncoding
            }
            return data
        case errSecItemNotFound:
            throw ProviderHandoffGatewayTransactionSecretStoreError.notFound
        default:
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .keychain(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    private func account(
        for binding: ProviderHandoffGatewayTransactionSecretBindingV1
    ) throws -> String {
        let digest = try ProviderHandoffDigest.domain(
            "container-handoff-gateway-transaction-secret-binding-v1",
            projection: .map([
                .init(
                    "destinationProviderFingerprint",
                    .textString(binding.destinationProviderFingerprint)
                ),
                .init(
                    "destinationStateRootUUID",
                    .textString(binding.destinationStateRootUUID)
                ),
                .init("manifestID", .textString(binding.manifestID)),
                .init(
                    "resultingAuthorityLineageUUID",
                    .textString(binding.resultingAuthorityLineageUUID)
                ),
                .init(
                    "resultingLineageDigestKeyVersion",
                    .unsigned(binding.resultingLineageDigestKeyVersion)
                ),
                .init(
                    "schemaVersion",
                    .unsigned(UInt64(binding.schemaVersion))
                ),
                .init("tokenID", .textString(binding.tokenID)),
                .init(
                    "trustRegistryRevision",
                    .unsigned(binding.trustRegistryRevision)
                )
            ])
        )
        return "\(accountPrefix):\(digest)"
    }

    private struct StoredSecretV1: Codable, Equatable, Sendable {
        static let currentSchemaVersion: UInt32 = 1

        var schemaVersion: UInt32
        var binding: ProviderHandoffGatewayTransactionSecretBindingV1
        var rawDerivationKey: Data
    }

    private static func secret(
        _ stored: StoredSecretV1,
        expectedBinding: ProviderHandoffGatewayTransactionSecretBindingV1
    ) throws -> ProviderHandoffGatewayTransactionSecretV1 {
        guard
            stored.schemaVersion == StoredSecretV1.currentSchemaVersion,
            stored.binding == expectedBinding,
            stored.rawDerivationKey.count == 32
        else {
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .bindingMismatch
        }
        try validate(stored.binding)
        return ProviderHandoffGatewayTransactionSecretV1(
            binding: stored.binding,
            rawDerivationKey: stored.rawDerivationKey
        )
    }

    private static func validate(
        _ binding: ProviderHandoffGatewayTransactionSecretBindingV1
    ) throws {
        let fingerprint = binding.destinationProviderFingerprint
            .hasPrefix("sha256:")
            ? String(binding.destinationProviderFingerprint.dropFirst(7))
            : ""
        guard
            binding.schemaVersion
            == ProviderHandoffGatewayTransactionSecretBindingV1
            .currentSchemaVersion,
            validIdentifier(binding.tokenID),
            validIdentifier(binding.manifestID),
            binding.trustRegistryRevision > 0,
            (try? ProviderHandoffDigest.parseSHA256(fingerprint))?.count == 32,
            canonicalUUID(binding.destinationStateRootUUID),
            canonicalUUID(binding.resultingAuthorityLineageUUID),
            binding.resultingLineageDigestKeyVersion > 0
        else {
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .invalidRecord
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && !value.utf8.contains(0)
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        guard let identifier = UUID(uuidString: value) else { return false }
        return identifier.uuidString.lowercased() == value
    }

    private static func randomKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data(
            (0 ..< 32).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            }
        )
    }

    private static func encode(_ value: StoredSecretV1) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let encoded = try encoder.encode(value)
            guard encoded.count <= maximumRecordBytes else {
                throw ProviderHandoffGatewayTransactionSecretStoreError
                    .invalidEncoding
            }
            return encoded
        } catch let error as ProviderHandoffGatewayTransactionSecretStoreError {
            throw error
        } catch {
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .invalidEncoding
        }
    }

    private static func decode(_ data: Data) throws -> StoredSecretV1 {
        guard data.count <= maximumRecordBytes else {
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .invalidEncoding
        }
        do {
            let value = try JSONDecoder().decode(StoredSecretV1.self, from: data)
            guard try encode(value) == data else {
                throw ProviderHandoffGatewayTransactionSecretStoreError
                    .invalidEncoding
            }
            return value
        } catch let error as ProviderHandoffGatewayTransactionSecretStoreError {
            throw error
        } catch {
            throw ProviderHandoffGatewayTransactionSecretStoreError
                .invalidEncoding
        }
    }
}
