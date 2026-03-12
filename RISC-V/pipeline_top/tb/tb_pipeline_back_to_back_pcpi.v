`timescale 1ns/1ps
// tb_pipeline_back_to_back_pcpi.v
//
// Verifies that the rv32_pipeline + pcpi_tinyml_accel can handle two
// CUSTOM_MATMUL instructions issued back-to-back with one intervening ADDI.
// Mirrors the picorv handoff test structure.
//
// Run 1: A = 4x4 identity (Q5.10), B = counting matrix (Q5.10 values 1..16)
//        Expected C = B  (identity × B = B)
//        All 16 C elements verified via mat_c_flat port.
//
// Run 2: A = all-ones matrix (1.0 each), B = 4x4 identity (Q5.10)
//        Expected C = A  (A × I = A, all elements = 1.0 = 0x0400)
//        All 16 C elements verified.
//
// Memory layout (packed 2-elem/word):
//   A words: byte 0x100 + pair*4   (pair 0..7)
//   B words: byte 0x140 + pair*4   (pair 0..7)
//   C words: byte 0x200 + pair*4   (written by PCPI wrapper)
//
// Firmware injection sequence (per run):
//   ADDI x1, x0, 0x100  |  ADDI x2, x0, 0x140  |  NOP×5  |  CUSTOM_MATMUL

module tb_pipeline_back_to_back_pcpi;

    localparam integer N = 4;

    // Instruction encodings
    localparam [31:0] NOP           = 32'h00000013;
    localparam [31:0] ADDI_X1_256   = 32'h10000093; // ADDI x1, x0, 0x100  (A base)
    localparam [31:0] ADDI_X2_320   = 32'h14000113; // ADDI x2, x0, 0x140  (B base)
    localparam [31:0] ADDI_X10_0    = 32'h00000513; // ADDI x10, x0, 0  (intermediate)
    // funct7=0101010 rs2=x2 rs1=x1 funct3=000 rd=x3 opcode=0001011
    localparam [31:0] CUSTOM_MATMUL = 32'h5420818B;

    localparam [31:0] A_BASE = 32'h0000_0100;
    localparam [31:0] B_BASE = 32'h0000_0140;

    // Q5.10 constants
    localparam [15:0] Q_1P0 = 16'h0400; // 1.0
    localparam [15:0] Q_0   = 16'h0000;

    // ── DUT signals ──────────────────────────────────────────────────────
    reg        clk, rst;
    reg [31:0] ext_instr_word;
    reg        ext_instr_valid, use_ext_instr;
    reg        host_mem_we;
    reg [31:0] host_mem_addr, host_mem_wdata;

    wire [31:0]  host_mem_rdata;
    wire [31:0]  dbg_pc_if, dbg_instr_if, dbg_instr_id, dbg_wb_data;
    wire         dbg_stall, dbg_custom_inflight, dbg_wb_regwrite;
    wire [4:0]   dbg_wb_rd;
    wire [255:0] mat_c_flat;
    wire         dbg_accel_done;

    // ── DUT ───────────────────────────────────────────────────────────────
    rv32_pipeline_pcpi_system dut (
        .clk              (clk),
        .rst              (rst),
        .ext_instr_word   (ext_instr_word),
        .ext_instr_valid  (ext_instr_valid),
        .use_ext_instr    (use_ext_instr),
        .host_mem_we      (host_mem_we),
        .host_mem_addr    (host_mem_addr),
        .host_mem_wdata   (host_mem_wdata),
        .host_mem_rdata   (host_mem_rdata),
        .dbg_pc_if        (dbg_pc_if),
        .dbg_instr_if     (dbg_instr_if),
        .dbg_instr_id     (dbg_instr_id),
        .dbg_stall        (dbg_stall),
        .dbg_custom_inflight (dbg_custom_inflight),
        .dbg_wb_regwrite  (dbg_wb_regwrite),
        .dbg_wb_rd        (dbg_wb_rd),
        .dbg_wb_data      (dbg_wb_data),
        .mat_c_flat       (mat_c_flat),
        .dbg_accel_done   (dbg_accel_done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ── Helpers ───────────────────────────────────────────────────────────

    task automatic host_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            host_mem_addr  <= addr;
            host_mem_wdata <= data;
            host_mem_we    <= 1'b1;
            @(posedge clk);
            host_mem_we    <= 1'b0;
        end
    endtask

    task automatic inject;
        input [31:0] instr;
        begin
            @(posedge clk);
            ext_instr_word  <= instr;
            ext_instr_valid <= 1'b1;
            @(posedge clk);
            ext_instr_valid <= 1'b0;
        end
    endtask

    // Wait for dbg_accel_done with a timeout; return 1 if found, 0 on timeout.
    task automatic wait_done;
        output integer found;
        integer guard;
        begin
            found = 0; guard = 0;
            while (!dbg_accel_done) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 500) begin
                    $display("B2B_PCPI [ERROR] accel_done never arrived (guard=%0d)", guard);
                    found = 0;
                    disable wait_done;
                end
            end
            found = 1;
        end
    endtask

    // Load a 4x4 Q5.10 matrix from a 256-bit flat rep into shared memory.
    // Format: flat[(r*4+c)*16 +: 16] = element [r][c].
    // Memory packed layout: 2 elements per 32-bit word (bits[31:16]=odd, [15:0]=even).
    task automatic load_matrix_packed;
        input [31:0]  base_byte;
        input [255:0] flat;
        integer pair;
        reg [15:0] lo, hi;
        begin
            for (pair = 0; pair < 8; pair = pair + 1) begin
                lo = flat[(pair*2  )*16 +: 16];
                hi = flat[(pair*2+1)*16 +: 16];
                host_write(base_byte + (pair << 2), {hi, lo});
            end
        end
    endtask

    // Check all 16 elements of mat_c_flat against expected 256-bit golden.
    // Returns number of failures.
    task automatic check_c;
        input [255:0]    expected;
        input [8*32-1:0] run_tag;
        output integer   fails;
        integer r, c;
        reg signed [15:0] got_v, exp_v;
        begin
            fails = 0;
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    got_v = mat_c_flat[(r*N+c)*16 +: 16];
                    exp_v = expected  [(r*N+c)*16 +: 16];
                    if (got_v !== exp_v) begin
                        $display("B2B_PCPI [FAIL] %0s C[%0d][%0d] exp 0x%04h got 0x%04h",
                                 run_tag, r, c, exp_v, got_v);
                        fails = fails + 1;
                    end
                end
            if (fails == 0)
                $display("B2B_PCPI [PASS] %0s all 16 C elements match", run_tag);
        end
    endtask

    // ── Test matrices ─────────────────────────────────────────────────────
    // A1 = 4x4 identity in Q5.10
    reg [255:0] a1_flat;
    // B1 = counting matrix: B[r][c] = (r*4+c+1).0 in Q5.10
    reg [255:0] b1_flat;
    // Expected C1 = A1 * B1 = B1  (identity × B = B)
    reg [255:0] c1_exp;

    // A2 = all-ones matrix (1.0 each) in Q5.10
    reg [255:0] a2_flat;
    // B2 = 4x4 identity in Q5.10
    reg [255:0] b2_flat;
    // Expected C2 = A2 * B2 = A2  (A × I = A, all elements 1.0)
    reg [255:0] c2_exp;

    integer r, c, found, run_fails, total_fails;

    // ── Stimulus ──────────────────────────────────────────────────────────
    initial begin
        // Build test matrices (flat, row-major, element [r][c] at position r*4+c)
        for (r = 0; r < 4; r = r + 1)
            for (c = 0; c < 4; c = c + 1) begin
                // A1: identity
                a1_flat[(r*4+c)*16 +: 16] = (r == c) ? Q_1P0 : Q_0;
                // B1: counting (1..16 in Q5.10)
                b1_flat[(r*4+c)*16 +: 16] = (r*4+c+1) * 1024; // N.0 in Q5.10
                // C1 expected = B1
                c1_exp[(r*4+c)*16 +: 16]  = (r*4+c+1) * 1024;
                // A2: all-ones
                a2_flat[(r*4+c)*16 +: 16] = Q_1P0;
                // B2: identity
                b2_flat[(r*4+c)*16 +: 16] = (r == c) ? Q_1P0 : Q_0;
                // C2 expected = A2 = all 1.0
                c2_exp[(r*4+c)*16 +: 16]  = Q_1P0;
            end

        // Initialise bus
        rst             = 1'b0;
        ext_instr_word  = NOP;
        ext_instr_valid = 1'b0;
        use_ext_instr   = 1'b1;
        host_mem_we     = 1'b0;
        host_mem_addr   = 32'd0;
        host_mem_wdata  = 32'd0;
        total_fails     = 0;

        // Reset
        repeat(4) @(posedge clk);
        rst = 1'b1;
        repeat(2) @(posedge clk);

        // ── Run 1: identity × counting ────────────────────────────────────
        $display("B2B_PCPI --- Run 1: identity x counting ---");
        load_matrix_packed(A_BASE, a1_flat);
        load_matrix_packed(B_BASE, b1_flat);

        inject(ADDI_X1_256);
        inject(ADDI_X2_320);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(CUSTOM_MATMUL);
        inject(NOP);
        inject(NOP);

        wait_done(found);
        if (!found) begin
            $display("B2B_PCPI TB_FAIL run1 accel_done timeout"); $finish;
        end
        @(posedge clk); // let mat_c_flat settle

        check_c(c1_exp, "run1", run_fails);
        total_fails = total_fails + run_fails;

        // ── Intermediate instruction ───────────────────────────────────────
        // One non-matmul instruction between the two CUSTOM_MATMUL instructions
        // (mirrors the handoff test that requires ≥1 regular instruction).
        inject(ADDI_X10_0);

        // ── Run 2: all-ones × identity ────────────────────────────────────
        $display("B2B_PCPI --- Run 2: all-ones x identity ---");
        load_matrix_packed(A_BASE, a2_flat);
        load_matrix_packed(B_BASE, b2_flat);

        inject(ADDI_X1_256);
        inject(ADDI_X2_320);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(NOP);
        inject(CUSTOM_MATMUL);
        inject(NOP);
        inject(NOP);

        wait_done(found);
        if (!found) begin
            $display("B2B_PCPI TB_FAIL run2 accel_done timeout"); $finish;
        end
        @(posedge clk);

        check_c(c2_exp, "run2", run_fails);
        total_fails = total_fails + run_fails;

        // ── Summary ───────────────────────────────────────────────────────
        $display("------------------------------------------------------");
        $display("B2B_PCPI SUMMARY: total_fails=%0d", total_fails);
        if (total_fails == 0)
            $display("B2B_PCPI TB_PASS back-to-back PCPI test complete");
        else
            $display("B2B_PCPI TB_FAIL %0d element mismatches", total_fails);
        $finish;
    end

    initial begin
        #500000;
        $display("B2B_PCPI [ERROR] global simulation timeout");
        $finish;
    end

    initial begin
        $dumpfile("tb_pipeline_back_to_back_pcpi.vcd");
        $dumpvars(0, tb_pipeline_back_to_back_pcpi);
    end

endmodule
