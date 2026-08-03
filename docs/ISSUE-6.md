# Issue 6: fragmented raw attach input is cancelled before completion

## Problem

The public Unix server split raw and WebSocket input into at most 1 MiB writes but bounded pending work by a count of 16 events. Ordinary Darwin/NIO reads are commonly much smaller than 1 MiB, so the effective capacity depended on transport fragmentation rather than byte volume. Adding the private provider hop increased the time required to consume each event and allowed a normal multi-megabyte attach payload to fill the event-count queue. The seventeenth pending fragment then cancelled the exact hijack session and closed the public socket even though the configured design intended to admit substantially more data.

The defect was exposed by the devcontainer Engine parity fixture `E03` and reproduced against the complete public gateway. Small inputs succeeded, while larger binary duplex inputs produced partial or empty output depending on how the kernel fragmented the same logical payload.

## Impact

Docker clients using attach stdin, WebSocket attach, or another hijacked route could lose a valid input stream under ordinary provider latency. Cancellation was fail-closed rather than silent, but the behavior was not Docker compatible and prevented the stock Apple devcontainer lane from reaching 18 of 18 fixtures.

## Expected behavior

The public input bound must be expressed in bytes, independent of the number and size of kernel read events. Accepted bytes and EOF must reach the selected session in wire order. Normal fragmented reads may be coalesced into bounded writes, and a consumer that falls more than the explicit byte limit behind must still cancel and close rather than drop or reorder data.

## Evidence

- GitHub issue: [#6](https://github.com/stephenlclarke/container-engine-api/issues/6)
- The focused complete-gateway regression sends and half-closes 4 MiB through the public Unix listener, shared gateway, private provider connection, delayed provider session, and response path; all 4,194,304 bytes return exactly.
- The local complete quality gate passes all 80 tests, including ordered byte/EOF, post-EOF, and overflow cancellation coverage.
- Exact dependency resolution, route generation, performance-helper self-tests, SwiftFormat, Markdown lint, warnings-as-errors builds, and all seven DocC modules pass on the designated Mac.
- Clean signed head `aefa9cb13bceae5e0921faef055085d8976f3966` passes all 66 same-host performance samples against Docker: 0.44x resize, 0.79x 32-byte WebSocket, and 0.45x 1 MiB WebSocket median ratios.
