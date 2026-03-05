# PCPI Demo Test Results Summary

Last updated: 2026-03-05

This document consolidates the latest simulation evidence for the PCPI demo, including the new software-MUL comparison.

Code snapshot context:

1. Unified smoke+cycle firmware source commit: `3e805d3`
2. Isolated custom 3-variant compare flow commit: `8630966`

## 1) Latest Test Matrix

| Flow | Command | Last Verified Date | Result | Key Evidence |
| --- | --- | --- | --- | --- |
| Smoke (asm) | `.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1 -FirmwareVariant asm` | 2026-03-05 | PASS | `TB_CYCLES=869`, result write + full C-buffer PASS |
| Smoke (c) | `.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1 -FirmwareVariant c` | 2026-03-05 | PASS | `TB_CYCLES=673`, result write + full C-buffer PASS |
| 8-case regression | `.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1` | 2026-03-05 | PASS (8/8) | `pcpi_regression_summary.json` |
| Handoff mixed-instruction test | `.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1` | 2026-03-05 | PASS | `custom_issue=2 ready=2 wr=2 handshake_ok=2 c_store=32` |
| Professor demo suite | `.\integration\pcpi_demo\scripts\run_pcpi_professor_demo.ps1` | 2026-03-05 | PASS (5/5) | `pcpi_prof_demo_summary.json` |
| Cycle comparison (accelerator vs SW no-MUL vs SW MUL) | `.\integration\pcpi_demo\scripts\run_cycle_compare.ps1` | 2026-03-05 | PASS | `pcpi_cycle_compare_summary.json` |
| Custom real-input isolated case flow | `python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json --append-custom --name custom_demo_identity` then `.\integration\pcpi_demo\scripts\run_pcpi_custom_case.ps1 -CaseName custom_demo_identity` | 2026-03-05 | PASS | custom case conversion + isolated run PASS (`TB_CYCLES=869`) |
| Custom isolated 3-variant cycle compare | `.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName custom_rand_case1` and `-CaseName custom_rand_case2` | 2026-03-05 | PASS | both cases PASS in accel + sw-no-mul + sw-mul with per-case summaries |
| Live evaluator one-command flow | edit `.\integration\pcpi_demo\tests\live_real_input.json`, then run `.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1` | 2026-03-05 | PASS | auto real->Q5.10 + auto firmware case + 3-way compare (`live_eval_active`) |
| One-command gate | `.\integration\pcpi_demo\scripts\run_pcpi_local_check.ps1` | 2026-03-05 | PASS | `smoke-asm + smoke-c + regression + handoff` all PASS |

## 2) Cycle Comparison Results (Same Matrix Case)

Case: `identity_x_sequence` (Q5.10)

| Path | Core Config | Firmware ISA Arch | Cycles |
| --- | --- | --- | ---: |
| Accelerator custom instruction | `ENABLE_PCPI=1`, `ENABLE_MUL=0`, `ENABLE_FAST_MUL=0` | `rv32i` | 673 |
| Software baseline (no MUL) | `ENABLE_PCPI=0`, `ENABLE_MUL=0`, `ENABLE_FAST_MUL=0` | `rv32i` | 26130 |
| Software baseline (MUL enabled) | `ENABLE_PCPI=0`, `ENABLE_MUL=1`, `ENABLE_FAST_MUL=0` | `rv32im` | 7975 |

Derived ratios:

1. Accelerator speedup over SW no-MUL: `26130 / 673 = 38.8262x`
2. Accelerator speedup over SW MUL-enabled: `7975 / 673 = 11.8499x`
3. SW MUL benefit over SW no-MUL: `26130 / 7975 = 3.2765x`

## 2B) Custom Isolated 3-Variant Results (Random Cases)

| Case | Accel Cycles | SW no-MUL Cycles | SW MUL Cycles | SW no-MUL / Accel | SW MUL / Accel |
| --- | ---: | ---: | ---: | ---: | ---: |
| `custom_rand_case1` | 673 | 36246 | 7975 | 53.8574x | 11.8499x |
| `custom_rand_case2` | 673 | 36034 | 7975 | 53.5423x | 11.8499x |
| `live_eval_active` | 673 | 36246 | 7975 | 53.8574x | 11.8499x |

## 3) Intricacies That Matter

1. This is a same-core comparison: all paths run on PicoRV32.
2. The difference is execution model:
   - software paths compute matrix multiply in firmware loops,
   - accelerator path issues one custom PCPI instruction and offloads compute.
3. Enabling `ENABLE_MUL=1` alone is not enough for fair MUL testing; firmware must also be compiled with `-march=rv32im` so MUL instructions can be emitted.
4. The no-MUL software baseline is intentionally strict (`rv32i` + `ENABLE_MUL=0`), so scalar multiply is done via software helpers / RV32I-compatible sequence.
5. Arithmetic semantics remain unchanged across all paths: RTL-exact Q5.10 wrap behavior.
6. `run_cycle_compare.ps1` and `run_pcpi_professor_demo.ps1` both rewrite firmware inputs; they are serialized via a shared lock file (`integration/pcpi_demo/firmware/.firmware_flow.lock`) to avoid race corruption.
7. Generated evidence under `integration/pcpi_demo/results/` is intentionally ignored by git; this tracked file acts as the stable handoff summary.
8. Evaluator real-value tests can now be isolated from baseline regression vectors:
   - baseline remains in `integration/pcpi_demo/tests/cases.json`
   - custom generated entries are stored in `integration/pcpi_demo/tests/custom_cases.json`
   - explicit cleanup is available via `--clear-generated`
9. Smoke-C and cycle-compare now share one firmware source (`integration/pcpi_demo/firmware/firmware_matmul_unified.c`) with compile-time mode/address macros; regression/prof/handoff default paths remain unchanged.
10. Isolated custom 3-way compare also uses the same unified firmware source; selected case data is injected through generated header arrays.
11. Custom 3-way flow now also emits per-case `*_outputs_real.json` containing Q5.10 and real-format matrix output for all 3 variants.

## 4) Source Artifacts

1. `integration/pcpi_demo/results/pcpi_cycle_compare_summary.json`
2. `integration/pcpi_demo/results/pcpi_regression_summary.json`
3. `integration/pcpi_demo/results/pcpi_handoff_summary.md`
4. `integration/pcpi_demo/results/pcpi_prof_demo_summary.json`
5. `integration/pcpi_demo/docs/MIDSEM_COMPLETE_PROJECT_GUIDE.md`
6. `integration/pcpi_demo/simulation/gtkwave/*.gtkw`
7. `integration/pcpi_demo/tests/custom_cases.json`
8. `integration/pcpi_demo/tests/real_to_q5_10_case.py`
9. `integration/pcpi_demo/firmware/firmware_matmul_unified.c`
10. `integration/pcpi_demo/results/custom_cases/*_cycle_compare_summary.json`
11. `integration/pcpi_demo/results/custom_cases/*_outputs_real.json`
