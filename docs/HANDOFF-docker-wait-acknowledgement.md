# Change handoff: acknowledge Docker wait before start

## Problem

Docker CLI's run path issues a removal wait before it sends start. It waits for
the HTTP response headers from that route before it sends the start request.
When the Engine API held the response until the terminal container state, the
client and server waited on each other indefinitely.

## Change

Signed Engine API commit afb8a8f68ed56829b669c95cbddb488a68dc9175 adds a
registration boundary to DockerContainerWaitBackend and uses it to return a
managed HTTP wait stream after the backend has registered the observer. The
stream keeps the response body open until the terminal result is available.

The simple non-callback backend API remains available. Cancellation is still
forwarded to the underlying waiter, and the new stream gate prevents a
terminal-result race before response registration.

## Focused proof

swift test --filter DockerLoggingAPIControllerTests passed 23 tests. The
changed Engine API source measured 92.31% line/function coverage.

The paired Container candidate then passed a real Docker CLI 29.7.1 run in an
isolated marker-protected runtime. The captured wire order is:

1. /wait?condition=removed
2. HTTP/1.1 200 OK
3. /start
4. successful marker output and exit zero

The retained preflight and result are under
/private/tmp/container-docker-wait-ack-01.ckwusl.

## Publication boundary

The consuming Container implementation is signed locally at
d843dd598fa086c8572e5df8a71eece56ad7b576, but its ordinary dependency graph
still resolves Engine API 0.3.5. Do not release or claim a normal dependency
closure until this Engine API commit and the matching Containerization
prerequisite are reviewed/published, Container's pins advance, and the same
proof passes without editable dependencies.

No push or pull request has been created by this handoff.
