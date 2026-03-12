// firmware_sw_bench.c
//
// Pure-software 4x4 Q5.10 matrix multiply benchmark firmware.
//
// Designed for rv32_pipeline_top used as a STANDALONE core (no PCPI wrapper).
// This firmware contains NO global const arrays (.rodata is empty) — all
// matrix data is pre-loaded into data memory (dmem) by the testbench using
// hierarchical references before reset is released.
//
// Memory layout (byte addresses, dmem is byte-addressed):
//   0x000          completion sentinel (written last; testbench polls this)
//   0x100 - 0x11F  Matrix A (8 x 32-bit packed words, 2 Q5.10 elements per word)
//   0x140 - 0x15F  Matrix B (8 x 32-bit packed words, 2 Q5.10 elements per word)
//   0x200 - 0x21F  Matrix C (result, 8 x 32-bit packed words, written by this firmware)
//   0x3F8          stack pointer (grows downward)
//
// Packed encoding per 32-bit word:
//   bits [15:0]  = element at even column  (col = 0 or 2)
//   bits [31:16] = element at odd  column  (col = 1 or 3)
//   stride: 4 bytes per packed word (covers 2 adjacent columns in the same row)
//
// Memory operation budget per matmul:
//   A:  2 LW per row × 4 rows  = 8 LW   (vs 64 with 1-per-word)
//   B:  4 LW per col-pair × 2 pairs × 4 rows = 32 LW  (vs 64)
//   C:  1 SW per col-pair × 2 pairs × 4 rows = 8 SW   (vs 16)
//
// Cycle measurement window (testbench):
//   START : rst released (cycles = 0)
//   STOP  : dmem[0x000] != 0  (sentinel written after matmul completes)
//
// Why no .rodata:
//   rv32_pipeline_top is a Harvard architecture — instruction memory (imem)
//   and data memory (dmem) are physically separate.  Global const arrays
//   placed in .rodata by the compiler reside in imem and are invisible to
//   LW/LH/LB data-memory load instructions.  This firmware avoids that
//   by never declaring static/global const data.

typedef   signed int   int32_t;
typedef   signed short int16_t;
typedef unsigned int   uint32_t;

// Q5.10 fixed-point multiply — radix-4 shift-and-add.
//
// Processes TWO bits of b per iteration (Booth radix-4 principle):
//   bits[1:0] = 0 → add 0       (no-op)
//   bits[1:0] = 1 → add 1×a
//   bits[1:0] = 2 → add 2×a
//   bits[1:0] = 3 → add 3×a (= 1×a + 2×a)
//
// This halves the maximum iteration count: 16-bit b → max 8 loops
// instead of 16, cutting multiply cycles by ~40% for the typical Q5.10
// range (values cluster near 0 so high bits are zero, exits early).
//
// Compiles to ~9 instructions/iteration on rv32i (ANDI×2, BEQ×2,
// ADD, SLLI, SLLI, SRLI, BNE) — same pipeline-friendly pattern as before.
// No JAL required; always_inline keeps it fused at each call site.
static inline __attribute__((always_inline)) int32_t q5_10_mul(int16_t a, int16_t b) {
    int32_t  ia  = (int32_t)a;
    int32_t  acc = 0;
    /* zero-extend b via unsigned int (uint32_t not available — use uint trick) */
    unsigned int ub = (unsigned int)(unsigned short)b;
    if (ub == 0u) return 0;
    do {
        unsigned int bits = ub & 3u;
        if (bits & 1u) acc += ia;            /* bit 0: add 1×a */
        if (bits & 2u) acc += (ia + ia);     /* bit 1: add 2×a */
        ia <<= 2;                             /* advance multiplicand 2 positions */
        ub >>= 2;                             /* consume 2 bits */
    } while (ub);
    return acc >> 10;
}

void _start(void) __attribute__((noreturn));
void _start(void) {
    // Set up stack before any local variable use.
    __asm__ volatile ("li sp, 0x3f8");

    // Packed layout: 2 Q5.10 elements per 32-bit word.
    // A[row][col]: word A[row*2 + col/2], half = (col&1) ? [31:16] : [15:0]
    // B[k][col]:   word B[k*2   + col/2], half = (col&1) ? [31:16] : [15:0]
    // C[row][col]: word C[row*2 + col/2], half = (col&1) ? [31:16] : [15:0]
    volatile uint32_t *A = (volatile uint32_t *)0x100;
    volatile uint32_t *B = (volatile uint32_t *)0x140;
    volatile uint32_t *C = (volatile uint32_t *)0x200;

    // Row-outer, k-inner loop.
    // Each row preloads A[row][0..3] from 2 words (aw01, aw23) — 2 LW total.
    // k loop loads B[k][0..3] from 2 words per k — 8 LW per row, 32 LW total.
    // C written as 2 packed words per row — 8 SW total.
    // All accumulators (c0..c3) are plain int32_t scalars → GCC keeps in
    // registers with -O2; no local array, no stack frame collision with li sp.
    //
    // Memory ops: 8 LW(A) + 32 LW(B) + 8 SW(C) = 48 total.
    unsigned int row, k;
    for (row = 0u; row < 4u; row++) {
        // 2 LW to cover all four A[row][k] elements.
        uint32_t aw01 = A[row * 2u];       /* { A[row][1], A[row][0] } */
        uint32_t aw23 = A[row * 2u + 1u];  /* { A[row][3], A[row][2] } */
        int32_t c0 = 0, c1 = 0, c2 = 0, c3 = 0;

        for (k = 0u; k < 4u; k++) {
            // 2 LW for B[k][0..3].
            uint32_t bw0 = B[k * 2u];
            uint32_t bw1 = B[k * 2u + 1u];
            // Select A[row][k]: k=0,1 come from aw01; k=2,3 from aw23.
            uint32_t aw = (k >> 1u) ? aw23 : aw01;
            int16_t aik = (k & 1u) ? (int16_t)(aw >> 16) : (int16_t)(aw & 0xFFFF);
            c0 += q5_10_mul(aik, (int16_t)(bw0 & 0xFFFF));
            c1 += q5_10_mul(aik, (int16_t)(bw0 >> 16));
            c2 += q5_10_mul(aik, (int16_t)(bw1 & 0xFFFF));
            c3 += q5_10_mul(aik, (int16_t)(bw1 >> 16));
        }

        /* 2 SW: pack and store C[row][0..3] */
        C[row * 2u]      = (((uint32_t)c1 & 0xFFFFu) << 16) | ((uint32_t)c0 & 0xFFFFu);
        C[row * 2u + 1u] = (((uint32_t)c3 & 0xFFFFu) << 16) | ((uint32_t)c2 & 0xFFFFu);
    }

    // Write the completion sentinel.
    // C[0] = packed { C[0][1], C[0][0] } = { 0x0800, 0x0400 } = 0x08000400.
    // Testbench polls dmem[0x000] for any non-zero value.
    {
        uint32_t sentinel = C[0];
        __asm__ volatile ("sw %0, 0(x0)" :: "r"(sentinel) : "memory");
    }

    // Halt.
    while (1) {
        __asm__ volatile ("jal x0, .");
    }
}
