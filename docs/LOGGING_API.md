# Docker Logging Engine API

| Item | Value |
| --- | --- |
| Status | Implemented runtime-neutral logging surface and fail-closed whole-response composition; final public-gateway and external-client certification remain |
| Reference | Docker Engine 29.2.1, API 1.53, minimum API 1.44 |
| Products | `ContainerEngineLogging`, `ContainerEngineRouter`, `ContainerEngineWire`, `ContainerUnixHTTPServer` |
| Runtime dependency | None; adopters supply one `DockerLoggingBackend` |

## Contract

`DockerLoggingAPIController` is the HTTP presentation boundary for logging. It never opens a bundle path, local store, cache, provider, or live process itself. One `DockerLoggingBackend` supplies the effective default/catalog, resolved inspect configuration, historical reader, and live attach session so native and Docker clients cannot drift onto separate state or read sources. The same selected authority may also supply one `DockerLoggingSharedResponseBackend` containing complete non-logging `/info` and inspect JSON documents; this is composition inside one provider, not a gateway merge between competing authorities.

The backend must resolve container names and IDs authoritatively, generation-fence any effectful reader or attach session, return only public-safe errors through `DockerLoggingBackendError`, and make `close` and `cancel` idempotent. A stopped-container reader and a running reader use the same protocol. An unsupported native/cache/provider reader throws `.unsupportedLogReader` before a streaming response starts.

## Routes

| Method and route | Mapping |
| --- | --- |
| `GET /info` | Returns `LoggingDriver` and sorted, de-duplicated `Plugins.Log`; Docker's special `none` driver is not advertised as a plugin. With a shared-response backend, it preserves the complete authority document and replaces only those two logging-owned fields. |
| `GET /containers/{id}/json` | Returns `HostConfig.LogConfig.Type`, the full resolved string option map at `HostConfig.LogConfig.Config`, `Config.Tty`, and top-level `LogPath`. `LogPath` is non-empty only for `json-file`; local/cache/provider paths are suppressed. With a shared-response backend, it preserves every other complete authority field. |
| `GET /containers/{id}/logs` | Validates Docker booleans and stream selection, normalizes `tail`, `since`, and `until`, then maps the backend's exact record sequence to raw TTY bytes or Docker multiplex frames. |
| `POST /containers/{id}/attach` | Passes Docker attach selection and detach keys to the live backend and returns the existing raw hijack session. Upgrade requests receive `101` from the Unix server and multiplexed content type for non-TTY output; non-upgrade and TTY responses use Docker raw-stream content type. |

Versionless routes use API 1.53 behavior. Versioned requests from 1.44 through 1.53 are accepted. Older and newer versions receive Docker 29.2.1-shaped `400` envelopes before query parsing or backend contact. `responseIfHandled(to:)` permits a complete gateway to compose non-logging controllers without duplicating version/query parsing.

Without a `DockerLoggingSharedResponseBackend`, the controller retains its source-compatible logging-only fragments. Those fragments are useful for focused tests and cannot justify advertising the generated whole-route operation. In complete-response mode, the controller requires every non-optional top-level field in Moby 29.2.1's `system.Info` or `container.InspectResponse`, validates the nested object it modifies, preserves all unrelated fields, and emits one deterministic JSON document. A partial base fails with a public-safe `500` before the route can masquerade as complete.

## Logs Query and Presentation

Docker form semantics are applied before validation: `+` is a space, `%2B` is a literal plus, and repeated values retain wire order. Malformed percent escapes and unescaped semicolons receive Docker's exact `400` messages (`invalid URL escape "..."` and `invalid semicolon separator in query`). Docker booleans are false for an absent/empty value, `0`, `no`, `false`, or `none` after case-folding and whitespace trimming; every other value is true.

At least one of `stdout` and `stderr` must be true. `tail` is a non-negative native integer; absent, `all`, negative, malformed, and overflowing values all mean all records, while zero means no records. `since` and nonzero `until` use Docker daemon `seconds[.fraction]` parsing, including subsecond scaling and truncation beyond nine digits. `until=0` is unset; `since=0` is the Unix epoch. Malformed timestamps retain Docker 29.2.1's pre-stream `500` `strconv.ParseInt` envelope.

The backend returns exact binary line bytes, including any line feed retained by its driver reader, plus source, timestamp, and bounded attributes. The controller defensively reapplies stdout/stderr selection. `timestamps=1` prefixes fixed nine-digit UTC RFC3339 nanoseconds. `details=1` sorts attributes by UTF-8 key, applies Go query escaping, joins them with commas, and appends one space even when no attributes exist. For non-TTY containers each record is one eight-byte Docker frame (`1` stdout, `2` stderr); TTY output is raw and the backend must expose its already-merged terminal stream as stdout. A reader failure after status `200` is emitted once on Docker system-error channel `3` as `Error grabbing logs: ...` and then the stream ends.

## Status and Error Mapping

| Condition | Status | Envelope message |
| --- | --- | --- |
| Missing stdout/stderr selection | `400` | `Bad parameters: you must choose at least one stream` |
| Invalid backend parameter | `400` | Backend's public-safe message |
| Unknown container | `404` | `No such container: {id}` |
| Dead/removing or other lifecycle conflict | `409` | Backend's Docker-compatible public-safe message |
| Unsupported historical reader | `500` | `configured logging driver does not support reading` |
| Malformed time or backend failure | `500` | Docker parse text or backend's public-safe server message |

JSON success and ordinary error bodies use `application/json`, stable key ordering, slash-preserving encoding, and the newline emitted by Docker's JSON writer. Logs use `application/vnd.docker.raw-stream` for TTY and `application/vnd.docker.multiplexed-stream` for non-TTY. Attach follows Docker's upgrade-dependent content-type behavior; pre-hijack attach failures use Docker's raw-stream content type and CRLF-terminated plain error rather than a JSON envelope.

## Bounds, Cancellation, and Remaining Transport Limit

Historical logs use `DockerHTTPStreamSession`, a pull-based transport contract. The Unix server requests at most one chunk, waits for that NIO write to complete, and only then asks for the next. Natural completion invokes `close` once. Task/channel cancellation invokes `cancel` on the exact backend reader; the logging adapter also cancels on corrupt/source errors and never retries from another store or provider.

The legacy generic `AsyncThrowingStream<Data>` response remains source-compatible but is not suitable for unbounded production downloads because it can enqueue writes faster than channel writability. Logging does not use it. Hijack output already waits for every write. Hijack stdin still uses an unbounded ordered input queue, so output-only Compose attach is supported by this slice but stdin-capable production advertisement remains gated on a bounded input/backpressure policy. With remote half-close enabled, a completely silent follow cannot observe whether a peer intended a full close or only closed its request-writing side until the next failed output write or a server drain fence; either boundary cancels the reader.

## Adoption Checklist

- Implement all four `DockerLoggingBackend` operations over the authoritative Container logging/lifecycle controller.
- Translate Container's driver-neutral record to `DockerLogRecord` without reopening files in the Engine layer; retain the reader's exact line-feed decision.
- Map the authoritative resolved driver/options into inspect and expose a public path only for `json-file`.
- Return the controller's effective default and currently registered provider names for info.
- Use the same live attach session as native/Compose foreground output; do not synthesize attach from historical logs.
- Keep backend stream errors redacted and public-safe; message payloads and protected option values must not enter diagnostics.
- Supply complete `/info` and inspect documents through `DockerLoggingSharedResponseBackend` from the same selected authority, then advertise `SystemInfo` and `ContainerInspect` only after the fail-closed composition tests pass.
- Keep stdin-capable attach gated until the raw input queue has a bounded policy.

## Upstream Applicability Audit

The managed outbound-stream fix is specific to the Engine HTTP server extracted from `devcontainer` revision `b31e80b2b9c09ecc73bb3badf9cd5cf16550a538`. That source's `DevContainerService/EngineServer.swift` enqueues every response body write onto the event loop without awaiting completion. The accepted Apple `container` checkout at revision `d7806cd2a7a1f95d8457d0d33d42de7025706f8e` contains no `DockerHTTPBody`, `ContainerUnixHTTPServer`, `OrderedDockerInputPump`, NIO `HTTPResponseEncoder`, or equivalent Docker Engine HTTP response path. Its command-side file-follow `AsyncThrowingStream` is a different local CLI pipeline and is not evidence that this NIO bug applies. Therefore this change does not qualify for an Apple-shaped commit or ISSUE/PR handoff.

The initially suspected duplicate raw-input enqueue was a display-truncation false positive, not a source defect. Both extracted `ContainerUnixHTTPServer.swift` at baseline `87c061ebcdef4cf6dc4e0f2742d1bccf526ac1e0` and source `DevContainerService/EngineServer.swift` at the accepted revision contain exactly one `continuation.yield(.data(data))`; the strict baseline `Docker input pump preserves bytes and EOF order` test also passed. Apple `container` has no corresponding pump. No upstream fix or handoff is warranted for that observation.
