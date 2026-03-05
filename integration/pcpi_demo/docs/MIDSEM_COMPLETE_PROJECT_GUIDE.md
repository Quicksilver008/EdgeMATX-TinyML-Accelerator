# TinyML Accelerator Midsem Complete Guide (From Scratch)

Last updated: 2026-03-05

This guide explains the entire project from zero background:

1. what is built
2. how accelerator + CPU integration works
3. what firmware does
4. what tests exist and how to run them
5. how to test evaluator-provided custom matrix values live
6. how to open waveforms in GTKWave (with saved `.gtkw` files)

## 1) Are We Midsem-Ready?

Short answer: yes for simulation-stage evaluation.

What is already verified:

1. Smoke integration (asm + c firmware): PASS
2. 8-case regression: PASS (8/8)
3. Mixed regular + custom instruction handoff: PASS
4. Professor explainable case suite: PASS (5/5)
5. Cycle comparison:
   - accelerator vs software no-MUL vs software MUL-enabled
6. Cycle scaling estimator run: PASS

Current limitation to state clearly in presentation:

1. results are simulation-based
2. board deployment and on-board timing/power/resource proof are next phase

## 2) High-Level Architecture

Main path is under `integration/pcpi_demo/`.

Core pieces:

1. CPU: `picorv32/picorv32.v`
2. PCPI wrapper: `integration/pcpi_demo/rtl/pcpi_tinyml_accel.v`
3. Accelerator RTL: `midsem_sim/rtl/matrix_accel_4x4_q5_10.v` (+ PE/issue/systolic modules)
4. Testbenches:
   - PCPI integration smoke/regression: `tb_picorv32_pcpi_tinyml.v`
   - Handoff: `tb_picorv32_pcpi_handoff.v`
   - SW baseline (no MUL): `tb_picorv32_sw_matmul.v`
   - SW baseline (MUL enabled): `tb_picorv32_sw_matmul_mul.v`

Custom instruction encoding used:

1. opcode: custom-0 (`0001011`)
2. funct3: `000`
3. funct7: `0101010`
4. machine word used in firmware: `0x5420818b`

## 3) How Accelerator Integration Works

### 3.1 Instruction-level flow

1. CPU executes custom instruction.
2. `rs1` carries base address of A matrix.
3. `rs2` carries base address of B matrix.
4. Wrapper (`pcpi_tinyml_accel.v`) detects instruction match.
5. Wrapper asserts `pcpi_wait` while running.
6. Wrapper reads A and B from memory sideband interface.
7. Wrapper starts accelerator (`matrix_accel_4x4_q5_10`).
8. After `done`, wrapper writes full C matrix back to memory (`0x200` base in demo flow).
9. Wrapper returns result (`c00`) through `pcpi_rd`, with `pcpi_ready`/`pcpi_wr`.
10. CPU resumes.

### 3.2 Wrapper state machine (important for viva)

In `pcpi_tinyml_accel.v`, state sequence:

1. `S_IDLE`
2. `S_LOAD_A`
3. `S_LOAD_B`
4. `S_KICK`
5. `S_WAIT_ACC`
6. `S_STORE_C`
7. `S_RESP`

Key handshake signals:

1. `pcpi_wait = pcpi_valid && insn_match && !resp_valid`
2. `pcpi_ready = pcpi_valid && insn_match && resp_valid`
3. `pcpi_wr = pcpi_ready`

### 3.3 Arithmetic contract (must remain unchanged)

All verification assumes exact RTL semantics:

1. signed16 multiply
2. arithmetic right shift by 10
3. signed32 accumulation
4. low16 wrap/truncate + sign-extend to 32 for compare

This is Q5.10 fixed-point behavior.

## 4) What Firmware Does (Why It Matters)

Firmware is the software program loaded into PicoRV32 memory in simulation.

Firmware roles:

1. place matrix A and B data in RAM
2. set pointers (`x1` and `x2` in custom-op path)
3. trigger custom instruction
4. write sentinel values (for TB PASS checks)

Important firmware variants:

1. `firmware.S`:
   - assembly path for PCPI custom instruction tests/regression
2. `firmware_c.c`:
   - C variant for smoke; still executes same custom instruction encoding
3. `firmware_sw_matmul.c`:
   - software-only 4x4 matmul baseline for cycle comparison
4. `firmware_handoff.S`:
   - test regular instructions in-between two custom instructions

## 5) Prerequisites and Setup

From repo root:

1. `git`
2. `PowerShell`
3. `iverilog` + `vvp`
4. `python`
5. optional: `gtkwave`
6. RISC-V toolchain native or WSL fallback

Quick check:

```powershell
git --version
iverilog -V
vvp -V
python --version
wsl bash -lc "riscv64-unknown-elf-gcc --version | head -n 1"
```

## 6) Full Test Flow Commands

### 6.1 One-command sanity gate

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_local_check.ps1
```

Runs:

1. smoke-asm
2. smoke-c
3. regression-8case
4. handoff

### 6.2 Cycle comparison (3-way)

```powershell
.\integration\pcpi_demo\scripts\run_cycle_compare.ps1
```

Outputs:

1. `pcpi_cycle_accel.log`
2. `pcpi_cycle_sw_nomul.log`
3. `pcpi_cycle_sw_mul.log`
4. summary `.md` + `.json`

### 6.3 Professor explainable demo suite

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_professor_demo.ps1
```

### 6.4 Handoff waveform-focused test

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1
```

## 7) Cycle Comparison Meaning (for oral explanation)

All three paths run on PicoRV32 family.

Compared paths:

1. Accelerator path:
   - PCPI custom instruction offload
2. Software no-MUL baseline:
   - `ENABLE_MUL=0`, firmware `rv32i`
3. Software MUL baseline:
   - `ENABLE_MUL=1`, firmware `rv32im`

Critical nuance:

1. setting `ENABLE_MUL=1` alone is not enough
2. firmware must also be compiled as `rv32im`
3. this is already handled in `run_cycle_compare.ps1`

## 8) Evaluator Custom Input Workflow (Most Important Section)

You have three safe live methods:

### Method A (recommended): Isolated custom real-input flow (no disturbance to baseline)

1. Real input template:
   - `integration/pcpi_demo/tests/sample_real_input.json`
2. Isolated custom case store:
   - `integration/pcpi_demo/tests/custom_cases.json`

Convert evaluator real values to Q5.10 and preview:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json
```

Append generated case (timestamped name by default) to custom case file:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json --append-custom
```

Run one custom case:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_case.ps1 -CaseName <custom_case_name>
```

Optional explicit cleanup of generated custom cases:

```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --clear-generated
```

### Method B: Add evaluator case into baseline `cases.json`

File:

1. `integration/pcpi_demo/tests/cases.json`

Add one case object with:

1. `name`
2. `a_q5_10` (16 ints)
3. `b_q5_10` (16 ints)
4. optional `notes`

Then run full regression:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1
```

If evaluator wants only one baseline case quickly:

```powershell
python .\integration\pcpi_demo\tests\gen_case_firmware.py --cases .\integration\pcpi_demo\tests\cases.json --case <your_case_name> --firmware-out .\integration\pcpi_demo\firmware\firmware.S --meta-out .\integration\pcpi_demo\results\cases\<your_case_name>.expected.json
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1
```

### Method C: Direct quick edit of `firmware.S`

Edit `a_init` and `b_init` in:

1. `integration/pcpi_demo/firmware/firmware.S`

Then run:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1
```

Method A is recommended during evaluator interaction because it keeps baseline regression vectors untouched.

## 9) Converting Evaluator Values to Q5.10

If evaluator gives decimal real numbers:

1. Q5.10 integer = `round(real_value * 1024)`
2. keep converted value in signed16 range (`-32768` to `32767`)
3. use `real_to_q5_10_case.py` to automate conversion and validation

Examples:

1. `1.0 -> 1024`
2. `0.5 -> 512`
3. `-1.0 -> -1024`

Range guidance (signed 16-bit storage in this flow):

1. representable raw range: `-32768` to `32767`
2. avoid overflow unless evaluator intentionally asks wrap behavior test

## 10) Waveforms and GTKWave (With Saved `.gtkw`)

### 10.1 Generate VCDs

1. PCPI demo VCD:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1
```
Generates:
`integration/pcpi_demo/results/pcpi_demo_wave.vcd`

2. Handoff VCD:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1
```
Generates:
`integration/pcpi_demo/results/pcpi_handoff_wave.vcd`

### 10.2 Open with saved GTKWave session files

1. Handoff-focused:
```powershell
gtkwave .\integration\pcpi_demo\results\pcpi_handoff_wave.vcd .\integration\pcpi_demo\simulation\gtkwave\pcpi_handoff_signals.gtkw
```

2. PCPI demo-focused:
```powershell
gtkwave .\integration\pcpi_demo\results\pcpi_demo_wave.vcd .\integration\pcpi_demo\simulation\gtkwave\pcpi_demo_signals.gtkw
```

If evaluator asks to add extra signals live:

1. add signals in GTKWave
2. File -> Write Save File
3. save back to same `.gtkw` for repeatable demo

## 11) What To Show in Midsem Demo (Suggested Script)

### Step 1: 30-second architecture intro

1. Show `pcpi_tinyml_accel.v` state machine
2. Explain rs1/rs2 pointers + pcpi_wait/ready flow

### Step 2: prove correctness quickly

1. run `run_pcpi_local_check.ps1`
2. mention PASS markers

### Step 3: show performance comparison

1. run `run_cycle_compare.ps1`
2. explain 3 baselines and speedups

### Step 4: evaluator custom matrix challenge

1. add case in `cases.json`
2. generate + run one-case demo or full regression
3. show expected vs observed pass

### Step 5: show handshake waveform if asked

1. open handoff VCD with `.gtkw`
2. point out `pcpi_wait -> pcpi_ready -> pcpi_wr`
3. show that regular instructions happened between two custom instructions

## 12) Common Failure Cases and Fixes

1. Toolchain missing:
   - install native or WSL RISC-V toolchain
2. Stale firmware hex / wrong variant:
   - rerun script; scripts rebuild by default when toolchain exists
3. Concurrent script race:
   - avoid parallel execution of firmware-rewriting scripts
   - lock is already added in cycle/prof-demo scripts
4. Wrong custom values:
   - re-check Q5.10 conversion and 16-element matrix ordering

## 13) Key Files You Should Know by Heart

1. `integration/pcpi_demo/rtl/pcpi_tinyml_accel.v`
2. `integration/pcpi_demo/tb/tb_picorv32_pcpi_tinyml.v`
3. `integration/pcpi_demo/tb/tb_picorv32_pcpi_handoff.v`
4. `integration/pcpi_demo/scripts/run_pcpi_local_check.ps1`
5. `integration/pcpi_demo/scripts/run_cycle_compare.ps1`
6. `integration/pcpi_demo/tests/cases.json`
7. `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`

## 14) Final Midsem Readiness Statement

For simulation-stage midsem evaluation:

1. functionality is validated
2. handshake/integration is validated
3. reproducible script-driven evidence exists
4. custom evaluator-input workflow is ready
5. waveform evidence is ready with reusable `.gtkw` setup files

For final project phase:

1. FPGA top-level deployment and board metrics remain next-stage work
