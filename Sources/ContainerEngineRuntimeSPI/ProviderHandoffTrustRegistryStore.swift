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
import Security

public enum ProviderHandoffTrustRegistryStoreError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case conflictingArchive(UInt64)
    case invalidEncoding
    case invalidInitialRevision(UInt64)
    case keychain(OSStatus)
    case notFound
    case registryTooLarge

    public var description: String {
        switch self {
        case .conflictingArchive(let revision):
            "provider handoff trust registry revision \(revision) conflicts with its immutable Keychain archive"
        case .invalidEncoding:
            "provider handoff trust registry Keychain value is invalid"
        case .invalidInitialRevision(let revision):
            "provider handoff initial trust registry revision must be 1, found \(revision)"
        case .keychain(let status):
            "provider handoff trust registry Keychain operation failed with status \(status)"
        case .notFound:
            "provider handoff trust registry does not exist"
        case .registryTooLarge:
            "provider handoff trust registry exceeds its 4 MiB bound"
        }
    }
}

/// Current-user Keychain persistence for signed trust-registry revisions.
///
/// Every accepted revision is first written under an immutable revision account.
/// The latest account is then replaced. A crash between those operations is safe:
/// retry observes the byte-identical archive and publishes the latest pointer.
public struct ProviderHandoffTrustRegistryStore: Sendable {
    public static let maximumRegistryBytes = 4 * 1024 * 1024

    public static func account(forStateRootUUID stateRootUUID: UUID) -> String {
        "trust-registry-v1.\(stateRootUUID.uuidString.lowercased())"
    }

    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = "io.github.stephenlclarke.container-engine.provider-handoff",
        account: String = "trust-registry-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load(
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    ) throws -> ProviderHandoffValidatedTrustRegistryV1 {
        let registry = try decode(read(account: account))
        return try ProviderHandoffTrustRegistryValidator.validate(
            registry,
            bootstrap: bootstrap
        )
    }

    public func loadRevision(
        _ revision: UInt64,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    ) throws -> ProviderHandoffValidatedTrustRegistryV1 {
        let registry = try decode(read(account: archiveAccount(revision)))
        guard registry.registryRevision == revision else {
            throw ProviderHandoffTrustRegistryStoreError.invalidEncoding
        }
        return try ProviderHandoffTrustRegistryValidator.validate(
            registry,
            bootstrap: bootstrap
        )
    }

    @discardableResult
    public func install(
        _ registry: ProviderHandoffTrustRegistryV1,
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1
    ) throws -> ProviderHandoffValidatedTrustRegistryV1 {
        let previous: ProviderHandoffTrustRegistryV1?
        do {
            previous = try decode(read(account: account))
        } catch ProviderHandoffTrustRegistryStoreError.notFound {
            previous = nil
        }
        if previous == nil, registry.registryRevision != 1 {
            throw ProviderHandoffTrustRegistryStoreError.invalidInitialRevision(
                registry.registryRevision
            )
        }
        let validated = try ProviderHandoffTrustRegistryValidator.validate(
            registry,
            bootstrap: bootstrap,
            previousRegistry: previous
        )
        let encoded = try encode(registry)
        try archive(encoded, revision: registry.registryRevision)
        try replaceLatest(encoded)
        return validated
    }

    private func archive(_ data: Data, revision: UInt64) throws {
        let revisionAccount = archiveAccount(revision)
        do {
            try add(data, account: revisionAccount)
        } catch ProviderHandoffTrustRegistryStoreError.keychain(errSecDuplicateItem) {
            guard try read(account: revisionAccount) == data else {
                throw ProviderHandoffTrustRegistryStoreError.conflictingArchive(
                    revision
                )
            }
        }
    }

    private func replaceLatest(_ data: Data) throws {
        let match = baseQuery(account: account)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(
            match as CFDictionary,
            attributes as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data, account: account)
        default:
            throw ProviderHandoffTrustRegistryStoreError.keychain(status)
        }
    }

    private func add(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderHandoffTrustRegistryStoreError.keychain(status)
        }
    }

    private func read(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw ProviderHandoffTrustRegistryStoreError.invalidEncoding
            }
            guard data.count <= Self.maximumRegistryBytes else {
                throw ProviderHandoffTrustRegistryStoreError.registryTooLarge
            }
            return data
        case errSecItemNotFound:
            throw ProviderHandoffTrustRegistryStoreError.notFound
        default:
            throw ProviderHandoffTrustRegistryStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    static func removeForTesting(
        service: String,
        account: String,
        archivedRevisions: ClosedRange<UInt64>
    ) throws {
        let archiveAccounts = archivedRevisions.map { revision in
            "\(account).revision.\(revision)"
        }
        for value in [account] + archiveAccounts {
            let status = SecItemDelete(
                [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: value,
                    kSecAttrSynchronizable: kCFBooleanFalse as Any,
                ] as CFDictionary)
            guard
                status == errSecSuccess || status == errSecItemNotFound
            else {
                throw ProviderHandoffTrustRegistryStoreError.keychain(status)
            }
        }
    }

    private func archiveAccount(_ revision: UInt64) -> String {
        "\(account).revision.\(revision)"
    }

    private func encode(_ registry: ProviderHandoffTrustRegistryV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(registry)
        guard data.count <= Self.maximumRegistryBytes else {
            throw ProviderHandoffTrustRegistryStoreError.registryTooLarge
        }
        return data
    }

    private func decode(_ data: Data) throws -> ProviderHandoffTrustRegistryV1 {
        do {
            return try JSONDecoder().decode(
                ProviderHandoffTrustRegistryV1.self,
                from: data
            )
        } catch {
            throw ProviderHandoffTrustRegistryStoreError.invalidEncoding
        }
    }
}
