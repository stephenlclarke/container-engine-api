# Shared Engine Streaming Performance

Same-host release-build transport samples. This lane covers the public Unix listener, shared gateway, private provider session, logging controller, and a bounded in-memory backend. It does not replace production-runtime or logging-driver performance evidence.

The executable regression rule is timeout, incomplete execution, or a candidate median at least 10x Docker. Direction assessment uses a lower-is-better 10%/0.5 ms noise band.

| Fixture | Docker median (s) | Docker P95 (s) | Engine median (s) | Engine P95 (s) | Candidate/reference | Direction | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| resize | 0.001378 | 0.004086 | 0.000607 | 0.000705 | 0.44x | better | PASS |
| websocket-roundtrip-32b | 0.000791 | 0.003266 | 0.000622 | 0.000808 | 0.79x | comparable | PASS |
| websocket-roundtrip-1mib | 0.027297 | 0.030305 | 0.012174 | 0.012758 | 0.45x | better | PASS |

Raw samples are in `timings.tsv`; fingerprints are in `fingerprints.json`; machine comparison is in `summary.json`.
