# SoC Integration Contract (Draft, Arithmetic-Stable)

This contract defines the architecture-facing interface for future SoC/FPGA top-level integration without changing current arithmetic or instruction semantics.

## Invariants (Must Not Change)

1. Arithmetic behavior remains RTL-exact Q5.10 wrap:
   - signed16 multiply
   - arithmetic right shift by 10
   - signed32 accumulation
   - output wrap to low16 then sign-extend to 32 bits
2. PCPI instruction encoding remains:
   - opcode `custom-0` (`0001011`)
   - funct3 `000`
   - funct7 `0101010`
   - current test instruction word `0x5420818b` (`rd=x3`, `rs1=x1`, `rs2=x2`)
3. Matrix dimensions remain 4x4 with 16-bit Q5.10 elements.

## Current Memory Layout (Demo/Testbench Contract)

1. Matrix A input buffer:
   - base `0x0000_0100`
   - 16 words (`0x100`..`0x13c`)
2. Matrix B input buffer:
   - base `0x0000_0140`
   - 16 words (`0x140`..`0x17c`)
3. Matrix C output buffer:
   - base `0x0000_0200`
   - 16 words (`0x200`..`0x23c`)
4. Sentinel locations used by firmware/testbench:
   - `0x0000_0000` first result (smoke/handoff)
   - `0x0000_0004` second result (handoff)
   - `0x0000_0008` regular instruction marker (handoff)

## PCPI Software-Facing Contract

1. Before issuing custom instruction:
   - `rs1` contains A base pointer.
   - `rs2` contains B base pointer.
2. During execution:
   - CPU may stall on `pcpi_wait`.
3. Completion:
   - accelerator writes full C matrix to C buffer.
   - CPU resumes when `pcpi_ready` is asserted.
   - `pcpi_wr` and `pcpi_rd` are asserted for architectural writeback.

## Future MMIO-Compatible Control Block (For SoC Top-Level)

The PCPI path remains valid. For memory-mapped integration, mirror equivalent controls:

1. `CTRL` (`BASE + 0x00`)
   - bit0 `start` (write 1 to start)
   - bit1 `busy` (read-only)
   - bit2 `done` (read/clear on write 1)
2. `A_BASE` (`BASE + 0x04`) 32-bit pointer to A buffer.
3. `B_BASE` (`BASE + 0x08`) 32-bit pointer to B buffer.
4. `C_BASE` (`BASE + 0x0c`) 32-bit pointer to C buffer.
5. `STATUS` (`BASE + 0x10`)
   - bit0 `handshake_error`
   - bit1 `addr_error`
   - bit2 `done_sticky`

## Compliance Expectations For New Integrations

1. Existing scripts and tests in `integration/pcpi_demo/scripts` stay reproducible.
2. Any top-level wrapper must preserve the exact arithmetic and custom instruction encoding above.
3. Regression (`run_pcpi_regression.ps1`) and handoff (`run_pcpi_handoff.ps1`) remain the compatibility gate.
