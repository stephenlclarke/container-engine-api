# Change handoff: expose the reusable Engine service lifecycle

## Summary

Expose the provider-selection and public-listener lifecycle as `ContainerEngineService`, retain the package executable as a thin entry point, and add bounded public and provider-backed health probes so provider-owned releases can supervise the canonical gateway without copying its implementation.

## Implementation

- Publish `ContainerEngineService` as a library product and move only the command entry point into `ContainerEngineServiceExecutable`.
- Expose typed service options, argument errors, startup, selected fingerprint, wait, and shutdown through the reusable library.
- Add a nonblocking, deadline-bounded Unix HTTP health client with strict path, response-size, status, and JSON checks.
- Keep `/_ping` as the public-listener probe and add `/info` as the provider-backed probe so stale fingerprint-bound sessions cannot be reported healthy.
- Preserve the existing `container-engine` command and help surface through the thin executable.
- Add the service library to the combined DocC build and document its package boundary.
- Add focused argument, live two-socket lifecycle, provider-health, timeout, fingerprint, and cleanup tests.

## Validation

The four focused service tests pass with real private and public Unix sockets, provider-backed `/info`, bounded failure, fingerprint comparison, and exact cleanup. The complete local gate passes all 87 tests in four suites, exact dependency resolution, generated-source and helper checks, formatting, Markdown lint, warnings-as-errors builds, and all eight DocC modules. Clean signed-head performance, hosted CI, and the matched enhanced Container adopter gate remain required before issue closure; their exact commands and results will be recorded in the issue comment and synchronized stack documentation.

## Compatibility

The `container-engine` command-line interface and public Docker HTTP behavior remain source- and wire-compatible. The new library is additive. `/info` health validation uses an already advertised provider route and adds no gateway authority or resource state.

## Linked issue

Closes [#9](https://github.com/stephenlclarke/container-engine-api/issues/9).

## Remaining risks

This change installs and supervises the shared gateway but does not broaden the selected provider's route capabilities. Full Docker API, external-client, socket-grant, immutable handoff, and production logging-driver evidence remain adopter-level gates.
