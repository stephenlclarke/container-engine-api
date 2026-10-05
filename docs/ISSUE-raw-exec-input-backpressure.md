# Issue: preserve bounded raw exec input under backpressure

## Problem

The raw upgraded Engine stream continued reading stdin while the runtime session was still consuming earlier bytes. A slow session could therefore fill the fixed 16 MiB pending-input queue and close an otherwise healthy upload, even when the client was willing to wait for socket capacity.

## Acceptance criteria

- Pause raw socket reads until the session has consumed the current bounded input batch, then resume reading.
- Reconcile queue state when takeover finishes so input received before callback/channel setup cannot strand later input.
- Preserve input byte order, stdin half-close ordering, cancellation behavior and the existing 16 MiB pending-input limit.
- Exercise an upload larger than 16 MiB against a deliberately slow session through the actual Unix HTTP server.

## Scope

This change applies to the raw upgraded stream. It does not increase queue limits, alter Docker wire behavior or change WebSocket input handling.

## Root validation

The complete Makefile test suite passes all 219 expanded test cases. The strengthened 32 MiB raw upload fails on the prior production code with a broken pipe and passes with this fix, preserving every byte and ordered stdin EOF. Formatting and Markdown checks pass. These local component results do not replace final signed Devcontainer runtime qualification.
