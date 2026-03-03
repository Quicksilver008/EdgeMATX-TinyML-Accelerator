# Quick Start: Vivado Simulation for Simple Instruction Tests

## 1) Add Files

In Vivado, create/open project and add these files:

- RTL Sources:
  - `RISC-V/register_bank/src/register_bank.v`
  - `RISC-V/alu/src/alu.v`
  - `RISC-V/data_memory/src/data_memory.v`
- Simulation Sources:
  - `RISC-V/simple_instruction_test.v`

Set `simple_instruction_test` as simulation top.

## 2) Run Simulation

- Run Behavioral Simulation.
- In Tcl console, run:

```tcl
run all
```

## 3) Expected Console Output

You should see 7 PASS lines and the summary:

```text
====== Test Summary ======
Total Tests: 7
Passed Tests: 7
ALL TESTS PASSED!
==========================
```

## 4) Signals to Observe (Optional)

- Testbench control: `Clk`, `Rst`
- Register bank: `Rd_reg_1`, `Rd_reg_2`, `Wr_reg`, `Wr_data`, `Reg_write`, `Rd_data_1`, `Rd_data_2`
- ALU: `alu_in1`, `alu_in2`, `alu_op`, `alu_out`
- Data memory: `mem_addr`, `mem_wr_data`, `mem_rd_data`, `mem_write`, `mem_read`

## 5) Common Issues

1. Wrong relative path during compile from `RISC-V`
- Use `.\register_bank\src\register_bank.v`, not `..\register_bank\src\register_bank.v`.

2. Empty or stale testbench file
- Verify `RISC-V/simple_instruction_test.v` is non-empty and the active simulation file.

3. Wrong simulation top
- Ensure top is `simple_instruction_test`, not a module RTL file.

4. Failing writes due to timing
- `Reg_write` and memory control signals must stay asserted through the target clock edge.
