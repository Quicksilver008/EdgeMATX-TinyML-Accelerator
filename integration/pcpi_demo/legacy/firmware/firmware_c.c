typedef unsigned int uint32_t;

#define A_BASE_WORD_ADDR 0x100u
#define B_BASE_WORD_ADDR 0x140u
#define C_BASE_WORD_ADDR 0x200u

static void pcpi_matmul_with_fixed_regs(uint32_t a_base, uint32_t b_base) {
    __asm__ volatile (
        // Preserve ABI-critical registers clobbered by the fixed encoding.
        "mv t0, ra\n"
        "mv t1, sp\n"
        "mv t2, gp\n"
        "mv ra, %0\n"
        "mv sp, %1\n"
        ".word 0x5420818b\n"
        "mv gp, t2\n"
        "mv sp, t1\n"
        "mv ra, t0\n"
        :
        : "r"(a_base), "r"(b_base)
        : "ra", "gp", "t0", "t1", "t2", "memory"
    );
}

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

static void run_program(void) {
    volatile uint32_t *const a_dst = (volatile uint32_t *)A_BASE_WORD_ADDR;
    volatile uint32_t *const b_dst = (volatile uint32_t *)B_BASE_WORD_ADDR;
    volatile uint32_t *const c_src = (volatile uint32_t *)C_BASE_WORD_ADDR;
    unsigned int i;

    for (i = 0; i < 16u; i++) {
        a_dst[i] = a_init[i];
        b_dst[i] = b_init[i];
    }

    pcpi_matmul_with_fixed_regs(A_BASE_WORD_ADDR, B_BASE_WORD_ADDR);

    {
        uint32_t c00 = c_src[0];
        __asm__ volatile ("sw %0, 0(x0)" :: "r"(c00) : "memory");
    }
}

void _start(void) __attribute__((noreturn));
void _start(void) {
    // Keep C runtime self-contained for bare-metal startup.
    __asm__ volatile ("li sp, 0x3f0");
    run_program();
    while (1) {
        __asm__ volatile ("jal x0, .");
    }
}
