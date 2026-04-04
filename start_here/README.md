# Start Here

Primary quick-access pointers for evaluation and handoff.

## Most Important Commands

1. Local full sanity gate:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_local_check.ps1
```

2. 3-way cycle comparison:
```powershell
.\integration\pcpi_demo\scripts\run_cycle_compare.ps1
```

3. Live evaluator one-command run:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1
```

4. PicoRV32 MLPerf Tiny proxy benchmark:
```powershell
.\integration\pcpi_demo\scripts\run_picorv_mlperf.ps1
```

5. RV32 Pipeline MLPerf Tiny proxy benchmark:
```powershell
.\RISC-V\pipeline_top\scripts\run_mlperf_proxy.ps1
```

6. RV32 Pipeline full test suite:
```powershell
.\RISC-V\pipeline_top\scripts\run_pipeline_tests.ps1
```

7. Standalone accelerator verification:
```powershell
.\accel_standalone\scripts\run_midsem_sim.ps1
```

## Latest Test Results (2026-04-04)

### PicoRV32 Integration
- **Accelerator**: 673 cycles
- **SW no-MUL (rv32i)**: 26,130 cycles (38.8x slower)
- **SW MUL (rv32im)**: 7,975 cycles (11.8x slower)
- **MLPerf Tiny AD @ 100 MHz**: 6.00 ms (MEETS <10ms target)

### RV32 Pipeline Integration
- **Accelerator**: 37 cycles
- **SW**: 2,580 cycles (69.7x slower)
- **MLPerf Tiny AD @ 100 MHz**: 2.58 ms (MEETS <10ms target)

### Standalone Accelerator
- **Test cases**: 19/19 passed (100%)
- **Compute cycles**: 10 per 4x4 matmul

### Pipeline Regression Tests
- **Total tests**: 11/11 passed (100%)
- Includes forwarding/hazards, back-to-back PCPI, and full regression

## Most Important Inputs/Docs

1. Live evaluator input JSON:
   - `integration/pcpi_demo/tests/live_real_input.json`
2. Midsem full walkthrough:
   - `integration/pcpi_demo/docs/MIDSEM_COMPLETE_PROJECT_GUIDE.md`
3. Consolidated test summary:
   - `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`
4. Detailed PCPI integration docs:
   - `integration/pcpi_demo/README.md`
5. Standalone accelerator evaluation flow:
   - `accel_standalone/README.md`
6. Main project README:
   - `README.md`

## Performance Highlights

1. **MLPerf Tiny Compliance**: Both PicoRV32 and RV32 pipeline integrations meet the <10ms inference target
2. **Significant Speedups**: 38-70x faster than software implementations
3. **Verified Correctness**: 100% pass rate across all test suites
4. **Multiple Architectures**: Validated on both PicoRV32 and custom RV32 pipeline cores

## Notes

- Preferred standalone accelerator path is `accel_standalone/`.
- Old `midsem_sim/` path is retained as a compatibility shim.
- All test results include measured cycle counts, not analytic estimates.
- MLPerf Tiny benchmarks extrapolate to full Anomaly Detection workload performance.
