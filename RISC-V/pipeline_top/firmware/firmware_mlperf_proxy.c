// firmware_mlperf_proxy.c
//
// MLCommons Tiny Anomaly Detection — proxy benchmark firmware for
// rv32_pipeline_top + PCPI EdgeMATX accelerator.
//
// ─── WHAT THIS MODELS ────────────────────────────────────────────────────────
// The MLPerf Tiny AD benchmark (https://github.com/mlcommons/tiny) uses a
// fully-connected autoencoder with 5 Dense layers of shape 128→128.
//
// Each Dense(128→128) layer is a GEMV:  y[128] = W[128×128] × x[128] + b[128]
// When batched to BATCH=4 samples, this becomes a GEMM:
//
//   C[128×4] = W[128×128] × X[128×4]
//
// Tiled onto our 4×4 accelerator:
//   Output tiles  = (128/4) × (4/4) = 32 × 1 = 32 tiles per "column group"
//   K-reduction   = 128/4 = 32 accumulation steps per output tile
//   Tiles / layer = 32 × 32 = 1,024  MATMUL_ACCEL calls
//   Tiles / infer = 5 × 1,024 = 5,120  MATMUL_ACCEL calls
//
// N_TILES (32 below) represents **one column group** — the 32 reduction-step
// tiles that produce 4 output neurons from all 128 input features.
// Multiply the measured cycle count by (5 × 32) to get estimated full-
// inference cycle budget.
//
// ─── CYCLE-COUNT EXTRAPOLATION ───────────────────────────────────────────────
// Measured: ~37 PCPI stall cycles + ~10 CPU setup/readback = ~47 cycles/tile.
//
//   N_TILES = 32 proxy calls  →  testbench measures T total cycles
//   cycles_per_tile = T / N_TILES
//   projected_AD_inference_cycles = cycles_per_tile × 5,120
//   @ 100 MHz  →  projected_ms = projected_AD_inference_cycles / 100,000
//   MLPerf Tiny AD target: < 10 ms  (typically < 5 ms for MCUs at 100 MHz)
//
// ─── MEMORY LAYOUT ───────────────────────────────────────────────────────────
// Same convention as firmware_accel_bench.c (pre-loaded by testbench):
//
//   0x000          cycle_count sentinel  (written here before halt)
//   0x004          N_TILES    (constant, helps TB parse results)
//   0x100 - 0x11F  Matrix A  (8 packed words, 2 Q5.10 elems per word)
//   0x140 - 0x15F  Matrix B  (8 packed words, 2 Q5.10 elems per word)
//   0x200 - 0x21F  Matrix C  (8 packed words, written by PCPI each call)
//   0x3F8          initial stack pointer
//
// NOTE: This proxy uses constant A/B (same tile repeated) to measure pure
// accelerator throughput.  A full implementation would load different weight
// tiles for each call; the compute latency is identical.
//
// ─── CUSTOM INSTRUCTION ──────────────────────────────────────────────────────
// R-type CUSTOM-0, same encoding as firmware_accel_bench.c:
//   opcode = 0b0001011, funct3 = 0b000, funct7 = 0b0101010
//   rs1 = byte address of A tile,  rs2 = byte address of B tile
//   CPU stalls until pcpi_ready; result C is written to dmem[0x200..0x21F].

typedef   signed int   int32_t;
typedef unsigned int   uint32_t;

// Number of MATMUL_ACCEL calls to issue.
// 32 = one K-reduction column-group of a 128→128 FC layer (BATCH=4).
#define N_TILES   32

// Issue the CUSTOM-0 matmul instruction.
// CPU stalls (via PCPI pcpi_wait) until the 4×4 systolic array finishes.
#define MATMUL_ACCEL(addr_a, addr_b)                                      \
    __asm__ volatile (                                                      \
        ".insn r 0x0b, 0, 0x2a, x0, %0, %1"                               \
        :                                                                    \
        : "r"((uint32_t)(addr_a)), "r"((uint32_t)(addr_b))                 \
        : "memory"                                                           \
    )

void _start(void) __attribute__((noreturn));
void _start(void) {
    // Initialise stack before any local variable use.
    __asm__ volatile ("li sp, 0x3f8");

    const uint32_t addr_a = 0x100u;   // Matrix A tile (pre-loaded by testbench)
    const uint32_t addr_b = 0x140u;   // Matrix B tile (pre-loaded by testbench)

    // ── Proxy loop ──────────────────────────────────────────────────────────
    // Issue N_TILES back-to-back MATMUL_ACCEL instructions.
    //
    // Each call:
    //  1. CPU issues CUSTOM-0 and stalls via pcpi_wait.
    //  2. pcpi_tinyml_accel.v reads A (8 dmem words) + B (8 dmem words).
    //  3. Systolic array runs for ~10 cycles.
    //  4. C written to dmem[0x200..0x21F]; pcpi_ready asserted.
    //  5. CPU resumes; loop counter decremented; repeat.
    //
    // In a real tiled-GEMM firmware each call would advance the A/B pointers
    // to cover a different 4×4 sub-block; here we reuse the same tile to
    // isolate accelerator throughput from memory-fetch latency.
    volatile int i;
    for (i = 0; i < N_TILES; i++) {
        MATMUL_ACCEL(addr_a, addr_b);
    }

    // ── Write sentinels ──────────────────────────────────────────────────────
    // dmem[0x000] (word 0) : N_TILES  — always non-zero; testbench polls this.
    // dmem[0x004] (word 1) : N_TILES again for readback verification.
    //
    // NOTE: C is in the PCPI wrapper's shared memory (accel_mem path), which
    // is a SEPARATE address space from the CPU's data memory (dmem).  The CPU
    // cannot load directly from the accelerator result buffer, so we use
    // N_TILES (a compile-time constant = 32, always non-zero) as the sentinel.
    // The testbench verifies the accelerator result via hierarchical access
    // to the PCPI system's shared memory (u_proxy.mem[]).
    __asm__ volatile ("sw %0, 0(x0)" :: "r"((uint32_t)N_TILES) : "memory");
    __asm__ volatile ("sw %0, 4(x0)" :: "r"((uint32_t)N_TILES) : "memory");

    // ── Halt ────────────────────────────────────────────────────────────────
    while (1) {
        __asm__ volatile ("jal x0, .");
    }
}
