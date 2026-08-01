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

The Dev Container-specific router handlers, runtime registries, resource DTO projections, state, CLI, service command, and Apple runtime modules were not extracted. In particular, the package imports neither `DevContainerCore`, `DevContainerModel`, `DevContainerRuntimeSPI`, `ComposeCore`, `apple/container`, nor `apple/containerization`. The later `ContainerEngineLogging` target remains runtime-neutral and depends only on the extracted wire and router products.

The raw session interface and stream-frame types were moved to `ContainerEngineWire` so the Unix server depends on a neutral protocol rather than the former Dev Container runtime SPI. `ContainerUnixHTTPServer` now accepts any `DockerHTTPResponder`; provider selection and endpoint policy belong in later gateway/adaptor work.

## Known Gaps And Non-Claims

### Docker Engine API 1.53 completeness

This package provides versioned route metadata and collision-safe matching primitives plus the logging-specific `/info`, inspect, logs, and attach routes for Docker Engine 29.2.1 API 1.44 through 1.53. It does not contain the complete API 1.53 DTO set or handlers, and it does not advertise whole-API 1.53 compatibility. Logging `/info` and inspect responses deliberately contain only the fields owned by this slice; a complete gateway must compose the other Engine fields. Request headers preserve original spelling, order, duplicates, and mixed-case duplicates through the NIO boundary, with all-value access and fail-closed unique lookup. Registry authentication, image push, BuildKit `/session`, complete archive/build semantics, and every non-logging route's pinned success/failure disposition remain future conformance work.

### Bounded streaming

Each inbound request body is still materialized as one `Foundation.Data` value, subject to per-request, aggregate-buffer, and pending-request caps. The logging surface uses `DockerHTTPStreamSession`: the server pulls one chunk at a time, awaits the NIO write before requesting another, closes natural completion exactly once, and cancels the exact source when the connection is force-closed. Raw hijack output likewise awaits each channel write. The source-compatible `AsyncThrowingStream<Data>` response case still does not suspend its producer on NIO writability, and the ordered raw-hijack input pump still has an unbounded queue when its session consumer is slower than the client. Large uploads require incremental delivery or inode-safe private-file spooling; adopters must use managed streams for large downloads, and stdin-capable raw routes need a bounded input policy before production advertisement.

### Remaining server hardening

The extracted server rejects empty, relative, repeated-separator, dot-component, NUL-containing, and UTF-8-overlong Unix socket paths before filesystem mutation. It validates the final parent as a current-user directory without group/world write permission and never changes caller-owned parent permissions. It preserves a mode-`0600` socket, an `O_NOFOLLOW` current-user single-link regular lock with nonblocking `flock`, exact device/inode cleanup, macOS `getpeereid` same-user admission, a global connection ceiling, per-connection and aggregate decoded request-body budgets, request-read and keep-alive idle deadlines, and a bounded graceful drain with forced child-channel closure. Lifecycle state is race-safe and explicitly one-shot after shutdown.

The package targets macOS and has no non-macOS peer-credential fallback; any future platform port must provide a kernel-authenticated equivalent and continue to fail closed when credentials are unavailable. The aggregate byte budget begins when NIO emits decoded body bytes, so NIO's separately bounded HTTP parser storage is not included in that metric. The server validates raw path components and the final parent but does not descriptor-walk every ancestor. Adversarial race/resource-exhaustion evidence, a bounded raw-hijack input queue, conversion of legacy producer-push streams, cancellation of non-cooperative responder work, and request-body streaming or inode-safe spooling remain open. With remote half-close enabled for Docker hijack compatibility, a silent followed response cannot distinguish a peer's full close from a legitimate write-side half-close until an output write fails or the server drain fence closes the channel; managed-source cancellation is immediate at either observable boundary.
