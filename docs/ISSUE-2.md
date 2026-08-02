# Issue 2: provider-session shutdown hangs hosted CI

## Problem

The first 0.2.1 hosted CI run completed its cold warnings-as-errors build in 69 seconds, then reached its 45-minute limit without test output. A follow-up run invoked the prebuilt Swift Testing bundle directly and proved the build and launcher were healthy: eight logging tests passed before `provider handshake forwards bytes and pull based streams` remained active until the bounded five-minute test timeout.

The first lifecycle correction made idle shutdown explicit, and the next hosted run proved that regression passed. Protocol-stage isolation then proved ownership, handshake, bytes, ordinary pull streams, and 2 MiB chunks all pass. The remaining hang is specifically queued hijack input followed by an output read.

Provider frame reads and writes used blocking Darwin calls inside `Task.detached`. On the smaller hosted cooperative executor, the client and server blocking reads occupy threads while the server's hijack child task that must produce the frame cannot run. Blocking POSIX work must run on a dispatch overcommit queue instead. Same-process listener ownership also needs its in-memory guard in addition to cross-process `flock`, and shutdown needs explicit wake ordering.

## Impact

The accepted source and adopter gates are green locally, but the package cannot obtain its required hosted `Validate` result. The same shutdown race can retain a provider process indefinitely after its gateway asks it to stop. Increasing the job timeout would hide the lifecycle defect and waste runner time without increasing functional coverage.

## Expected behavior

Listener creation must reject a duplicate standardized lock path within the process before filesystem mutation while retaining nonblocking `flock` for cross-process exclusion. Shutdown must mark the server stopped, close active sessions, wake the idle accept loop through its private socket, await that loop, and only then close and unlink the listener. Blocking frame I/O must not occupy cooperative-executor threads required by protocol processing. CI must retain the direct, bounded test launch so any future stuck test identifies itself.

## Evidence

- Failed run: [CI 30769631699](https://github.com/stephenlclarke/container-engine-api/actions/runs/30769631699)
- Isolating run: [CI 30771480808](https://github.com/stephenlclarke/container-engine-api/actions/runs/30771480808)
- Idle-shutdown run: [CI 30771906033](https://github.com/stephenlclarke/container-engine-api/actions/runs/30771906033)
- Protocol-isolation run: [CI 30772469677](https://github.com/stephenlclarke/container-engine-api/actions/runs/30772469677)
- Hijack-isolation run: [CI 30772677790](https://github.com/stephenlclarke/container-engine-api/actions/runs/30772677790)
- GitHub issue: [#2](https://github.com/stephenlclarke/container-engine-api/issues/2)
- Adopter CI: [devcontainer CI 30770245056](https://github.com/stephenlclarke/devcontainer/actions/runs/30770245056)
