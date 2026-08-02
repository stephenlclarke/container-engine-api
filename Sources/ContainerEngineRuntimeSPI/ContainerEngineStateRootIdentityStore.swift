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

import Darwin
import Foundation

/// Owns the immutable UUID of one provider state root.
///
/// The path is provider-owned and separate from the gateway selection record.
/// Replacing the directory therefore produces a different provider fingerprint
/// even when the provider binary and capability declaration are unchanged.
public struct ContainerEngineStateRootIdentityStore: Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path.standardizedFileURL
    }

    public func loadOrCreate() throws -> UUID {
        try loadOrCreate(initial: UUID())
    }

    /// Creates a new identity with a migration-supplied UUID when absent.
    public func loadOrCreate(initial identifier: UUID) throws -> UUID {
        try prepareParentDirectory()
        if FileManager.default.fileExists(atPath: path.path) {
            return try load()
        }
        do {
            try create(identifier)
            return identifier
        } catch let error as POSIXError where error.code == .EEXIST {
            return try load()
        }
    }

    public func load() throws -> UUID {
        let descriptor = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        try validate(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 128 else {
            throw ContainerEngineProviderIdentityError.stateRootIdentityFileTooLarge
        }
        guard
            let value = String(data: data, encoding: .utf8),
            let identifier = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw ContainerEngineProviderIdentityError.invalidStateRootIdentity
        }
        return identifier
    }

    private func create(_ identifier: UUID) throws {
        let descriptor = open(
            path.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var keepFile = false
        defer {
            close(descriptor)
            if !keepFile {
                try? FileManager.default.removeItem(at: path)
            }
        }
        try validate(descriptor)
        let data = Data((identifier.uuidString.lowercased() + "\n").utf8)
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

    private func validate(_ descriptor: Int32) throws {
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
