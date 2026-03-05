# PCPI Legacy / Fallback Assets

This folder keeps fallback/reference assets that are intentionally separated from the active flow.

## Active Firmware Path

Use `integration/pcpi_demo/firmware/` for active flows. Primary sources are:

1. `firmware.S`
2. `firmware_handoff.S`
3. `firmware_matmul_unified.c`
4. `Makefile`
5. `sections.lds`

## Legacy Firmware References

1. `legacy/firmware/firmware_c.c`
2. `legacy/firmware/firmware_sw_matmul.c`

These files are kept for historical comparison and rollback reference. Active scripts do not depend on them.
