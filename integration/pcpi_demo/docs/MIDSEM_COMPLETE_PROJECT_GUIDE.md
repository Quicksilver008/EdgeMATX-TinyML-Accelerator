# TinyML Accelerator Midsem Complete Guide (From Scratch)

Last updated: 2026-03-05

This guide explains the entire project from zero background:

1. what is built
2. how accelerator + CPU integration works
3. what firmware does
4. what tests exist and how to run them
5. how to test evaluator-provided custom matrix values live
6. how to open waveforms in GTKWave (with saved `.gtkw` files)
7. how to use the interactive visualizer for architecture, stall/handoff, and systolic dataflow explanation

## Visualizer

Interactive visualizer:
1. local source: `integration/pcpi_demo/visualizer/`
2. local entry: `integration/pcpi_demo/visualizer/index.html`
3. production URL: `https://tinyml-pcpi-visualizer.vercel.app`

What it shows:
1. system architecture across CPU, wrapper, accelerator, and memory
2. per-arrow signal inspection using small `i` buttons on architecture paths
3. CPU stall/handoff explanation from the CPU block `i` button
4. project-level opcode / Q5.10 / file-mapping explanation from `Architecture Info`
5. PE-level operand movement in the 4x4 systolic array
6. forward and backward stepping of the wrapper transaction

How to use it in demo:
1. use `App Guide` for explaining the four windows
2. use `Architecture Info` when evaluators ask about opcode, Q5.10, files, or handshakes
3. use the CPU `i` button when asked how the core stalls and resumes
4. use per-arrow `i` buttons when asked which exact RTL signals travel on a path
5. use `Step Back` if you overshoot a state during explanation

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
3. Accelerator RTL: `accel_standalone/rtl/matrix_accel_4x4_q5_10.v` (+ PE/issue/systolic modules)
   - compatibility shim note: old `midsem_sim/` path still forwards to `accel_standalone/`.
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

Why this opcode is fixed in this project:

1. The PCPI wrapper RTL decodes one exact instruction pattern (opcode/funct3/funct7).
2. Standard C compiler optimization does not auto-convert nested matmul loops into your custom instruction.
3. So firmware must explicitly emit this machine word when offload is intended.

How custom instruction can look in assembly:

1. Raw word form (used here, always works):
```asm
.word 0x5420818b
```
2. Equivalent conceptual R-type layout:
```asm
# funct7=0101010, rs2=x2, rs1=x1, funct3=000, rd=x3, opcode=0001011
custom_matmul x3, x1, x2
```
3. Some toolchains can express it with `.insn`, but support is assembler-dependent. Raw `.word` is the robust portable choice in this flow.

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
2. `firmware_matmul_unified.c`:
   - shared C source used for smoke-C and 3-way cycle comparison
   - compile-time macros select mode:
     - accelerator custom-op path (`MATMUL_MODE_ACCEL=1`)
     - software matmul path (`MATMUL_MODE_SW=1`)
   - compile-time base-address macros map to each testbench memory layout
3. `firmware_c.c` and `firmware_sw_matmul.c`:
   - retained as fallback/reference sources under `integration/pcpi_demo/legacy/firmware/`
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

### 6.5 Custom case 3-way cycle comparison

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName <custom_case_name>
```

Outputs (per selected case):

1. `integration/pcpi_demo/results/custom_cases/<case>_cycle_accel.log`
2. `integration/pcpi_demo/results/custom_cases/<case>_cycle_sw_nomul.log`
3. `integration/pcpi_demo/results/custom_cases/<case>_cycle_sw_mul.log`
4. `integration/pcpi_demo/results/custom_cases/<case>_cycle_compare_summary.md`
5. `integration/pcpi_demo/results/custom_cases/<case>_cycle_compare_summary.json`
6. `integration/pcpi_demo/results/custom_cases/<case>_outputs_real.json` (per-variant output matrix in Q5.10 and real format)

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
2. Live one-file template (recommended in viva):
   - `integration/pcpi_demo/tests/live_real_input.json`
3. Isolated custom case store:
   - `integration/pcpi_demo/tests/custom_cases.json`

One-command live mode (edit one file, run one command):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1
```

Current checked-in live profile is seeded for near-50x no-MUL comparison and currently measures:
1. `accel=673`, `sw_nomul=36246`, `sw_mul=7975`
2. `sw_nomul/accel=53.8574x`
3. `sw_mul/accel=11.8499x`

What it does automatically:

1. reads `live_real_input.json`
2. converts to Q5.10
3. generates isolated live case (`live_eval_active`)
4. runs accelerator + sw-no-mul + sw-mul and writes cycle summary
5. writes `<case>_outputs_real.json` with output matrix in Q5.10 and real values

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

Run one custom case across all 3 performance variants:

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName <custom_case_name>
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
When evaluator asks for performance comparison on the same live input, run `run_pcpi_custom_cycle_compare.ps1`.

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

This section explains the function of each core file and what the important code in that file is doing.

### 13.1 `integration/pcpi_demo/rtl/pcpi_tinyml_accel.v`

Function:
1. This is the hardware bridge between PicoRV32 PCPI port and your matrix accelerator RTL.

Important code behavior:
1. Instruction decode checks the fixed custom encoding match.
2. State machine sequence controls full transaction:
   - `S_IDLE -> S_LOAD_A -> S_LOAD_B -> S_KICK -> S_WAIT_ACC -> S_STORE_C -> S_RESP`
3. Memory sideband reads matrix A and B from CPU memory map.
4. Starts accelerator, waits for `done`.
5. Writes all 16 output elements to C buffer.
6. Returns `c00` on `pcpi_rd` with `pcpi_ready`/`pcpi_wr`.

Why it matters:
1. This is the main integration logic that proves offload works.

### 13.2 `integration/pcpi_demo/tb/tb_picorv32_pcpi_tinyml.v`

Function:
1. End-to-end integration testbench for custom instruction path.

Important code behavior:
1. Instantiates PicoRV32 + PCPI wrapper + memory model.
2. Loads `firmware.hex`.
3. Watches sentinel write at address `0x0` to confirm `c00`.
4. Recomputes expected 4x4 output in TB using RTL-exact arithmetic.
5. Verifies full C buffer content (`16` elements), not only first result.
6. Emits cycle marker `TB_CYCLES matmul_to_sentinel_cycles=...`.

Why it matters:
1. This is your primary proof of correctness for accelerator offload.

### 13.3 `integration/pcpi_demo/tb/tb_picorv32_pcpi_handoff.v`

Function:
1. Verifies mixed execution: custom instruction, regular instructions, then custom instruction again.

Important code behavior:
1. Checks first custom result sentinel.
2. Checks regular instruction marker write (`lw/sw/addi` path actually executed).
3. Checks second custom result sentinel.
4. Counts handshake quality:
   - issue count
   - ready count
   - wr count
   - handshake_ok count
   - C-store count

Why it matters:
1. Shows CPU control returns cleanly between custom and normal code.

### 13.4 `integration/pcpi_demo/firmware/firmware_matmul_unified.c`

Function:
1. Single C firmware source used by smoke-C and cycle-compare flows.

Important code behavior:
1. Compile-time mode switch:
   - `MATMUL_MODE_ACCEL=1` uses custom instruction offload.
   - `MATMUL_MODE_SW=1` uses software nested-loop matmul.
2. Compile-time address macros map to TB-specific memory layout:
   - `A_BASE_WORD_ADDR`, `B_BASE_WORD_ADDR`, `C_BASE_WORD_ADDR`
3. Copies `a_init`/`b_init` into RAM.
4. Runs selected matmul path.
5. Stores first output element to sentinel address `0x0`.
6. In accelerator mode, emits explicit custom opcode `.word 0x5420818b`.

Why it matters:
1. Demonstrates same source-level algorithm harness for fair comparisons.

### 13.5 `integration/pcpi_demo/scripts/run_pcpi_demo.ps1`

Function:
1. Smoke runner for one integration simulation.

Important code behavior:
1. Selects firmware variant (`asm` or `c`).
2. Builds firmware using native toolchain if available, otherwise WSL fallback.
3. For C variant, passes compile-time mode/address macros to unified firmware.
4. Compiles TB and runs simulation.
5. Produces log and waveform file.

Why it matters:
1. Fast sanity check command for demos and handoff.

### 13.6 `integration/pcpi_demo/scripts/run_cycle_compare.ps1`

Function:
1. Produces 3-way cycle comparison in one command.

Important code behavior:
1. Uses firmware lock to avoid concurrent rewrite races.
2. Builds same unified C firmware in three configurations:
   - accelerator mode (`rv32i`)
   - software no-MUL (`rv32i`)
   - software MUL-enabled (`rv32im`)
3. Runs three TBs and extracts cycle markers from logs.
4. Computes speedup ratios and writes markdown/json summaries.

Why it matters:
1. This is your quantitative performance evidence.

### 13.7 `integration/pcpi_demo/scripts/run_pcpi_local_check.ps1`

Function:
1. One-command gate for local sanity before push/demo.

Important code behavior:
1. Runs sequence:
   - smoke-asm
   - smoke-c
   - regression-8case
   - handoff
2. Stops immediately on any failure.

Why it matters:
1. Prevents accidental breakage across flows.

### 13.8 `integration/pcpi_demo/tests/cases.json`

Function:
1. Baseline regression vector source of truth.

Important code behavior:
1. Stores named A/B matrices in signed Q5.10 integer form.
2. Regression script iterates all cases and auto-generates firmware per case.

Why it matters:
1. Keeps regression deterministic and reviewable.

### 13.9 `integration/pcpi_demo/tests/custom_cases.json`

Function:
1. Isolated evaluator/mentor custom vectors.

Important code behavior:
1. Same schema as baseline cases.
2. Can include generated metadata from real-value converter flow.
3. Explicit cleanup mode removes generated entries without touching baseline file.

Why it matters:
1. Lets you test live custom inputs without disturbing official regression set.

### 13.10 `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`

Function:
1. Tracked consolidated evidence table for handoff/mentor review.

Important code behavior:
1. Lists latest pass/fail status per flow.
2. Captures cycle comparison table and derived ratios.
3. Documents key intricacies and source artifacts.

Why it matters:
1. Single reference document to present progress quickly.

### 13.11 `integration/pcpi_demo/scripts/run_pcpi_custom_cycle_compare.ps1`

Function:
1. Runs one selected custom case across accelerator, SW no-MUL, and SW MUL paths.

Important code behavior:
1. Uses shared firmware flow lock to avoid concurrent firmware rewrite races.
2. Generates header data from chosen custom case, then compiles unified firmware for 3 variants.
3. Runs corresponding TBs and extracts cycle markers.
4. Writes per-case markdown/json speedup summary.

Why it matters:
1. Lets you benchmark evaluator-provided matrices without mutating baseline regression vectors.

### 13.12 `integration/pcpi_demo/tests/gen_case_header.py`

Function:
1. Converts one named case from JSON into `firmware_case_data.h` used by unified C firmware.

Important code behavior:
1. Validates matrix lengths and values.
2. Emits deterministic C arrays for `a_init` and `b_init`.
3. Supports isolated custom-case pipeline wiring.

Why it matters:
1. Enables same firmware source to consume dynamic custom case inputs.

### 13.13 Dedicated RTL learning docs (new)

Files:
1. `integration/pcpi_demo/docs/RTL_WRAPPER_LINE_BY_LINE.md`
2. `integration/pcpi_demo/docs/RTL_ACCELERATOR_LINE_BY_LINE.md`
3. `integration/pcpi_demo/docs/SYSTOLIC_ARRAY_FROM_SCRATCH.md`
4. `integration/pcpi_demo/docs/END_TO_END_BLOCK_INTERACTION.md`

Why it matters:
1. Gives beginner-focused deep explanation of wrapper FSM, systolic dataflow, and block interactions without changing RTL code.

### 13.14 `integration/pcpi_demo/docs/DESIGN_TRADEOFFS_AND_USE_CASES.md`

Function:
1. Documents design directions for low power, low latency, high throughput, lower resource usage, and higher clock-frequency goals.

Important content:
1. Lists what hardware changes can be made for each goal.
2. Explains the tradeoffs of those changes.
3. Summarizes where this accelerator is a better fit than a heavy GPU.

Why it matters:
1. Helps explain future hardware roadmap decisions in a structured way during review or evaluation.
2. Also documents practical deployment use cases and how the accelerator could be integrated with third-party CPU cores in either custom-instruction or future MMIO style.

## 14) Final Midsem Readiness Statement

For simulation-stage midsem evaluation:

1. functionality is validated
2. handshake/integration is validated
3. reproducible script-driven evidence exists
4. custom evaluator-input workflow is ready
5. waveform evidence is ready with reusable `.gtkw` setup files

For final project phase:

1. FPGA top-level deployment and board metrics remain next-stage work
