# container-engine-api

<!-- markdownlint-disable MD013 MD033 -->
<p>
  <img align="left" hspace="20" src="docs/images/container-engine-api-icon.png" width="147" alt="container-engine-api icon: a frosted engine over the standard three-row container service panel" />
  <a href="https://github.com/stephenlclarke/container-engine-api/actions/workflows/ci.yml?query=branch%3Amain"><img alt="CI" src="https://github.com/stephenlclarke/container-engine-api/actions/workflows/ci.yml/badge.svg?branch=main" /></a>
  <a href="https://github.com/stephenlclarke/container-engine-api/actions/workflows/codeql.yml?query=branch%3Amain"><img alt="CodeQL" src="https://github.com/stephenlclarke/container-engine-api/actions/workflows/codeql.yml/badge.svg?branch=main" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Quality Gate Status" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=alert_status" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Coverage" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=coverage" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Bugs" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=bugs" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Code Smells" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=code_smells" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Security Rating" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=security_rating" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Maintainability Rating" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=sqale_rating" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Duplicated Lines" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=duplicated_lines_density" /></a>
  <a href="https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-engine-api"><img alt="Lines of Code" src="https://sonarcloud.io/api/project_badges/measure?project=stephenlclarke_container-engine-api&amp;metric=ncloc" /></a>
  <img alt="Repo Visitors" src="https://visitor-badge.laobi.icu/badge?page_id=stephenlclarke.container-engine-api" />
</p>
<br clear="left" />
<br>
<!-- markdownlint-enable MD033 -->

`container-engine-api` is a runtime-neutral Swift package for Docker-compatible Engine HTTP transport. It contains no Dev Container policy, Compose policy, runtime state, or Apple Container imports.

The package currently exposes nine libraries and one executable:

| Product | Responsibility |
| --- | --- |
| `ContainerEngineWire` | HTTP request/response types, ordered duplicate-preserving request headers with fail-closed unique lookup, deterministic Docker JSON, byte/stream/raw-hijack/WebSocket bodies, raw session contracts, and Docker multiplex framing. |
| `ContainerEngineRouter` | Docker API-version parsing, request-target parsing, route patterns, validated route availability intervals, duplicate-signature detection, declaration-order-independent literal-first matching, and Docker-compatible unknown-route handling before supported-version rejection. |
| `ContainerEngineLogging` | Docker 29.2.1-compatible version discovery, container listing, `/info`, inspect, logs, raw attach, WebSocket attach, and terminal-resize projections over one runtime-neutral authority, including fail-closed complete-response validation, API 1.44–1.53 routing, query/filter normalization, exact error envelopes, TTY/raw and non-TTY multiplex framing, and pull-based cancellable reads. |
| `ContainerEngineProviderSession` | Versioned out-of-process provider handshake and fingerprint binding over a private singleton Unix socket, with byte, pull-based stream, raw-hijack, and WebSocket forwarding plus ordered, bounded, chunked duplex input. |
| `ContainerEngineGateway` | Complete generated API 1.53 route-ledger enforcement and fail-closed dispatch to exactly the routes advertised by the selected provider. |
| `ContainerEngineRuntimeSPI` | Runtime-neutral stock/enhanced provider declarations, versioned capabilities, immutable state-root identities, canonical fingerprints, and a private fail-closed provider-selection record that cannot be overwritten as an implicit handoff. |
| `ContainerEngineService` | Reusable provider selection, public-listener lifecycle, argument parsing, and bounded gateway/provider health probes for provider-owned packaging and supervision. |
| `ContainerUnixHTTPServer` | A user-owned Unix HTTP/1.1 server with strict `sockaddr_un` path validation, socket/lock ownership checks, same-user macOS peer enforcement, exact-inode cleanup, global connection and decoded-body budgets, read/idle deadlines, ordered pipelining, bounded graceful drain, chunked responses, pull-based managed response streams, bounded raw/WebSocket stdin, and RFC 6455 binary streaming. |
| `ContainerUnixHTTPClient` | A small current-user Unix HTTP/1.1 client for native Engine consumers. It validates socket ownership and permissions, bounds headers, chunk framing, trailers and response bodies, supports fixed, chunked, and close-delimited responses, and performs blocking socket work away from Swift's cooperative executor. Requests have an absolute deadline and cancellation closes owned work before returning. |
| `container-engine` | The one runtime-neutral public Engine listener. It probes and binds one provider fingerprint before opening the public socket, then applies the route ledger and forwards only provider-advertised operations. |

The checked-in route ledger contains all 107 method/path operations in Docker Engine 29.2.1 API 1.53. It is generated from ten checksum-pinned Moby Swagger specifications spanning API 1.44–1.53. Presence in that ledger is not an implementation claim: routes default to `unimplemented`, local Swarm routes are `platformUnavailable`, and `container-engine` forwards a route only when the selected provider advertises the exact `engine.route.<OperationId>` capability. The controller can retain its source-compatible logging-only `/info` and inspect fragments for unadvertised adapters, accept one `DockerLoggingSharedResponseBackend` from the same selected authority, and optionally expose complete `SystemVersion` and `ContainerList` responses through `DockerEngineDiscoveryBackend`. Complete responses reject missing Moby non-optional top-level fields. Container-list parsing supports Docker's `all`, `limit`, `size`, modern array filters, and legacy Boolean filter maps; malformed values fail before backend contact. A provider must advertise only the complete operations its selected authority supplies.

The executable, reusable service lifecycle, and provider-session boundary are implemented. Provider packages can link `ContainerEngineService`, install their own thin `container-engine` entry point, and supervise it only after the selected provider answers a real provider-backed `/info` probe; the packaged executable remains the same thin entry point for standalone use. Devcontainer supplies the stock adapter, and its production listener now uses the same gateway over an internal private provider session. The matched enhanced Container implementation supplies the logging authority adapter and private provider session; synchronized release dependency publication is still required before that path is reproducible from public pins. Explicit drain/import/commit handoff, provider-session authentication beyond current-user private socket ownership, public-listener request streaming/spooling, and the complete unrelated route handlers remain required before whole-API or `use_api_socket` compatibility can be advertised.

`ContainerUnixHTTPServer` instances are deliberately one-shot: a failed start may be retried after cleanup, but an instance cannot restart after shutdown. Concurrent lifecycle transitions fail explicitly, completed shutdown is idempotent, and callers must create a new server instance to bind again. `ContainerUnixHTTPServerLimits` configures the global connection ceiling, per-connection and aggregate decoded request-body budgets, pending-request limit, request-read deadline, keep-alive idle deadline, and graceful-drain deadline. Its original three-argument initializer remains source-compatible and derives an aggregate budget no smaller than the configured per-connection budget, with a 2 GiB floor. Hijacked sessions are exempt from ordinary HTTP read/idle deadlines and are force-closed only if they outlive graceful drain.

## Documentation

Browse the [container-engine-api DocC reference](https://stephenlclarke.github.io/api/container-engine-api/) as part of the integrated container developer API collection.

Generate the same static site locally with:

```sh
scripts/make-docs.sh _site api/container-engine-api
```

The focused native client boundary can also be tested with `make bazel-client-test FAMILY_BAZEL=/absolute/path/to/devcontainer/Tools/bazel/run.sh`. This reuses the digest-pinned Container-family launcher, enrolled SSD scratch/cache and internal retained evidence; it does not wrap `swift test`. The initial Bazel graph covers the client, its wire/server dependencies and client tests only, not the whole package. The consumer tooling lock must match the reviewed launcher bytes. `timeoutSeconds` is now the maximum duration of one complete client request, including connect, write, headers and body; choose an appropriately larger finite value for long-lived streams. Response callbacks run synchronously and must not block indefinitely.

`ContainerUnixHTTPClient.openDuplex(_:)` adds the Engine's `Connection: Upgrade` / `Upgrade: tcp` headers and requires a valid HTTP 101 reply. The returned connection preserves raw bytes, including Docker multiplex framing, and supports simultaneous `read()` and `write(_:)`. Reads are bounded to 64 KiB; `finishInput()` delivers stdin EOF while retaining output, and `close()` is idempotent and safe during I/O. Callers must close the connection when finished and decode its framing themselves. Cancellation of an active operation interrupts both directions. The original absolute deadline includes the handshake and the entire upgraded session; expiry interrupts I/O, while explicit close or deinitialization releases the owned connection. No Docker executable or VM is used by this transport.

Streaming callbacks receive successful response bodies only. HTTP error documents are captured separately, capped at 64 KiB (or a tighter caller limit), and reported as errors without contaminating event or log output.

Build and test the complete package with SwiftPM:

```sh
make test
make coverage
python3 Tools/generate_route_ledger.py --check
```

`make coverage` executes the real Swift package tests with instrumentation, converts the resulting LLVM line data to SonarQube's generic coverage format, and enforces the repository's 80% clean-gate floor. `make sonar-scan` then submits that evidence with the exact current commit as the previous-version baseline. The authoritative issue 43 run measured 84.54% (20,560 of 24,320 executable lines); 90% remains the improvement target and maintained handoff/security code is not excluded to inflate the result.

Run the maintained same-host streaming transport comparator with a release build and the active Docker Unix socket:

```sh
python3 -B Tools/performance/check_engine_streaming_performance.py
```

The comparator exercises resize plus 32-byte and 1 MiB WebSocket round trips through the complete shared path: public `ContainerUnixHTTPServer`, `ContainerEngineGatewayResponder`, private `ContainerEngineProviderSessionServer`, and `DockerLoggingAPIController`. It retains raw monotonic TSV samples, exact host/runtime/binary fingerprints, JUnit, machine-readable comparison JSON, and a human median/P95 matrix under `.build/performance/engine-streaming`. The matched Docker container, candidate process, and temporary sockets are exact-name scoped and removed on success or failure. This is a transport-overhead lane with a bounded in-memory provider; it does not replace the production Container, logging-driver, Compose, or external-client performance matrices.

The [v0.3.5 release evidence](docs/performance/engine-streaming-v0.3.5/timing-matrix.md) was captured on the clean signed code head `8d01a2388c749add99e70180d44f060749da8616` with 11 counterbalanced repetitions per lane. Candidate/Docker median ratios were 0.39x for resize, 0.51x for a 32-byte WebSocket round trip, and 0.60x for a 1 MiB WebSocket round trip; every regression gate passed and all three candidate lanes were directionally better.

On Xcode 26.6 hosted runners, CI builds tests once with `swift build --build-tests` and loads the resulting bundle through `Tools/ci/run-swift-testing-bundle.sh`, the same Swift Testing helper path already proven by the devcontainer consumer. This exposes per-test progress and gives the test process its own five-minute bound; it does not skip, retry, or reinterpret results. That diagnostic path identified and the package now regression-tests three Darwin lifecycle edges: same-process listener exclusion is enforced in memory as well as through cross-process `flock`, an idle blocking provider `accept()` is woken explicitly before its listener is closed during shutdown, and blocking POSIX frame reads/writes run on a dispatch queue rather than occupying Swift cooperative-executor threads needed by bidirectional hijack work.

See [`docs/LOGGING_API.md`](docs/LOGGING_API.md) for the logging adapter contract and [`docs/EXTRACTION.md`](docs/EXTRACTION.md) for source provenance, extraction mechanics, exclusions, and remaining gaps.
