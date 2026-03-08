# TinyML-Accelerator

TinyML-Accelerator is a Verilog-based RISC-V accelerator project that integrates a 4x4 fixed-point matrix-multiplication engine with PicoRV32 through the PCPI custom-instruction interface.

The repository is organized around a simulation-first workflow:
1. standalone accelerator validation,
2. PicoRV32 + PCPI integration,
3. firmware-driven regression and cycle comparison,
4. preparation for later FPGA deployment on Pynq-Z2.

## Project Highlights

1. 4x4 Q5.10 systolic matrix accelerator RTL.
2. PicoRV32 integration through a custom PCPI instruction.
3. Scripted regression, handoff validation, and 3-way cycle comparison.
4. Live real-input flow for evaluator-provided matrices.
5. Beginner-focused documentation for wrapper RTL, accelerator RTL, and systolic-array concepts.

## Current Status

1. Standalone accelerator RTL is validated in simulation.
2. PicoRV32 + PCPI integration is working end-to-end in simulation.
3. Firmware-driven smoke, regression, handoff, professor-demo, and cycle-compare flows are available.
4. FPGA timing closure and on-board performance measurement remain future work.

## Repository Map

1. `start_here/`: quick-entry docs and evaluation flow.
2. `integration/pcpi_demo/`: main PicoRV32 + PCPI + accelerator flow.
3. `accel_standalone/`: standalone accelerator RTL evaluation flow.
4. `picorv32/`: vendored PicoRV32 core from YosysHQ.
5. `RISC-V/`: vendored RV32I core reference implementation.
6. `midsem_sim/`: compatibility shim for older standalone-flow paths.
7. `integration/pcpi_demo/legacy/`: fallback/reference assets separated from active flow.

## Start Here

1. `start_here/README.md`
2. `start_here/EVAL_FLOW.md`
3. `integration/pcpi_demo/README.md`
4. `docs/diagrams/pcpi_wrapper_realistic_block_diagram.drawio.xml`

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

- Show simulation-first progress in mid-sem using `accel_standalone`.
- Stabilize accelerator + custom instruction interface in simulation before FPGA deployment.
- Transition from analytic speedup estimates to measured board timings (ARM and `mcycle`).

## Core Integration Status

- Accelerator is currently validated in standalone RTL simulation (`accel_standalone`).
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

## Standalone Accelerator Quick Start

Run from repository root:

```powershell
.\accel_standalone\scripts\run_midsem_sim.ps1
```

Generated artifacts:

- `accel_standalone/results/sim_output.log`
- `accel_standalone/results/MIDSEM_RESULTS.md`

Compatibility shim (old path, still supported):

```powershell
.\midsem_sim\scripts\run_midsem_sim.ps1
```

## PCPI Integration Demo Quick Start

Run from repository root:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1
```

Optional C firmware variant (same custom instruction semantics):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1 -FirmwareVariant c
```

Note: the C smoke variant and cycle-compare flow both use the shared source
`integration/pcpi_demo/firmware/firmware_matmul_unified.c` with compile-time mode/address macros.
Accelerator offload uses an explicitly emitted custom instruction word (`0x5420818b`), not automatic loop-to-accelerator compiler conversion.

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

1. `accel_cycles=673`
2. `sw_nomul_cycles=26130` (`rv32i`, `ENABLE_MUL=0`)
3. `sw_mul_cycles=7975` (`rv32im`, `ENABLE_MUL=1`)
4. `sw_nomul/accel=38.8262x`
5. `sw_mul/accel=11.8499x`
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

## Custom Real-Input Case Flow

Mentor/evaluator-provided real matrices can be tested without touching baseline regression `cases.json`.

Fastest live-evaluation mode (edit one JSON, run one script):

1. Edit `integration/pcpi_demo/tests/live_real_input.json`
2. Run:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1
```

This single command automatically converts real values to Q5.10, generates firmware case data, and runs accelerator + SW no-MUL + SW MUL comparisons.
It also writes per-variant outputs in real format:

- `integration/pcpi_demo/results/custom_cases/live_eval_active_outputs_real.json`

Current checked-in live profile (`live_real_input.json`) is tuned for near-50x no-MUL comparison and currently measures:
1. `accel=673`, `sw_nomul=36246`, `sw_mul=7975`
2. `sw_nomul/accel=53.8574x`
3. `sw_mul/accel=11.8499x`

Convert real values to Q5.10 and print preview only:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json
```

Convert and append timestamped custom case into isolated custom file:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json --append-custom
```

Run one custom case from custom case file:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_case.ps1 -CaseName <custom_case_name>
```

Run one custom case across all 3 performance variants (accelerator, SW no-MUL, SW MUL):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName <custom_case_name>
```

This writes per-variant logs plus a per-case cycle summary:

- `integration/pcpi_demo/results/custom_cases/<case>_cycle_accel.log`
- `integration/pcpi_demo/results/custom_cases/<case>_cycle_sw_nomul.log`
- `integration/pcpi_demo/results/custom_cases/<case>_cycle_sw_mul.log`
- `integration/pcpi_demo/results/custom_cases/<case>_cycle_compare_summary.md`
- `integration/pcpi_demo/results/custom_cases/<case>_cycle_compare_summary.json`
- `integration/pcpi_demo/results/custom_cases/<case>_outputs_real.json`

Explicitly clear generated custom cases:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --clear-generated
```

## Repo Hygiene + Handoff Discipline

1. Generated outputs are intentionally ignored (do not commit):
   - `integration/pcpi_demo/results/pcpi_cycle_*`
   - `integration/pcpi_demo/results/pcpi_prof_demo_*`
   - `integration/pcpi_demo/results/prof_demo_cases/*`
   - `pynq_z2_custom_core/build/*.out`
2. `run_cycle_compare.ps1` and `run_pcpi_professor_demo.ps1` now use a shared lock file (`integration/pcpi_demo/firmware/.firmware_flow.lock`) to avoid concurrent firmware rewrite races.
   - `run_pcpi_custom_case.ps1` also uses this lock.
   - `run_pcpi_custom_cycle_compare.ps1` also uses this lock.
3. After any code/script/RTL/testbench change, update both:
   - `README.md`
   - `handoff_project_context.md`
4. Consolidated tracked handoff/testing table is maintained at:
   - `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`
5. Mentor-facing progress brief is maintained at:
   - `mentor_progress_update.txt`
6. Beginner-to-advanced full project walkthrough is maintained at:
   - `integration/pcpi_demo/docs/MIDSEM_COMPLETE_PROJECT_GUIDE.md`
7. Dedicated RTL learning docs (wrapper, accelerator, systolic concept, end-to-end interaction) are at:
   - `integration/pcpi_demo/docs/RTL_WRAPPER_LINE_BY_LINE.md`
   - `integration/pcpi_demo/docs/RTL_ACCELERATOR_LINE_BY_LINE.md`
   - `integration/pcpi_demo/docs/SYSTOLIC_ARRAY_FROM_SCRATCH.md`
   - `integration/pcpi_demo/docs/END_TO_END_BLOCK_INTERACTION.md`
8. Design-space and deployment tradeoff note is at:
   - `integration/pcpi_demo/docs/DESIGN_TRADEOFFS_AND_USE_CASES.md`
9. Interactive web visualizer for architecture + handshake animation is at:
   - `integration/pcpi_demo/visualizer/README.md`
   - `integration/pcpi_demo/visualizer/index.html`
   - Production URL: `https://tinyml-pcpi-visualizer.vercel.app`
   - It now includes per-arrow signal inspection, CPU stall/handoff guidance, project-level architecture info, PE dataflow view, step-back control, and draggable split-pane layout.

Generated artifacts:

- `integration/pcpi_demo/results/pcpi_handoff.log`
- `integration/pcpi_demo/results/pcpi_handoff_wave.vcd`
- `integration/pcpi_demo/results/pcpi_handoff_summary.md`

## License

This repository is licensed under the MIT License. See `LICENSE`.
