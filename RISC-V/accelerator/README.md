# Accelerator — 4×4 Systolic Array (Q5.10)

Standalone RTL for the `matrix_accel_4x4_q5_10` systolic array accelerator, its testbenches, simulation scripts, and results.

## Directory Layout

```
accelerator/
├── rtl/
│   ├── pe_cell_q5_10.v              ← Processing element: MAC with Q5.10 fixed-point multiply
│   ├── issue_logic_4x4_q5_10.v      ← Skew/feed logic that feeds A rows and B columns
│   ├── systolic_array_4x4_q5_10.v   ← 4×4 grid of pe_cell instances
│   ├── matrix_accel_4x4_q5_10.v     ← Top-level controller + memory interface
│   ├── riscv_matmul_bridge.v         ← Custom-instruction decode bridge (PCPI → accel)
│   └── riscv_accel_integration_stub.v← Lightweight integration stub for standalone test
├── tb/
│   ├── tb_matrix_accel_4x4.v         ← 19-case hardening regression (midsem suite)
│   └── tb_riscv_accel_integration.v  ← RISC-V instruction-level integration test
├── scripts/
│   ├── run_midsem_sim.ps1            ← Compiles + runs tb_matrix_accel_4x4, generates summary
│   ├── run_riscv_integration_sim.ps1 ← Compiles + runs tb_riscv_accel_integration
│   ├── summarize_midsem_results.py   ← Parses sim log → MIDSEM_RESULTS.md
│   └── summarize_riscv_integration_results.py
└── results/                          ← Generated: logs, .out binaries, markdown summaries
```

## Running Simulations

All commands from the **workspace root** (`EdgeMATX-TinyML-Accelerator/`).

### Midsem hardening regression (19 test cases)
```powershell
powershell -ExecutionPolicy Bypass -File "RISC-V\accelerator\scripts\run_midsem_sim.ps1"
```
Expected: `SUMMARY pass=19 total=19`  
Output log: `accelerator/results/sim_output.log`  
Markdown summary: `accelerator/results/MIDSEM_RESULTS.md`

### RISC-V instruction integration test
```powershell
powershell -ExecutionPolicy Bypass -File "RISC-V\accelerator\scripts\run_riscv_integration_sim.ps1"
```
Output: `accelerator/results/RISCV_INTEGRATION_RESULTS.md`

## Q5.10 Fixed-Point Format

| Field | Bits |
|-------|------|
| Sign | [15] |
| Integer | [14:10] (5 bits, range −16 … +15) |
| Fraction | [9:0] (1/1024 resolution) |

`1.0` = `0x0400`.  Multiply: `(a * b) >> 10` (shift-and-add, no hardware multiplier needed).

## Hardening Test Cases (tb_matrix_accel_4x4)

| Case | Description |
|------|-------------|
| `identity` | I × A = A |
| `ones` | All-ones matrix |
| `signed_mixed` | Positive and negative Q5.10 values |
| `overflow_wrap` | Saturating/wrapping boundary values |
| `start_while_busy` | Extra start pulse during active computation |
| `reset_abort` | Mid-run async reset, verify clean recovery |
| `post_reset_recovery` | Full computation after reset |
| `random_0` … `random_11` | 12 pseudo-random input pairs |

## Full PCPI Integration

For end-to-end testing with the RV32I pipeline, see [`../pipeline_top/`](../pipeline_top/README.md). The PCPI wrapper (`pcpi_tinyml_accel.v`) lives in `integration/pcpi_demo/rtl/`.
