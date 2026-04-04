/*
 * firmware_mlperf_proxy_picorv.c
 *
 * PicoRV32 + PCPI  --  MLCommons Tiny AD proxy benchmark (HW path)
 *
 * Issues N_TILES back-to-back MATMUL_ACCEL (CUSTOM-0) instructions then
 * writes N_TILES as a completion sentinel at address 0 so the testbench
 * can detect completion and measure total cycle count.
 *
 * Memory layout (same as pcpi_demo convention):
 *   A matrix : byte 0x100  (loaded once by copy_inputs)
 *   B matrix : byte 0x140
 *   C matrix : byte 0x200  (written by accelerator each tile; last tile
 *                            result is left there after the loop)
 *   Sentinel : byte 0x000  (written by firmware as N_TILES = 32)
 *
 * PCPI instruction encoding (R-type, custom-0):
 *   opcode = 0x0b  (CUSTOM-0)
 *   funct3 = 0x0
 *   funct7 = 0x2A
 *   rd     = x3   (gp  -- unused return)
 *   rs1    = x1   (ra  -- a_base loaded here before the word)
 *   rs2    = x2   (sp  -- b_base loaded here before the word)
 *   encoding: 0x5420818b
 */

typedef unsigned int uint32_t;

#define N_TILES  32u
#define A_BASE   0x100u   /* byte address */
#define B_BASE   0x140u   /* byte address */

/* ---- Test matrices -------------------------------------------------------
 * A = 4x4 identity in Q5.10  (1.0 = 0x0400)
 * B = 4x4 counting in Q5.10  (1.0 .. 16.0)
 * Expected C = A * B = B  (identity property)
 * C[0][0] = 0x0400
 * ----------------------------------------------------------------------- */
static const uint32_t a_init[16] = {
    0x00000400u, 0x00000000u, 0x00000000u, 0x00000000u,
    0x00000000u, 0x00000400u, 0x00000000u, 0x00000000u,
    0x00000000u, 0x00000000u, 0x00000400u, 0x00000000u,
    0x00000000u, 0x00000000u, 0x00000000u, 0x00000400u
};

static const uint32_t b_init[16] = {
    0x00000400u, 0x00000800u, 0x00000c00u, 0x00001000u,
    0x00001400u, 0x00001800u, 0x00001c00u, 0x00002000u,
    0x00002400u, 0x00002800u, 0x00002c00u, 0x00003000u,
    0x00003400u, 0x00003800u, 0x00003c00u, 0x00004000u
};

/* ---- Write A and B into shared memory once before tiling ---------------- */
static void copy_inputs(void)
{
    volatile uint32_t *const a_dst = (volatile uint32_t *)A_BASE;
    volatile uint32_t *const b_dst = (volatile uint32_t *)B_BASE;
    unsigned int i;
    for (i = 0u; i < 16u; i++) {
        a_dst[i] = a_init[i];
        b_dst[i] = b_init[i];
    }
}

/* ---- Issue one MATMUL_ACCEL PCPI instruction ----------------------------
 * Uses the same fixed-register encoding as pcpi_demo/firmware_matmul_unified.c:
 *   ra (x1) <- a_base
 *   sp (x2) <- b_base
 * Saves/restores ra, sp, gp around the hijack. */
static void pcpi_matmul(uint32_t a_base, uint32_t b_base)
{
    __asm__ volatile (
        "mv  t0, ra\n"          /* save ra (return address) */
        "mv  t1, sp\n"          /* save sp (stack pointer)  */
        "mv  t2, gp\n"          /* save gp (global pointer) */
        "mv  ra, %0\n"          /* ra = a_base              */
        "mv  sp, %1\n"          /* sp = b_base              */
        ".word 0x5420818b\n"    /* MATMUL_ACCEL             */
        "mv  gp, t2\n"          /* restore gp               */
        "mv  sp, t1\n"          /* restore sp               */
        "mv  ra, t0\n"          /* restore ra               */
        :
        : "r"(a_base), "r"(b_base)
        : "ra", "gp", "t0", "t1", "t2", "memory"
    );
}

/* ---- Entry point -------------------------------------------------------- */
void _start(void) __attribute__((noreturn));
void _start(void)
{
    unsigned int tile;

    /* Initialise stack (overrides PicoRV32 STACKADDR parameter). */
    __asm__ volatile ("li sp, 0x3f0");

    copy_inputs();

    for (tile = 0u; tile < N_TILES; tile++) {
        pcpi_matmul(A_BASE, B_BASE);
    }

    /* Write N_TILES as completion sentinel at address 0.
     * The testbench polls this location and measures how many cycles
     * elapsed from reset-release to this write. */
    __asm__ volatile ("sw %0, 0(x0)" :: "r"((uint32_t)N_TILES) : "memory");

    /* Spin forever so the testbench doesn't see a trap. */
    while (1) {
        __asm__ volatile ("jal x0, .");
    }
}
