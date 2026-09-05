//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

@testable import ContainerEngineRuntimeSPI
import LocalAuthentication
import Security
import Testing

struct ProviderHandoffKeychainQueryTests {
    @Test
    func `Provider handoff Keychain access disables all authentication UI`() throws {
        var query: [CFString: Any] = [:]
        ProviderHandoffKeychainQuery.disableAuthenticationUI(in: &query)

        let context = try #require(
            query[kSecUseAuthenticationContext] as? LAContext
        )
        #expect(context.interactionNotAllowed)
        #expect(
            String(describing: query["u_AuthUI" as CFString])
                == "Optional(u_AuthUIF)"
        )
    }
}
