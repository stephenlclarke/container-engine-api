//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation
import Security

public struct ProviderHandoffLineageKeyBindingV1:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var providerFingerprint: String
    public var sourceStateRootUUID: String
    public var authorityLineageUUID: String
    public var keyVersion: UInt64

    public init(
        providerFingerprint: String,
        sourceStateRootUUID: String,
        authorityLineageUUID: String,
        keyVersion: UInt64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.providerFingerprint = providerFingerprint
        self.sourceStateRootUUID = sourceStateRootUUID
        self.authorityLineageUUID = authorityLineageUUID
        self.keyVersion = keyVersion
    }
}

public enum ProviderHandoffLineageKeyStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case bindingMismatch
    case invalidBinding
    case invalidEncoding
    case invalidKey
    case keychain(OSStatus)
    case notFound

    public var description: String {
        switch self {
        case .bindingMismatch:
            "provider handoff lineage key does not match its provider, root, lineage, and version binding"
        case .invalidBinding:
            "provider handoff lineage key binding is invalid"
        case .invalidEncoding:
            "provider handoff lineage key Keychain value is invalid"
        case .invalidKey:
            "provider handoff lineage HMAC-SHA256 key is invalid"
        case let .keychain(status):
            "provider handoff lineage key Keychain operation failed with status \(status)"
        case .notFound:
            "provider handoff lineage key does not exist"
        }
    }
}

/// Current-user Keychain persistence for a provider-owned lineage HMAC key.
///
/// Each provider/root/lineage/version tuple is immutable and receives a
/// distinct non-synchronizing, device-only Keychain item. A duplicate
/// first-writer race adopts only a byte-valid winner with the exact binding.
/// Rotation therefore creates a new versioned item and can never silently
/// replace the key needed to verify an earlier handoff.
public struct ProviderHandoffLineageKeyStore: Sendable {
    public static let maximumRecordBytes = 4 * 1024

    public let service: String
    public let accountPrefix: String
    public let accessGroup: String?

    public init(
        service: String =
            "io.github.stephenlclarke.container-engine.provider-handoff",
        accountPrefix: String = "lineage-hmac-key-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accountPrefix = accountPrefix
        self.accessGroup = accessGroup
    }

    public func loadOrCreate(
        binding: ProviderHandoffLineageKeyBindingV1
    ) throws -> ProviderHandoffLineageKeyV1 {
        try Self.validate(binding)
        do {
            return try load(binding: binding)
        } catch ProviderHandoffLineageKeyStoreError.notFound {
            let value = StoredLineageKeyV1(
                schemaVersion: StoredLineageKeyV1.currentSchemaVersion,
                binding: binding,
                rawHMACSHA256Key: Self.randomKey()
            )
            let encoded = try Self.encode(value)
            do {
                try add(encoded, account: account(for: binding))
                return try Self.lineageKey(value, expectedBinding: binding)
            } catch ProviderHandoffLineageKeyStoreError
                .keychain(errSecDuplicateItem)
            {
                return try load(binding: binding)
            }
        }
    }

    public func load(
        binding: ProviderHandoffLineageKeyBindingV1
    ) throws -> ProviderHandoffLineageKeyV1 {
        try Self.validate(binding)
        let data = try read(account: account(for: binding))
        return try Self.lineageKey(
            Self.decode(data),
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
            throw ProviderHandoffLineageKeyStoreError.keychain(status)
        }
    }

    private func read(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        ProviderHandoffKeychainQuery.disableAuthenticationUI(in: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                data.count <= Self.maximumRecordBytes
            else {
                throw ProviderHandoffLineageKeyStoreError.invalidEncoding
            }
            return data
        case errSecItemNotFound:
            throw ProviderHandoffLineageKeyStoreError.notFound
        default:
            throw ProviderHandoffLineageKeyStoreError.keychain(status)
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
        for binding: ProviderHandoffLineageKeyBindingV1
    ) throws -> String {
        let digest = try ProviderHandoffDigest.domain(
            "container-handoff-lineage-key-binding-v1",
            projection: .map([
                .init(
                    "authorityLineageUUID",
                    .textString(binding.authorityLineageUUID)
                ),
                .init("keyVersion", .unsigned(binding.keyVersion)),
                .init(
                    "providerFingerprint",
                    .textString(binding.providerFingerprint)
                ),
                .init(
                    "schemaVersion",
                    .unsigned(UInt64(binding.schemaVersion))
                ),
                .init(
                    "sourceStateRootUUID",
                    .textString(binding.sourceStateRootUUID)
                )
            ])
        )
        return "\(accountPrefix):\(digest)"
    }

    static func removeForTesting(
        service: String,
        accountPrefix: String,
        binding: ProviderHandoffLineageKeyBindingV1
    ) throws {
        let store = ProviderHandoffLineageKeyStore(
            service: service,
            accountPrefix: accountPrefix
        )
        let status = try SecItemDelete(
            store.baseQuery(account: store.account(for: binding))
                as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderHandoffLineageKeyStoreError.keychain(status)
        }
    }

    private struct StoredLineageKeyV1: Codable, Equatable, Sendable {
        static let currentSchemaVersion: UInt32 = 1

        var schemaVersion: UInt32
        var binding: ProviderHandoffLineageKeyBindingV1
        var rawHMACSHA256Key: Data
    }

    private static func lineageKey(
        _ value: StoredLineageKeyV1,
        expectedBinding: ProviderHandoffLineageKeyBindingV1
    ) throws -> ProviderHandoffLineageKeyV1 {
        guard
            value.schemaVersion == StoredLineageKeyV1.currentSchemaVersion,
            value.binding == expectedBinding
        else {
            throw ProviderHandoffLineageKeyStoreError.bindingMismatch
        }
        try validate(value.binding)
        guard value.rawHMACSHA256Key.count == 32 else {
            throw ProviderHandoffLineageKeyStoreError.invalidKey
        }
        return ProviderHandoffLineageKeyV1(
            sourceStateRootUUID: value.binding.sourceStateRootUUID,
            authorityLineageUUID: value.binding.authorityLineageUUID,
            keyVersion: value.binding.keyVersion,
            rawHMACSHA256Key: value.rawHMACSHA256Key
        )
    }

    private static func validate(
        _ binding: ProviderHandoffLineageKeyBindingV1
    ) throws {
        let fingerprint = binding.providerFingerprint.hasPrefix("sha256:")
            ? String(binding.providerFingerprint.dropFirst(7))
            : ""
        guard
            binding.schemaVersion
            == ProviderHandoffLineageKeyBindingV1.currentSchemaVersion,
            (try? ProviderHandoffDigest.parseSHA256(fingerprint))?.count == 32,
            canonicalUUID(binding.sourceStateRootUUID),
            canonicalUUID(binding.authorityLineageUUID),
            binding.keyVersion > 0
        else {
            throw ProviderHandoffLineageKeyStoreError.invalidBinding
        }
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

    private static func encode(_ value: StoredLineageKeyV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            guard data.count <= maximumRecordBytes else {
                throw ProviderHandoffLineageKeyStoreError.invalidEncoding
            }
            return data
        } catch let error as ProviderHandoffLineageKeyStoreError {
            throw error
        } catch {
            throw ProviderHandoffLineageKeyStoreError.invalidEncoding
        }
    }

    private static func decode(_ data: Data) throws -> StoredLineageKeyV1 {
        guard data.count <= maximumRecordBytes else {
            throw ProviderHandoffLineageKeyStoreError.invalidEncoding
        }
        do {
            let value = try JSONDecoder().decode(
                StoredLineageKeyV1.self,
                from: data
            )
            guard try encode(value) == data else {
                throw ProviderHandoffLineageKeyStoreError.invalidEncoding
            }
            return value
        } catch let error as ProviderHandoffLineageKeyStoreError {
            throw error
        } catch {
            throw ProviderHandoffLineageKeyStoreError.invalidEncoding
        }
    }
}
