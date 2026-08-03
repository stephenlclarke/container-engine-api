# Shared Engine Streaming Performance

Same-host release-build transport samples. This lane covers the public Unix listener, shared gateway, private provider session, logging controller, and a bounded in-memory backend. It does not replace production-runtime or logging-driver performance evidence.

The executable regression rule is timeout, incomplete execution, or a candidate median at least 10x Docker. Direction assessment uses a lower-is-better 10%/0.5 ms noise band.

| Fixture | Docker median (s) | Docker P95 (s) | Engine median (s) | Engine P95 (s) | Candidate/reference | Direction | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| resize | 0.002055 | 0.003274 | 0.000625 | 0.000772 | 0.30x | better | PASS |
| websocket-roundtrip-32b | 0.001578 | 0.005320 | 0.000596 | 0.000725 | 0.38x | better | PASS |
| websocket-roundtrip-1mib | 0.023453 | 0.026899 | 0.012057 | 0.012526 | 0.51x | better | PASS |

Raw samples are in `timings.tsv`; fingerprints are in `fingerprints.json`; machine comparison is in `summary.json`.
