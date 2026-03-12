`timescale 1ns/1ps

// tb_cycle_benchmark.v
//
// Measures and compares the clock cycles required to compute a 4x4 Q5.10
// matrix multiply via two paths:
//
//   ACCEL PATH  ── rv32_pipeline_pcpi_system with instruction injection.
//                  Matrix A and B pre-loaded into shared memory by the host
//                  (testbench) before reset.  The custom PCPI instruction
//                  causes pcpi_valid to assert; the CPU stalls until
//                  pcpi_ready.  We count those stall cycles.
//
//   SW PATH     ── rv32_pipeline_top (bare, no PCPI wrapper) runs
//                  firmware_sw_bench.hex which executes the matmul entirely
//                  in software (rv32i: no MUL instruction, __mulsi3 from
//                  libgcc).  Matrix A and B are pre-loaded into dmem[64..71]
//                  (A, packed) and dmem[80..87] (B, packed) by the testbench.  We count
//                  clock cycles from rst release until the completion sentinel
//                  appears at dmem[0].
//
// Test vectors (identity × counting = B, result is B):
//   A = diag(1.0, 1.0, 1.0, 1.0) in Q5.10  →  element = 0x0400
//   B[r][c] = (r*4+c+1).0 in Q5.10         →  elements 0x0400..0x4000
//   Expected C = B  →  C[0][0] = 0x0400 = 1024 decimal
//
// The hex file path below is relative to where vvp is executed.
// Run with: cd RISC-V/pipeline_top && vvp cycle_bench.vvp (or use run_benchmark.ps1)
//
// Output example:
//   CYCLE_BENCH [ACCEL] pcpi_valid→pcpi_ready  : 62 cycles
//   CYCLE_BENCH [SW]    rst→sentinel            : 1247 cycles
//   CYCLE_BENCH [SPEEDUP]                       : 20.1x

module tb_cycle_benchmark;

    // ──────────────────────────────────────────────────────────────────────
    // Shared 10 ns clock (100 MHz)
    // ──────────────────────────────────────────────────────────────────────
    reg clk;
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ──────────────────────────────────────────────────────────────────────
    // Instruction encodings (injected via ext_instr_word in ACCEL run)
    // ──────────────────────────────────────────────────────────────────────
    localparam [31:0] NOP           = 32'h00000013;  // ADDI x0, x0, 0
    localparam [31:0] ADDI_X1_256  = 32'h10000093;  // ADDI x1, x0, 256 (A_BASE)
    localparam [31:0] ADDI_X2_320  = 32'h14000113;  // ADDI x2, x0, 320 (B_BASE)
    // funct7=0101010 rs2=x2 rs1=x1 funct3=000 rd=x3 opcode=0001011
    localparam [31:0] CUSTOM_MATMUL = 32'h5420818B;

    // ──────────────────────────────────────────────────────────────────────
    // Test matrix data (identity A × counting B → expected C = B)
    // Each 32-bit word: [31:16]=0, [15:0]=Q5.10 element
    // Word index i maps to row=i/4, col=i%4
    // ──────────────────────────────────────────────────────────────────────
    reg [31:0] A_data [0:15];
    reg [31:0] B_data [0:15];

    integer i;
    integer accel_cycles;
    integer sw_cycles;
    integer guard;

    // ══════════════════════════════════════════════════════════════════════
    // ACCEL DUT  ─  rv32_pipeline_pcpi_system
    // ══════════════════════════════════════════════════════════════════════
    reg        rst_a;
    reg [31:0] ext_instr_word_a;
    reg        ext_instr_valid_a;
    reg        host_mem_we_a;
    reg [31:0] host_mem_addr_a;
    reg [31:0] host_mem_wdata_a;

    wire [31:0] host_mem_rdata_a;
    wire [31:0] dbg_pc_if_a;
    wire [31:0] dbg_instr_if_a;
    wire [31:0] dbg_instr_id_a;
    wire        dbg_stall_a;
    wire        dbg_custom_inflight_a;
    wire        dbg_wb_regwrite_a;
    wire [4:0]  dbg_wb_rd_a;
    wire [31:0] dbg_wb_data_a;
    wire [255:0] mat_c_flat_a;
    wire         dbg_accel_done_a;

    rv32_pipeline_pcpi_system u_accel (
        .clk             (clk),
        .rst             (rst_a),
        .ext_instr_word  (ext_instr_word_a),
        .ext_instr_valid (ext_instr_valid_a),
        .use_ext_instr   (1'b1),
        .host_mem_we     (host_mem_we_a),
        .host_mem_addr   (host_mem_addr_a),
        .host_mem_wdata  (host_mem_wdata_a),
        .host_mem_rdata  (host_mem_rdata_a),
        .dbg_pc_if           (dbg_pc_if_a),
        .dbg_instr_if        (dbg_instr_if_a),
        .dbg_instr_id        (dbg_instr_id_a),
        .dbg_stall           (dbg_stall_a),
        .dbg_custom_inflight (dbg_custom_inflight_a),
        .dbg_wb_regwrite     (dbg_wb_regwrite_a),
        .dbg_wb_rd           (dbg_wb_rd_a),
        .dbg_wb_data         (dbg_wb_data_a),
        .mat_c_flat      (mat_c_flat_a),
        .dbg_accel_done  (dbg_accel_done_a)
    );

    // ══════════════════════════════════════════════════════════════════════
    // SW DUT  ─  rv32_pipeline_top (bare, no PCPI wrapper)
    // ══════════════════════════════════════════════════════════════════════
    reg        rst_sw;
    wire [31:0] dbg_pc_if_sw;
    wire [31:0] dbg_instr_if_sw;
    wire [31:0] dbg_instr_id_sw;
    wire        dbg_stall_sw;
    wire        dbg_custom_inflight_sw;
    wire        dbg_wb_regwrite_sw;
    wire [4:0]  dbg_wb_rd_sw;
    wire [31:0] dbg_wb_data_sw;

    // IMEM_FILE param is not used — firmware is loaded manually after reset (see SW RUN section)
    rv32_pipeline_top u_sw (
        .clk             (clk),
        .rst             (rst_sw),
        .ext_instr_word  (32'h00000013),
        .ext_instr_valid (1'b0),
        .use_ext_instr   (1'b0),
        // PCPI inputs tied off — no co-processor in SW run
        .pcpi_wait       (1'b0),
        .pcpi_ready      (1'b0),
        .pcpi_wr         (1'b0),
        .pcpi_rd         (32'd0),
        .dbg_pc_if           (dbg_pc_if_sw),
        .dbg_instr_if        (dbg_instr_if_sw),
        .dbg_instr_id        (dbg_instr_id_sw),
        .dbg_stall           (dbg_stall_sw),
        .dbg_custom_inflight (dbg_custom_inflight_sw),
        .dbg_wb_regwrite     (dbg_wb_regwrite_sw),
        .dbg_wb_rd           (dbg_wb_rd_sw),
        .dbg_wb_data         (dbg_wb_data_sw)
    );

    // ──────────────────────────────────────────────────────────────────────
    // Helper: write one word into u_accel's shared memory via host_mem_we
    // ──────────────────────────────────────────────────────────────────────
    task host_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            host_mem_addr_a  <= addr;
            host_mem_wdata_a <= data;
            host_mem_we_a    <= 1'b1;
            @(posedge clk);
            host_mem_we_a    <= 1'b0;
        end
    endtask

    // ──────────────────────────────────────────────────────────────────────
    // Helper: inject one instruction into u_accel's CPU
    // ──────────────────────────────────────────────────────────────────────
    task inject;
        input [31:0] instr;
        begin
            @(posedge clk);
            ext_instr_word_a  <= instr;
            ext_instr_valid_a <= 1'b1;
            @(posedge clk);
            ext_instr_valid_a <= 1'b0;
        end
    endtask

    // ══════════════════════════════════════════════════════════════════════
    // Main stimulus
    // ══════════════════════════════════════════════════════════════════════
    initial begin
        // ── Initialise test vectors ─────────────────────────────────────
        // A = identity matrix in Q5.10 (1.0 = 0x0400)
        A_data[ 0]=32'h00000400; A_data[ 1]=32'h00000000; A_data[ 2]=32'h00000000; A_data[ 3]=32'h00000000;
        A_data[ 4]=32'h00000000; A_data[ 5]=32'h00000400; A_data[ 6]=32'h00000000; A_data[ 7]=32'h00000000;
        A_data[ 8]=32'h00000000; A_data[ 9]=32'h00000000; A_data[10]=32'h00000400; A_data[11]=32'h00000000;
        A_data[12]=32'h00000000; A_data[13]=32'h00000000; A_data[14]=32'h00000000; A_data[15]=32'h00000400;
        // B = counting matrix: B[r][c] = (r*4+c+1).0
        B_data[ 0]=32'h00000400; B_data[ 1]=32'h00000800; B_data[ 2]=32'h00000c00; B_data[ 3]=32'h00001000;
        B_data[ 4]=32'h00001400; B_data[ 5]=32'h00001800; B_data[ 6]=32'h00001c00; B_data[ 7]=32'h00002000;
        B_data[ 8]=32'h00002400; B_data[ 9]=32'h00002800; B_data[10]=32'h00002c00; B_data[11]=32'h00003000;
        B_data[12]=32'h00003400; B_data[13]=32'h00003800; B_data[14]=32'h00003c00; B_data[15]=32'h00004000;

        // Initialise
        rst_a             = 1'b0;
        rst_sw            = 1'b0;
        ext_instr_word_a  = NOP;
        ext_instr_valid_a = 1'b0;
        host_mem_we_a     = 1'b0;
        host_mem_addr_a   = 32'd0;
        host_mem_wdata_a  = 32'd0;
        accel_cycles      = 0;
        sw_cycles         = 0;

        // ─────────────────────────────────────────────────────────────────
        // ACCEL RUN
        // ─────────────────────────────────────────────────────────────────
        // 1. Bring up reset first so shared memory writes are enabled
        //    (the memory write always-block is gated by `if (rst)`).
        repeat(4) @(posedge clk);
        rst_a = 1'b1;
        repeat(2) @(posedge clk);

        // 2. Pre-load A and B into shared memory via host_mem_we
        //    (rst_a=1 so the memory write gate is open).
        //    Packed layout: 2 Q5.10 elements per 32-bit word.
        //    word[i] = { elem[i*2+1][15:0], elem[i*2][15:0] }
        for (i = 0; i < 8; i = i + 1)
            host_write(32'h100 + (i << 2), {A_data[i*2+1][15:0], A_data[i*2][15:0]});
        for (i = 0; i < 8; i = i + 1)
            host_write(32'h140 + (i << 2), {B_data[i*2+1][15:0], B_data[i*2][15:0]});

        // 4. Inject: ADDI x1=A_BASE, ADDI x2=B_BASE, 5 NOPs, CUSTOM
        inject(ADDI_X1_256);
        inject(ADDI_X2_320);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(CUSTOM_MATMUL);  // pcpi_valid will assert one cycle later
        inject(NOP);
        inject(NOP);

        // 4. Count cycles: start on pcpi_valid, stop on dbg_accel_done
        //
        // IMPORTANT: dbg_accel_done = pcpi_ready which is a ONE-cycle pulse.
        // We must check every single posedge (no double-advance) to avoid
        // missing the window due to a parity mismatch.
        guard = 0;
        // Wait for pcpi_valid to assert (single-posedge loop — safe to check every cycle)
        while (!dbg_custom_inflight_a) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 200) begin
                $display("CYCLE_BENCH [ERROR] ACCEL pcpi_valid never asserted");
                $finish;
            end
        end
        // Count stall cycles.  Each @(posedge clk) advances exactly one clock so
        // we cannot miss the single-cycle pcpi_ready pulse.
        guard = 0;
        accel_cycles = 0;
        while (!dbg_accel_done_a) begin
            @(posedge clk);
            accel_cycles = accel_cycles + 1;
            guard = guard + 1;
            if (guard > 200) begin
                $display("CYCLE_BENCH [ERROR] ACCEL timeout: pcpi_ready never pulsed");
                $finish;
            end
        end
        // Verify C[0][0] == 0x0400 (1.0 × 1.0 = 1.0 in Q5.10)
        begin : accel_check
            reg [31:0] got;
            @(posedge clk); // let shared memory settle
            got = u_accel.mem[32'h200 >> 2];
            if (got[15:0] === 16'h0400)
                $display("CYCLE_BENCH [ACCEL] C[0][0] check PASS (got 0x%04h)", got[15:0]);
            else
                $display("CYCLE_BENCH [ACCEL] C[0][0] check FAIL (got 0x%04h, exp 0x0400)", got[15:0]);
        end

        // ─────────────────────────────────────────────────────────────────
        // SW RUN
        // ─────────────────────────────────────────────────────────────────
        // 1. Load firmware via local buffer then copy to u_sw.imem[]
        //    (Direct hierarchical $readmemh into a parameterised instance's
        //     reg array is unreliable in Icarus Verilog.  Use a local buffer
        //     and copy word-by-word to guarantee correct loading.)
        begin : fw_load
            reg [31:0] fw_buf [0:255];
            $readmemh("firmware/firmware_sw_bench.hex", fw_buf);
            for (i = 0; i < 256; i = i + 1)
                u_sw.imem[i] = fw_buf[i];
        end
        if (u_sw.imem[0] === 32'bx) begin
            $display("CYCLE_BENCH [ERROR] imem[0] still X after manual load");
            $finish;
        end

        // 2. Pre-load A and B directly into u_sw's data memory.
        //    byte_addr >> 2 gives word index into dmem.MEM[].
        //    A_BASE = 0x100 → word 64 (packed, 8 words); B_BASE = 0x140 → word 80 (8 words).
        //    Packing: word[i] = { elem[i*2+1][15:0], elem[i*2][15:0] }.
        for (i = 0; i < 8; i = i + 1) begin
            u_sw.dmem.MEM[64 + i] = {A_data[i*2+1][15:0], A_data[i*2][15:0]};
            u_sw.dmem.MEM[80 + i] = {B_data[i*2+1][15:0], B_data[i*2][15:0]};
        end
        // Zero the sentinel so we get a clean start signal
        u_sw.dmem.MEM[0] = 32'd0;

        // 3. Release reset
        repeat(4) @(posedge clk);
        rst_sw = 1'b1;

        // 4. Count cycles until sentinel written (dmem[0] != 0)
        guard = 0;
        while (u_sw.dmem.MEM[0] === 32'd0) begin
            @(posedge clk);
            sw_cycles = sw_cycles + 1;
            guard = guard + 1;
            if (guard > 20000) begin
                $display("CYCLE_BENCH [ERROR] SW timeout -- sentinel never appeared  PC=%0h",
                    u_sw.dbg_pc_if);
                $finish;
            end
        end

        // Verify all 8 packed C words — dmem words 128..135 (byte 0x200..0x21C)
        // A=identity, B=counting  → C=B, so C_word[i] = {B[i*2+1][15:0], B[i*2][15:0]}
        begin : sw_check
            reg [31:0] exp_words [0:7];
            reg [31:0] got;
            integer wi, sw_fails;
            exp_words[0] = 32'h08000400; // {B[1],B[0]}
            exp_words[1] = 32'h10000c00; // {B[3],B[2]}
            exp_words[2] = 32'h18001400; // {B[5],B[4]}
            exp_words[3] = 32'h20001c00; // {B[7],B[6]}
            exp_words[4] = 32'h28002400; // {B[9],B[8]}
            exp_words[5] = 32'h30002c00; // {B[11],B[10]}
            exp_words[6] = 32'h38003400; // {B[13],B[12]}
            exp_words[7] = 32'h40003c00; // {B[15],B[14]}
            sw_fails = 0;
            for (wi = 0; wi < 8; wi = wi + 1) begin
                got = u_sw.dmem.MEM[128 + wi];
                if (got !== exp_words[wi]) begin
                    $display("CYCLE_BENCH [SW]    C word[%0d] FAIL (got 0x%08h, exp 0x%08h)",
                             wi, got, exp_words[wi]);
                    sw_fails = sw_fails + 1;
                end
            end
            if (sw_fails == 0)
                $display("CYCLE_BENCH [SW]    C matrix check PASS (all 8 words)");
        end

        // ─────────────────────────────────────────────────────────────────
        // Summary
        // ─────────────────────────────────────────────────────────────────
        $display("");
        $display("======================================================");
        $display("  4x4 Q5.10 MatMul -- Cycle Benchmark (rv32_pipeline)  ");
        $display("======================================================");
        $display("  ACCEL (pcpi_valid -> pcpi_ready)  : %0d cycles", accel_cycles);
        $display("  SW    (rst -> dmem sentinel)      : %0d cycles", sw_cycles);
        $display("------------------------------------------------------");
        if (accel_cycles > 0)
            $display("  Speedup (SW/ACCEL)               : %0d.%01dx",
                sw_cycles / accel_cycles,
                (sw_cycles * 10 / accel_cycles) % 10);
        $display("======================================================");
        $display("");
        $display("Notes:");
        $display("  ACCEL breakdown: 8 mem-reads(A) + 8 mem-reads(B) +");
        $display("    ~12-cycle systolic compute + 8 mem-writes(C)  [2 Q5.10 elems/word]");
        $display("  SW uses packed 2-elem/word, row-outer loop (8 LW A, 32 LW B, 8 SW C = 48 total);");
        $display("  multiply via inline q5_10_mul (shift-and-add, no __mulsi3 call).");
        $display("");
        $finish;
    end

    // Safety timeout
    initial begin
        #5000000;
        $display("CYCLE_BENCH [ERROR] Global simulation timeout");
        $finish;
    end

    initial begin
        $dumpfile("tb_cycle_benchmark.vcd");
        $dumpvars(0, tb_cycle_benchmark);
    end

endmodule
