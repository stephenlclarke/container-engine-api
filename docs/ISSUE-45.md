# Issue context for PR 45: bound native Unix client requests

## Problem

Native foreground startup also needs an acknowledged streaming response before it starts the process. Waiting for the complete `/wait` response cannot establish readiness; starting a request concurrently without header acknowledgement still races automatic removal. The shared client therefore needs an optional successful-head callback, while the provider must separately register the incarnation-bound exit waiter before sending those headers.

The native Engine client at `276a7cfdba91fef60c232177a44c054e5de9ae8f` uses per-system-call inactivity timeouts and an uncancelled detached Swift task. A trickling peer can keep a request alive indefinitely. Concurrent blocking reads can exhaust Swift's cooperative executor, preventing asynchronous peers and cancellation work from progressing. Chunk-size and trailer lines are unbounded, and an empty chunk-size line can trap. These defects block adoption by the Docker-free devcontainer command frontend.

## Acceptance criteria

- Never forward an HTTP error document into a successful event/log body callback; bound diagnostic bodies even when successful streams have no aggregate limit.

- Add full-duplex Engine upgrade transport for interactive frontend execution without Docker, retaining stdin half-close, raw framing, bounded reads and race-safe explicit closure.
- Prove that synchronous deadline detection shuts down the opposite blocked direction even when timer delivery is delayed.
- Apply one monotonic absolute deadline across connect, request write, response head and body.
- Forward task cancellation to the owned socket and await worker cleanup before returning; never close a descriptor from a competing thread.
- Keep blocking socket work off Swift's cooperative executor and prove more simultaneous requests than worker threads complete.
- Bound response headers, individual chunk lines and aggregate trailers independently of the body budget; reject invalid chunk sizes without trapping.
- Preserve valid fixed, chunked and close-delimited responses and server errors.
- Exercise real private sockets through native Bazel, retaining failed and successful evidence on the established SSD/internal-storage workflow.

Owner: Container-family D01 implementation stream. This is a prerequisite fix, not completion of D01, the package-wide Bazel migration, runtime parity or a release. No Docker runtime or Apple service is needed by these tests.

Pull request: [#45](https://github.com/stephenlclarke/container-engine-api/pull/45).
