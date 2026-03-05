# Evaluator Live Flow (One JSON + One Command)

## Step 1: Edit real-valued input

Update:

- `integration/pcpi_demo/tests/live_real_input.json`

Provide evaluator matrices in `a_real_4x4` and `b_real_4x4`.
Current checked-in profile is intentionally dense to demonstrate near-50x SW no-MUL speedup in live mode.

## Step 2: Run one command

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1
```

This automatically does:

1. Real -> Q5.10 conversion
2. Case generation (`live_eval_active`)
3. Firmware case-data generation
4. Accelerator + SW no-MUL + SW MUL runs
5. Cycle + speedup summary generation
6. Real-format output JSON generation

## Step 3: Open outputs

1. Cycle summary:
   - `integration/pcpi_demo/results/custom_cases/live_eval_active_cycle_compare_summary.json`
2. Per-variant real output matrix:
   - `integration/pcpi_demo/results/custom_cases/live_eval_active_outputs_real.json`

Both files are regenerated on each run.

## Current reference numbers (2026-03-05)

For the current `live_real_input.json` profile:

1. `accel_cycles = 673`
2. `sw_nomul_cycles = 36246`
3. `sw_mul_cycles = 7975`
4. `sw_nomul/accel = 53.8574x`
5. `sw_mul/accel = 11.8499x`
