# Shared Engine Streaming Performance

Same-host release-build transport samples. This lane covers the public Unix listener, shared gateway, private provider session, logging controller, and a bounded in-memory backend. It does not replace production-runtime or logging-driver performance evidence.

The executable regression rule is timeout, incomplete execution, or a candidate median at least 10x Docker. Direction assessment uses a lower-is-better 10%/0.5 ms noise band.

| Fixture | Docker median (s) | Docker P95 (s) | Engine median (s) | Engine P95 (s) | Candidate/reference | Direction | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| resize | 0.001546 | 0.003634 | 0.000621 | 0.000708 | 0.40x | better | PASS |
| websocket-roundtrip-32b | 0.000834 | 0.002623 | 0.000647 | 0.000841 | 0.78x | comparable | PASS |
| websocket-roundtrip-1mib | 0.027554 | 0.030606 | 0.012122 | 0.015204 | 0.44x | better | PASS |

Raw samples are in `timings.tsv`; fingerprints are in `fingerprints.json`; machine comparison is in `summary.json`.
