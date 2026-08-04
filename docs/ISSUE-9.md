# Issue 9: package the public Engine gateway for provider-owned runtimes

## Problem

The package exposed the shared `container-engine` implementation only as an executable target. A provider-owned runtime could start its private provider session, but it could not install a release-owned gateway binary or supervise the same implementation without copying the executable source. Testing also stopped at in-process router coverage rather than proving the reusable lifecycle across both Unix sockets.

## Impact

The enhanced Container runtime could not ship the canonical public Docker endpoint from its own matched release. Any copied entry point would create packaging drift, duplicate lifecycle behavior, and a risk that gateway-owned `/_ping` appeared healthy while the selected private provider was stale or unavailable.

## Expected behavior

The package must expose one reusable service library for argument parsing, immutable provider selection, public listener startup/shutdown, and bounded health checks while retaining `container-engine` as a thin executable. Provider releases must be able to install their own thin entry point, supervise it after the private provider starts, prove both public `/_ping` and provider-backed `/info`, and shut down without creating another Docker authority.

## Evidence

- GitHub issue: [#9](https://github.com/stephenlclarke/container-engine-api/issues/9)
- The focused service suite starts a real private provider session, starts the reusable public gateway, verifies both Unix endpoints through `/_ping` and `/info`, confirms the selected fingerprint, and proves exact socket cleanup.
- The matched enhanced Container package links the library product, stages and signs its thin executable, writes a private launchd plist, and treats provider-backed health as a system-start/status requirement.
