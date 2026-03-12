# Core — RV32I Pipeline Sub-modules

Individual RTL sub-modules that make up the 5-stage Harvard RV32I pipeline, plus their corresponding unit testbenches.

## Directory Layout

```
core/
├── rtl/
│   ├── alu.v                   ← 32-bit ALU (AND, OR, ADD, SUB, SLT, SLL, SRL, SRA, XOR)
│   ├── alu_control.v           ← ALU operation selector (funct3/funct7 decode)
│   ├── Control_Unit.v          ← Main control signals from opcode
│   ├── data_memory.v           ← Byte-addressed 32-bit data memory (synchronous write)
│   ├── forwarding_unit.v       ← EX/MEM and MEM/WB data forwarding paths
│   ├── hazard_detection_unit.v ← Load-use stall and N+3 write-through bypass detection
│   ├── instruction_decoder.v   ← Splits 32-bit instruction into fields (rs1, rs2, rd, imm…)
│   ├── Program_Counter.v       ← PC register with synchronous reset and branch/jump mux
│   ├── register_bank.v         ← 32×32 register file with write-through on WB port
│   ├── seq_mul.v               ← Iterative 32-bit multiplier (shift-and-add, 32 cycles)
│   └── seq_div.v               ← Iterative 32-bit divider (non-restoring, 32 cycles)
└── tb/
    ├── tb_alu.v
    ├── tb_Control_Unit.v
    ├── tb_data_memory.v
    ├── tb_forwarding_unit.v
    ├── tb_hazard_detection_unit.v
    ├── tb_instruction_decoder.v
    ├── tb_Program_Counter.v
    ├── tb_register_bank.v
    ├── tb_seq_mul.v
    └── tb_seq_div.v
```

## Running a Unit Test

Each testbench is self-contained. Run from the **workspace root**:

```powershell
# Example: ALU unit test
iverilog -g2012 -o _alu_tb.vvp `
  RISC-V/core/rtl/alu.v `
  RISC-V/core/tb/tb_alu.v
vvp _alu_tb.vvp
Remove-Item _alu_tb.vvp
```

Replace `alu` / `tb_alu` with the module name for other units.

Testbenches that depend on multiple sub-modules (e.g. forwarding, hazard) include the necessary RTL via `` `include `` or require the dependent file listed first on the compile line.

## Pipeline Integration

These modules are assembled together in [`../pipeline_top/src/rv32_pipeline_top.v`](../pipeline_top/src/rv32_pipeline_top.v). For end-to-end tests, use the scripts in [`../pipeline_top/scripts/`](../pipeline_top/scripts/).

## Key Design Points

- **Harvard architecture**: separate instruction memory (imem, 256 words, ROM-style) and data memory (dmem, 256 words).
- **Forwarding**: EX/MEM forwarding requires 0 stall NOPs; MEM/WB forwarding requires 1 NOP for load-use; register file write-through covers N+3 (2-NOP gap).
- **No hardware multiply/divide in base ISA path**: `seq_mul` / `seq_div` are instantiated as coprocessors; the pipeline uses shift-and-add Q5.10 multiply in accelerator firmware.
