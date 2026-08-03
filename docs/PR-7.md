# Change handoff: chunk provider request bodies

## Summary

Advance the private provider protocol to schema 3, keep request metadata in a bounded control frame, and transfer request bodies as ordered 1 MiB frames followed by an explicit end marker. Enforce the public 1 GiB body limit independently of the unchanged 48 MiB frame guard.

## Implementation

- Add `requestBody` and `requestEnd` provider frame kinds and remove the body from `ProviderSessionRequest` metadata.
- Bump the fail-closed provider protocol schema from 2 to 3 so mixed-version processes reject each other rather than interpreting a partial request.
- Send body data sequentially in at most 1 MiB frames and always send `requestEnd`, including for an empty body.
- Accumulate body frames in a dedicated state machine with checked size arithmetic and the same 1 GiB total limit as the production public listener.
- Reject body frames without data, unexpected frame kinds, and total-bound overflow with deterministic provider protocol errors.
- Add a complete provider client/server regression for a 36 MiB + 1 byte request, which could not fit in the old base64-expanded 48 MiB JSON frame.
- Add focused state-machine coverage for explicit completion, missing data, unexpected ordering, and total-bound overflow.
- Document schema 3 and distinguish implemented provider-body framing from the still-outstanding public-listener streaming/spooling optimization.

## Validation

```console
swift test --filter ContainerEngineProviderSessionTests
swiftformat --lint Package.swift Sources Tests Tools/ContainerEngineStreamingPerformanceFixture
markdownlint README.md docs
swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors --build-tests
```

The two new focused tests pass, including exact comparison of every byte in the body that exceeded the old frame geometry. The complete local gate passes all 82 tests, exact dependency resolution, generation and helper checks, formatting, Markdown lint, warnings-as-errors builds, and all seven DocC modules. Clean signed head `6edd44ae092d2d8eb083c96045f5e4539370524c` passes all 66 same-host performance samples against Docker: 0.40x resize, 0.78x 32-byte WebSocket, and 0.44x 1 MiB WebSocket median ratios. Hosted CI and the D05 adopter gate remain required before issue closure.

## Compatibility

The public Swift and Docker HTTP APIs are unchanged. Provider protocol schema 3 intentionally requires gateway and provider processes from the same package release; an older peer fails during the fingerprint-bound handshake instead of accepting an incomplete request. The 48 MiB per-frame guard remains unchanged, while the total request-body contract now matches the public server's 1 GiB production limit.

## Linked issue

Closes [#7](https://github.com/stephenlclarke/container-engine-api/issues/7).

## Remaining risks

The provider process still assembles the complete request before invoking `DockerHTTPResponder`, mirroring the responder's current `Data` contract. The public listener also buffers accepted bodies. Later public-listener streaming or secure spooling can reduce peak memory without another provider framing change. Clean-head evidence shows no material small-request regression from the extra `requestEnd` frame.
