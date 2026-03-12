`timescale 1ns/1ps

// rv32_pipeline_pcpi_system
//
// Top-level system that wires the 5-stage pipelined RV32I core
// (rv32_pipeline_top) to the pcpi_tinyml_accel PCPI coprocessor wrapper,
// sharing a single on-chip memory array.
//
// Architecture
// ------------
// The CPU uses ext_instr_word injection for firmware delivery (use_ext_instr=1).
// The testbench pre-loads matrices A and B into shared memory via the
// host_mem_we preload interface, then injects firmware that issues the
// custom matmul instruction.  The PCPI wrapper handles all memory
// reads/writes independently of the CPU data memory path.
//
// Memory layout (byte addresses, MEM_WORDS=256 => 1 KB):
//   0x000 - 0x0FF  general purpose (desc, scratch)
//   0x100 - 0x13F  Matrix A   (16 x Q5.10, one element per 32-bit word)
//   0x140 - 0x17F  Matrix B   (16 x Q5.10, one element per 32-bit word)
//   0x200 - 0x23F  Matrix C   (16 x Q5.10, written by PCPI wrapper)
//
// Firmware instruction sequence (injected via ext_instr_word):
//   ADDI x1, x0, 0x100    ; rs1 = byte base of A
//   ADDI x2, x0, 0x140    ; rs2 = byte base of B
//   <NOPs to flush pipeline>
//   CUSTOM (rs1=x1,rs2=x2,rd=x3)  ; fires matmul over PCPI
//   <NOPs>
//
// Reset polarity:
//   Both rv32_pipeline_top and pcpi_tinyml_accel use the convention
//   "0 = reset, 1 = run" (rst / resetn).  Direct connection is correct.

module rv32_pipeline_pcpi_system #(
    parameter MEM_WORDS = 256   // shared memory depth in 32-bit words (1 KB)
) (
    input  wire        clk,
    input  wire        rst,              // 0 = reset, 1 = running

    // External instruction injection (CPU runs with use_ext_instr=1)
    input  wire [31:0] ext_instr_word,
    input  wire        ext_instr_valid,
    input  wire        use_ext_instr,

    // Host memory preload / readback (testbench side)
    input  wire        host_mem_we,
    input  wire [31:0] host_mem_addr,   // byte address, must be word-aligned
    input  wire [31:0] host_mem_wdata,
    output wire [31:0] host_mem_rdata,

    // Debug
    output wire [31:0] dbg_pc_if,
    output wire [31:0] dbg_instr_if,
    output wire [31:0] dbg_instr_id,
    output wire        dbg_stall,
    output wire        dbg_custom_inflight,
    output wire        dbg_wb_regwrite,
    output wire [4:0]  dbg_wb_rd,
    output wire [31:0] dbg_wb_data,

    // Result
    // C matrix elements packed as Q5.10 half-words (row-major, elem i at [i*16+:16])
    output wire [255:0] mat_c_flat,
    // One-cycle pulse when the PCPI wrapper signals completion (pcpi_ready)
    output wire         dbg_accel_done
);

    // -----------------------------------------------------------------------
    // Shared memory (word-addressed, 32-bit words)
    // -----------------------------------------------------------------------
    reg [31:0] mem [0:MEM_WORDS-1];

    // Host combinatorial read
    assign host_mem_rdata = mem[host_mem_addr[31:2]];

    // C matrix starts at byte 0x200 (hardcoded in pcpi_tinyml_accel)
    localparam integer C_WORD_BASE = 32'h200 >> 2;   // = 128

    // Expose C as a flat 256-bit wire.
    // Packed memory layout: 2 Q5.10 elements per 32-bit word.
    //   mem[C_WORD_BASE + pair] = {C_odd[15:0], C_even[15:0]}
    //   element linear index e = row*4+col → pair = e/2, half = e%2
    reg [255:0] mat_c_flat_r;
    integer c_i;
    always @(*) begin
        for (c_i = 0; c_i < 16; c_i = c_i + 1) begin
            if (c_i[0] == 1'b0)
                mat_c_flat_r[c_i*16 +: 16] = mem[C_WORD_BASE + c_i/2][15:0];  // even elem → lo half
            else
                mat_c_flat_r[c_i*16 +: 16] = mem[C_WORD_BASE + c_i/2][31:16]; // odd  elem → hi half
        end
    end
    assign mat_c_flat = mat_c_flat_r;

    // -----------------------------------------------------------------------
    // PCPI interconnect wires
    // -----------------------------------------------------------------------
    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire        pcpi_wait;
    wire        pcpi_ready;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;

    // -----------------------------------------------------------------------
    // Memory bus from PCPI wrapper to shared memory
    //
    // Zero-cycle ready model (combinatorial):
    //   accel_mem_ready = accel_mem_valid  (no extra pipeline stage)
    //   accel_mem_rdata = mem[addr>>2]     (combinatorial)
    // This gives one memory transaction per clock cycle in the PCPI FSM.
    // -----------------------------------------------------------------------
    wire        accel_mem_valid;
    wire        accel_mem_we_sig;
    wire [31:0] accel_mem_addr;
    wire [31:0] accel_mem_wdata;

    // Combinatorial read
    reg  [31:0] accel_mem_rdata;
    always @(*) begin
        accel_mem_rdata = mem[accel_mem_addr[31:2]];
    end

    // Zero-cycle ready: wrapper gets immediate acknowledgement
    wire accel_mem_ready;
    assign accel_mem_ready = accel_mem_valid;

    // Synchronous write (host preload has priority on same-address conflicts)
    always @(posedge clk) begin
        if (rst) begin
            if (accel_mem_valid && accel_mem_we_sig)
                mem[accel_mem_addr[31:2]] <= accel_mem_wdata;
            if (host_mem_we)
                mem[host_mem_addr[31:2]] <= host_mem_wdata;
        end
    end

    // -----------------------------------------------------------------------
    // CPU instance
    // -----------------------------------------------------------------------
    rv32_pipeline_top cpu (
        .clk             (clk),
        .rst             (rst),
        .ext_instr_word  (ext_instr_word),
        .ext_instr_valid (ext_instr_valid),
        .use_ext_instr   (use_ext_instr),
        .pcpi_valid      (pcpi_valid),
        .pcpi_insn       (pcpi_insn),
        .pcpi_rs1        (pcpi_rs1),
        .pcpi_rs2        (pcpi_rs2),
        .pcpi_wait       (pcpi_wait),
        .pcpi_ready      (pcpi_ready),
        .pcpi_wr         (pcpi_wr),
        .pcpi_rd         (pcpi_rd),
        .dbg_pc_if           (dbg_pc_if),
        .dbg_instr_if        (dbg_instr_if),
        .dbg_instr_id        (dbg_instr_id),
        .dbg_stall           (dbg_stall),
        .dbg_custom_inflight (dbg_custom_inflight),
        .dbg_wb_regwrite     (dbg_wb_regwrite),
        .dbg_wb_rd           (dbg_wb_rd),
        .dbg_wb_data         (dbg_wb_data)
    );

    // -----------------------------------------------------------------------
    // PCPI coprocessor wrapper
    // (same module as integration/pcpi_demo/rtl/pcpi_tinyml_accel.v)
    //
    // Reset note: resetn=0 means reset, resetn=1 means run — same polarity
    // as rv32_pipeline_top's rst signal. Direct connection is correct.
    // -----------------------------------------------------------------------
    pcpi_tinyml_accel wrapper (
        .clk             (clk),
        .resetn          (rst),
        .pcpi_valid      (pcpi_valid),
        .pcpi_insn       (pcpi_insn),
        .pcpi_rs1        (pcpi_rs1),
        .pcpi_rs2        (pcpi_rs2),
        .pcpi_wr         (pcpi_wr),
        .pcpi_rd         (pcpi_rd),
        .pcpi_wait       (pcpi_wait),
        .pcpi_ready      (pcpi_ready),
        .accel_mem_valid (accel_mem_valid),
        .accel_mem_we    (accel_mem_we_sig),
        .accel_mem_addr  (accel_mem_addr),
        .accel_mem_wdata (accel_mem_wdata),
        .accel_mem_rdata (accel_mem_rdata),
        .accel_mem_ready (accel_mem_ready)
    );

    // pcpi_ready pulses for one cycle when the wrapper finishes and the CPU
    // is about to deassert pcpi_valid.
    assign dbg_accel_done = pcpi_ready;

endmodule
