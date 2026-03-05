# Midsem Simulation Pack

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

## Notes

- This flow targets simulation evidence for mid-sem review.
- Speedup values in the markdown are analytic estimates based on a scalar software cycle model and should be replaced by measured hardware timings in later phases.
