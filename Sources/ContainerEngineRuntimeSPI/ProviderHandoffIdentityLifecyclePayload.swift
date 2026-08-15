//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// The sole portable writer-owned identity, lifecycle, and event record for a
/// container during a coherent provider handoff.
public struct ProviderHandoffIdentityLifecycleContainerV1:
    Codable, Equatable, Sendable
{
    public static let schemaVersion: UInt32 = 1

    public var lifecycle: ContainerLifecycleRecordV2
    public var events: [ContainerAuthorityEventV2]
    public var pendingOperationIDs: [String]
    public var pendingFinalizationIDs: [String]

    public init(
        lifecycle: ContainerLifecycleRecordV2,
        events: [ContainerAuthorityEventV2] = [],
        pendingOperationIDs: [String] = [],
        pendingFinalizationIDs: [String] = []
    ) {
        self.lifecycle = lifecycle
        self.events = events
        self.pendingOperationIDs = pendingOperationIDs
        self.pendingFinalizationIDs = pendingFinalizationIDs
    }
}

public enum ProviderHandoffIdentityLifecyclePayloadError:
    Error, Equatable, Sendable
{
    case emptyPackage
    case duplicateContainerID(String)
    case duplicateName(String)
    case inconsistentProviderFingerprint(String)
    case invalidContainer(String)
    case invalidEventSequence(String)
    case invalidPackage
    case recordTooLarge(String)
}

/// Deterministic package projection for the `identityLifecycleEvents` handoff
/// part. Each bounded record is canonical CBOR containing a sorted,
/// millisecond-precision JSON value so providers can adopt it without
/// implementation types.
public enum ProviderHandoffIdentityLifecyclePayloadCodec {
    public static let mediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-identity-lifecycle-events.v1+cbor"
    public static let recordKind = "identity-lifecycle-events-container-v1"

    public static func package(
        containers: [ProviderHandoffIdentityLifecycleContainerV1],
        sourceStateRootUUID: String
    ) throws -> ProviderHandoffPayloadPackageV1 {
        let validated = try validate(containers)
        guard canonicalUUID(sourceStateRootUUID) else {
            throw ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        }
        return try ProviderHandoffPayloadPackageV1(
            partKind: .identityLifecycleEvents,
            entries: validated.map { container in
                let record = try encode(container)
                guard
                    record.count
                    <= ProviderHandoffPayloadPackageFileDecoder
                    .maximumCanonicalRecordBytes
                else {
                    throw
                        ProviderHandoffIdentityLifecyclePayloadError
                        .recordTooLarge(container.lifecycle.containerID)
                }
                return ProviderHandoffPayloadPackageEntryV1(
                    entryID: container.lifecycle.containerID,
                    sourceStateRootUUID: sourceStateRootUUID,
                    recordKind: recordKind,
                    schemaVersion:
                    ProviderHandoffIdentityLifecycleContainerV1.schemaVersion,
                    canonicalRecordBytes: record
                )
            }
        )
    }

    public static func containers(
        from package: ProviderHandoffPayloadPackageV1
    ) throws -> [ProviderHandoffIdentityLifecycleContainerV1] {
        guard
            package.schemaVersion
            == ProviderHandoffPayloadPackageV1.currentSchemaVersion,
            package.partKind == .identityLifecycleEvents
        else {
            throw ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        }
        guard let sourceStateRootUUID = package.entries.first?
            .sourceStateRootUUID
        else {
            throw ProviderHandoffIdentityLifecyclePayloadError.emptyPackage
        }
        guard
            canonicalUUID(sourceStateRootUUID),
            package.entries.allSatisfy({
                $0.sourceStateRootUUID == sourceStateRootUUID
            })
        else {
            throw ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        }
        let entryIDs = package.entries.map(\.entryID)
        guard
            entryIDs == entryIDs.sorted(by: utf8Precedes)
        else {
            throw ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
        }
        let decoded = try package.entries.map { entry in
            guard
                entry.recordKind == recordKind,
                entry.schemaVersion
                == ProviderHandoffIdentityLifecycleContainerV1.schemaVersion,
                canonicalUUID(entry.sourceStateRootUUID)
            else {
                throw ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
            }
            guard
                case let .byteString(json) =
                try ProviderHandoffCanonicalCBOR
                    .decode(entry.canonicalRecordBytes)
            else {
                throw ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
            }
            let container = try decoder().decode(
                ProviderHandoffIdentityLifecycleContainerV1.self,
                from: json
            )
            guard
                try encoder().encode(container) == json,
                entry.entryID == container.lifecycle.containerID
            else {
                throw ProviderHandoffIdentityLifecyclePayloadError.invalidPackage
            }
            return container
        }
        return try validate(decoded)
    }

    private static func validate(
        _ containers: [ProviderHandoffIdentityLifecycleContainerV1]
    ) throws -> [ProviderHandoffIdentityLifecycleContainerV1] {
        guard !containers.isEmpty else {
            throw ProviderHandoffIdentityLifecyclePayloadError.emptyPackage
        }
        var identifiers = Set<String>()
        var names = Set<String>()
        var eventSequences = Set<UInt64>()
        var selectedProviderFingerprint: String?
        for container in containers {
            let lifecycle = container.lifecycle
            guard
                lifecycle.schemaVersion == ContainerLifecycleRecordV2.schemaVersion,
                isDockerContainerID(lifecycle.containerID),
                !lifecycle.canonicalName.isEmpty,
                isNFC(lifecycle.canonicalName),
                !lifecycle.immutableBundleKey.isEmpty,
                isNFC(lifecycle.immutableBundleKey),
                validFingerprint(lifecycle.selectedProviderFingerprint),
                isNFC(lifecycle.snapshot.error),
                lifecycle.snapshot.health?.log.allSatisfy({ isNFC($0.output) })
                != false,
                container.pendingOperationIDs.allSatisfy({
                    !$0.isEmpty && isNFC($0)
                }),
                container.pendingFinalizationIDs.allSatisfy({
                    !$0.isEmpty && isNFC($0)
                })
            else {
                throw ProviderHandoffIdentityLifecyclePayloadError.invalidContainer(
                    lifecycle.containerID
                )
            }
            if let selectedProviderFingerprint {
                guard
                    selectedProviderFingerprint
                    == lifecycle.selectedProviderFingerprint
                else {
                    throw
                        ProviderHandoffIdentityLifecyclePayloadError
                        .inconsistentProviderFingerprint(
                            lifecycle.containerID
                        )
                }
            } else {
                selectedProviderFingerprint =
                    lifecycle.selectedProviderFingerprint
            }
            guard identifiers.insert(lifecycle.containerID).inserted else {
                throw
                    ProviderHandoffIdentityLifecyclePayloadError
                    .duplicateContainerID(lifecycle.containerID)
            }
            guard names.insert(lifecycle.canonicalName).inserted else {
                throw
                    ProviderHandoffIdentityLifecyclePayloadError
                    .duplicateName(lifecycle.canonicalName)
            }
            var previousSequence: UInt64 = 0
            var previousTransitionRevision: UInt64 = 0
            var previousOperationGeneration: UInt64 = 0
            for event in container.events {
                guard
                    event.actorID == lifecycle.containerID,
                    isNFC(event.type),
                    isNFC(event.action),
                    event.attributes.allSatisfy({
                        isNFC($0.key) && isNFC($0.value)
                    }),
                    event.sequence > previousSequence,
                    eventSequences.insert(event.sequence).inserted,
                    event.transitionRevision >= previousTransitionRevision,
                    event.transitionRevision
                    <= lifecycle.snapshot.transitionRevision,
                    event.operationGeneration >= previousOperationGeneration,
                    event.operationGeneration
                    <= lifecycle.snapshot.operationGeneration
                else {
                    throw
                        ProviderHandoffIdentityLifecyclePayloadError
                        .invalidEventSequence(lifecycle.containerID)
                }
                previousSequence = event.sequence
                previousTransitionRevision = event.transitionRevision
                previousOperationGeneration = event.operationGeneration
            }
        }
        return containers.sorted {
            utf8Precedes(
                $0.lifecycle.containerID,
                $1.lifecycle.containerID
            )
        }
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func isDockerContainerID(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
            }
    }

    private static func validFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        return (try? ProviderHandoffDigest.parseSHA256(
            String(value.dropFirst("sha256:".count))
        )) != nil
    }

    private static func isNFC(_ value: String) -> Bool {
        value.utf8.elementsEqual(
            value.precomposedStringWithCanonicalMapping.utf8
        )
    }

    private static func canonicalUUID(_ value: String?) -> Bool {
        guard
            let value,
            let identifier = UUID(uuidString: value)
        else {
            return false
        }
        return identifier.uuidString.lowercased() == value
    }

    private static func encode(
        _ container: ProviderHandoffIdentityLifecycleContainerV1
    ) throws -> Data {
        try ProviderHandoffCanonicalCBOR.encode(
            .byteString(encoder().encode(container))
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
