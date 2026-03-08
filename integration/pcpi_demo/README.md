# PCPI Integration Demo

This demo validates an end-to-end integration path:

- PicoRV32 core (`ENABLE_PCPI=1`)
- PCPI custom instruction wrapper
- Existing 4x4 Q5.10 accelerator RTL

## Dependencies (Collaborator Setup)

Minimum required:

1. `iverilog`
2. `vvp`
3. `python` (Python 3)
4. `PowerShell` (for `*.ps1` scripts)

Optional (waveforms):

1. `gtkwave`

Firmware rebuild toolchain (required for regression and handoff flows):

Option A: Native Windows toolchain:

1. `riscv64-unknown-elf-gcc`
2. `riscv64-unknown-elf-objcopy`
3. `make`

Option B: WSL Ubuntu fallback:

```bash
sudo apt-get update
sudo apt-get install -y gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf make python3
```

Tool verify:

```powershell
iverilog -V
vvp -V
python --version
wsl bash -lc "riscv64-unknown-elf-gcc --version | head -n 1"
```

## What It Proves

1. Core issues a custom instruction on PCPI.
2. `rs1` and `rs2` are interpreted as base addresses for matrix A and B buffers.
3. PCPI module reads A and B from memory, launches accelerator, and writes C buffer to memory.
4. Core is stalled via `pcpi_wait` and resumes on `pcpi_ready`.
5. Result register write-back (`pcpi_rd`) and memory outputs are checked by testbench.

## Custom Instruction Used

- Opcode: `custom-0` (`0001011`)
- `funct3`: `000`
- `funct7`: `0101010`
- Machine code in demo program: `0x5420818b`

Why fixed:

1. The PCPI RTL decode matches this exact instruction pattern.
2. C compiler does not auto-detect nested matmul loops and replace them with custom op.
3. Firmware must explicitly emit this instruction for accelerator offload.

Assembly representation:

```asm
.word 0x5420818b
```

Conceptually this means:

```asm
# custom matmul rd=x3, rs1=x1 (A base), rs2=x2 (B base)
custom_matmul x3, x1, x2
```

## Demo Program (loaded directly in testbench memory)

1. Copy `a_init[16]` from firmware image into RAM buffer at `0x100`
2. Copy `b_init[16]` from firmware image into RAM buffer at `0x140`
3. `addi x1, x0, 0x100` (A base address)
4. `addi x2, x0, 0x140` (B base address)
5. `custom matmul x3, x1, x2`
6. `lw x4, 0x200(x0)` (read first C element)
7. `sw x4, 0(x0)` (write to sentinel location for pass/fail check)
8. `jal x0, 0`

Memory layout used in this demo:

- A matrix buffer: `0x100` .. `0x13C` (16 words)
- B matrix buffer: `0x140` .. `0x17C` (16 words)
- C matrix buffer: `0x200` .. `0x23C` (16 words, written by PCPI module)

Input data source:

- For single-case smoke runs, A and B values are taken from `integration/pcpi_demo/firmware/firmware.S` (`a_init`, `b_init`).
- For regression runs, A and B values are generated per case from `integration/pcpi_demo/tests/cases.json` into `firmware.S`.
- Testbench computes expected C from RAM A/B contents at runtime using RTL-exact wrap semantics.

To try custom matrices (single-case flow):

1. Edit `a_init` and `b_init` in `firmware.S` (Q5.10 format).
2. Re-run `.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1`.

To add/update regression vectors:

1. Edit `integration/pcpi_demo/tests/cases.json`.
2. Re-run `.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1`.

## Run

From repo root:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1
```

Optional C firmware smoke variant (keeps instruction encoding unchanged, uses explicit custom-op macro):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1 -FirmwareVariant c
```

Smoke C and cycle-comparison now share one firmware source:

- `integration/pcpi_demo/firmware/firmware_matmul_unified.c`
- build mode is selected via `EXTRA_CFLAGS` macros (`MATMUL_MODE_ACCEL` vs `MATMUL_MODE_SW`) plus base-address macros.

Regression (8-case suite):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1
```

Handoff/handshake validation (mixed regular + custom instructions):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1
```

Cycle comparison (software no-MUL baseline vs software MUL baseline vs accelerator):

```powershell
.\integration\pcpi_demo\scripts\run_cycle_compare.ps1
```

This run reports:

1. software no-MUL (`rv32i`, `ENABLE_MUL=0`)
2. software MUL-enabled (`rv32im`, `ENABLE_MUL=1`)
3. accelerator custom-instruction path
4. speedups between all three.

Latest verified cycle values (2026-03-05):

1. Accelerator: `673`
2. Software no-MUL (`rv32i`): `26130`
3. Software MUL-enabled (`rv32im`): `7975`
4. Accelerator speedup vs no-MUL software: `38.8262x`
5. Accelerator speedup vs MUL-enabled software: `11.8499x`
6. MUL-enabled software speedup vs no-MUL software: `3.2765x`

Professor-ready explainable demo cases:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_professor_demo.ps1
```

Cycle scaling estimator (normal core vs accelerator, ideal + overhead-aware model):

```powershell
python .\integration\pcpi_demo\scripts\estimate_cycle_scaling.py --sizes 4,8,16,32,64
```

One-command local checker (smoke asm + smoke c + regression + handoff):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_local_check.ps1
```

Custom real-input case flow (isolated from baseline `tests/cases.json`):

Fast live evaluator mode (one file + one command):

1. edit `integration/pcpi_demo/tests/live_real_input.json`
2. run:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1
```

This auto-converts real input to Q5.10, injects generated case data into unified firmware, and runs all 3 variants.
It also generates:
- `integration/pcpi_demo/results/custom_cases/live_eval_active_outputs_real.json`

Current checked-in live profile (`live_real_input.json`) is tuned for near-50x no-MUL comparison and currently measures:
1. `accel=673`, `sw_nomul=36246`, `sw_mul=7975`
2. `sw_nomul/accel=53.8574x`
3. `sw_mul/accel=11.8499x`

1. Convert real matrices to Q5.10 preview:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json
```

2. Convert and append timestamped custom case:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json --append-custom
```

3. Run one custom case:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_case.ps1 -CaseName <custom_case_name>
```

4. Run one custom case across all 3 variants (accelerator, SW no-MUL, SW MUL):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName <custom_case_name>
```

5. Optional explicit cleanup of generated custom cases:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --clear-generated
```

Default isolated custom file:

- `integration/pcpi_demo/tests/custom_cases.json`

Firmware flow notes:

- If `riscv64-unknown-elf-gcc` is available, the script rebuilds firmware from:
  - `integration/pcpi_demo/firmware/firmware.S` (default)
  - `integration/pcpi_demo/firmware/firmware_matmul_unified.c` (when `-FirmwareVariant c`)
  - `integration/pcpi_demo/firmware/sections.lds`
  - `integration/pcpi_demo/firmware/Makefile`
- If native toolchain is missing, scripts try WSL toolchain fallback.
- If toolchain is missing, asm smoke can use checked-in fallback:
  - `integration/pcpi_demo/firmware/firmware.hex`
- C smoke variant requires a toolchain rebuild (no stale-hex fallback).
- Accelerator RTL root is auto-resolved by scripts:
  - preferred: `accel_standalone/rtl/`
  - compatibility fallback: `midsem_sim/rtl/`
- Legacy firmware sources retained as fallback/reference:
  - `integration/pcpi_demo/legacy/firmware/firmware_c.c`
  - `integration/pcpi_demo/legacy/firmware/firmware_sw_matmul.c`
  - See `integration/pcpi_demo/legacy/README.md` for rationale.

Artifacts:

- `integration/pcpi_demo/results/pcpi_demo.log`
- `integration/pcpi_demo/results/pcpi_demo_wave.vcd`
- `integration/pcpi_demo/results/cases/*.log` (regression per-case logs)
- `integration/pcpi_demo/results/pcpi_regression_summary.md`
- `integration/pcpi_demo/results/pcpi_regression_summary.json`
- `integration/pcpi_demo/results/pcpi_handoff.log`
- `integration/pcpi_demo/results/pcpi_handoff_wave.vcd`
- `integration/pcpi_demo/results/pcpi_handoff_summary.md`
- `integration/pcpi_demo/results/pcpi_cycle_accel.log`
- `integration/pcpi_demo/results/pcpi_cycle_sw_nomul.log`
- `integration/pcpi_demo/results/pcpi_cycle_sw_mul.log`
- `integration/pcpi_demo/results/pcpi_cycle_compare_summary.md`
- `integration/pcpi_demo/results/pcpi_cycle_compare_summary.json`
- `integration/pcpi_demo/results/pcpi_prof_demo_summary.md`
- `integration/pcpi_demo/results/pcpi_prof_demo_summary.json`
- `integration/pcpi_demo/results/pcpi_cycle_scaling_estimate.json`
- `integration/pcpi_demo/results/custom_cases/*.log`
- `integration/pcpi_demo/results/custom_cases/*.expected.json`
- `integration/pcpi_demo/results/custom_cases/*_cycle_compare_summary.md`
- `integration/pcpi_demo/results/custom_cases/*_cycle_compare_summary.json`
- `integration/pcpi_demo/results/custom_cases/*_outputs_real.json`
- `integration/pcpi_demo/docs/MIDSEM_COMPLETE_PROJECT_GUIDE.md`
- `integration/pcpi_demo/simulation/gtkwave/pcpi_demo_signals.gtkw`
- `integration/pcpi_demo/simulation/gtkwave/pcpi_handoff_signals.gtkw`
- `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md` (tracked, consolidated handoff table)

For mentor/demo handoff, use this consolidated table first:

- `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`

Beginner RTL deep-dive docs:

- `integration/pcpi_demo/docs/RTL_WRAPPER_LINE_BY_LINE.md`
- `integration/pcpi_demo/docs/RTL_ACCELERATOR_LINE_BY_LINE.md`
- `integration/pcpi_demo/docs/SYSTOLIC_ARRAY_FROM_SCRATCH.md`
- `integration/pcpi_demo/docs/END_TO_END_BLOCK_INTERACTION.md`
- `integration/pcpi_demo/docs/DESIGN_TRADEOFFS_AND_USE_CASES.md`

Interactive architecture + handshake visualizer app:

- `integration/pcpi_demo/visualizer/README.md`
- `integration/pcpi_demo/visualizer/index.html`
- Production URL: `https://tinyml-pcpi-visualizer.vercel.app`
- Features now include per-arrow signal info popups, CPU stall/handoff explanation, architecture/project info modals, PE-level operand movement, and step-back navigation.

Architecture contract draft for future SoC top-level:

- `integration/pcpi_demo/SOC_MMIO_CONTRACT.md`

## Handoff Test (What It Verifies)

The handoff flow executes firmware with:

1. First custom instruction
2. Regular instructions (`lw`, `sw`, `addi`)
3. Second custom instruction

The handoff testbench verifies:

1. First sentinel write (`addr 0x0`) matches expected first result (`0x00000400`)
2. Regular-instruction marker write (`addr 0x8`) matches expected (`0x0000047b`)
3. Second sentinel write (`addr 0x4`) matches expected second result (`0xfffffc00`)
4. Handshake correctness for both custom instructions:
   - `custom_issue_count=2`
   - `ready_count=2`
   - `wr_count=2`
   - `handshake_ok_count=2`
5. Accelerator C-buffer store count for two runs: `c_store_count=32`

To inspect waveform:

```powershell
gtkwave .\integration\pcpi_demo\results\pcpi_handoff_wave.vcd
```

Or load the pre-saved handoff signal view:

```powershell
gtkwave .\integration\pcpi_demo\results\pcpi_handoff_wave.vcd .\integration\pcpi_demo\simulation\gtkwave\pcpi_handoff_signals.gtkw
```

Recommended signals to add in GTKWave:

- `pcpi_valid`
- `pcpi_insn`
- `pcpi_wait`
- `pcpi_ready`
- `pcpi_wr`
- `pcpi_rd`
- `accel_mem_valid`
- `accel_mem_we`
- `accel_mem_addr`
- `accel_mem_wdata`
- `mem_valid`
- `mem_addr`
- `mem_wdata`
- `mem_wstrb`

## Regression Case Manifest

`integration/pcpi_demo/tests/cases.json` schema per case:

- `name`: string
- `a_q5_10`: 16 signed values (decimal or hex string)
- `b_q5_10`: 16 signed values (decimal or hex string)
- `notes`: optional description

Isolated custom case file (`integration/pcpi_demo/tests/custom_cases.json`) uses the same fields and may include:

- `meta.generated_by`: `real_to_q5_10`
- `meta.created_at_utc`
- `meta.input_source`

All regression checks use RTL-exact arithmetic:

- signed16 multiply
- arithmetic shift-right by 10
- signed32 accumulation
- final compare on low 16 bits (wrap), sign-extended to 32-bit memory word

## Custom 3-Variant Compare (Isolated Cases)

This flow uses the same unified source (`firmware_matmul_unified.c`) for all 3 runs and injects selected custom-case matrices via generated header data:

1. generator: `integration/pcpi_demo/tests/gen_case_header.py`
2. runner: `integration/pcpi_demo/scripts/run_pcpi_custom_cycle_compare.ps1`

Latest verified random custom examples (2026-03-05):

1. `custom_rand_case1`: accel `673`, sw-no-mul `36246`, sw-mul `7975`
2. `custom_rand_case2`: accel `673`, sw-no-mul `36034`, sw-mul `7975`
