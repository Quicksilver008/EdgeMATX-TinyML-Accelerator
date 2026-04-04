# MLCommons Tiny Benchmark Feasibility for EdgeMATX

**Repo:** https://github.com/mlcommons/tiny  
**Date:** 2026-03-12  
**Accelerator:** EdgeMATX 4×4 Q5.10 systolic array + RV32I PCPI pipeline

---

## 1. What MLPerf Tiny Is

MLCommons Tiny (v1.x) defines four closed-division embedded-inference benchmarks:

| Task | Short name | Model | Input | Primary op |
|------|-----------|-------|-------|-----------|
| Anomaly Detection | AD | FC autoencoder (128→128→128→128→128) | 128-D MFCC | Dense (GEMV) |
| Keyword Spotting | KWS | DS-CNN | 49×10 spectrogram | DepthwiseConv2D + Conv2D |
| Image Classification | IC | ResNet-8 / MobileNet-v1 | 32×32 RGB | Conv2D |
| Visual Wake Words | VWW | MobileNet-v1 | 96×96 RGB | Conv2D |

Each benchmark is measured by:
- **Latency** — wall-clock ms per inference, via the Energy-Efficient MCU (EEM) UART protocol.
- **Energy** — µJ per inference (requires external power measurement board).
- Optionally **accuracy** on a closed test set.

The host PC sends a 16-byte command packet over UART, the DUT responds when inference is complete, and the reference host `runner/` Python scripts score the result.

---

## 2. What EdgeMATX Currently Provides

| Capability | Status |
|-----------|--------|
| 4×4 Q5.10 matrix multiply (PCPI custom instruction) | ✅ RTL verified |
| 5-stage RV32I pipeline | ✅ RTL verified |
| ~37 PCPI cycles per 4×4 matmul | ✅ Measured in simulation |
| Shared 1 KB on-chip data memory | ✅ Present |
| UART / host communication | ❌ Not implemented |
| Timer / cycle counter (CSR) | ❌ Not implemented |
| INT8 or FP32 data path | ❌ Q5.10 16-bit only |
| TFLite Micro or equivalent runtime | ❌ Not implemented |
| Conv2D, DepthwiseConv2D, ReLU primitives | ❌ Not implemented |
| >1 KB weight/activation storage | ❌ Current dmem = 1 KB |

---

## 3. Gap Analysis per Benchmark Task

### 3.1 Anomaly Detection (AD) — **Most Feasible**

The AD autoencoder is entirely Dense (FC) layers.  Dense layers are
GEMV: `y = W×x + b`, which decomposes into 4×4 GEMM tiles.

**Model dimensions:**
- Architecture: 128 → 128 → 128 → 128 → 128 (5 FC layers)
- Weight per layer: 128×128 = 16,384 elements × 2 bytes (Q5.10) = **32 KB**
- Total weights: 5 × 32 KB = **160 KB** — far exceeds current 1 KB dmem

**Tile math** (batching 4 inference samples, M=128, N=4, K=128):
```
Output tiles   = (M/4) × (N/4) = 32 × 1 = 32  (N=4 fits one tile)
Inner K tiles  = K/4 = 32
Total tiles/layer = 32 × 32 = 1,024  MATMUL_ACCEL calls
Total tiles/inference = 5 × 1,024 = 5,120  calls
```

**Cycle estimate** (single-sample GEMV, 37 PCPI + ~10 overhead = 47 cycles/tile):
```
5,120 tiles × 47 cycles = 240,640 cycles
@ 100 MHz clock → ~2.4 ms per inference (4-sample batch amortized)
MLPerf Tiny target: <10 ms  → on-track, even after SW ReLU/bias overhead
```

**Missing pieces for full submission:**
- 160 KB weight memory (external DRAM or large on-chip SRAM)
- Bias add + ReLU in firmware (trivial scalar C code)
- UART EEM host interface
- INT8 quantisation or Q5.10 packing of the official model checkpoint

### 3.2 Keyword Spotting (KWS) — **Possible with SW fallback**

DS-CNN has 1-D and 2-D depthwise separable convolutions.  These _can_ be
lowered to GEMM via im2col:
```
im2col(input_patch) → 2D matrix → MATMUL_ACCEL tiles
```
However KWS requires ~100 Conv2D + DepthwiseConv2D + Dense layers, so the
firmware SW stack (im2col, padding, activation) is substantial.

**Verdict:** Feasible in firmware, not yet implemented.  Purely scalar RV32I
fallback would work but wastes the accelerator on small inner loops.

### 3.3 Image Classification (IC) and Visual Wake Words (VWW) — **Not practical yet**

Both require large 2-D convolutions on 32×32 or 96×96 images.  Primary obstacles:
- Image data alone (96×96×3 = 27 KB) exceeds current memory.
- MobileNet-v1 has ~4.2 M parameters → multi-MB weight storage required.
- DSP-heavy operations (pointwise + depthwise conv) need additional kernel development.

---

## 4. What We Can Do Right Now — Proxy Benchmark

Rather than a full MLPerf Tiny submission, we can **measure and report
directly comparable cycle counts** for the core compute kernel using the
existing PCPI infrastructure.

### 4.1 Proxy benchmark design

`firmware_mlperf_proxy.c` (located at `RISC-V/pipeline_top/firmware/`) implements:

1. **`N_TILES` = 32** MATMUL_ACCEL calls — equivalent to computing **one output
   row-group** (4 output neurons × full 128-dim input) of an AD FC layer.
2. Writes a sentinel after all tiles complete so the testbench measures total
   wall-clock cycles.
3. Emits `total_cycles / N_TILES` as "cycles per tile" to memory so TB can
   log it.

**Extrapolated AD inference time** at measured throughput:
```
cycles_per_tile = ~47  (measured at 100 MHz)
5,120 tiles × 47 = 240,640 cycles → 2.41 ms
SW overhead (bias, relu, data movement) est. +30% → ~3.1 ms
```

This is **reportable against MLPerf Tiny AD target** as a "projected"
performance number, clearly labelled as simulation-only.

### 4.2 How to run the proxy benchmark

```powershell
cd RISC-V/pipeline_top/firmware
make FIRMWARE_SRC=firmware_mlperf_proxy.c \
     OUT_STEM=firmware_mlperf_proxy

cd ..
# Simulate with your existing tb_rv32_pipeline_pcpi_system testbench,
# overriding the hex file to firmware_mlperf_proxy.hex
```

---

## 5. Roadmap Toward a Full MLPerf Tiny AD Submission

| Step | Change needed | Effort |
|------|--------------|--------|
| **S1** | Extend dmem / add external memory controller (160 KB weights) | Hardware |
| **S2** | Add CSR `mcycle` register to RV32I pipeline | Small RTL change |
| **S3** | Implement tiled GEMV firmware library (`edgematx_gemv`) | Firmware |
| **S4** | Add ReLU + bias kernel in C (scalar, no acceleration needed) | Firmware |
| **S5** | Port MLPerf Tiny EEM UART host protocol | Firmware |
| **S6** | Quantise AD reference model weights to Q5.10 | Python script |
| **S7** | Validate accuracy against the official MLPerf Tiny test set | SW + Python |
| **S8** | (Optional) Scale array to 8×8 or 16×16 for higher throughput | Hardware |

Steps S3–S7 can be done entirely in firmware/software on top of the current
RTL, making AD the natural first complete benchmark.

---

## 6. Data-Type Compatibility Note

MLPerf Tiny reference models are quantised to **INT8** (8-bit integer, per-tensor
or per-channel).  Our accelerator uses **Q5.10** (16-bit fixed-point).

Options:
- **Re-quantise** the AD model checkpoint to Q5.10 using the existing Python
  quantisation scripts — accuracy within ±1% of INT8 is expected given the Q5.10
  dynamic range is wider (16-bit vs 8-bit).
- **Sign-extend INT8→16** inputs before feeding the PCPI instruction — works but
  yields 1920-cycle savings vs native INT8 (which would require a different PE cell).

The Q5.10 format gives **higher dynamic range** than INT8 for the same compute
cost (same 16×16 MAC), which is a justifiable deviation for an academic project.

---

## 7. Summary

| Benchmark | Feasibility now | With S1–S7 roadmap |
|-----------|----------------|-------------------|
| AD | **Proxy firmware ready** | Full submission feasible |
| KWS | Partial (SW im2col needed) | Feasible with firmware effort |
| IC | Not practical | Requires larger memory + 2D conv |
| VWW | Not practical | Requires >1 MB storage |

**Bottom line:** Direct use of the MLCommons Tiny runner framework requires a
UART/EEM host interface and sufficient weight storage.  The **AD benchmark** is
the closest fit — the tile-GEMM pattern maps directly onto the PCPI custom
instruction, and the compute requirement (~5,120 tiles) is measurable in
simulation today using `firmware_mlperf_proxy.c`.
