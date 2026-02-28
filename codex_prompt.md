# Codex Handoff Prompt (Resume File)

Last updated: 2026-02-28

Use this file to resume work with Codex without losing context.

## Copy-Paste Prompt For Next Collaborator

```text
Read codex_prompt.md and continue the TinyML-Accelerator project from the latest state.
Do not restart from scratch.
First confirm current repo status, then continue from the "Immediate Next Tasks" section.
Prioritize simulation credibility and architecture-readiness for later hardware deployment.
Keep all work reproducible with scripts and update codex_prompt.md at the end with what you changed.
```

## Project Goal (Short)

Build a TinyML-oriented matrix multiplication accelerator flow on RISC-V, with final target platform Pynq-Z2.  
Current priority is mid-sem simulation evidence; full hardware integration comes after.

## What Has Been Done So Far

### 1. Repository setup and vendoring

- Created/used repo root: `TinyML-Accelerator`.
- Vendored upstream RISC-V code into `RISC-V/` from:
  - `https://github.com/srpoyrek/RISC-V`
  - imported commit: `9881b5c687e7b3c8c7b04dddb4c07abf3b07ed81`
- Removed nested git metadata (`RISC-V/.git`) so it is a vendor copy, not submodule.
- Added provenance file:
  - `RISC-V/VENDORING.md`

### 2. Top-level documentation update

- Updated `README.md` with:
  - project overview
  - repo structure
  - vendored-core details
  - midsem simulation quick-start

### 3. Mid-sem simulation pack (new)

Added a self-contained simulation flow under `midsem_sim/`:

- RTL:
  - `midsem_sim/rtl/pe_cell_q5_10.v`
  - `midsem_sim/rtl/issue_logic_4x4_q5_10.v`
  - `midsem_sim/rtl/systolic_array_4x4_q5_10.v`
  - `midsem_sim/rtl/matrix_accel_4x4_q5_10.v`
- Testbench:
  - `midsem_sim/tb/tb_matrix_accel_4x4.v`
- Scripts:
  - `midsem_sim/scripts/run_midsem_sim.ps1`
  - `midsem_sim/scripts/summarize_midsem_results.py`
- Docs:
  - `midsem_sim/README.md`
- Generated results:
  - `midsem_sim/results/sim_output.log`
  - `midsem_sim/results/MIDSEM_RESULTS.md`

### 4. Simulation verification status

The scripted run currently passes:

- Test `identity`: pass=1, accel_cycles=10
- Test `ones`: pass=1, accel_cycles=10
- Summary: 2/2 pass

Reported in:
- `midsem_sim/results/MIDSEM_RESULTS.md`

### 5. Repo hygiene additions

- Added `.gitignore` entries for simulation build artifacts:
  - `midsem_sim/results/*.out`
  - `midsem_sim/results/*.vcd`

## Important Clarification

- A **new replacement RISC-V core has NOT been cloned yet**.
- Only the `srpoyrek/RISC-V` repo was vendored.
- Current accelerator simulation is standalone and not yet integrated with a full CPU system.

## Core Integration Status (Explicit)

- Standalone accelerator simulation: done and passing.
- Custom instruction path from CPU: not done.
- Assembly/machine-code driven integration test: not done.
- Hardware deployment on Pynq-Z2: not started.

## Why This Path Was Chosen

Mid-sem needed demonstrable output quickly.  
A clean simulation-first deliverable was built first, then hardware integration can follow with lower risk.

## How To Reproduce Current Results

From repo root (PowerShell):

```powershell
.\midsem_sim\scripts\run_midsem_sim.ps1
```

Expected key console lines:

- `RESULT test=identity pass=1 accel_cycles=10`
- `RESULT test=ones pass=1 accel_cycles=10`
- `SUMMARY pass=2 total=2`

Output artifacts:

- `midsem_sim/results/sim_output.log`
- `midsem_sim/results/MIDSEM_RESULTS.md`

## Known Limitations / Gaps

1. Speedup values in `MIDSEM_RESULTS.md` are analytic model estimates, not hardware-measured.
2. No ARM vs RISC-V board-level timing has been measured yet.
3. No CPU custom-opcode integration yet.
4. Vendored `RISC-V/` includes many simulator-generated files (`.wlf`, `.qdb`, `.mpf`, `work/`) and is not yet cleaned.
5. Existing vendored RISC-V module set appears incomplete for direct full-core integration.

## Immediate Next Tasks (Priority Order)

1. Core strategy decision
- Prefer a proven integration-ready core (recommended: PicoRV32) for custom instruction/coproc handshake.
- Keep current vendored `RISC-V/` as reference only unless needed.

2. Integration simulation (before FPGA)
- Wrap accelerator with clean `start/busy/done` interface.
- Connect to chosen core via custom instruction path in simulation.
- Add integration testbench to validate instruction trigger and stall behavior.

3. Benchmark methodology hardening
- Define fixed matrix sizes and trial counts.
- Separate compute-only vs end-to-end (data movement included).
- Keep cycle metrics comparable across ARM baseline and accelerator path.

4. Repo cleanup
- Add additional ignore rules for transient files from vendored RISC-V sims.
- Optionally remove non-source simulator artifacts from tracked content in a dedicated cleanup commit (coordinate with team first).

## Suggested Technical Direction (Recommended)

- Use PicoRV32 + PCPI-like coprocessor interface for clean custom op integration.
- Reuse existing `midsem_sim` accelerator modules as the base engine.
- Maintain this staged flow:
  1. standalone accelerator simulation (done)
  2. CPU+accelerator simulation
  3. Vivado integration on Pynq-Z2
  4. on-board timing collection

## Integration Checklist (Next Engineer)

1. Clone or vendor PicoRV32 in a dedicated directory (`core/picorv32` or similar).
2. Define one custom matmul instruction contract (opcode/funct fields and semantics).
3. Implement coprocessor wrapper between core and `midsem_sim` accelerator (`start/busy/done`).
4. Add a simulation program/testbench that issues the custom instruction and validates output matrix.
5. Record instruction-triggered cycle counts in a markdown artifact similar to `MIDSEM_RESULTS.md`.
6. Update `README.md` and this file with exact run commands and expected output lines.

## Operational Notes For Next Codex Session

- Start by running:
  - `git status --short`
  - `.\midsem_sim\scripts\run_midsem_sim.ps1`
- Do not delete or overwrite existing staged work unless explicitly requested.
- Keep updates in this `codex_prompt.md` after each significant milestone so future sessions remain continuous.

## Definition Of Done For Next Milestone

1. Chosen replacement core added (or decision documented with rationale).
2. CPU+accelerator simulation testbench passing with at least one custom-op invocation.
3. Results artifact generated similarly to current `MIDSEM_RESULTS.md`.
4. `README.md` and this `codex_prompt.md` updated with new commands and outputs.
