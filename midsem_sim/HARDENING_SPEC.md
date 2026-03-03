# Midsem Systolic Accelerator Hardening Spec (Step 1 Freeze)

Date: 2026-03-03
Scope: `midsem_sim` standalone accelerator only (no CPU integration in this step).

## 1. Module Under Test

- Top: `midsem_sim/rtl/matrix_accel_4x4_q5_10.v`
- Array: `midsem_sim/rtl/systolic_array_4x4_q5_10.v`
- PE: `midsem_sim/rtl/pe_cell_q5_10.v`
- Issue logic: `midsem_sim/rtl/issue_logic_4x4_q5_10.v`

## 2. Data Representation Contract (Frozen for Steps 1-3)

- Input format: signed Q5.10 in 16-bit two's complement.
- Per-MAC multiply:
  - `product_full = x_in * y_in` (signed 32-bit)
  - fixed-point alignment by arithmetic shift right 10:
    - `product_q5_10 = product_full >>> 10`
- Accumulate:
  - `z_acc = z_acc + product_q5_10` in signed 32-bit accumulator.
- Output cast:
  - final exported matrix element uses low 16 bits: `z_acc[15:0]`.
  - behavior is wrap/truncate to 16-bit two's complement (no saturation in current RTL).

Important: saturation/alternate rounding is intentionally deferred to Step 4+.

## 3. Handshake Contract (Current RTL)

Signals: `start`, `busy`, `done`.

- `start` is sampled on rising edge.
- A new operation is accepted only when `start==1 && busy==0`.
- While `busy==1`, additional `start` assertions are ignored.
- `done` is a one-cycle pulse at operation completion.
- `busy` deasserts when operation completes.

## 4. Reset Contract

- `rst=1` forces accelerator control state to idle (`busy=0`, `done=0`, counters cleared).
- Asserting reset during an active operation aborts the in-flight operation.

## 5. Latency Contract (Current 4x4 Design)

- `COMPUTE_CYCLES = 10` (as implemented in top module).
- Testbench should treat this as expected latency for accepted operations.

## 6. Verification Acceptance for Steps 1-3

The hardening pass for Steps 1-3 is considered complete when:

1. Directed tests pass (identity, ones, signed/mixed, overflow-wrap, handshake corner cases).
2. Random regression cases pass against golden model.
3. Test logs contain explicit pass/fail `$display` lines per case and overall summary.

## 7. Explicitly Deferred

- Saturation/rounding policy changes in RTL.
- Parameterization beyond fixed 4x4 timing path.
- CPU custom instruction integration.
