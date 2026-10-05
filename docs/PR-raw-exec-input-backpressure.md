# Pull request: preserve bounded raw exec input under backpressure

## Summary

Disable automatic reads after raw stream takeover and request the next socket read only after the current read batch is complete and the ordered session-input pump has drained. This propagates a slow runtime session's backpressure to the Unix socket while retaining the existing 16 MiB pending-input cap and bounded 1 MiB pump chunks. WebSocket input behavior is unchanged.

The real Unix-server regression uploads 32 MiB to a session that initially blocks its first write. It verifies the sender becomes backpressured, the full payload arrives in order after the session resumes, stdin EOF follows the payload, and the session is not cancelled.

See [issue context](ISSUE-raw-exec-input-backpressure.md).

## Validation

Root will run the focused Make-backed test suite after the source change. The same deterministic regression failed against the unmodified pinned source with `Broken pipe` at 0.028 seconds; its retained baseline is `/Volumes/SSD/q/engine-raw-upload-regression-before-v4.log`.

## Compatibility and remaining risk

Docker Engine protocol bytes and session APIs are unchanged. The server now reads raw stdin only when the prior batch has drained. The existing overflow cancellation remains as a hard safety bound for an individual read batch that exceeds the queue budget.

## Root validation

The complete Makefile test suite passes all 219 expanded test cases. The strengthened 32 MiB raw upload fails on the prior production code with a broken pipe and passes with this fix, preserving every byte and ordered stdin EOF. Formatting and Markdown checks pass. These local component results do not replace final signed Devcontainer runtime qualification.
