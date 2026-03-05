# PCPI Handoff Test Results

Last validated: 2026-03-05

## Purpose

Validate that PicoRV32 can execute mixed instruction flow:

1. Custom instruction over PCPI
2. Regular instructions in between
3. Another custom instruction

and that handshake/memory behavior is correct end-to-end.

## Run Command

```powershell
.\integration\pcpi_demo\scripts\run_pcpi_handoff.ps1
```

## Latest Observed PASS Output

From `integration/pcpi_demo/results/pcpi_handoff.log`:

- `TB_INFO first custom result observed: 0x00000400`
- `TB_INFO regular instruction marker observed: 0x0000047b`
- `TB_INFO second custom result observed: 0xfffffc00`
- `TB_PASS handoff test complete.`
- `TB_PASS custom_issue_count=2 ready_count=2 wr_count=2 handshake_ok_count=2 c_store_count=32`

## Acceptance Checks Enforced By Testbench

1. First custom result sentinel (`addr 0x0`) equals `0x00000400`.
2. Regular instruction marker (`addr 0x8`) equals `0x0000047b`.
3. Second custom result sentinel (`addr 0x4`) equals `0xfffffc00`.
4. Handshake counts:
   - `custom_issue_count = 2`
   - `ready_count = 2`
   - `wr_count = 2`
   - `handshake_ok_count = 2`
5. Accelerator C-buffer stores for two runs:
   - `c_store_count = 32`

## Waveform Artifact

- `integration/pcpi_demo/results/pcpi_handoff_wave.vcd`

## Cross-Reference

- Consolidated multi-flow evidence table:
  - `integration/pcpi_demo/TEST_RESULTS_SUMMARY.md`

Open with:

```powershell
gtkwave .\integration\pcpi_demo\results\pcpi_handoff_wave.vcd
```
