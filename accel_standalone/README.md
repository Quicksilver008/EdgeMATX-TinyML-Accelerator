# Standalone Accelerator Simulation

This folder provides a self-contained pre-silicon simulation flow for the 4x4 Q5.10 systolic matrix accelerator.

## What Is Included

- `rtl/`: Synthesizable Verilog modules (`pe_cell`, issue logic, 4x4 array, top-level accelerator).
- `tb/`: Self-checking testbench with pass/fail criteria and cycle reporting.
- `scripts/`: Automation scripts to run simulation and generate a markdown summary.
- `results/`: Generated logs and report artifacts.

## Quick Run (Windows PowerShell)

```powershell
.\accel_standalone\scripts\run_midsem_sim.ps1
```

Artifacts generated:

- `accel_standalone/results/sim_output.log`
- `accel_standalone/results/MIDSEM_RESULTS.md`

Compatibility shim (old path still works):

```powershell
.\midsem_sim\scripts\run_midsem_sim.ps1
```

## Latest Verification Results (2026-04-04)

| Metric | Value |
|---|---:|
| Total test cases | 19 |
| Passed | 19 |
| Failed | 0 |
| Pass rate | **100%** |
| Accelerator cycles (per 4x4 matmul) | 10 |

### Test Coverage

The test suite includes:
- **Functional tests**: identity, ones, signed_mixed, overflow_wrap
- **Control tests**: start_while_busy, reset_abort, post_reset_recovery
- **Randomized tests**: 12 random matrix cases with varying data patterns

All tests verify:
1. Correct Q5.10 fixed-point arithmetic (16-bit signed multiply → 32-bit accumulate → arithmetic shift-right by 10)
2. Proper overflow/wrap behavior
3. Control signal handshaking (start, busy, done)
4. Reset and recovery behavior

## Integration Status

This standalone accelerator RTL is integrated into:

1. **PicoRV32 via PCPI**: See `integration/pcpi_demo/`
   - Accelerator cycles in full system: 673 cycles
   - Speedup vs software: 38.8x (rv32i), 11.8x (rv32im)
   - MLPerf Tiny AD latency: 6.00 ms @ 100 MHz (MEETS <10ms target)

2. **Custom RV32 Pipeline via PCPI**: See `RISC-V/pipeline_top/`
   - Accelerator cycles: 37 cycles (pcpi_valid → pcpi_ready)
   - Speedup vs software: 69.7x
   - MLPerf Tiny AD latency: 2.58 ms @ 100 MHz (MEETS <10ms target)

## Notes

- This flow targets simulation evidence for mid-sem review and RTL verification.
- The standalone accelerator achieves 10-cycle compute latency.
- In full system integration, total cycles increase due to memory access overhead and PCPI handshaking.
- Analytic speedup estimates in MIDSEM_RESULTS.md are superseded by measured cycle counts from integration flows (see above).
