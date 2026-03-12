# RISC-V Pipeline Core

A five-stage Harvard RV32I pipeline implemented in Verilog HDL, extended with a PCPI coprocessor interface for a 4×4 systolic matrix accelerator (Q5.10 fixed-point).

## Directory Structure

```
RISC-V/
├── core/
│   ├── rtl/        ← 11 pipeline sub-module RTL files
│   └── tb/         ← 10 unit testbenches (one per sub-module)
├── accelerator/
│   ├── rtl/        ← Systolic array accelerator RTL (standalone)
│   ├── tb/         ← Accelerator-only testbenches
│   ├── scripts/    ← run_midsem_sim.ps1, run_riscv_integration_sim.ps1
│   └── results/    ← Simulation logs and markdown summaries
├── pipeline_top/
│   ├── src/        ← Assembled top-level system RTL
│   ├── tb/         ← Integration and benchmark testbenches
│   ├── firmware/   ← Compiled SW benchmark firmware
│   ├── scripts/    ← run_benchmark.ps1, run_pipeline_tests.ps1
│   └── diagrams/   ← Architecture diagrams
├── docs/
│   ├── assets/     ← Architecture diagrams/images
│   ├── references/ ← RISC-V spec PDFs, reference cards
│   └── verification/ ← Instruction verification guides
├── legacy/         ← Old standalone test files (not under active development)
└── README.md       ← This file
```

## Sub-system READMEs

| Directory | Description |
|-----------|-------------|
| [core/](core/README.md) | Pipeline sub-modules and unit testbenches |
| [accelerator/](accelerator/README.md) | Standalone systolic array accelerator |
| [pipeline_top/](pipeline_top/README.md) | Assembled CPU + PCPI system, benchmarks |

## Quick Start

All commands run from the **workspace root** (`EdgeMATX-TinyML-Accelerator/`).

### Run all pipeline integration tests
```powershell
.\RISC-V\pipeline_top\scripts\run_pipeline_tests.ps1
```
Expected: `ALL PIPELINE TESTS PASSED`

### Run accelerator standalone regression
```powershell
powershell -ExecutionPolicy Bypass -File "RISC-V\accelerator\scripts\run_midsem_sim.ps1"
```
Expected: `SUMMARY pass=19 total=19`

### Run cycle benchmark (requires WSL + riscv32 toolchain)
```powershell
.\RISC-V\pipeline_top\scripts\run_benchmark.ps1
```
Expected: `Speedup (SW/ACCEL) : 179.8x`

### View waveforms
VCDs are written to `pipeline_top/simulation/` each time the pipeline tests run. Open with pre-configured layouts:
```powershell
gtkwave RISC-V/pipeline_top/simulation/tb_pipeline_forwarding_hazards.vcd RISC-V/pipeline_top/simulation/gtkwave/forwarding_hazards.gtkw
gtkwave RISC-V/pipeline_top/simulation/tb_cycle_benchmark.vcd             RISC-V/pipeline_top/simulation/gtkwave/cycle_benchmark.gtkw
```

## Pipeline Stages

| Stage | Key Modules |
|-------|-------------|
| IF | `rv32_pipeline_top.v` (internal PC + imem) |
| ID | `instruction_decoder.v`, `Control_Unit.v`, `register_bank.v` |
| EX | `alu_control.v`, `alu.v`, `forwarding_unit.v` |
| MEM | `data_memory.v` |
| WB | `hazard_detection_unit.v`, register writeback + PCPI result mux |

Hazard handling: full data forwarding (EX/MEM, MEM/WB), load-use stall (1 cycle), N+3 write-through bypass.
