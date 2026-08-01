# Extraction Provenance

## Accepted Source

This repository was extracted locally on the development Mac from the clean `main` checkout at `/Users/sclarke/github/devcontainer`. The accepted immutable source revision is `b31e80b2b9c09ecc73bb3badf9cd5cf16550a538`, with tree `c76192747bcf65db1158840121c564eb0a886f58` and subject `fix(compose): normalize inherited option placement`.

Before extraction, both `git status --porcelain=v2` and the index/worktree diffs were empty. The source checkout was read only throughout this work.

Extraction used `/opt/homebrew/bin/git-filter-repo` version `a40bce548d2c` with separate `--source` and `--target` repositories. The target was initialized without a remote and still has no configured remote. Only `refs/heads/main` and the paths listed below were selected. File renames were performed by `git-filter-repo --path-rename`, so the filtered commits retain the original authors, dates, messages, and per-file ancestry.

The filtered baseline tip is `fe15f77ffb3711bcb8ae3b83dd9cca1b394bb618`, mapping source commit `e047fb7070599dd995fc12feba1434c80dbb3f70`. The accepted source tip itself touched none of the selected paths and was therefore pruned as an empty filtered commit; its exact revision and tree remain the extraction authority recorded above. Post-extraction package assembly is recorded in `cb4311e8cf103bd21a4473356382e70639996b58`; the filtered commits retain their original attribution beneath that local commit.

## Source Path Mapping

| Source path at `b31e80b2b9c09ecc73bb3badf9cd5cf16550a538` | Source blob | Extracted path |
| --- | --- | --- |
| `Sources/DevContainerDockerAPI/DockerHTTPTypes.swift` | `3bef399a706273f638c303fb1ec18c684bf95051` | `Sources/ContainerEngineWire/DockerHTTPTypes.swift` |
| `Sources/DevContainerDockerAPI/DockerRouter.swift` | `54edab11b6f35e7bd06027597ae0737328767886` | `Sources/ContainerEngineRouter/DockerRouterMetadata.swift` |
| `Sources/DevContainerDockerAPI/DockerRouterSupport.swift` | `e8c7962fc5a99aa6e6f86739b45443314e3f2b56` | `Sources/ContainerEngineRouter/DockerRouteTarget.swift` |
| `Sources/DevContainerService/EngineServer.swift` | `53db780123028fa36ddb34249be997d6830c83bf` | `Sources/ContainerUnixHTTPServer/ContainerUnixHTTPServer.swift` |
| `Sources/DevContainerService/EngineServerLimits.swift` | `875f30c7a1b6ab893b8c9ccf76f419e53a3f4daa` | `Sources/ContainerUnixHTTPServer/ContainerUnixHTTPServerLimits.swift` |
| `Tests/DevContainerDockerAPITests/DockerRouterTests.swift` | `ebbd2d13344cc5b1d8f8346d2677275446ba0175` | `Tests/ContainerEngineRouterTests/DockerRouterMetadataTests.swift` |
| `Tests/DevContainerServiceTests/EngineServerTests.swift` | `7d83a25f22360b14ab3e9715a3f78ad3875e3614` | `Tests/ContainerUnixHTTPServerTests/ContainerUnixHTTPServerTests.swift` |
| `Tests/DevContainerServiceTests/OrderedRuntimeInputPumpTests.swift` | `481029efca1a315d44ab8fa3c8a12769091914c8` | `Tests/ContainerUnixHTTPServerTests/OrderedRuntimeInputPumpTests.swift` |

The root `Package.swift`, `Package.resolved`, `LICENSE`, `NOTICE.md`, `.gitignore`, `.swiftformat`, and `.markdownlint.json` histories were selected as supporting package provenance. Package assembly, notice updates, runtime-neutral adaptation, and extracted tests were committed together in the post-extraction checkpoint identified above; later hardening commits retain the filtered history and source mapping.

## Deliberate Exclusions

The Dev Container-specific router handlers, runtime registries, resource DTO projections, state, CLI, service command, and Apple runtime modules were not extracted. In particular, the new package imports neither `DevContainerCore`, `DevContainerModel`, `DevContainerRuntimeSPI`, `ComposeCore`, `apple/container`, nor `apple/containerization`.

The raw session interface and stream-frame types were moved to `ContainerEngineWire` so the Unix server depends on a neutral protocol rather than the former Dev Container runtime SPI. `ContainerUnixHTTPServer` now accepts any `DockerHTTPResponder`; provider selection and endpoint policy belong in later gateway/adaptor work.

## Known Gaps And Non-Claims

### Docker Engine API 1.53 completeness

This slice provides versioned route metadata and collision-safe matching primitives, not the generated Docker Engine API 1.53 route and field ledger. It does not contain the complete API 1.53 DTO set or handlers, and it does not advertise API 1.53 compatibility. Request headers now preserve original spelling, order, duplicates, and mixed-case duplicates through the NIO boundary, with all-value access and fail-closed unique lookup. Registry authentication, image push, BuildKit `/session`, complete archive/build semantics, and every route's pinned success/failure disposition remain future conformance work.

### Bounded streaming

Each inbound request body is still materialized as one `Foundation.Data` value, subject to per-request, aggregate-buffer, and pending-request caps. The header hardening in this slice does not change that body contract. Outbound `AsyncThrowingStream<Data>` responses are chunked but are not yet suspended on NIO channel writability, so a producer can outrun a slow client. The ordered raw-hijack input pump also uses an unbounded queue when its session consumer is slower than the client. Large uploads require incremental delivery or inode-safe private-file spooling, large downloads require watermarked backpressure and cancellation tests, and raw input needs a bounded backpressure or fail-closed policy before their routes can be advertised. Raw hijack output awaits each channel write, but that does not close the remaining streaming gaps.

### Remaining server hardening

The extracted server preserves a mode-`0700` current-user socket directory, a mode-`0600` socket, an `O_NOFOLLOW` current-user single-link regular lock with nonblocking `flock`, bounded in-memory request/pipeline queues, ordered responses, half-close-safe hijack, active-connection tracking, and exact device/inode cleanup. A complete gateway still needs explicit encoded Unix-path-length preflight, every-component path validation, a configured connection ceiling, peer-credential policy where required, graceful drain deadlines, and adversarial resource-exhaustion evidence.
