SHELL := bash
PYTHON ?= python
TOOLCHAIN_PREFIX ?= riscv64-unknown-elf-
CC := $(TOOLCHAIN_PREFIX)gcc
OBJCOPY := $(TOOLCHAIN_PREFIX)objcopy
OBJDUMP := $(TOOLCHAIN_PREFIX)objdump
CFLAGS ?= -O2 -msmall-data-limit=0
EXTRA_CFLAGS ?=
LDLIBS ?= -lgcc
ABI ?= ilp32
ARCH ?= rv32i

PICORV32_MAKEHEX ?= ../../../picorv32/firmware/makehex.py
WORDS ?= 256
FIRMWARE_SRC ?= firmware.S

all: firmware.hex

firmware.elf: $(FIRMWARE_SRC) sections.lds
	$(CC) $(CFLAGS) $(EXTRA_CFLAGS) -mabi=$(ABI) -march=$(ARCH) -ffreestanding -nostdlib -o $@ \
		-Wl,--build-id=none,-Bstatic,-T,sections.lds,-Map,firmware.map,--strip-debug \
		$(FIRMWARE_SRC) $(LDLIBS)

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

firmware.hex: firmware.bin $(PICORV32_MAKEHEX)
	$(PYTHON) $(PICORV32_MAKEHEX) firmware.bin $(WORDS) > $@

firmware.dis: firmware.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f firmware.elf firmware.bin firmware.hex firmware.map firmware.dis

.PHONY: all clean
