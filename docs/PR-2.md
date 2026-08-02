# Change handoff: make provider shutdown deterministic

## Summary

Use a bounded direct Swift Testing launch to identify the previously opaque hosted timeout, enforce same-process listener ownership independently of advisory file-lock semantics, and make provider shutdown deterministic by waking its idle blocking accept loop before closing the listener.

## Implementation

- Add `Tools/ci/run-swift-testing-bundle.sh` for absolute bundle validation, helper/platform discovery, framework and library paths, optional sanitizer runtime selection, and direct Swift Testing launch.
- Validate the script with `bash -n` in CI.
- Give the test-launch step its own five-minute timeout.
- Keep exact resolution, route-ledger generation, formatting, documentation checks, warnings-as-errors compilation, and all tests unchanged.
- Reserve each standardized provider lock path in a process-local locked set before opening its cross-process lock file, and release both ownership layers together on every failure and shutdown path.
- Mark the provider server stopped and close its active connections before wakeup.
- Connect to the mode-`0600` private socket to wake the listener, reject that accepted wake connection after observing the stopped state, and await the accept loop before closing and unlinking its descriptor.
- Add a focused regression proving an idle listener shuts down and removes its socket.

## Validation

```console
bash -n Tools/ci/run-swift-testing-bundle.sh
swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors --build-tests
Tools/ci/run-swift-testing-bundle.sh \
  "$(swift build --disable-automatic-resolution --show-bin-path)/container-engine-apiPackageTests.xctest/Contents/MacOS/container-engine-apiPackageTests" \
  --no-parallel
```

The direct bundle run passes all 55 tests in three suites on the designated Mac. Hosted accepted-head evidence is required before issue closure.

## Compatibility

The CI path changes only test launch. The runtime change is internal and preserves package APIs, dependency pins, route behavior, session framing, and shutdown's public contract while removing an indefinite wait.

## Linked issue

Closes [#2](https://github.com/stephenlclarke/container-engine-api/issues/2).

## Remaining risks

The helper path is toolchain-internal but is the executable SwiftPM itself resolves for the active `swiftc`, and the script fails explicitly if its expected path or macOS platform frameworks are unavailable. Process-local exclusion is intentionally additive: `flock` remains authoritative between processes. If the listener path is removed or replaced before shutdown wakeup, the wake connection can fail; the current server exclusively owns the locked path and exact-inode cleanup, so that condition indicates an already broken ownership invariant rather than an expected lifecycle transition.
