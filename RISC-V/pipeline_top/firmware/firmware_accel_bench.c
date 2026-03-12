// firmware_accel_bench.c
//
// Hardware-accelerator firmware benchmark for rv32_pipeline_top + PCPI.
//
// The CPU executes a single custom R-type instruction (CUSTOM-0 opcode) which
// is intercepted by pcpi_tinyml_accel.v.  The PCPI wrapper stalls the CPU
// via pcpi_wait, loads matrices A and B from dmem, fires the 4x4 Q5.10
// systolic array, writes result C back to dmem, then releases the stall via
// pcpi_ready.  The CPU resumes as if the instruction took one "long" cycle.
//
// Custom instruction encoding (R-type):
//   opcode [6:0]  = 0b0001011  (CUSTOM-0 = 0x0b)
//   rd     [11:7] = x0         (result discarded; C written directly to dmem)
//   funct3 [14:12]= 0b000
//   rs1    [19:15]= reg with base address of A  (0x100 = dmem byte addr)
//   rs2    [24:20]= reg with base address of B  (0x140 = dmem byte addr)
//   funct7 [31:25]= 0b0101010  (0x2A)
//
// The GAS ".insn r" directive assembles this directly:
//   .insn r OPCODE, FUNCT3, FUNCT7, RD, RS1, RS2
//
// Memory layout (dmem byte addresses):
//   0x000          completion sentinel  (written by this firmware after matmul)
//   0x100 - 0x11F  Matrix A (8 packed words, 2 Q5.10 elems per word)
//   0x140 - 0x15F  Matrix B (8 packed words, 2 Q5.10 elems per word)
//   0x200 - 0x21F  Matrix C (8 packed words, written by PCPI accelerator)
//   0x3F8          initial stack pointer
//
// The testbench pre-loads A and B before releasing reset (same convention as
// fw_sw_bench).  This firmware just fires the instruction and writes the
// sentinel so the testbench knows the accelerator is done.
//
// Cycle budget (measured from CPU issuing the instruction to pcpi_ready):
//   8 mem-reads(A) + 8 mem-reads(B) + ~10 systolic cycles + 8 mem-writes(C)
//   + FSM overhead = ~37 PCPI cycles.
//   Add ~5 CPU setup cycles + ~5 readback cycles -> total ~47 firmware cycles.

typedef   signed int   int32_t;
typedef unsigned int   uint32_t;

// Macro: issue the CUSTOM-0 matmul instruction.
//   rs1 = byte address of matrix A in dmem
//   rs2 = byte address of matrix B in dmem
// The CPU stalls until the accelerator finishes; after this line C is ready.
#define MATMUL_ACCEL(addr_a, addr_b)                                    \
    __asm__ volatile (                                                    \
        ".insn r 0x0b, 0, 0x2a, x0, %0, %1"                             \
        :                                                                  \
        : "r"((uint32_t)(addr_a)), "r"((uint32_t)(addr_b))               \
        : "memory"                                                         \
    )

void _start(void) __attribute__((noreturn));
void _start(void) {
    // Set stack pointer before any local variable use.
    __asm__ volatile ("li sp, 0x3f8");

    // Base addresses of matrices in data memory (byte addresses).
    uint32_t addr_a = 0x100u;
    uint32_t addr_b = 0x140u;

    // Fire the hardware accelerator.
    // CPU stalls here for ~37 cycles while pcpi_tinyml_accel.v:
    //   1. Reads 8 packed words from dmem[A]
    //   2. Reads 8 packed words from dmem[B]
    //   3. Runs the 4x4 Q5.10 systolic array
    //   4. Writes 8 packed words to dmem[0x200..0x21F]
    // Then pcpi_ready is asserted and the CPU resumes here.
    MATMUL_ACCEL(addr_a, addr_b);

    // C[0] is now at dmem[0x200] = packed {C[0][1], C[0][0]}.
    // Write it as the completion sentinel so the testbench knows we are done.
    volatile uint32_t *C = (volatile uint32_t *)0x200u;
    uint32_t sentinel = C[0];
    __asm__ volatile ("sw %0, 0(x0)" :: "r"(sentinel) : "memory");

    // Halt.
    while (1) {
        __asm__ volatile ("jal x0, .");
    }
}
