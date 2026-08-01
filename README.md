# container-engine-api

`container-engine-api` is a runtime-neutral Swift package for Docker-compatible Engine HTTP transport. It contains no Dev Container policy, Compose policy, runtime state, or Apple Container imports.

The package currently exposes four libraries:

| Product | Responsibility |
| --- | --- |
| `ContainerEngineWire` | HTTP request/response types, ordered duplicate-preserving request headers with fail-closed unique lookup, deterministic Docker JSON, byte/stream/hijack bodies, raw session contracts, and Docker multiplex framing. |
| `ContainerEngineRouter` | Docker API-version parsing, request-target parsing, route patterns, validated route availability intervals, duplicate-signature detection, and declaration-order-independent literal-first matching. |
| `ContainerEngineLogging` | Docker 29.2.1-compatible `/info`, inspect, logs, and attach logging projections over one runtime-neutral backend, including API 1.44–1.53 routing, query normalization, exact error envelopes, TTY/raw and non-TTY multiplex framing, and pull-based cancellable reads. |
| `ContainerUnixHTTPServer` | A user-owned Unix HTTP/1.1 server with strict `sockaddr_un` path validation, socket/lock ownership checks, same-user macOS peer enforcement, exact-inode cleanup, global connection and decoded-body budgets, read/idle deadlines, ordered pipelining, bounded graceful drain, chunked responses, pull-based managed response streams, and tested happy-path early half-close handling. |

This package remains library-only and does not claim complete Docker Engine API 1.53 compatibility. The logging controller implements the shared logging surface but intentionally returns only logging-relevant `/info` and inspect fields; the adopting gateway must compose the remaining Engine fields and use the same authoritative backend. It has no directly runnable executable.

`ContainerUnixHTTPServer` instances are deliberately one-shot: a failed start may be retried after cleanup, but an instance cannot restart after shutdown. Concurrent lifecycle transitions fail explicitly, completed shutdown is idempotent, and callers must create a new server instance to bind again. `ContainerUnixHTTPServerLimits` configures the global connection ceiling, per-connection and aggregate decoded request-body budgets, pending-request limit, request-read deadline, keep-alive idle deadline, and graceful-drain deadline. Its original three-argument initializer remains source-compatible and derives an aggregate budget no smaller than the configured per-connection budget, with a 2 GiB floor. Hijacked sessions are exempt from ordinary HTTP read/idle deadlines and are force-closed only if they outlive graceful drain.

Build and test with SwiftPM:

```sh
swift build
swift test
```

See [`docs/LOGGING_API.md`](docs/LOGGING_API.md) for the logging adapter contract and [`docs/EXTRACTION.md`](docs/EXTRACTION.md) for source provenance, extraction mechanics, exclusions, and remaining gaps.
