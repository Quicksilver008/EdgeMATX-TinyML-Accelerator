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

Regression (8-case suite):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_regression.ps1
```

Handoff/handshake validation (mixed regular + custom instructions):

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1
```

Cycle comparison (software baseline vs accelerator custom instruction):

```powershell
.\integration\pcpi_demo\scripts\run_cycle_compare.ps1
```

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

Firmware flow notes:

- If `riscv64-unknown-elf-gcc` is available, the script rebuilds firmware from:
  - `integration/pcpi_demo/firmware/firmware.S` (default)
  - `integration/pcpi_demo/firmware/firmware_c.c` (when `-FirmwareVariant c`)
  - `integration/pcpi_demo/firmware/sections.lds`
  - `integration/pcpi_demo/firmware/Makefile`
- If native toolchain is missing, scripts try WSL toolchain fallback.
- If toolchain is missing, asm smoke can use checked-in fallback:
  - `integration/pcpi_demo/firmware/firmware.hex`
- C smoke variant requires a toolchain rebuild (no stale-hex fallback).

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
- `integration/pcpi_demo/results/pcpi_cycle_sw.log`
- `integration/pcpi_demo/results/pcpi_cycle_compare_summary.md`
- `integration/pcpi_demo/results/pcpi_cycle_compare_summary.json`
- `integration/pcpi_demo/results/pcpi_prof_demo_summary.md`
- `integration/pcpi_demo/results/pcpi_prof_demo_summary.json`
- `integration/pcpi_demo/results/pcpi_cycle_scaling_estimate.json`

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

All regression checks use RTL-exact arithmetic:

- signed16 multiply
- arithmetic shift-right by 10
- signed32 accumulation
- final compare on low 16 bits (wrap), sign-extended to 32-bit memory word
