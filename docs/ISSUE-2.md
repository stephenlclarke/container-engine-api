# Issue 2: provider-session shutdown hangs hosted CI

## Problem

The first 0.2.1 hosted CI run completed its cold warnings-as-errors build in 69 seconds, then reached its 45-minute limit without test output. A follow-up run invoked the prebuilt Swift Testing bundle directly and proved the build and launcher were healthy: eight logging tests passed before `provider handshake forwards bytes and pull based streams` remained active until the bounded five-minute test timeout.

The provider server closed its listener from the shutdown task and then awaited the task blocked in Darwin `accept()`. Closing a listening descriptor from another task does not reliably wake that blocking call on the hosted macOS runner.

## Impact

The accepted source and adopter gates are green locally, but the package cannot obtain its required hosted `Validate` result. The same shutdown race can retain a provider process indefinitely after its gateway asks it to stop. Increasing the job timeout would hide the lifecycle defect and waste runner time without increasing functional coverage.

## Expected behavior

Shutdown must mark the server stopped, close active sessions, wake the idle accept loop through its private socket, await that loop, and only then close and unlink the listener. CI must retain the direct, bounded test launch so any future stuck test identifies itself.

## Evidence

- Failed run: [CI 30769631699](https://github.com/stephenlclarke/container-engine-api/actions/runs/30769631699)
- Isolating run: [CI 30771480808](https://github.com/stephenlclarke/container-engine-api/actions/runs/30771480808)
- GitHub issue: [#2](https://github.com/stephenlclarke/container-engine-api/issues/2)
- Adopter CI: [devcontainer CI 30770245056](https://github.com/stephenlclarke/devcontainer/actions/runs/30770245056)
