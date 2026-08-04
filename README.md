<!-- markdownlint-disable MD033 -->
<h1>
  <img
    alt="container-engine-api icon: frosted engine and container panel"
    src="docs/images/container-engine-api-icon.png"
    width="70"
    valign="middle">
  &nbsp;container-engine-api
</h1>
<!-- markdownlint-enable MD033 -->

`container-engine-api` is a runtime-neutral Swift package for Docker-compatible Engine HTTP transport. It contains no Dev Container policy, Compose policy, runtime state, or Apple Container imports.

The package currently exposes eight libraries and one executable:

| Product | Responsibility |
| --- | --- |
| `ContainerEngineWire` | HTTP request/response types, ordered duplicate-preserving request headers with fail-closed unique lookup, deterministic Docker JSON, byte/stream/raw-hijack/WebSocket bodies, raw session contracts, and Docker multiplex framing. |
| `ContainerEngineRouter` | Docker API-version parsing, request-target parsing, route patterns, validated route availability intervals, duplicate-signature detection, declaration-order-independent literal-first matching, and Docker-compatible unknown-route handling before supported-version rejection. |
| `ContainerEngineLogging` | Docker 29.2.1-compatible `/info`, inspect, logs, raw attach, WebSocket attach, and terminal-resize projections over one runtime-neutral backend, including fail-closed complete-response composition, API 1.44–1.53 routing, query normalization, exact error envelopes, TTY/raw and non-TTY multiplex framing, and pull-based cancellable reads. |
| `ContainerEngineProviderSession` | Versioned out-of-process provider handshake and fingerprint binding over a private singleton Unix socket, with byte, pull-based stream, raw-hijack, and WebSocket forwarding plus ordered, bounded, chunked duplex input. |
| `ContainerEngineGateway` | Complete generated API 1.53 route-ledger enforcement and fail-closed dispatch to exactly the routes advertised by the selected provider. |
| `ContainerEngineRuntimeSPI` | Runtime-neutral stock/enhanced provider declarations, versioned capabilities, immutable state-root identities, canonical fingerprints, and a private fail-closed provider-selection record that cannot be overwritten as an implicit handoff. |
| `ContainerEngineService` | Reusable provider selection, public-listener lifecycle, argument parsing, and bounded gateway/provider health probes for provider-owned packaging and supervision. |
| `ContainerUnixHTTPServer` | A user-owned Unix HTTP/1.1 server with strict `sockaddr_un` path validation, socket/lock ownership checks, same-user macOS peer enforcement, exact-inode cleanup, global connection and decoded-body budgets, read/idle deadlines, ordered pipelining, bounded graceful drain, chunked responses, pull-based managed response streams, bounded raw/WebSocket stdin, and RFC 6455 binary streaming. |
| `container-engine` | The one runtime-neutral public Engine listener. It probes and binds one provider fingerprint before opening the public socket, then applies the route ledger and forwards only provider-advertised operations. |

The checked-in route ledger contains all 107 method/path operations in Docker Engine 29.2.1 API 1.53. It is generated from ten checksum-pinned Moby Swagger specifications spanning API 1.44–1.53. Presence in that ledger is not an implementation claim: routes default to `unimplemented`, local Swarm routes are `platformUnavailable`, and `container-engine` forwards a route only when the selected provider advertises the exact `engine.route.<OperationId>` capability. The logging controller can retain its source-compatible logging-only `/info` and inspect fragments for unadvertised adapters, or accept one `DockerLoggingSharedResponseBackend` from the same selected authority. In complete-response mode it rejects missing Moby non-optional top-level fields before overlaying only `LoggingDriver`, `Plugins.Log`, `Config.Tty`, `HostConfig.LogConfig`, and `LogPath`; a provider must not advertise `SystemInfo` or `ContainerInspect` while using fragment mode.

The executable, reusable service lifecycle, and provider-session boundary are implemented. Provider packages can link `ContainerEngineService`, install their own thin `container-engine` entry point, and supervise it only after the selected provider answers a real provider-backed `/info` probe; the packaged executable remains the same thin entry point for standalone use. Devcontainer supplies the stock adapter, and its production listener now uses the same gateway over an internal private provider session. The matched enhanced Container implementation supplies the logging authority adapter and private provider session; synchronized release dependency publication is still required before that path is reproducible from public pins. Explicit drain/import/commit handoff, provider-session authentication beyond current-user private socket ownership, public-listener request streaming/spooling, and the complete unrelated route handlers remain required before whole-API or `use_api_socket` compatibility can be advertised.

`ContainerUnixHTTPServer` instances are deliberately one-shot: a failed start may be retried after cleanup, but an instance cannot restart after shutdown. Concurrent lifecycle transitions fail explicitly, completed shutdown is idempotent, and callers must create a new server instance to bind again. `ContainerUnixHTTPServerLimits` configures the global connection ceiling, per-connection and aggregate decoded request-body budgets, pending-request limit, request-read deadline, keep-alive idle deadline, and graceful-drain deadline. Its original three-argument initializer remains source-compatible and derives an aggregate budget no smaller than the configured per-connection budget, with a 2 GiB floor. Hijacked sessions are exempt from ordinary HTTP read/idle deadlines and are force-closed only if they outlive graceful drain.

## Documentation

Browse the [container-engine-api DocC reference](https://stephenlclarke.github.io/api/container-engine-api/) as part of the integrated container developer API collection.

Generate the same static site locally with:

```sh
scripts/make-docs.sh _site api/container-engine-api
```

Build and test with SwiftPM:

```sh
swift build
swift test
python3 Tools/generate_route_ledger.py --check
```

Run the maintained same-host streaming transport comparator with a release build and the active Docker Unix socket:

```sh
python3 -B Tools/performance/check_engine_streaming_performance.py
```

The comparator exercises resize plus 32-byte and 1 MiB WebSocket round trips through the complete shared path: public `ContainerUnixHTTPServer`, `ContainerEngineGatewayResponder`, private `ContainerEngineProviderSessionServer`, and `DockerLoggingAPIController`. It retains raw monotonic TSV samples, exact host/runtime/binary fingerprints, JUnit, machine-readable comparison JSON, and a human median/P95 matrix under `.build/performance/engine-streaming`. The matched Docker container, candidate process, and temporary sockets are exact-name scoped and removed on success or failure. This is a transport-overhead lane with a bounded in-memory provider; it does not replace the production Container, logging-driver, Compose, or external-client performance matrices.

The [v0.3.3 release evidence](docs/performance/engine-streaming-v0.3.3/timing-matrix.md) was captured on the clean signed code head `6edd44ae092d2d8eb083c96045f5e4539370524c` with 11 counterbalanced repetitions per lane. Candidate/Docker median ratios were 0.40x for resize, 0.78x for a 32-byte WebSocket round trip, and 0.44x for a 1 MiB WebSocket round trip; every regression gate passed, two candidate lanes were directionally better, and the sub-millisecond 32-byte lane was comparable.

On Xcode 26.6 hosted runners, CI builds tests once with `swift build --build-tests` and loads the resulting bundle through `Tools/ci/run-swift-testing-bundle.sh`, the same Swift Testing helper path already proven by the devcontainer consumer. This exposes per-test progress and gives the test process its own five-minute bound; it does not skip, retry, or reinterpret results. That diagnostic path identified and the package now regression-tests three Darwin lifecycle edges: same-process listener exclusion is enforced in memory as well as through cross-process `flock`, an idle blocking provider `accept()` is woken explicitly before its listener is closed during shutdown, and blocking POSIX frame reads/writes run on a dispatch queue rather than occupying Swift cooperative-executor threads needed by bidirectional hijack work.

See [`docs/LOGGING_API.md`](docs/LOGGING_API.md) for the logging adapter contract and [`docs/EXTRACTION.md`](docs/EXTRACTION.md) for source provenance, extraction mechanics, exclusions, and remaining gaps.
