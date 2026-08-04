# Shared Engine Streaming Performance

Same-host release-build transport samples. This lane covers the public Unix listener, shared gateway, private provider session, logging controller, and a bounded in-memory backend. It does not replace production-runtime or logging-driver performance evidence.

The executable regression rule is timeout, incomplete execution, or a candidate median at least 10x Docker. Direction assessment uses a lower-is-better 10%/0.5 ms noise band.

| Fixture | Docker median (s) | Docker P95 (s) | Engine median (s) | Engine P95 (s) | Candidate/reference | Direction | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| resize | 0.001714 | 0.002569 | 0.000665 | 0.000738 | 0.39x | better | PASS |
| websocket-roundtrip-32b | 0.001296 | 0.002433 | 0.000664 | 0.000790 | 0.51x | better | PASS |
| websocket-roundtrip-1mib | 0.020869 | 0.026312 | 0.012607 | 0.015270 | 0.60x | better | PASS |

Raw samples are in `timings.tsv`; fingerprints are in `fingerprints.json`; machine comparison is in `summary.json`.
