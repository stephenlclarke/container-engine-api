# Change handoff: run the prebuilt Swift Testing bundle

## Summary

Split the hosted test step into an explicit warnings-as-errors `swift build --build-tests` and a bounded invocation of the resulting bundle through `swiftpm-testing-helper`. Reuse the launch path already proven by the devcontainer adopter on Xcode 26.6.

## Implementation

- Add `Tools/ci/run-swift-testing-bundle.sh` for absolute bundle validation, helper/platform discovery, framework and library paths, optional sanitizer runtime selection, and direct Swift Testing launch.
- Validate the script with `bash -n` in CI.
- Give the test-launch step its own five-minute timeout.
- Keep exact resolution, route-ledger generation, formatting, documentation checks, warnings-as-errors compilation, and all tests unchanged.
- Document why hosted CI does not use the `swift test` launcher.

## Validation

```console
bash -n Tools/ci/run-swift-testing-bundle.sh
swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors --build-tests
Tools/ci/run-swift-testing-bundle.sh \
  "$(swift build --disable-automatic-resolution --show-bin-path)/container-engine-apiPackageTests.xctest/Contents/MacOS/container-engine-apiPackageTests" \
  --no-parallel
```

The direct bundle run passes all 54 tests in three suites on the designated Mac. Hosted accepted-head evidence is required before issue closure.

## Compatibility

This changes only CI test launch. Runtime products, package APIs, dependency pins, route behavior, test selection, and pass/fail interpretation are unchanged.

## Linked issue

Closes [#2](https://github.com/stephenlclarke/container-engine-api/issues/2).

## Remaining risks

The helper path is toolchain-internal but is the executable SwiftPM itself resolves for the active `swiftc`, and the script fails explicitly if its expected path or macOS platform frameworks are unavailable.
