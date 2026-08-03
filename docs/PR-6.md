# Change handoff: preserve large raw attach input

## Summary

Replace the public hijack input event-count buffer with a byte-accounted queue so normal Darwin/NIO fragmentation cannot cancel valid multi-megabyte Docker attach or WebSocket input. Coalesce small reads into bounded provider writes, retain exact input/EOF order, and regression-test 4 MiB through the complete shared gateway.

## Implementation

- Keep the existing 1 MiB maximum input operation size and replace the 16-event `AsyncStream<Data>` buffer with a locked queue bounded at 16 MiB.
- Use a coalesced one-element wake stream only as a worker signal; retain accepted data in the byte-accounted queue rather than relying on signal count for capacity or correctness.
- Merge adjacent small reads up to 1 MiB before calling the selected hijack session, reducing provider framing and actor scheduling overhead without changing byte order.
- Drain all accepted data before forwarding EOF, and drain accepted data without EOF on natural output completion.
- On byte-bound overflow, clear the queue, cancel the worker and exact selected session, and close the public channel through the existing handler path.
- Adapt ordered-input tests to assert complete byte order independently of coalescing boundaries.
- Add a complete-gateway regression with a delayed provider session that sends, half-closes, and verifies a deterministic 4 MiB payload.
- Make the test Unix client use real monotonic deadlines so immediately successful `poll()` calls do not consume fictitious timeout intervals.
- Document the byte-accounted queue, coalescing limit, and overflow contract in the logging API article.

## Validation

```console
python3 Tools/generate_route_ledger.py --check
python3 -B Tools/performance/check_engine_streaming_performance.py --self-test
bash -n Tools/ci/*.sh
swiftformat --lint Package.swift Sources Tests Tools/ContainerEngineStreamingPerformanceFixture
markdownlint README.md docs
swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors --build-tests
swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors --target ContainerEngineStreamingPerformanceFixture
Tools/ci/run-swift-testing-bundle.sh \
  "$(swift build --disable-automatic-resolution --show-bin-path)/container-engine-apiPackageTests.xctest/Contents/MacOS/container-engine-apiPackageTests" \
  --no-parallel
scripts/make-docs.sh /tmp/container-engine-api-docc-v032 api/container-engine-api
```

The direct bundle run passes all 80 tests in three suites. The complete-gateway 4 MiB regression returns all bytes in 0.325 seconds in the focused run. Exact dependency resolution, generation checks, helper checks, formatting, Markdown, warnings-as-errors builds, and all seven DocC modules also pass locally. Clean-head performance evidence and hosted CI remain release gates.

## Compatibility

The change does not alter public Swift APIs, Docker routes, provider framing, dependency pins, or the documented 1 MiB per-operation limit. It makes the effective pending-input limit deterministic at 16 MiB instead of allowing kernel fragmentation to reduce it to as little as 16 small reads. Accepted bytes retain their original order; write-call boundaries are intentionally not part of the `DockerHijackSession` contract.

## Linked issue

Closes [#6](https://github.com/stephenlclarke/container-engine-api/issues/6).

## Remaining risks

The queue can retain up to 16 MiB per active hijack before failing closed, so the server's existing connection ceiling remains the aggregate resource bound. Coalescing copies adjacent fragments into at most 1 MiB values; release performance evidence must confirm the reduced provider-call count does not introduce a meaningful latency or memory regression. Production Container and external-client parity lanes remain separate adopter gates after this package release.
