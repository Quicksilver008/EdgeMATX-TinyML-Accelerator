# Pipeline Top — Assembled RV32I + PCPI System

This directory contains the assembled top-level RTL, testbenches, firmware, and scripts for the full RV32I pipeline with PCPI matrix accelerator integration.

## Directory Layout

```
pipeline_top/
├── src/
│   ├── rv32_pipeline_top.v          ← 5-stage Harvard RV32I CPU (PCPI ports exposed)
│   ├── rv32_pipeline_pcpi_system.v  ← CPU + pcpi_tinyml_accel + shared memory
│   └── rv32_pipeline_matmul_system.v← CPU + descriptor-based matmul system (legacy v1)
├── tb/
│   ├── tb_rv32_pipeline_top_smoke.v ← Basic smoke test
│   ├── tb_rv32_pipeline_pcpi_system.v← PCPI system integration test
│   ├── tb_rv32_pipeline_matmul_system.v ← Descriptor contract regression (8 cases)
│   ├── tb_pipeline_forwarding_hazards.v ← Forwarding/hazard unit tests (4 checks)
│   ├── tb_pipeline_back_to_back_pcpi.v  ← Back-to-back CUSTOM_MATMUL test
│   ├── tb_pipeline_pcpi_regression.v    ← 4-case PCPI regression suite
│   └── tb_cycle_benchmark.v         ← ACCEL vs SW cycle count benchmark
├── firmware/
│   ├── firmware_sw_bench.c          ← RV32I software matrix multiply (packed Q5.10)
│   ├── firmware_sw_bench.hex        ← Pre-built hex (loaded by benchmark TB)
│   └── Makefile                     ← Build with riscv32 toolchain under WSL
├── scripts/
│   ├── run_pipeline_tests.ps1       ← Gate check: runs all 4 pipeline TBs
│   └── run_benchmark.ps1            ← Builds firmware + runs cycle benchmark
├── simulation/
│   ├── tb_pipeline_forwarding_hazards.vcd  ← Generated on test run
│   ├── tb_pipeline_back_to_back_pcpi.vcd
│   ├── tb_pipeline_pcpi_regression.vcd
│   ├── tb_cycle_benchmark.vcd
│   └── gtkwave/
│       ├── forwarding_hazards.gtkw  ← Pre-configured signal layouts
│       ├── back_to_back_pcpi.gtkw
│       ├── pcpi_regression.gtkw
│       └── cycle_benchmark.gtkw
└── diagrams/
    └── rv32_pipeline_matmul_architecture.drawio.xml
```

## Running Tests

All commands from the **workspace root** (`EdgeMATX-TinyML-Accelerator/`).

### All pipeline gate tests (recommended)
```powershell
.\RISC-V\pipeline_top\scripts\run_pipeline_tests.ps1
```
Runs in order: `forwarding_hazards` → `back_to_back_pcpi` → `pcpi_regression` → `cycle_benchmark`. Fails fast on first error.

Expected final line: `ALL PIPELINE TESTS PASSED`

Each testbench dumps a VCD to `simulation/` automatically.

### Cycle benchmark only
```powershell
.\RISC-V\pipeline_top\scripts\run_benchmark.ps1
```
Requires WSL with `riscv32-unknown-elf-gcc` to rebuild firmware. Pre-built hex included.

Expected: `Speedup (SW/ACCEL) : 179.8x`

## Waveform Inspection (GTKWave)

All four testbenches emit VCD files into `simulation/`. Pre-configured signal layouts are in `simulation/gtkwave/`.

```powershell
# Open with pre-loaded signals (from workspace root)
gtkwave RISC-V/pipeline_top/simulation/tb_pipeline_forwarding_hazards.vcd RISC-V/pipeline_top/simulation/gtkwave/forwarding_hazards.gtkw
gtkwave RISC-V/pipeline_top/simulation/tb_pipeline_back_to_back_pcpi.vcd  RISC-V/pipeline_top/simulation/gtkwave/back_to_back_pcpi.gtkw
gtkwave RISC-V/pipeline_top/simulation/tb_pipeline_pcpi_regression.vcd    RISC-V/pipeline_top/simulation/gtkwave/pcpi_regression.gtkw
gtkwave RISC-V/pipeline_top/simulation/tb_cycle_benchmark.vcd             RISC-V/pipeline_top/simulation/gtkwave/cycle_benchmark.gtkw
```

| Save file | Pre-loaded signals |
|-----------|-------------------|
| `forwarding_hazards.gtkw` | clk, rst, PC, IF/ID instructions, stall, WB (rd/data), rf[2,4,7,9] |
| `back_to_back_pcpi.gtkw` | clk, rst, PC, IF/ID, stall, custom_inflight, accel_done, WB, mat_c_flat |
| `pcpi_regression.gtkw` | same as above — step through all 4 matrix cases |
| `cycle_benchmark.gtkw` | ACCEL path (`_a`) and SW path (`_sw`) side-by-side |

## Memory Layout (PCPI System)

Shared 256-word (1 KB) data memory, byte-addressed:

| Region | Base address | Size | Contents |
|--------|-------------|------|----------|
| A matrix | `0x100` | 8 words | 4×4 Q5.10, packed 2 per word |
| B matrix | `0x140` | 8 words | 4×4 Q5.10, packed 2 per word |
| C matrix | `0x200` | 8 words | 4×4 Q5.10, packed 2 per word |

Packed word format: `{C[r][c+1][15:0], C[r][c][15:0]}` (even column in lower half).

## Custom Instruction Encoding (CUSTOM_MATMUL)

| Field | Value |
|-------|-------|
| `opcode` | `0001011` (custom-0) |
| `funct3` | `000` |
| `funct7` | `0101010` |
| `rs1` | A base pointer (byte addr) |
| `rs2` | B base pointer (byte addr) |
| `rd` | ignored (result in C memory) |

## Latest Test Results (2026-04-04)

### Full Test Suite

| Test Suite | Cases | Result |
|---|---:|---|
| forwarding_hazards | 4/4 | **PASS** |
| back_to_back_pcpi | 2/2 | **PASS** |
| pcpi_regression | 4/4 | **PASS** |
| cycle_benchmark | 1/1 | **PASS** |
| **Total** | **11/11** | **100% PASS** |

Test coverage includes:
- **Pipeline hazards**: EX/MEM forwarding, MEM/WB forwarding, load-use stalls, WB bypass
- **PCPI handshaking**: Back-to-back custom instructions without corruption
- **Matrix correctness**: Identity, ones, mixed-sign, zero matrices
- **Performance**: Cycle-accurate accelerator vs software comparison

### 4x4 Cycle Benchmark

| Metric | Value |
|---|---:|
| ACCEL cycles (pcpi_valid → pcpi_ready) | 37 |
| SW cycles (reset → sentinel) | 2,580 |
| **Speedup (SW/ACCEL)** | **69.7x** |

Accelerator breakdown:
- 8 memory reads (A matrix, 2 elements/word)
- 8 memory reads (B matrix, 2 elements/word)
- ~12 systolic compute cycles
- 8 memory writes (C matrix, 2 elements/word)

SW firmware uses packed 2-elem/word row-outer loop: 8 LW A + 32 LW B + 8 SW C = 48 memory ops.

### MLPerf Tiny Anomaly Detection Proxy Benchmark

Run MLCommons Tiny Anomaly Detection proxy benchmark:

```powershell
.\RISC-V\pipeline_top\scripts\run_mlperf_proxy.ps1
```

Latest results (2026-04-04):

| Metric | HW Accelerator | SW (RV32I) |
|---|---:|---:|
| Cycles per 4x4 tile | 50.4 | 2,579.0 |
| Proxy cycles (32 tiles) | 1,612 | 82,528 |
| AD inference cycles (5120 tiles) | 257,920 | 13,204,480 |
| **AD inference @ 100 MHz** | **2.58 ms** | 132.04 ms |
| **MLPerf Tiny target (<10ms)** | **MEETS ✓** | EXCEEDS ✗ |
| **Speedup vs HW** | 1.0x | 51.2x slower |

The hardware accelerator achieves **2.58 ms** for a full Anomaly Detection inference, well below the 10ms MLPerf Tiny target. Software implementation takes **132.04 ms**, exceeding the target by 13x.

## PCPI Interface Ports (rv32_pipeline_top.v)

```verilog
output reg        pcpi_valid,
output reg [31:0] pcpi_insn,
output reg [31:0] pcpi_rs1,
output reg [31:0] pcpi_rs2,
input             pcpi_wr,
input      [31:0] pcpi_rd,
input             pcpi_wait,
input             pcpi_ready
```


- IF: internal PC + instruction fetch
- ID: instruction decode + control + register read
- EX: ALU control + forwarding + ALU
- MEM: data memory access
- WB: register write-back

File:

- `src/rv32_pipeline_top.v`

## Included Integration Hooks

The top includes custom-instruction hook ports intended for accelerator integration:

- `accel_start`, `accel_src0`, `accel_src1`, `accel_rd`
- `accel_busy`, `accel_done`, `accel_result`

Current custom decode pattern is:

- `opcode=0001011`
- `funct3=000`
- `funct7=0101010`

## Smoke Testbench

Testbench:

- `tb/tb_rv32_pipeline_top_smoke.v`

Icarus compile/run:

```powershell
iverilog -g2012 -o .\RISC-V\pipeline_top\smoke.vvp `
  .\RISC-V\pipeline_top\src\rv32_pipeline_top.v `
  .\RISC-V\pipeline_top\tb\tb_rv32_pipeline_top_smoke.v `
  .\RISC-V\instruction_decoder\src\instruction_decoder.v `
  .\RISC-V\Control_Unit\src\Control_Unit.v `
  .\RISC-V\alu_control\src\alu_control.v `
  .\RISC-V\alu\src\alu.v `
  .\RISC-V\register_bank\src\register_bank.v `
  .\RISC-V\data_memory\src\data_memory.v `
  .\RISC-V\hazard_detection_unit\src\hazard_detection_unit.v `
  .\RISC-V\forwarding_unit\src\forwarding_unit.v

vvp .\RISC-V\pipeline_top\smoke.vvp
```

Expected terminal line:

- `TB_PASS smoke test completed.`

## Note

This is an assembled, integration-ready top for iterative development, not yet a fully verified production core. It is intended to make end-to-end edits and accelerator hookup practical.

## Pipeline + Matrix Accelerator System Test (Descriptor Contract v1)

System wrapper:

- `src/rv32_pipeline_matmul_system.v`

Testbench:

- `tb/tb_rv32_pipeline_matmul_system.v`

Contract used by custom instruction:

- `rs1` = descriptor base pointer (byte address)
- `rs2` = reserved (must be zero in v1)
- `rd` = status code written on completion

Descriptor layout at `rs1`:

- `+0x00`: `A_base`
- `+0x04`: `B_base`
- `+0x08`: `C_base`
- `+0x0C`: `{N[31:16], M[15:0]}` (must be 4,4 in v1)
- `+0x10`: `{flags[31:16], K[15:0]}` (K must be 4 in v1)
- `+0x14`: `strideA` (bytes)
- `+0x18`: `strideB` (bytes)
- `+0x1C`: `strideC` (bytes)

Status values returned in `rd`:

- `0`: success
- `1`: bad dimensions
- `2`: bad alignment
- `3`: invalid reserved `rs2` usage

Compile/run:

```powershell
iverilog -g2012 -o .\RISC-V\pipeline_top\matmul_system_tb.vvp `
  .\RISC-V\pipeline_top\src\rv32_pipeline_top.v `
  .\RISC-V\pipeline_top\src\rv32_pipeline_matmul_system.v `
  .\RISC-V\pipeline_top\tb\tb_rv32_pipeline_matmul_system.v `
  .\RISC-V\instruction_decoder\src\instruction_decoder.v `
  .\RISC-V\Control_Unit\src\Control_Unit.v `
  .\RISC-V\alu_control\src\alu_control.v `
  .\RISC-V\alu\src\alu.v `
  .\RISC-V\register_bank\src\register_bank.v `
  .\RISC-V\data_memory\src\data_memory.v `
  .\RISC-V\hazard_detection_unit\src\hazard_detection_unit.v `
  .\RISC-V\forwarding_unit\src\forwarding_unit.v `
  .\midsem_sim\rtl\pe_cell_q5_10.v `
  .\midsem_sim\rtl\issue_logic_4x4_q5_10.v `
  .\midsem_sim\rtl\systolic_array_4x4_q5_10.v `
  .\midsem_sim\rtl\matrix_accel_4x4_q5_10.v

vvp .\RISC-V\pipeline_top\matmul_system_tb.vvp
```

Expected key lines:

- For each case: pass checks for `wb_pre`, `dbg_stall`, `wb_during`, `wb_status`, `wb_post`, `C_mem`, `matmul_cycle_count`
- Final summary: `TB_PASS summary pass=8 total=8`

Current regression covers 8 matrix combinations:

- `identity`
- `ones_x_ones`
- `signed_mixed`
- `zero_x_rand`
- `rand_x_zero`
- `diag_x_identity`
- `upper_x_lower`
- `checker_signed`
