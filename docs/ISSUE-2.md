# Issue 2: cold Swift build exceeds the hosted CI timeout

## Problem

The first 0.2.1 hosted CI run completed its cold warnings-as-errors build in 69 seconds, then stalled while `swift test` attempted to launch the generated Swift Testing bundle. The job reached its 45-minute limit without test output even though the same built bundle completes all 54 tests on the designated Mac in about 1.3 seconds.

## Impact

The accepted source and adopter gates are green locally, but the package cannot obtain its required hosted `Validate` result. Increasing the job timeout would hide the launcher defect and waste runner time without increasing functional coverage.

## Expected behavior

CI must build the tests once, invoke the prebuilt bundle through the supported SwiftPM testing helper, retain warnings-as-errors and exact dependency resolution, and complete within its existing bound.

## Evidence

- Failed run: [CI 30769631699](https://github.com/stephenlclarke/container-engine-api/actions/runs/30769631699)
- GitHub issue: [#2](https://github.com/stephenlclarke/container-engine-api/issues/2)
- Adopter CI: [devcontainer CI 30770245056](https://github.com/stephenlclarke/devcontainer/actions/runs/30770245056)
