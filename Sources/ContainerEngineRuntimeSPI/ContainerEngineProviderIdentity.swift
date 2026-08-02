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

public enum ContainerEngineProviderProfile: String, Codable, Sendable {
    case enhanced
    case stock
}

public enum ContainerEngineProviderKind: String, Codable, Sendable {
    case containerAuthority = "container-authority"
    case devcontainerStock = "devcontainer-stock"
}

public enum ContainerEngineCapabilityStatus: String, Codable, Sendable {
    case emulated
    case native
    case unavailable
}

public struct ContainerEngineProviderCapability:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public var identifier: String
    public var version: UInt32
    public var status: ContainerEngineCapabilityStatus

    public init(
        identifier: String,
        version: UInt32 = 1,
        status: ContainerEngineCapabilityStatus
    ) throws {
        guard Self.isValidIdentifier(identifier), version > 0 else {
            throw ContainerEngineProviderIdentityError.invalidCapability(identifier)
        }
        self.identifier = identifier
        self.version = version
        self.status = status
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            value.first?.isLetter == true,
            value.last?.isLetter == true || value.last?.isNumber == true
        else {
            return false
        }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
        }
    }
}

/// The provider-supplied, restart-stable parts of an Engine authority identity.
///
/// Deliberately absent are process IDs, boot IDs, sandbox generations and live
/// observations. Those values are reconciliation clocks, not provider identity.
public struct ContainerEngineProviderDeclaration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var profile: ContainerEngineProviderProfile
    public var kind: ContainerEngineProviderKind
    public var implementationVersion: String
    public var runtimeRevisions: [String: String]
    public var stateSchemaVersion: UInt64
    public var capabilities: [ContainerEngineProviderCapability]

    public init(
        profile: ContainerEngineProviderProfile,
        kind: ContainerEngineProviderKind,
        implementationVersion: String,
        runtimeRevisions: [String: String],
        stateSchemaVersion: UInt64,
        capabilities: [ContainerEngineProviderCapability]
    ) throws {
        guard
            !implementationVersion.isEmpty,
            stateSchemaVersion > 0,
            runtimeRevisions.allSatisfy({
                !$0.key.isEmpty && !$0.value.isEmpty
            })
        else {
            throw ContainerEngineProviderIdentityError.invalidDeclaration
        }
        let capabilityKeys = capabilities.map {
            "\($0.identifier)@\($0.version)"
        }
        guard Set(capabilityKeys).count == capabilityKeys.count else {
            throw ContainerEngineProviderIdentityError.duplicateCapability
        }
        schemaVersion = Self.currentSchemaVersion
        self.profile = profile
        self.kind = kind
        self.implementationVersion = implementationVersion
        self.runtimeRevisions = runtimeRevisions
        self.stateSchemaVersion = stateSchemaVersion
        self.capabilities = capabilities.sorted(by: Self.capabilityLess)
    }

    private static func capabilityLess(
        _ lhs: ContainerEngineProviderCapability,
        _ rhs: ContainerEngineProviderCapability
    ) -> Bool {
        if lhs.identifier != rhs.identifier {
            return lhs.identifier.utf8.lexicographicallyPrecedes(rhs.identifier.utf8)
        }
        return lhs.version < rhs.version
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case implementationVersion
        case kind
        case profile
        case runtimeRevisions
        case schemaVersion
        case stateSchemaVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ContainerEngineProviderIdentityError.unsupportedDeclarationSchema(
                schemaVersion
            )
        }
        try self.init(
            profile: container.decode(
                ContainerEngineProviderProfile.self,
                forKey: .profile
            ),
            kind: container.decode(
                ContainerEngineProviderKind.self,
                forKey: .kind
            ),
            implementationVersion: container.decode(
                String.self,
                forKey: .implementationVersion
            ),
            runtimeRevisions: container.decode(
                [String: String].self,
                forKey: .runtimeRevisions
            ),
            stateSchemaVersion: container.decode(
                UInt64.self,
                forKey: .stateSchemaVersion
            ),
            capabilities: container.decode(
                [ContainerEngineProviderCapability].self,
                forKey: .capabilities
            )
        )
    }
}

public struct ContainerEngineProviderFingerprint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var declaration: ContainerEngineProviderDeclaration
    public var stateRootUUID: UUID
    public var digest: String

    public init(
        declaration: ContainerEngineProviderDeclaration,
        stateRootUUID: UUID
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.declaration = declaration
        self.stateRootUUID = stateRootUUID
        digest = try Self.digest(
            declaration: declaration,
            stateRootUUID: stateRootUUID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case declaration
        case digest
        case schemaVersion
        case stateRootUUID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ContainerEngineProviderIdentityError.unsupportedFingerprintSchema(
                schemaVersion
            )
        }
        let declaration = try container.decode(
            ContainerEngineProviderDeclaration.self,
            forKey: .declaration
        )
        let stateRootUUID = try container.decode(UUID.self, forKey: .stateRootUUID)
        let digest = try container.decode(String.self, forKey: .digest)
        let expected = try Self.digest(
            declaration: declaration,
            stateRootUUID: stateRootUUID
        )
        guard digest == expected else {
            throw ContainerEngineProviderIdentityError.fingerprintDigestMismatch
        }
        self.schemaVersion = schemaVersion
        self.declaration = declaration
        self.stateRootUUID = stateRootUUID
        self.digest = digest
    }

    private static func digest(
        declaration: ContainerEngineProviderDeclaration,
        stateRootUUID: UUID
    ) throws -> String {
        let payload = FingerprintPayload(
            declaration: declaration,
            stateRootUUID: stateRootUUID.uuidString.lowercased()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        return "sha256:" + SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private struct FingerprintPayload: Encodable {
    var declaration: ContainerEngineProviderDeclaration
    var stateRootUUID: String
}

/// Persists the one provider selected for a state root.
///
/// A normal restart supplies the same declaration and receives the original
/// fingerprint. A different declaration fails closed; explicit handoff is a
/// separate protocol and cannot be approximated by overwriting this record.
public struct ContainerEngineProviderSelectionStore: Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path.standardizedFileURL
    }

    public func select(
        _ declaration: ContainerEngineProviderDeclaration
    ) throws -> ContainerEngineProviderFingerprint {
        try prepareParentDirectory()
        if FileManager.default.fileExists(atPath: path.path) {
            let existing = try load()
            guard existing.declaration == declaration else {
                throw ContainerEngineProviderIdentityError.providerMismatch(
                    selected: existing.digest
                )
            }
            return existing
        }

        let fingerprint = try ContainerEngineProviderFingerprint(
            declaration: declaration,
            stateRootUUID: UUID()
        )
        try create(fingerprint)
        return try load()
    }

    public func load() throws -> ContainerEngineProviderFingerprint {
        let descriptor = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 1024 * 1024 else {
            throw ContainerEngineProviderIdentityError.selectionFileTooLarge
        }
        return try JSONDecoder().decode(
            ContainerEngineProviderFingerprint.self,
            from: data
        )
    }

    private func create(_ fingerprint: ContainerEngineProviderFingerprint) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(fingerprint)
        let descriptor = open(
            path.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                let existing = try load()
                guard existing.declaration == fingerprint.declaration else {
                    throw ContainerEngineProviderIdentityError.providerMismatch(
                        selected: existing.digest
                    )
                }
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var keepFile = false
        defer {
            close(descriptor)
            if !keepFile {
                try? FileManager.default.removeItem(at: path)
            }
        }
        try validateFileDescriptor(descriptor)
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        keepFile = true
    }

    private func prepareParentDirectory() throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var status = stat()
        guard
            lstat(parent.path, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_mode & (S_IRWXG | S_IRWXO) == 0
        else {
            throw ContainerEngineProviderIdentityError.unsafeSelectionDirectory(
                parent.path
            )
        }
    }

    private func validateFileDescriptor(_ descriptor: Int32) throws {
        var status = stat()
        guard
            fstat(descriptor, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_mode & (S_IRWXG | S_IRWXO) == 0,
            status.st_nlink == 1
        else {
            throw ContainerEngineProviderIdentityError.unsafeSelectionFile(path.path)
        }
    }
}

public enum ContainerEngineProviderIdentityError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case duplicateCapability
    case fingerprintDigestMismatch
    case invalidCapability(String)
    case invalidDeclaration
    case providerMismatch(selected: String)
    case selectionFileTooLarge
    case unsafeSelectionDirectory(String)
    case unsafeSelectionFile(String)
    case unsupportedDeclarationSchema(UInt32)
    case unsupportedFingerprintSchema(UInt32)

    public var description: String {
        switch self {
        case .duplicateCapability:
            "provider declaration contains duplicate capability versions"
        case .fingerprintDigestMismatch:
            "provider fingerprint digest does not match its canonical payload"
        case let .invalidCapability(identifier):
            "invalid provider capability \(identifier)"
        case .invalidDeclaration:
            "invalid provider declaration"
        case let .providerMismatch(selected):
            "state root is already owned by provider \(selected); explicit handoff is required"
        case .selectionFileTooLarge:
            "provider selection file exceeds the 1 MiB safety limit"
        case let .unsafeSelectionDirectory(path):
            "unsafe provider selection directory at \(path)"
        case let .unsafeSelectionFile(path):
            "unsafe provider selection file at \(path)"
        case let .unsupportedDeclarationSchema(version):
            "unsupported provider declaration schema \(version)"
        case let .unsupportedFingerprintSchema(version):
            "unsupported provider fingerprint schema \(version)"
        }
    }
}
