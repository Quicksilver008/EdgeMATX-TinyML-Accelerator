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

// Q5.10 fixed-point multiply — binary shift-and-add.
//
// Inlined at every call site so _start has no outgoing calls → GCC generates
// no function prologue → the "li sp" inline-asm at the top of _start runs
// before any stack access.  Binary shift (not radix-4) keeps the inner loop
// to {ua, ub, acc} only — no 2*ua scratch register — so four sequential
// expansions inside the k-loop cannot alias each other's neg flag.
//
// Both inputs signed Q5.10; returns (a × b) >> 10, matching pe_cell_q5_10.v.
static inline __attribute__((always_inline)) int32_t q5_10_mul(int16_t a, int16_t b) {
    int32_t  ia  = (int32_t)a;
    int32_t  ib  = (int32_t)b;
    int32_t  acc = 0;
    int      neg = 0;
    /* Normalise both inputs to non-negative so the shift loop works.
     * Track combined sign and apply at the end. */
    if (ia < 0) { ia = -ia; neg ^= 1; }
    if (ib < 0) { ib = -ib; neg ^= 1; }
    if (ia == 0 || ib == 0) return 0;
    {
        unsigned int ua = (unsigned int)ia;
        unsigned int ub = (unsigned int)ib;
        /* Simple binary shift-and-add; 16 iterations maximum. */
        do {
            if (ub & 1u) acc += (int32_t)ua;
            ua <<= 1;
            ub >>= 1;
        } while (ub);
    }
    if (neg) acc = -acc;
    return acc >> 10;
}

/* Single entry-point.  always_inline on q5_10_mul means _start contains no
 * outgoing calls, so GCC emits no function prologue.  The volatile asm sets
 * sp before any C-generated stack access occurs. */
__attribute__((noreturn, section(".text.startup")))
void _start(void) {
    __asm__ volatile ("li sp, 0x3f8" ::: "memory");
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
