SHELL := bash
PYTHON          ?= python3
TOOLCHAIN_PREFIX ?= riscv64-unknown-elf-
CC              := $(TOOLCHAIN_PREFIX)gcc
OBJCOPY         := $(TOOLCHAIN_PREFIX)objcopy
OBJDUMP         := $(TOOLCHAIN_PREFIX)objdump

# rv32I bare-metal, no stdlib
ARCH  ?= rv32i
ABI   ?= ilp32
CFLAGS ?= -O2 -msmall-data-limit=0
EXTRA_CFLAGS ?=
LDLIBS ?= -lgcc

# Number of 32-bit words in imem — must match IMEM_DEPTH in rv32_pipeline_top.
# Default: 256 (1 KB).  Override with: make WORDS=512
WORDS ?= 256

# Path to picorv32 makehex.py which converts a flat binary to $readmemh hex.
PICORV32_MAKEHEX ?= ../../../picorv32/firmware/makehex.py

# Source file — override with: make FIRMWARE_SRC=my_fw.c
FIRMWARE_SRC ?= firmware_pipeline_matmul.c

# ── Build modes (pass via EXTRA_CFLAGS) ──────────────────────────────────────
#   Hardware accelerator (default):
#     make
#     make EXTRA_CFLAGS="-DMATMUL_MODE_ACCEL=1 -DMATMUL_MODE_SW=0"
#
#   Software fallback:
#     make EXTRA_CFLAGS="-DMATMUL_MODE_ACCEL=0 -DMATMUL_MODE_SW=1"
#
#   Custom test data:
#     make EXTRA_CFLAGS="-DMATMUL_MODE_ACCEL=1 -DUSE_EXTERNAL_CASE_DATA"
# ─────────────────────────────────────────────────────────────────────────────

all: firmware.hex firmware_sw_bench.hex

firmware.elf: $(FIRMWARE_SRC) sections.lds
	$(CC) $(CFLAGS) $(EXTRA_CFLAGS) \
		-mabi=$(ABI) -march=$(ARCH) \
		-ffreestanding -nostdlib \
		-o $@ \
		-Wl,--build-id=none,-Bstatic,-T,sections.lds,-Map,firmware.map,--strip-debug \
		$(FIRMWARE_SRC) $(LDLIBS)

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

firmware.hex: firmware.bin $(PICORV32_MAKEHEX)
	$(PYTHON) $(PICORV32_MAKEHEX) firmware.bin $(WORDS) > $@

firmware.dis: firmware.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f firmware.elf firmware.bin firmware.hex firmware.map firmware.dis \
	      firmware_sw_bench.elf firmware_sw_bench.bin firmware_sw_bench.hex firmware_sw_bench.map firmware_sw_bench.dis

# ── SW bench firmware (no .rodata, for Harvard-safe cycle benchmarking) ───────
firmware_sw_bench.elf: firmware_sw_bench.c sections.lds
	$(CC) $(CFLAGS) $(EXTRA_CFLAGS) \
		-mabi=$(ABI) -march=$(ARCH) \
		-ffreestanding -nostdlib \
		-o $@ \
		-Wl,--build-id=none,-Bstatic,-T,sections.lds,-Map,firmware_sw_bench.map,--strip-debug \
		firmware_sw_bench.c $(LDLIBS)

firmware_sw_bench.bin: firmware_sw_bench.elf
	$(OBJCOPY) -O binary $< $@

firmware_sw_bench.hex: firmware_sw_bench.bin $(PICORV32_MAKEHEX)
	$(PYTHON) $(PICORV32_MAKEHEX) firmware_sw_bench.bin $(WORDS) > $@

firmware_sw_bench.dis: firmware_sw_bench.elf
	$(OBJDUMP) -d $< > $@

.PHONY: all clean
