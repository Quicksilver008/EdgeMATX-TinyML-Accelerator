/* Linker script for rv32_pipeline_top bare-metal firmware.
 *
 * Instruction memory (imem) base address is 0x00000000.
 * The CPU fetches from imem[pc >> 2]; pc starts at 0 after reset.
 * All sections are packed from 0x0 so the resulting .hex file maps
 * directly into imem via $readmemh(IMEM_FILE, imem).
 */

ENTRY(_start)

SECTIONS
{
  . = 0x00000000;

  .text   : { *(.text*)   }
  .rodata : { *(.rodata*) }
  .data   : { *(.data*)   }
  .bss    : { *(.bss*) *(COMMON) }
}
