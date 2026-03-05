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

## Notes

- Preferred standalone accelerator path is `accel_standalone/`.
- Old `midsem_sim/` path is retained as a compatibility shim.
