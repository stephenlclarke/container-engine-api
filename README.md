# container-engine-api

`container-engine-api` is a runtime-neutral Swift package for Docker-compatible Engine HTTP transport. It contains no Dev Container policy, Compose policy, runtime state, or Apple Container imports.

The package currently exposes seven libraries and one executable:

| Product | Responsibility |
| --- | --- |
| `ContainerEngineWire` | HTTP request/response types, ordered duplicate-preserving request headers with fail-closed unique lookup, deterministic Docker JSON, byte/stream/hijack bodies, raw session contracts, and Docker multiplex framing. |
| `ContainerEngineRouter` | Docker API-version parsing, request-target parsing, route patterns, validated route availability intervals, duplicate-signature detection, and declaration-order-independent literal-first matching. |
| `ContainerEngineLogging` | Docker 29.2.1-compatible `/info`, inspect, logs, and attach logging projections over one runtime-neutral backend, including API 1.44–1.53 routing, query normalization, exact error envelopes, TTY/raw and non-TTY multiplex framing, and pull-based cancellable reads. |
| `ContainerEngineProviderSession` | Versioned out-of-process provider handshake and fingerprint binding over a private singleton Unix socket, with byte, pull-based stream, and bidirectional hijack forwarding. |
| `ContainerEngineGateway` | Complete generated API 1.53 route-ledger enforcement and fail-closed dispatch to exactly the routes advertised by the selected provider. |
| `ContainerEngineRuntimeSPI` | Runtime-neutral stock/enhanced provider declarations, versioned capabilities, immutable state-root identities, canonical fingerprints, and a private fail-closed provider-selection record that cannot be overwritten as an implicit handoff. |
| `ContainerUnixHTTPServer` | A user-owned Unix HTTP/1.1 server with strict `sockaddr_un` path validation, socket/lock ownership checks, same-user macOS peer enforcement, exact-inode cleanup, global connection and decoded-body budgets, read/idle deadlines, ordered pipelining, bounded graceful drain, chunked responses, pull-based managed response streams, and tested happy-path early half-close handling. |
| `container-engine` | The one runtime-neutral public Engine listener. It probes and binds one provider fingerprint before opening the public socket, then applies the route ledger and forwards only provider-advertised operations. |

The checked-in route ledger contains all 107 method/path operations in Docker Engine 29.2.1 API 1.53. It is generated from ten checksum-pinned Moby Swagger specifications spanning API 1.44–1.53. Presence in that ledger is not an implementation claim: routes default to `unimplemented`, local Swarm routes are `platformUnavailable`, and `container-engine` forwards a route only when the selected provider advertises the exact `engine.route.<OperationId>` capability. The logging controller implements the shared logging surface but intentionally returns only logging-relevant `/info` and inspect fields; the enhanced provider must compose the remaining Engine fields from the same Container authority.

The executable and provider-session boundary are implemented, and devcontainer 1.0.1 supplies the first stock adapter through that private session. The enhanced Container authority has not completed its process cutover. Explicit drain/import/commit handoff, provider-session authentication beyond current-user private socket ownership, request-body streaming/spooling, and the complete route handlers remain required before whole-API or `use_api_socket` compatibility can be advertised.

`ContainerUnixHTTPServer` instances are deliberately one-shot: a failed start may be retried after cleanup, but an instance cannot restart after shutdown. Concurrent lifecycle transitions fail explicitly, completed shutdown is idempotent, and callers must create a new server instance to bind again. `ContainerUnixHTTPServerLimits` configures the global connection ceiling, per-connection and aggregate decoded request-body budgets, pending-request limit, request-read deadline, keep-alive idle deadline, and graceful-drain deadline. Its original three-argument initializer remains source-compatible and derives an aggregate budget no smaller than the configured per-connection budget, with a 2 GiB floor. Hijacked sessions are exempt from ordinary HTTP read/idle deadlines and are force-closed only if they outlive graceful drain.

Build and test with SwiftPM:

```sh
swift build
swift test
python3 Tools/generate_route_ledger.py --check
```

On Xcode 26.6 hosted runners, CI builds tests once with `swift build --build-tests` and loads the resulting bundle through `Tools/ci/run-swift-testing-bundle.sh`, the same Swift Testing helper path already proven by the devcontainer consumer. This exposes per-test progress and gives the test process its own five-minute bound; it does not skip, retry, or reinterpret results. That diagnostic path identified and the package now regression-tests two Darwin lifecycle edges: same-process listener exclusion is enforced in memory as well as through cross-process `flock`, and an idle blocking provider `accept()` is woken explicitly before its listener is closed during shutdown.

See [`docs/LOGGING_API.md`](docs/LOGGING_API.md) for the logging adapter contract and [`docs/EXTRACTION.md`](docs/EXTRACTION.md) for source provenance, extraction mechanics, exclusions, and remaining gaps.
