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

# ---- MLPerf Tiny AD proxy benchmark firmware --------------------------------
# SW variant: single-tile software Q5.10 matmul (shift-add, no MUL extension)
#             A/B/C base at 0x800/0x840/0x900 to avoid overlap with firmware and stack
MLPERF_SW_CFLAGS := -DMATMUL_MODE_ACCEL=0 -DMATMUL_MODE_SW=1 \
                    -DA_BASE_WORD_ADDR=0x800u -DB_BASE_WORD_ADDR=0x840u \
                    -DC_BASE_WORD_ADDR=0x900u

firmware_sw_picorv_mlperf.elf: firmware_matmul_unified.c sections.lds
	$(CC) $(CFLAGS) $(MLPERF_SW_CFLAGS) -mabi=$(ABI) -march=$(ARCH) -ffreestanding -nostdlib \
		-o $@ \
		-Wl,--build-id=none,-Bstatic,-T,sections.lds,-Map,firmware_sw_picorv_mlperf.map,--strip-debug \
		$< $(LDLIBS)

firmware_sw_picorv_mlperf.bin: firmware_sw_picorv_mlperf.elf
	$(OBJCOPY) -O binary $< $@

firmware_sw_picorv_mlperf.hex: firmware_sw_picorv_mlperf.bin $(PICORV32_MAKEHEX)
	$(PYTHON) $(PICORV32_MAKEHEX) $< 1024 > $@

# SW MUL variant: same software kernel, compiled for rv32im so the core can use MUL.
firmware_sw_picorv_mlperf_mul.elf: firmware_matmul_unified.c sections.lds
	$(CC) $(CFLAGS) $(MLPERF_SW_CFLAGS) -mabi=$(ABI) -march=rv32im -ffreestanding -nostdlib \
		-o $@ \
		-Wl,--build-id=none,-Bstatic,-T,sections.lds,-Map,firmware_sw_picorv_mlperf_mul.map,--strip-debug \
		$< $(LDLIBS)

firmware_sw_picorv_mlperf_mul.bin: firmware_sw_picorv_mlperf_mul.elf
	$(OBJCOPY) -O binary $< $@

firmware_sw_picorv_mlperf_mul.hex: firmware_sw_picorv_mlperf_mul.bin $(PICORV32_MAKEHEX)
	$(PYTHON) $(PICORV32_MAKEHEX) $< 1024 > $@

# HW variant: 32-tile back-to-back PCPI accelerator proxy
firmware_mlperf_proxy_picorv.elf: firmware_mlperf_proxy_picorv.c sections.lds
	$(CC) $(CFLAGS) -mabi=$(ABI) -march=$(ARCH) -ffreestanding -nostdlib \
		-o $@ \
		-Wl,--build-id=none,-Bstatic,-T,sections.lds,-Map,firmware_mlperf_proxy_picorv.map,--strip-debug \
		$< $(LDLIBS)

firmware_mlperf_proxy_picorv.bin: firmware_mlperf_proxy_picorv.elf
	$(OBJCOPY) -O binary $< $@

firmware_mlperf_proxy_picorv.hex: firmware_mlperf_proxy_picorv.bin $(PICORV32_MAKEHEX)
	$(PYTHON) $(PICORV32_MAKEHEX) $< 256 > $@

mlperf: firmware_sw_picorv_mlperf.hex firmware_sw_picorv_mlperf_mul.hex firmware_mlperf_proxy_picorv.hex

clean:
	rm -f firmware.elf firmware.bin firmware.hex firmware.map firmware.dis
	rm -f firmware_sw_picorv_mlperf.elf firmware_sw_picorv_mlperf.bin \
	      firmware_sw_picorv_mlperf.hex firmware_sw_picorv_mlperf.map
	rm -f firmware_sw_picorv_mlperf_mul.elf firmware_sw_picorv_mlperf_mul.bin \
	      firmware_sw_picorv_mlperf_mul.hex firmware_sw_picorv_mlperf_mul.map
	rm -f firmware_mlperf_proxy_picorv.elf firmware_mlperf_proxy_picorv.bin \
	      firmware_mlperf_proxy_picorv.hex firmware_mlperf_proxy_picorv.map

.PHONY: all clean mlperf
