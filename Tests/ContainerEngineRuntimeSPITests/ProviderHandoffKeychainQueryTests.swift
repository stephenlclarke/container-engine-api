//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import LocalAuthentication
import Security
import Testing

@testable import ContainerEngineRuntimeSPI

struct ProviderHandoffKeychainQueryTests {
    @Test("Provider handoff Keychain access disables all authentication UI")
    func disablesAuthenticationUI() throws {
        var query: [CFString: Any] = [:]
        #expect(
            ProviderHandoffKeychainQuery.disableAuthenticationUI(in: &query)
                == errSecSuccess
        )

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
