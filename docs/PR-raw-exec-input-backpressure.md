# Pull request: preserve bounded raw exec input under backpressure

## Summary

Disable automatic reads after raw stream takeover and request the next socket read only after the current read batch is complete and the ordered session-input pump has drained. Setup reconciles the pump's authoritative drained state after the channel is installed, so an early prefix whose notification preceded callback registration cannot strand subsequent input. This propagates a slow runtime session's backpressure to the Unix socket while retaining the existing 16 MiB pending-input cap and bounded 1 MiB pump chunks. WebSocket input behavior is unchanged.

The real Unix-server regressions upload 32 MiB to a session that initially blocks its first write and deliver an early stdin prefix with the upgrade request before sending later bytes without half-closing. A deterministic embedded-channel test covers the missed-notification ordering directly, including stale drain rejection. Together they verify backpressure, ordered delivery, recovery after early input, stdin EOF ordering and normal session completion.

See [issue context](ISSUE-raw-exec-input-backpressure.md).

## Validation

Root will run the focused Make-backed test suite after the source change. The same deterministic regression failed against the unmodified pinned source with `Broken pipe` at 0.028 seconds; its retained baseline is `/Volumes/SSD/q/engine-raw-upload-regression-before-v4.log`.

## Compatibility and remaining risk

Docker Engine protocol bytes and session APIs are unchanged. The server now reads raw stdin only when the prior batch has drained. The existing overflow cancellation remains as a hard safety bound for an individual read batch that exceeds the queue budget.

## Root validation

In the stock/client source lineage, the complete Makefile test suite passes all 221 reported test functions after the startup correction. The enhanced source suite passes all 189 reported test functions, including the same startup and large upload regressions. Both source suites also pass with compiler warnings treated as errors; strict logs are `/Volumes/SSD/q/engine-startup-stock-strict-v2.log` and `/Volumes/SSD/q/engine-startup-enhanced-strict-v2.log`. The deterministic initial-drain regression fails without that correction and passes with it; the real Unix early-prefix/later-input test also passes. Evidence is retained in `/Volumes/SSD/q/engine-startup-regression-before.log` and `/Volumes/SSD/q/engine-startup-full-after.log`. The strengthened 32 MiB raw upload fails on the prior production code with a broken pipe and passes with this fix, preserving every byte and ordered stdin EOF. Formatting and Markdown checks pass. These local component results do not replace final signed Devcontainer runtime qualification.
