# Codex Handoff Prompt (Compaction-Safe)

Last updated: 2026-03-07

This file is the single source of truth to resume work after context compaction.

## Copy-Paste Prompt For Next Codex Session

```text
Read integration/pcpi_demo/legacy/internal_handoff/project_handoff_context.md fully and continue from the current repository state without restarting.

Mandatory first actions:
1) Show `git branch --show-current` and `git status --short`.
2) Re-run `.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1`.
3) Re-run `.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1`.
4) Confirm whether all regression + handoff checks still pass and report summary lines.

Then continue from "Immediate Next Work (Do In Order)" in integration/pcpi_demo/legacy/internal_handoff/project_handoff_context.md.
Do not change arithmetic semantics: use RTL-exact Q5.10 wrap behavior.
Keep all flows script-driven and reproducible.
Update integration/pcpi_demo/legacy/internal_handoff/project_handoff_context.md again at the end with what changed.
```

## Project Intent

Build a TinyML-oriented matrix accelerator flow on RISC-V (final target: Pynq-Z2), with simulation-first credibility now and hardware integration after.

## Current Repo Snapshot

- Repository root: `TinyML-Accelerator`
- Active working branch: `main`
- Public-facing repo polish now includes:
  - root `LICENSE` (MIT)
  - tightened root `README.md` intro/map for GitHub readers
- Recent local commits on `main`:
  - `8630966` (`Add isolated custom 3-variant cycle compare flow`)
  - `3e805d3` (`Unify smoke and cycle compare on one firmware source`)

## What Is Implemented And Verified

### A) Vendor setup

1. Vendored `RISC-V/` from `https://github.com/srpoyrek/RISC-V` (as vendor copy, no nested `.git`).
2. Vendored `picorv32/` from `https://github.com/YosysHQ/picorv32`.

### B) Mid-sem standalone accelerator simulation

`accel_standalone/` includes RTL + TB + scripts and passes baseline tests.
Compatibility shim:
1. `midsem_sim/scripts/run_midsem_sim.ps1` forwards to `accel_standalone/scripts/run_midsem_sim.ps1`.

### C) PicoRV32 + PCPI integration demo

Directory: `integration/pcpi_demo`

Implemented:
1. PCPI wrapper: `rtl/pcpi_tinyml_accel.v`
2. CPU integration TB: `tb/tb_picorv32_pcpi_tinyml.v`
3. Firmware flow: `firmware/firmware.S`, `firmware/sections.lds`, `firmware/Makefile`
4. Smoke script: `scripts/run_pcpi_demo.ps1`

Behavior:
1. Custom instruction over PCPI.
2. `rs1/rs2` interpreted as A/B base pointers.
3. Wrapper reads A/B from memory, runs accelerator, writes C to `0x200`.
4. TB checks both returned `c00` and full C buffer.

### D) Firmware-driven matrix input path

No matrix hardcoding in TB for functional vectors.
Firmware provides A and B (`a_init`, `b_init`) and copies to RAM before custom op.

### E) 8-case scripted regression suite (new)

Added:
1. Case manifest: `integration/pcpi_demo/tests/cases.json`
2. Generator: `integration/pcpi_demo/tests/gen_case_firmware.py`
3. Regression runner: `integration/pcpi_demo/scripts/run_pcpi_regression.ps1`
4. TB case label plusarg support: `+CASE_NAME=<name>`

Regression semantics:
1. signed16 multiply
2. arithmetic right shift by 10
3. signed32 accumulation
4. final compare on wrapped low16, sign-extended to 32-bit

Case set:
1. `identity_x_sequence`
2. `zero_x_random`
3. `random_x_zero`
4. `neg_identity`
5. `mixed_sign_small`
6. `near_wrap_positive`
7. `rand_seed_42`
8. `rand_seed_1234`

Last verified result:
1. `run_pcpi_regression.ps1` executed all 8 cases.
2. Summary showed `Pass: 8`, `Fail: 0`.

### F) Mixed-instruction handoff validation (new)

Added:
1. Firmware: `integration/pcpi_demo/firmware/firmware_handoff.S`
2. Testbench: `integration/pcpi_demo/tb/tb_picorv32_pcpi_handoff.v`
3. Runner: `integration/pcpi_demo/scripts/run_pcpi_handoff.ps1`
4. Results note: `integration/pcpi_demo/HANDOFF_TEST_RESULTS.md`

What this validates:
1. CPU executes custom instruction #1.
2. CPU executes regular instructions (`lw`, `sw`, `addi`) in between custom ops.
3. CPU executes custom instruction #2.
4. PCPI handshake correctness for both custom ops (`wait -> ready/wr`).
5. Accelerator memory writeback count is correct for two matrix outputs.

Latest observed pass metrics from handoff run:
1. First result sentinel: `0x00000400`
2. Regular marker write: `0x0000047b`
3. Second result sentinel: `0xfffffc00`
4. `custom_issue_count=2`
5. `ready_count=2`
6. `wr_count=2`
7. `handshake_ok_count=2`
8. `c_store_count=32`

### G) Optional C firmware smoke path (new)

Added:
1. Shared C firmware source for smoke-C and cycle-compare: `integration/pcpi_demo/firmware/firmware_matmul_unified.c`
2. Firmware selector in smoke script: `integration/pcpi_demo/scripts/run_pcpi_demo.ps1 -FirmwareVariant <asm|c>`
3. Build selector in firmware makeflow: `integration/pcpi_demo/firmware/Makefile` now accepts `FIRMWARE_SRC=...` and `EXTRA_CFLAGS=...`

Notes:
1. Default remains assembly (`firmware.S`); existing path unchanged.
2. C variant uses explicit custom instruction macro with unchanged instruction encoding (`0x5420818b`) when built in accelerator mode.
3. Unified C source uses compile-time mode/address macros:
   - `MATMUL_MODE_ACCEL` / `MATMUL_MODE_SW`
   - `A_BASE_WORD_ADDR` / `B_BASE_WORD_ADDR` / `C_BASE_WORD_ADDR`
4. Arithmetic semantics remain RTL-exact Q5.10 wrap (no behavior change).

### H) CI-style local checker (new)

Added:
1. Script: `integration/pcpi_demo/scripts/run_pcpi_local_check.ps1`
2. Runs in order:
   - smoke-asm
   - smoke-c
   - regression-8case
   - handoff
3. Exits non-zero on first failure.

### I) Architecture-ready SoC contract draft (new)

Added:
1. `integration/pcpi_demo/SOC_MMIO_CONTRACT.md`
2. Defines invariants (instruction encoding + Q5.10 wrap semantics) and draft MMIO control register contract for future top-level integration.

### J) Cycle comparison flow (new)

Added:
1. Shared firmware source for accelerator and software cycle-compare runs: `integration/pcpi_demo/firmware/firmware_matmul_unified.c`
2. Software-only baseline testbench: `integration/pcpi_demo/tb/tb_picorv32_sw_matmul.v`
3. Software MUL-enabled baseline testbench: `integration/pcpi_demo/tb/tb_picorv32_sw_matmul_mul.v`
4. Unified comparison runner: `integration/pcpi_demo/scripts/run_cycle_compare.ps1`
5. Cycle marker in accelerator TB: `TB_CYCLES matmul_to_sentinel_cycles=...`

What it does:
1. Builds the same C source three times with different compile-time mode/address/ISA knobs.
2. Runs accelerator path, software no-MUL path (`rv32i`), and software MUL-enabled path (`rv32im`).
3. Extracts cycle counts from all logs.
4. Emits speedup summary markdown/json across all three baselines.

Latest observed run (2026-03-05):
1. Accelerator cycles: `673`
2. Software cycles (no-MUL): `26130`
3. Software cycles (MUL-enabled): `7975`
4. Speedup (`sw_no_mul / accelerator`): `38.8262x`
5. Speedup (`sw_mul / accelerator`): `11.8499x`
6. MUL benefit (`sw_no_mul / sw_mul`): `3.2765x`
7. Summary files:
   - `integration/pcpi_demo/results/pcpi_cycle_compare_summary.md`
   - `integration/pcpi_demo/results/pcpi_cycle_compare_summary.json`

### K) Professor-facing demo case flow (new)

Added:
1. Curated explainable demo cases: `integration/pcpi_demo/tests/professor_demo_cases.json`
2. Demo runner: `integration/pcpi_demo/scripts/run_pcpi_professor_demo.ps1`
3. Demo summary outputs:
   - `integration/pcpi_demo/results/pcpi_prof_demo_summary.md`
   - `integration/pcpi_demo/results/pcpi_prof_demo_summary.json`

Demo case set:
1. `demo_identity_passthrough`
2. `demo_negative_identity`
3. `demo_zero_matrix`
4. `demo_half_scale`
5. `demo_signed_passthrough`

### L) Cycle scaling estimator (normal core vs accelerator) (new)

Added:
1. Script: `integration/pcpi_demo/scripts/estimate_cycle_scaling.py`
2. Output: `integration/pcpi_demo/results/pcpi_cycle_scaling_estimate.json`
3. Supports:
   - ideal O(N^3) scaling comparison
   - overhead-aware scaling knobs for tiling/control/contention discussion

### M) Cleanup + robustness hardening (new)

Added/updated:
1. `.gitignore` now ignores generated cycle/prof-demo/custom-case outputs and `pynq_z2_custom_core/build/*.out`.
2. `integration/pcpi_demo/legacy/firmware/firmware_c.c` now preserves/restores ABI-critical registers around the fixed custom instruction encoding path.
3. `integration/pcpi_demo/firmware/Makefile` now includes `-msmall-data-limit=0`, configurable `ARCH`/`ABI`, and `EXTRA_CFLAGS` for mode/address macro wiring.
4. `integration/pcpi_demo/scripts/run_cycle_compare.ps1` and `integration/pcpi_demo/scripts/run_pcpi_professor_demo.ps1` now use a shared lock file (`integration/pcpi_demo/firmware/.firmware_flow.lock`) to serialize firmware-rewrite flows.
5. Added tracked consolidated evidence file: `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`.

### N) Isolated evaluator custom real-input flow (new)

Added:
1. Isolated custom case store: `integration/pcpi_demo/tests/custom_cases.json`
2. Real-to-Q5.10 converter: `integration/pcpi_demo/tests/real_to_q5_10_case.py`
3. Sample real input template: `integration/pcpi_demo/tests/sample_real_input.json`
4. Single-case runner for isolated custom file: `integration/pcpi_demo/scripts/run_pcpi_custom_case.ps1`

What it enables:
1. Accept mentor/evaluator real-valued matrices (`a_real`/`b_real` or `a_real_4x4`/`b_real_4x4`).
2. Convert using `round(real * 1024)` with strict signed16 range checking.
3. Optionally append timestamped or named generated case entries into isolated custom file.
4. Explicit cleanup mode to remove generated custom entries without touching baseline `tests/cases.json`.

Non-disturbance guarantee:
1. `run_pcpi_regression.ps1` still consumes only `integration/pcpi_demo/tests/cases.json`.
2. Cycle-compare and professor-demo flows are unchanged.

### O) Isolated custom 3-variant cycle compare flow (new)

Added:
1. Case header generator:
   - `integration/pcpi_demo/tests/gen_case_header.py`
2. Per-case 3-way compare runner:
   - `integration/pcpi_demo/scripts/run_pcpi_custom_cycle_compare.ps1`
3. Unified firmware custom-data include path:
   - `integration/pcpi_demo/firmware/firmware_matmul_unified.c` (`USE_EXTERNAL_CASE_DATA`)

What it enables:
1. Run the same selected custom case across accelerator, SW no-MUL, and SW MUL in one command.
2. Keep baseline `cases.json` untouched.
3. Generate per-case logs and cycle summary (`.md` + `.json`) under `results/custom_cases/`.

## Toolchain Status

### Windows native

- `riscv64-unknown-elf-gcc` not available natively in this machine environment.

### WSL fallback (validated)

- Installed and working in WSL:
  - `riscv64-unknown-elf-gcc`
  - `binutils-riscv64-unknown-elf`
  - `make`
- Firmware builds in WSL via:
  - `make clean all PYTHON=python3`

Regression script automatically uses:
1. native toolchain if available
2. otherwise WSL fallback
3. fails clearly if neither path is available

## Dependency Checklist (For New Collaborators)

Install these before running scripts:

1. `git`
2. `PowerShell`
3. `iverilog` + `vvp`
4. `python` (Python 3)
5. `gtkwave` (optional, for waveform viewing)

For firmware rebuild (regression + handoff):

Option A (native Windows):
1. `riscv64-unknown-elf-gcc`
2. `riscv64-unknown-elf-objcopy`
3. `make`

Option B (WSL Ubuntu fallback):
```bash
sudo apt-get update
sudo apt-get install -y gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf make python3
```

Quick verify:

```powershell
git --version
iverilog -V
vvp -V
python --version
wsl bash -lc "riscv64-unknown-elf-gcc --version | head -n 1"
```

## Commands That Should Work Now

From repo root (`TinyML-Accelerator`):

1. Smoke demo:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1
```

1b. Smoke demo (C firmware variant):
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_demo.ps1 -FirmwareVariant c
```

2. Full 8-case regression:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1
```

2b. One-command local checker:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_local_check.ps1
```

2c. Professor explainable demo run:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_professor_demo.ps1
```

2d. Cycle scaling estimator:
```powershell
python .\integration\pcpi_demo\scripts\estimate_cycle_scaling.py --sizes 4,8,16,32,64
```

2e. Convert evaluator real matrices to Q5.10 preview (isolated custom flow):
```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json
```

2f. Append custom case then run it (isolated file):
```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json --append-custom
.\integration\pcpi_demo\scripts\run_pcpi_custom_case.ps1 -CaseName <custom_case_name>
```

2g. Explicit cleanup of generated custom cases:
```powershell
python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --clear-generated
```

2h. Run one isolated custom case across all 3 variants:
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName <custom_case_name>
```

2i. Live evaluator one-command mode (edit one JSON, no arguments needed):
```powershell
.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1
```
Input file:
`integration/pcpi_demo/tests/live_real_input.json`

3. Generate one specific firmware case manually:
```powershell
python .\integration\pcpi_demo\tests\gen_case_firmware.py --cases .\integration\pcpi_demo\tests\cases.json --case identity_x_sequence --firmware-out .\integration\pcpi_demo\firmware\firmware.S --meta-out .\integration\pcpi_demo\results\cases\identity_x_sequence.expected.json
```

4. Rebuild firmware in WSL manually:
```powershell
$fwDirWin=(Resolve-Path .\integration\pcpi_demo\firmware).Path; $fwDirWsl="/mnt/$($fwDirWin.Substring(0,1).ToLower())$($fwDirWin.Substring(2).Replace('\','/'))"; wsl bash -lc "cd '$fwDirWsl' && make clean all PYTHON=python3"
```

5. Rebuild firmware in WSL with M extension enabled (for MUL baseline experiments):
```powershell
$fwDirWin=(Resolve-Path .\integration\pcpi_demo\firmware).Path; $fwDirWsl="/mnt/$($fwDirWin.Substring(0,1).ToLower())$($fwDirWin.Substring(2).Replace('\','/'))"; wsl bash -lc "cd '$fwDirWsl' && make clean all PYTHON=python3 FIRMWARE_SRC=firmware_matmul_unified.c ARCH=rv32im WORDS=1024 EXTRA_CFLAGS='-DMATMUL_MODE_ACCEL=0 -DMATMUL_MODE_SW=1 -DA_BASE_WORD_ADDR=0x800u -DB_BASE_WORD_ADDR=0x840u -DC_BASE_WORD_ADDR=0x900u'"
```

## Generated Evidence Files

1. `integration/pcpi_demo/results/cases/*.log`
2. `integration/pcpi_demo/results/pcpi_regression_summary.md`
3. `integration/pcpi_demo/results/pcpi_regression_summary.json`
4. `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md` (tracked consolidated table)
5. `integration/pcpi_demo/results/custom_cases/*.log`
6. `integration/pcpi_demo/results/custom_cases/*.expected.json`
7. `integration/pcpi_demo/results/custom_cases/*_cycle_compare_summary.md`
8. `integration/pcpi_demo/results/custom_cases/*_cycle_compare_summary.json`
9. `integration/pcpi_demo/results/custom_cases/*_outputs_real.json`

Note: summary and per-case expected JSON are currently ignored via `.gitignore`.

## Important Operational Notes

1. `run_pcpi_regression.ps1` rewrites `firmware/firmware.S` and `firmware/firmware.hex` for each case.
2. After regression, firmware ends on the last case unless explicitly reset.
3. In this workspace, firmware was reset to `identity_x_sequence` after regression for predictable smoke behavior.
4. TB now prints `TB_INFO case=...` using optional plusarg; functional behavior unchanged.
5. `run_cycle_compare.ps1` and `run_pcpi_professor_demo.ps1` both rewrite firmware inputs; they are now serialized via lock file to avoid races if launched concurrently.
6. Generated evidence artifacts should stay untracked; keep repository commits source-only unless intentionally archiving evidence.
7. Mandatory handoff discipline: after any code/script/RTL/testbench change, update both `README.md` and `integration/pcpi_demo/legacy/internal_handoff/project_handoff_context.md`.
8. For MUL-enabled software baseline, both core config and firmware ISA must align:
   - core: `ENABLE_MUL=1`
   - firmware compile arch: `rv32im`
9. Keep handoff docs synchronized after each meaningful update:
   - `README.md`
   - `integration/pcpi_demo/legacy/internal_handoff/project_handoff_context.md`
   - `mentor_progress_update.txt`
   - `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`
10. Full beginner-friendly operation guide:
    - `integration/pcpi_demo/docs/MIDSEM_COMPLETE_PROJECT_GUIDE.md`
11. Interactive visualizer is active and deployed:
    - source: `integration/pcpi_demo/visualizer/`
    - prod URL: `https://tinyml-pcpi-visualizer.vercel.app`
    - current UI includes:
      - per-panel `Run / Step Back / Step / Reset`
      - per-arrow `i` signal popups
      - CPU `i` modal for PicoRV32 stall/handoff explanation
      - `Architecture Info` modal for opcode / Q5.10 / files / signal groups
      - top-level `App Guide` modal
12. Saved GTKWave sessions for repeatable demos are stored at:
    - `integration/pcpi_demo/simulation/gtkwave/pcpi_demo_signals.gtkw`
    - `integration/pcpi_demo/simulation/gtkwave/pcpi_handoff_signals.gtkw`
13. Evaluator custom real-input flow is isolated:
    - baseline vectors: `integration/pcpi_demo/tests/cases.json`
    - custom generated vectors: `integration/pcpi_demo/tests/custom_cases.json`
    - cleanup command: `python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --clear-generated`
14. `run_pcpi_custom_case.ps1` and `run_pcpi_custom_cycle_compare.ps1` rewrite firmware inputs and use the shared firmware flow lock; do not run concurrent firmware-rewrite scripts without lock discipline.
15. `run_pcpi_custom_cycle_compare.ps1` supports live mode with no arguments:
    - reads `integration/pcpi_demo/tests/live_real_input.json`
    - auto-converts real to Q5.10
    - writes isolated generated case to `integration/pcpi_demo/tests/live_eval_cases.json`
    - runs accel + sw-no-mul + sw-mul
    - writes per-case real-format output JSON (`*_outputs_real.json`)
16. Smoke-C and cycle-compare are unified at source level using:
    - `integration/pcpi_demo/firmware/firmware_matmul_unified.c`
    Legacy files remain for fallback/reference:
    - `integration/pcpi_demo/legacy/firmware/firmware_c.c`
    - `integration/pcpi_demo/legacy/firmware/firmware_sw_matmul.c`
17. Custom accelerator instruction remains explicit and fixed in firmware (`0x5420818b`);
    compiler does not auto-convert generic nested matmul loops into this custom opcode.
18. Repository organization update:
    - primary standalone accelerator folder: `accel_standalone/`
    - legacy compatibility shim: `midsem_sim/`
    - fallback firmware references moved to: `integration/pcpi_demo/legacy/firmware/`
19. Design-space and deployment tradeoff note:
    - `integration/pcpi_demo/docs/DESIGN_TRADEOFFS_AND_USE_CASES.md`

## Immediate Next Work (Do In Order)

1. Stabilize commit boundaries:
   - Separate commits for:
     - cycle comparison + demo scripts
     - documentation updates
     - any unrelated existing changes
2. Professor demo readiness:
   - keep `run_pcpi_professor_demo.ps1` green
   - keep `run_cycle_compare.ps1` green
   - prepare 1-page architecture slide using the module/wiring explanation prompt
3. Hardware progression:
   - map current PCPI + memory contract to FPGA top-level integration checklist
   - preserve arithmetic and instruction encoding invariants

## Latest Execution Status (This Session)

Validated on 2026-03-05:

1. Regression:
   - command: `.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1`
   - result: PASS (`8/8`)
2. Handoff:
   - command: `.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1`
   - result: PASS
   - key metrics: `custom_issue_count=2`, `ready_count=2`, `wr_count=2`, `handshake_ok_count=2`, `c_store_count=32`
3. Cycle comparison:
   - command: `.\integration\pcpi_demo\scripts\run_cycle_compare.ps1`
   - result: PASS
   - measured: `accel_cycles=673`, `sw_nomul_cycles=26130`, `sw_mul_cycles=7975`
   - ratios: `sw_nomul/accel=38.8262x`, `sw_mul/accel=11.8499x`, `sw_nomul/sw_mul=3.2765x`
4. Cycle scaling estimator:
   - command: `python .\integration\pcpi_demo\scripts\estimate_cycle_scaling.py --sizes 4,8,16,32,64`
   - output generated: `integration/pcpi_demo/results/pcpi_cycle_scaling_estimate.json`
5. Professor demo curated cases:
   - command: `.\integration\pcpi_demo\scripts\run_pcpi_professor_demo.ps1`
   - result: PASS (`5/5`)
   - summary files:
     - `integration/pcpi_demo/results/pcpi_prof_demo_summary.md`
     - `integration/pcpi_demo/results/pcpi_prof_demo_summary.json`
6. One-command local check:
   - command: `.\integration\pcpi_demo\scripts\run_pcpi_local_check.ps1`
   - result: PASS (`smoke-asm`, `smoke-c`, `regression-8case`, `handoff`)
7. Isolated evaluator custom flow:
   - command:
     - `python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --input-json .\integration\pcpi_demo\tests\sample_real_input.json --append-custom --name custom_demo_identity`
     - `.\integration\pcpi_demo\scripts\run_pcpi_custom_case.ps1 -CaseName custom_demo_identity`
     - `python .\integration\pcpi_demo\tests\real_to_q5_10_case.py --clear-generated`
   - result: PASS (conversion + custom case run + explicit cleanup)
8. Isolated custom 3-way compare on random cases:
   - command:
     - `.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName custom_rand_case1`
     - `.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1 -CaseName custom_rand_case2`
   - result: PASS
   - measured:
     - `custom_rand_case1`: accel `673`, sw_nomul `36246`, sw_mul `7975`
     - `custom_rand_case2`: accel `673`, sw_nomul `36034`, sw_mul `7975`
9. Live one-command evaluator mode:
   - command:
     - `.\integration\pcpi_demo\scripts\run_pcpi_custom_cycle_compare.ps1`
   - input:
     - `integration/pcpi_demo/tests/live_real_input.json`
   - result: PASS
   - measured:
     - `live_eval_active`: accel `673`, sw_nomul `36246`, sw_mul `7975`
     - `sw_nomul/accel=53.8574x`, `sw_mul/accel=11.8499x`
     - current `live_real_input.json` is pre-seeded for near-50x no-MUL live evaluation demo

## Not In Scope Yet

1. Full board deployment on Pynq-Z2
2. ARM vs accelerator measured board timings
3. Replacing arithmetic behavior with saturation

## Definition Of Done For Next Milestone

1. Regression flow remains green (`8/8 pass`) after any new changes.
2. C firmware variant added and runnable (without breaking assembly flow).
3. One-command verification script added and documented.
4. `README.md` and this file updated with exact commands and observed outputs.
