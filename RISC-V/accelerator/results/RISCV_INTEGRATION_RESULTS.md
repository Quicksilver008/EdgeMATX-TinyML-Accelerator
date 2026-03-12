# RISC-V Custom-Instruction Integration Results

## Verification Summary

| Test | Pass | Accelerator Cycles |
|---|---:|---:|
| `identity_custom` | 1 | 10 |
| `issue_while_busy` | 1 | 10 |
| `signed_mixed_custom` | 1 | 10 |

Overall pass rate: **3 / 3**

## Covered Behaviors

- Custom instruction decode match and accept pulse generation.
- CPU stall assertion while accelerator operation is in flight.
- Busy-window protection (instruction re-issue while busy is ignored).
- Correct matrix output compared against a golden model.

## Notes

- This is an integration stub simulation, not full pipeline CPU execution.
- Next milestone is replacing the instruction stub source with an actual CPU fetch/decode stream.
