# Issue 7: provider request frames reject large image loads

## Problem

The provider client encoded each Docker request, including its complete `Data` body, into one JSON frame. Provider frames are intentionally limited to 48 MiB, and JSON encodes binary data as base64, so valid Docker requests failed far below the public Unix server's 1 GiB request limit. Increasing the frame limit would hide the protocol design error, amplify peak allocation, and make every decoder accept unnecessarily large control frames.

The exact devcontainer `container-compose` parity lane exposed the defect after BuildKit successfully built and exported the D05 feature image. Its 133,511,589-byte `POST /images/load` body was rejected before the selected runtime provider received the request.

## Impact

Large image loads and any other body-bearing Docker route could return a synthetic provider-unavailable response despite being accepted by the public Engine listener. This prevented the D05 adopter fixture from completing and made the shared out-of-process gateway incompatible with ordinary BuildKit output sizes.

## Expected behavior

Request metadata must remain in one bounded control frame. The body must follow as ordered bounded data frames plus an explicit end marker, with malformed ordering rejected and a total body limit aligned with the public listener. The per-frame safety limit must not be raised.

## Evidence

- GitHub issue: [#7](https://github.com/stephenlclarke/container-engine-api/issues/7)
- Exact failing body: 133,511,589 bytes in the D05 `POST /images/load` request.
- Exact adopter result before the fix: 16 of 18 `container-compose` fixtures passed; D05 failed on the provider frame limit and C04 reproduced the separately tracked stable-bundle alias limitation.
- The focused protocol regression transfers and compares a 36 MiB + 1 byte body whose previous base64 JSON frame exceeded the 48 MiB guard.
- Focused framing tests also prove explicit empty-body completion, malformed/missing data rejection, and fail-closed total-bound enforcement.
- The complete local gate passes all 82 tests, exact dependency resolution, generation and helper checks, formatting, Markdown lint, warnings-as-errors builds, and all seven DocC modules.
