# RISC-V Machine Code Reference (Simple Instruction Tests)

This file lists the exact encodings used by `simple_instruction_test.v`.

## Instruction Encodings

1. `ADDI x1, x0, 10`
- Binary: `000000001010 00000 000 00001 0010011`
- Hex: `0x00A00093`

2. `ADDI x2, x0, 20`
- Binary: `000000010100 00000 000 00010 0010011`
- Hex: `0x01400113`

3. `ADD x3, x1, x2`
- Binary: `0000000 00010 00001 000 00011 0110011`
- Hex: `0x002081B3`

4. `SW x3, 0(x0)`
- Binary: `0000000 00011 00000 010 00000 0100011`
- Hex: `0x00302023`

5. `LW x4, 0(x0)`
- Binary: `000000000000 00000 010 00100 0000011`
- Hex: `0x00002203`

6. `ADDI x5, x1, 15`
- Binary: `000000001111 00001 000 00101 0010011`
- Hex: `0x00F08293`

7. `SUB x6, x3, x1`
- Binary: `0100000 00001 00011 000 00110 0110011`
- Hex: `0x40118333`

## Opcode Quick Map

- `0010011` (`0x13`) -> OP-IMM (`ADDI`)
- `0110011` (`0x33`) -> OP (`ADD`, `SUB`)
- `0000011` (`0x03`) -> LOAD (`LW`)
- `0100011` (`0x23`) -> STORE (`SW`)

## Register Values Expected After Tests

- `x1 = 10` (`0x0000000A`)
- `x2 = 20` (`0x00000014`)
- `x3 = 30` (`0x0000001E`)
- `x4 = 30` (`0x0000001E`)
- `x5 = 25` (`0x00000019`)
- `x6 = 20` (`0x00000014`)
