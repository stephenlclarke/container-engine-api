# container-engine-api

`container-engine-api` is a runtime-neutral Swift package for Docker-compatible Engine HTTP transport. It contains no Dev Container policy, Compose policy, runtime state, or Apple Container imports.

The package currently exposes three libraries:

| Product | Responsibility |
| --- | --- |
| `ContainerEngineWire` | HTTP request/response types, deterministic Docker JSON, byte/stream/hijack bodies, raw session contracts, and Docker multiplex framing. |
| `ContainerEngineRouter` | Docker API-version parsing, request-target parsing, route patterns, versioned route metadata, duplicate-signature detection, and matching primitives. Literal/parameter overlap precedence remains an adoption blocker. |
| `ContainerUnixHTTPServer` | A user-owned Unix HTTP/1.1 server with socket/lock ownership checks, mode enforcement, exact-inode cleanup, per-connection in-memory request bounds, ordered pipelining, chunked responses, and tested happy-path early half-close handling. Global budgets, streaming backpressure, and adversarial cancellation remain adoption blockers. |

This Wave 1 package is a non-production, library-only extraction checkpoint. It
does not yet claim complete Docker Engine API 1.53 compatibility, is not ready
for runtime adoption, and has no directly runnable executable.

Build and test with SwiftPM:

```sh
swift build
swift test
```

See [`docs/EXTRACTION.md`](docs/EXTRACTION.md) for source provenance, extraction mechanics, exclusions, and remaining gaps.
