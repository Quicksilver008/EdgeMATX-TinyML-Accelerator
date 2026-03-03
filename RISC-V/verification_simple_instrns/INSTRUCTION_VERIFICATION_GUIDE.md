# RISC-V Simple Instruction Verification Guide

## Overview
This guide verifies basic instruction behavior using:

- `RISC-V/simple_instruction_test.v`
- `RISC-V/register_bank/src/register_bank.v`
- `RISC-V/alu/src/alu.v`
- `RISC-V/data_memory/src/data_memory.v`

The testbench covers 7 operations:

1. `ADDI x1, x0, 10`
2. `ADDI x2, x0, 20`
3. `ADD x3, x1, x2`
4. `SW x3, 0(x0)`
5. `LW x4, 0(x0)`
6. `ADDI x5, x1, 15`
7. `SUB x6, x3, x1`

## Run With Icarus Verilog

From `RISC-V`:

```powershell
iverilog -o test_program.vvp `
  .\register_bank\src\register_bank.v `
  .\alu\src\alu.v `
  .\data_memory\src\data_memory.v `
  .\simple_instruction_test.v

vvp .\test_program.vvp
```

Important: if your shell is already inside `RISC-V`, use `.\...` paths, not `..\...`.

## Expected Result

You should see `PASS` for all 7 tests and:

```text
====== Test Summary ======
Total Tests: 7
Passed Tests: 7
ALL TESTS PASSED!
==========================
```

## Vivado Simulation Setup

1. Create/open a project in Vivado.
2. Add RTL sources:
   - `RISC-V/register_bank/src/register_bank.v`
   - `RISC-V/alu/src/alu.v`
   - `RISC-V/data_memory/src/data_memory.v`
3. Add simulation source:
   - `RISC-V/simple_instruction_test.v`
4. Set `simple_instruction_test` as simulation top.
5. Run Behavioral Simulation.
6. Check console output for 7 passes.

## Instruction Format Reminder

- I-type (`ADDI`, `LW`): `imm[11:0] rs1 funct3 rd opcode`
- R-type (`ADD`, `SUB`): `funct7 rs2 rs1 funct3 rd opcode`
- S-type (`SW`): `imm[11:5] rs2 rs1 funct3 imm[4:0] opcode`

## Quick Debug Checklist

If any test fails:

1. Confirm `simple_instruction_test.v` is not empty and is the file actually compiled.
2. Confirm `Reg_write` is high during a clock edge for register writes.
3. Confirm reset sequencing:
   - `Rst=0` for initial reset cycles
   - then `Rst=1` for normal operation
4. Confirm memory control signals are not both active:
   - Store: `MemWrite=1`, `MemRead=0`
   - Load: `MemWrite=0`, `MemRead=1`
5. Rebuild from scratch (`iverilog` then `vvp`) after edits.
