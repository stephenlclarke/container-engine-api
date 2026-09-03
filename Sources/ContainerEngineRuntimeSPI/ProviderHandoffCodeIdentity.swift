//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation
import Security

public struct ProviderHandoffCodeIdentityV1:
    Codable,
    Equatable,
    Sendable
{
    public var signingIdentifier: String
    public var teamIdentifier: String?
    public var designatedRequirementDigestSHA256: String

    public init(
        signingIdentifier: String,
        teamIdentifier: String?,
        designatedRequirementDigestSHA256: String
    ) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.designatedRequirementDigestSHA256 =
            designatedRequirementDigestSHA256
    }
}

public enum ProviderHandoffCodeIdentityError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidCode(OSStatus)
    case invalidIdentity
    case unavailable

    public var description: String {
        switch self {
        case let .invalidCode(status):
            "provider handoff code identity failed validation with status \(status)"
        case .invalidIdentity:
            "provider handoff code identity is incomplete"
        case .unavailable:
            "provider handoff code identity is unavailable"
        }
    }
}

/// Extracts the stable designated requirement and signing identity for a
/// provider executable. The gateway independently resolves the peer's same
/// values before accepting a public-key enrollment proposal.
public enum ProviderHandoffCodeIdentity {
    private static let currentIdentityCache =
        ProviderHandoffCurrentCodeIdentityCache()

    public static func current() throws -> ProviderHandoffCodeIdentityV1 {
        try currentIdentityCache.identity {
            guard let executable = Bundle.main.executableURL else {
                throw ProviderHandoffCodeIdentityError.unavailable
            }
            return try load(at: executable)
        }
    }

    public static func load(
        at executable: URL
    ) throws -> ProviderHandoffCodeIdentityV1 {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executable.standardizedFileURL as CFURL,
            SecCSFlags(),
            &code
        )
        guard createStatus == errSecSuccess, let code else {
            throw ProviderHandoffCodeIdentityError.invalidCode(createStatus)
        }
        let validationStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validationStatus == errSecSuccess else {
            throw ProviderHandoffCodeIdentityError.invalidCode(
                validationStatus
            )
        }

        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(
            code,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw ProviderHandoffCodeIdentityError.invalidCode(
                requirementStatus
            )
        }
        var requirementText: CFString?
        let textStatus = SecRequirementCopyString(
            requirement,
            SecCSFlags(),
            &requirementText
        )
        guard
            textStatus == errSecSuccess,
            let requirementText = requirementText as String?,
            !requirementText.isEmpty
        else {
            throw ProviderHandoffCodeIdentityError.invalidCode(textStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard
            informationStatus == errSecSuccess,
            let values = information as? [CFString: Any],
            let identifier = values[kSecCodeInfoIdentifier] as? String,
            !identifier.isEmpty
        else {
            throw informationStatus == errSecSuccess
                ? ProviderHandoffCodeIdentityError.invalidIdentity
                : ProviderHandoffCodeIdentityError.invalidCode(
                    informationStatus
                )
        }
        let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String
        guard teamIdentifier?.isEmpty != true else {
            throw ProviderHandoffCodeIdentityError.invalidIdentity
        }
        return ProviderHandoffCodeIdentityV1(
            signingIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            designatedRequirementDigestSHA256: ProviderHandoffDigest.sha256(
                Data(requirementText.utf8)
            )
        )
    }
}

/// Retains the successfully verified identity of this process's executable.
///
/// A running process cannot change its executable image. Revalidating the same
/// on-disk image for every provider handshake adds avoidable Security.framework
/// work and can make a healthy gateway miss its bounded health deadline. The
/// lock also coalesces concurrent first use, while failures remain retryable.
final class ProviderHandoffCurrentCodeIdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: ProviderHandoffCodeIdentityV1?

    func identity(
        load: () throws -> ProviderHandoffCodeIdentityV1
    ) throws -> ProviderHandoffCodeIdentityV1 {
        try lock.withLock {
            if let cached {
                return cached
            }
            let identity = try load()
            cached = identity
            return identity
        }
    }
}
