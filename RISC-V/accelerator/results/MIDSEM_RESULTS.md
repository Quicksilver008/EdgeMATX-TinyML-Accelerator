# Midsem Simulation Results

## Accelerator Verification

| Test | Pass | Accelerator Cycles |
|---|---:|---:|
| `identity` | 1 | 10 |
| `ones` | 1 | 10 |
| `signed_mixed` | 1 | 10 |
| `overflow_wrap` | 1 | 10 |
| `start_while_busy` | 1 | 10 |
| `reset_abort` | 1 | 0 |
| `post_reset_recovery` | 1 | 10 |
| `random_0` | 1 | 10 |
| `random_1` | 1 | 10 |
| `random_2` | 1 | 10 |
| `random_3` | 1 | 10 |
| `random_4` | 1 | 10 |
| `random_5` | 1 | 10 |
| `random_6` | 1 | 10 |
| `random_7` | 1 | 10 |
| `random_8` | 1 | 10 |
| `random_9` | 1 | 10 |
| `random_10` | 1 | 10 |
| `random_11` | 1 | 10 |

Overall pass rate: **19 / 19**

## Analytic Comparison (Cycle Model)

Assumptions: scalar software MM model uses 5 cycles/MAC plus loop overhead; accelerator setup overhead is modeled as 8 cycles.

| Metric | Value |
|---|---:|
| Matrix Size | 4x4 |
| Software Cycle Model | 352 |
| Accelerator Compute Cycles (simulated) | 10 |
| Accelerator End-to-End Cycles (modeled) | 18 |
| Speedup (compute-only) | 35.20x |
| Speedup (end-to-end) | 19.56x |

These speedups are pre-silicon estimates for presentation, not final board measurements.

## Next Step

Use this same test content after core integration, then replace analytic software cycles with measured `mcycle` or ARM `clock_gettime` data.
