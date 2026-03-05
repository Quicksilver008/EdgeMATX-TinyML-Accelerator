# PCPI Professor Demo Summary

- Generated (UTC): 2026-03-04T22:36:52Z
- Total: 5
- Pass: 5
- Fail: 0

| Case | Explanation | Status | Expected c00 | Observed c00 |
| --- | --- | --- | --- | --- |
| demo_identity_passthrough | A = identity, so output C should equal B exactly. | PASS | 0x00000400 | 0x00000400 |
| demo_negative_identity | A = -identity, so output C should be element-wise negation of B. | PASS | 0xfffffc00 | 0xfffffc00 |
| demo_zero_matrix | A = all zeros, so output C must be all zeros regardless of B. | PASS | 0x00000000 | 0x00000000 |
| demo_half_scale | A = 0.5 * identity, so output C should be 0.5 * B. | PASS | 0x00000200 | 0x00000200 |
| demo_signed_passthrough | A = identity, B has mixed signs; output C should preserve each signed B element. | PASS | 0xfffffc00 | 0xfffffc00 |

Logs: integration/pcpi_demo/results/prof_demo_cases/*.log
