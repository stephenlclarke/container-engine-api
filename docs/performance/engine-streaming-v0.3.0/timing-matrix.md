# Shared Engine Streaming Performance

Same-host release-build transport samples. This lane covers the public Unix listener, shared gateway, private provider session, logging controller, and a bounded in-memory backend. It does not replace production-runtime or logging-driver performance evidence.

The executable regression rule is timeout, incomplete execution, or a candidate median at least 10x Docker. Direction assessment uses a lower-is-better 10%/0.5 ms noise band.

| Fixture | Docker median (s) | Docker P95 (s) | Engine median (s) | Engine P95 (s) | Candidate/reference | Direction | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| resize | 0.001462 | 0.004725 | 0.000531 | 0.000691 | 0.36x | better | PASS |
| websocket-roundtrip-32b | 0.000990 | 0.003047 | 0.000616 | 0.000762 | 0.62x | comparable | PASS |
| websocket-roundtrip-1mib | 0.022800 | 0.028382 | 0.011895 | 0.012620 | 0.52x | better | PASS |

Raw samples are in `timings.tsv`; fingerprints are in `fingerprints.json`; machine comparison is in `summary.json`.
