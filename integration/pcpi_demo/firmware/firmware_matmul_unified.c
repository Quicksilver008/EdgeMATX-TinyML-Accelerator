typedef unsigned int uint32_t;
typedef signed int int32_t;
typedef signed short int16_t;

#ifndef A_BASE_WORD_ADDR
#define A_BASE_WORD_ADDR 0x100u
#endif

#ifndef B_BASE_WORD_ADDR
#define B_BASE_WORD_ADDR 0x140u
#endif

#ifndef C_BASE_WORD_ADDR
#define C_BASE_WORD_ADDR 0x200u
#endif

#ifndef MATMUL_MODE_ACCEL
#define MATMUL_MODE_ACCEL 1
#endif

#ifndef MATMUL_MODE_SW
#define MATMUL_MODE_SW 0
#endif

#if ((MATMUL_MODE_ACCEL + MATMUL_MODE_SW) != 1)
#error "Exactly one mode must be enabled: MATMUL_MODE_ACCEL or MATMUL_MODE_SW."
#endif

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

static void copy_inputs(void) {
    volatile uint32_t *const a_dst = (volatile uint32_t *)A_BASE_WORD_ADDR;
    volatile uint32_t *const b_dst = (volatile uint32_t *)B_BASE_WORD_ADDR;
    unsigned int i;
    for (i = 0; i < 16u; i++) {
        a_dst[i] = a_init[i];
        b_dst[i] = b_init[i];
    }
}

#if MATMUL_MODE_ACCEL
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

static void run_matmul(void) {
    pcpi_matmul_with_fixed_regs(A_BASE_WORD_ADDR, B_BASE_WORD_ADDR);
}
#endif

#if MATMUL_MODE_SW
static void run_matmul(void) {
    volatile uint32_t *const a_dst = (volatile uint32_t *)A_BASE_WORD_ADDR;
    volatile uint32_t *const b_dst = (volatile uint32_t *)B_BASE_WORD_ADDR;
    volatile uint32_t *const c_dst = (volatile uint32_t *)C_BASE_WORD_ADDR;
    volatile uint32_t *a_row;
    volatile uint32_t *c_row;
    volatile uint32_t *b_col;
    volatile uint32_t *a_ptr;
    volatile uint32_t *b_ptr;
    unsigned int row;
    unsigned int col;
    unsigned int dot;

    a_row = a_dst;
    c_row = c_dst;
    for (row = 0; row < 4u; row++) {
        b_col = b_dst;
        for (col = 0; col < 4u; col++) {
            int32_t acc = 0;
            a_ptr = a_row;
            b_ptr = b_col;
            for (dot = 0; dot < 4u; dot++) {
                int16_t a_elem = (int16_t)(*a_ptr);
                int16_t b_elem = (int16_t)(*b_ptr);
                acc += ((int32_t)a_elem * (int32_t)b_elem) >> 10;
                a_ptr++;
                b_ptr += 4;
            }
            c_row[col] = (uint32_t)(int32_t)(int16_t)acc;
            b_col++;
        }
        a_row += 4;
        c_row += 4;
    }
}
#endif

static void run_program(void) {
    volatile uint32_t *const c_src = (volatile uint32_t *)C_BASE_WORD_ADDR;
    uint32_t c00;

    copy_inputs();
    run_matmul();

    c00 = c_src[0];
    __asm__ volatile ("sw %0, 0(x0)" :: "r"(c00) : "memory");
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
