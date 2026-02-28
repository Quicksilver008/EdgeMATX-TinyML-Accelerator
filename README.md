# TinyML-Accelerator

TinyML-Accelerator is a major project focused on building a TinyML accelerator on top of a RISC-V based hardware platform.

## Current Repository Layout

- `RISC-V/`: Vendored Verilog implementation of a 5-stage pipelined RV32I core and related modules.
- `midsem_sim/`: Self-contained systolic-array simulation flow for mid-sem evaluation.
- `README.md`: Top-level project documentation.

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
- CPU-core integration is **not implemented yet**.
- No assembly or machine-code-driven custom instruction path has been tested yet.
- No replacement core (for example PicoRV32) has been added yet.

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
