# Issue 18: cache verified provider-session peer identities

## Problem

Every provider-session connection resolved the peer PID and executable path and then repeated strict macOS static-code validation. The gateway creates a new provider connection for each provider-backed Docker request, so an otherwise sub-millisecond request paid roughly 400–450 ms for code-signature verification on every connection.

## Impact

The terminal-session parity oracle completed against Docker Engine 29.2.1 in about 0.19 seconds but needed about 4.36 seconds through the matched Container provider stack. The repeated verification made normal multi-request Compose operations visibly slower even though the runtime and transport work itself was fast.

## Expected behavior

A process that has already passed strict code-signature validation may reuse that successful identity result for later connections from the same exact executable image. Cached evidence must not survive PID reuse, an `exec`, a failed validation, or unbounded process churn. Every connection must continue comparing the peer-resolved identity with the identity claimed by the session protocol.

## Security model

The cache key combines the socket-authenticated opaque peer audit token and PID with the kernel-reported process start time and current executable path. The audit token changes for every `exec`, including an `exec` of the same path, while a recycled PID changes the start time. The implementation stores the complete opaque token instead of parsing its private representation. Only successful strict validations enter the cache, storage is bounded to 32 executable images, and the existing per-connection claimed-identity comparison remains unchanged.

## Evidence

- GitHub issue: [#18](https://github.com/stephenlclarke/container-engine-api/issues/18)
- Focused cache tests prove exact-instance reuse, PID-reuse isolation, executable-path isolation, failure retry, and bounded eviction.
- The complete provider-session test suite exercises the cache inside the existing signed-peer handshake and request transports.
- The matched signed Container adopter passes the terminal-session behavior and <10× timing gate in 1.238173 seconds on its first post-start capture and 0.920554 seconds warm, down from 4.359129 seconds before the cache; the pinned Docker fixture is 0.184992 seconds.
