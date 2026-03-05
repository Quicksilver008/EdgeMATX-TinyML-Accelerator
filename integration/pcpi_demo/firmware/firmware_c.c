typedef unsigned int uint32_t;

#define A_BASE_WORD_ADDR 0x100u
#define B_BASE_WORD_ADDR 0x140u
#define C_BASE_WORD_ADDR 0x200u

// custom-0 matmul with funct7=0101010, funct3=000, rd=x3, rs1=x1, rs2=x2
#define PCPI_MATMUL_X3_X1_X2() __asm__ volatile (".word 0x5420818b")

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

    __asm__ volatile (
        "addi x1, x0, 0x100\n"
        "addi x2, x0, 0x140\n"
    );
    PCPI_MATMUL_X3_X1_X2();

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
