# Issue 2: provider-session shutdown hangs hosted CI

## Problem

The first 0.2.1 hosted CI run completed its cold warnings-as-errors build in 69 seconds, then reached its 45-minute limit without test output. A follow-up run invoked the prebuilt Swift Testing bundle directly and proved the build and launcher were healthy: eight logging tests passed before `provider handshake forwards bytes and pull based streams` remained active until the bounded five-minute test timeout.

The first lifecycle correction made idle shutdown explicit, and the next hosted run proved that regression passed. The compound ownership test still hung immediately afterward. The remaining root cause is same-process lock behavior: hosted Darwin can allow another descriptor in the process to acquire the advisory file lock, after which the competing server removes and replaces the live socket. The original accept loop is then unreachable through that path. Cross-process `flock` therefore needs a process-local ownership guard, and shutdown needs its explicit wake ordering.

## Impact

The accepted source and adopter gates are green locally, but the package cannot obtain its required hosted `Validate` result. The same shutdown race can retain a provider process indefinitely after its gateway asks it to stop. Increasing the job timeout would hide the lifecycle defect and waste runner time without increasing functional coverage.

## Expected behavior

Listener creation must reject a duplicate standardized lock path within the process before filesystem mutation while retaining nonblocking `flock` for cross-process exclusion. Shutdown must mark the server stopped, close active sessions, wake the idle accept loop through its private socket, await that loop, and only then close and unlink the listener. CI must retain the direct, bounded test launch so any future stuck test identifies itself.

## Evidence

- Failed run: [CI 30769631699](https://github.com/stephenlclarke/container-engine-api/actions/runs/30769631699)
- Isolating run: [CI 30771480808](https://github.com/stephenlclarke/container-engine-api/actions/runs/30771480808)
- Idle-shutdown run: [CI 30771906033](https://github.com/stephenlclarke/container-engine-api/actions/runs/30771906033)
- GitHub issue: [#2](https://github.com/stephenlclarke/container-engine-api/issues/2)
- Adopter CI: [devcontainer CI 30770245056](https://github.com/stephenlclarke/devcontainer/actions/runs/30770245056)
