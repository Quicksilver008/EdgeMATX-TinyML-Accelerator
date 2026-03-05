# TinyML-Accelerator

TinyML-Accelerator is a major project focused on building a TinyML accelerator on top of a RISC-V based hardware platform.

## Current Repository Layout

- `RISC-V/`: Vendored Verilog implementation of a 5-stage pipelined RV32I core and related modules.
- `picorv32/`: Vendored PicoRV32 core from YosysHQ.
- `midsem_sim/`: Self-contained systolic-array simulation flow for mid-sem evaluation.
- `integration/pcpi_demo/`: First PicoRV32+PCPI+accelerator integration demo.
- `README.md`: Top-level project documentation.

## Dependencies (Install Before Running)

Required for all simulation flows:

1. `git`
2. `PowerShell` (Windows)
3. `iverilog` and `vvp` (Icarus Verilog)
4. `python` (Python 3)

Recommended for waveform inspection:

1. `gtkwave`

Required for firmware rebuild (PCPI regression/handoff):

Option A: Native toolchain on Windows:
1. `riscv64-unknown-elf-gcc`
2. `riscv64-unknown-elf-objcopy`
3. `make`

Option B: WSL fallback (Ubuntu), used by scripts when native toolchain is missing:
```bash
sudo apt-get update
sudo apt-get install -y gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf make python3
```

Quick verify commands:

```powershell
git --version
iverilog -V
vvp -V
python --version
gtkwave --version
wsl bash -lc "riscv64-unknown-elf-gcc --version | head -n 1"
```

## Vendored RISC-V Core

This repository currently includes the upstream core as a vendor copy (not a submodule):

- Upstream: `https://github.com/srpoyrek/RISC-V`
- Imported on: `2026-02-28`
- Import metadata: `RISC-V/VENDORING.md`

The `RISC-V/` folder is tracked directly by this repo, and `RISC-V/.git` is intentionally removed.

## Upstream Core Summary

Based on the upstream README, the core includes:

- 5-stage pipelined RISC-V architecture (RV32I)
- Verilog HDL implementation
- Modules such as control unit, hazard detection, forwarding, ALU, and memory-related blocks
- Testbench-based verification (ModelSim-oriented upstream setup)

## Next Development Focus

- Show simulation-first progress in mid-sem using `midsem_sim`.
- Stabilize accelerator + custom instruction interface in simulation before FPGA deployment.
- Transition from analytic speedup estimates to measured board timings (ARM and `mcycle`).

## Core Integration Status

- Accelerator is currently validated in standalone RTL simulation (`midsem_sim`).
- PicoRV32 is vendored and available in-repo (`picorv32/`).
- A first CPU integration milestone is implemented in simulation via PCPI (`integration/pcpi_demo`).
- Custom instruction path is tested with machine-code loaded directly in testbench memory.
- PCPI demo now uses matrix base pointers (rs1/rs2), reads A/B from memory, and writes C buffer back to memory.
- Firmware scaffold is added (`firmware.S`, linker script, Makefile, hex generation path) with fallback hex support when toolchain is unavailable.
- Full board deployment is still pending.

## Planned Core Integration Path

1. Add a proven integration-ready RV32 core (recommended: PicoRV32).
2. Wrap the accelerator with a coprocessor/custom-op interface (`start`, `busy`, `done`).
3. Add decode/handshake logic so a custom instruction triggers matrix multiply.
4. Build CPU+accelerator simulation testbench and verify correctness plus stall behavior.
5. Replace analytic speedup estimates with measured cycle counts (`mcycle` / ARM timing).
6. Move to Vivado/Pynq-Z2 hardware integration after simulation sign-off.

## Midsem Simulation Quick Start

Run from repository root:

```powershell
.\midsem_sim\scripts\run_midsem_sim.ps1
```

Generated artifacts:

- `midsem_sim/results/sim_output.log`
- `midsem_sim/results/MIDSEM_RESULTS.md`

## PCPI Integration Demo Quick Start

Run from repository root:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1
```

Optional C firmware variant (same custom instruction semantics):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1 -FirmwareVariant c
```

Generated artifacts:

- `integration/pcpi_demo/results/pcpi_demo.log`
- `integration/pcpi_demo/results/pcpi_demo_wave.vcd`

## PCPI 8-Case Regression Quick Start

Run from repository root:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1
```

Generated artifacts:

- `integration/pcpi_demo/results/cases/*.log`
- `integration/pcpi_demo/results/pcpi_regression_summary.md`
- `integration/pcpi_demo/results/pcpi_regression_summary.json`

## PCPI Handoff Validation Quick Start

Run from repository root:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1
```

## PCPI One-Command Local Checker

Run from repository root:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_local_check.ps1
```

This script runs smoke (`asm` + `c`), full regression, and handoff, and exits non-zero on any failure.

## PCPI Cycle Comparison

Run from repository root:

```powershell
.\integration\pcpi_demo\scripts\run_cycle_compare.ps1
```

This reports cycle counts for:

1. software baseline without scalar MUL (`rv32i`, `ENABLE_MUL=0`)
2. software baseline with scalar MUL (`rv32im`, `ENABLE_MUL=1`)
3. custom-instruction accelerator path

and writes speedup ratios across all three.

Latest verified (2026-03-05):

1. `accel_cycles=869`
2. `sw_nomul_cycles=26130` (`rv32i`, `ENABLE_MUL=0`)
3. `sw_mul_cycles=7975` (`rv32im`, `ENABLE_MUL=1`)
4. `sw_nomul/accel=30.069x`
5. `sw_mul/accel=9.1772x`
6. `sw_nomul/sw_mul=3.2765x`

## PCPI Professor Demo Cases

Run from repository root:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_professor_demo.ps1
```

This runs an explainable set of matrix cases (identity, negative identity, zero, half-scale, signed passthrough) and produces a concise demo summary.

## Cycle Scaling Estimator

Run from repository root:

```powershell
python .\integration\pcpi_demo\scripts\estimate_cycle_scaling.py --sizes 4,8,16,32,64
```

This generates estimated normal-core vs accelerator scaling tables (ideal and overhead-aware) in JSON form.

## Repo Hygiene + Handoff Discipline

1. Generated outputs are intentionally ignored (do not commit):
   - `integration/pcpi_demo/results/pcpi_cycle_*`
   - `integration/pcpi_demo/results/pcpi_prof_demo_*`
   - `integration/pcpi_demo/results/prof_demo_cases/*`
   - `pynq_z2_custom_core/build/*.out`
2. `run_cycle_compare.ps1` and `run_pcpi_professor_demo.ps1` now use a shared lock file (`integration/pcpi_demo/firmware/.firmware_flow.lock`) to avoid concurrent firmware rewrite races.
3. After any code/script/RTL/testbench change, update both:
   - `README.md`
   - `codex_prompt.md`
4. Consolidated tracked handoff/testing table is maintained at:
   - `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`
5. Mentor-facing progress brief is maintained at:
   - `mentor_progress_update.txt`

Generated artifacts:

- `integration/pcpi_demo/results/pcpi_handoff.log`
- `integration/pcpi_demo/results/pcpi_handoff_wave.vcd`
- `integration/pcpi_demo/results/pcpi_handoff_summary.md`
