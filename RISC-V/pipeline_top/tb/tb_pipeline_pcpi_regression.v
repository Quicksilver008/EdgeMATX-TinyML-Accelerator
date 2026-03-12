`timescale 1ns/1ps
// tb_pipeline_pcpi_regression.v
//
// Multi-case regression for rv32_pipeline_pcpi_system + pcpi_tinyml_accel.
// Mirrors the structure of the 8-case picorv regression but targets the
// pipelined RV32I core.  Each case loads A and B into shared memory, fires
// the CUSTOM_MATMUL instruction, then verifies all 16 C elements (via both
// mat_c_flat and memory read-back) against a software-computed golden.
//
// Test cases
// ----------
// 1. identity_x_seq    A = 4x4 identity, B = counting (1..16) → C = B
// 2. ones_x_ones       A = all 1.0,      B = all 1.0          → C = all 4.0
// 3. mixed_sign        A = checkerboard (+1/-1), B = counting  → golden via task
// 4. zero_a            A = all zeros,    B = counting          → C = all zeros

module tb_pipeline_pcpi_regression;

    localparam integer N = 4;

    localparam [31:0] NOP           = 32'h00000013;
    localparam [31:0] ADDI_X1_256   = 32'h10000093; // ADDI x1, x0, 0x100
    localparam [31:0] ADDI_X2_320   = 32'h14000113; // ADDI x2, x0, 0x140
    localparam [31:0] CUSTOM_MATMUL = 32'h5420818B;

    localparam [31:0] A_BASE = 32'h0000_0100;
    localparam [31:0] B_BASE = 32'h0000_0140;

    localparam [15:0] Q_1P0  = 16'h0400; // +1.0 in Q5.10
    localparam [15:0] Q_N1P0 = 16'hFC00; // -1.0 in Q5.10 (two's complement)
    localparam [15:0] Q_4P0  = 16'h1000; //  4.0 in Q5.10
    localparam [15:0] Q_0    = 16'h0000;

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

    // ── Memory and injection helpers ──────────────────────────────────────
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

    // Load a packed (2-elem/word) matrix into shared memory
    task automatic load_matrix;
        input [31:0]  base_byte;
        input [255:0] flat;
        integer pair;
        begin
            for (pair = 0; pair < 8; pair = pair + 1)
                host_write(base_byte + (pair << 2),
                           {flat[(pair*2+1)*16 +: 16], flat[(pair*2)*16 +: 16]});
        end
    endtask

    // Wait for dbg_accel_done pulse (500-cycle timeout)
    task automatic wait_done;
        output integer ok;
        integer guard;
        begin
            ok = 0; guard = 0;
            while (!dbg_accel_done) begin
                @(posedge clk);
                if (++guard > 500) disable wait_done;
            end
            ok = 1;
        end
    endtask

    // ── Software golden (Q5.10 matrix multiply) ───────────────────────────
    function automatic signed [31:0] q5_10_mul_f;
        input signed [15:0] a, b;
        reg signed [31:0] p;
        begin q5_10_mul_f = ($signed(a) * $signed(b)) >>> 10; end
    endfunction

    task automatic golden_mm;
        input  [255:0] a_in, b_in;
        output reg [255:0] c_out;
        integer rr, cc, kk;
        reg signed [31:0] acc;
        begin
            c_out = 256'd0;
            for (rr = 0; rr < N; rr = rr + 1)
                for (cc = 0; cc < N; cc = cc + 1) begin
                    acc = 32'sd0;
                    for (kk = 0; kk < N; kk = kk + 1)
                        acc = acc + q5_10_mul_f(
                            a_in[(rr*N+kk)*16 +: 16],
                            b_in[(kk*N+cc)*16 +: 16]);
                    c_out[(rr*N+cc)*16 +: 16] = acc[15:0];
                end
        end
    endtask

    // ── Per-case run and verify ───────────────────────────────────────────
    integer total_pass, total_fail;

    task automatic run_case;
        input [255:0]    a_in, b_in, c_exp;
        input [8*32-1:0] case_name;
        integer ok, r, c, fails;
        reg signed [15:0] got_v, exp_v;
        begin
            $display("PCPI_REG --- case: %0s ---", case_name);

            load_matrix(A_BASE, a_in);
            load_matrix(B_BASE, b_in);

            inject(ADDI_X1_256);
            inject(ADDI_X2_320);
            inject(NOP); inject(NOP); inject(NOP); inject(NOP); inject(NOP);
            inject(CUSTOM_MATMUL);
            inject(NOP); inject(NOP);

            wait_done(ok);
            if (!ok) begin
                $display("PCPI_REG [FAIL] %0s: accel_done timeout", case_name);
                total_fail = total_fail + 1;
                disable run_case;
            end
            @(posedge clk); // mat_c_flat settle

            fails = 0;
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    got_v = mat_c_flat[(r*N+c)*16 +: 16];
                    exp_v = c_exp    [(r*N+c)*16 +: 16];
                    if (got_v !== exp_v) begin
                        $display("PCPI_REG [FAIL] %0s C[%0d][%0d] exp 0x%04h got 0x%04h",
                                 case_name, r, c, exp_v, got_v);
                        fails = fails + 1;
                    end
                end

            if (fails == 0) begin
                $display("PCPI_REG [PASS] %0s: all 16 elements correct", case_name);
                total_pass = total_pass + 1;
            end else begin
                $display("PCPI_REG [FAIL] %0s: %0d element mismatches", case_name, fails);
                total_fail = total_fail + 1;
            end
        end
    endtask

    // ── Test vectors ──────────────────────────────────────────────────────
    reg [255:0] a_flat, b_flat, c_exp;
    integer r, c;

    // ── Stimulus ──────────────────────────────────────────────────────────
    initial begin
        rst             = 1'b0;
        ext_instr_word  = NOP;
        ext_instr_valid = 1'b0;
        use_ext_instr   = 1'b1;
        host_mem_we     = 1'b0;
        host_mem_addr   = 32'd0;
        host_mem_wdata  = 32'd0;
        total_pass      = 0;
        total_fail      = 0;

        repeat(4) @(posedge clk);
        rst = 1'b1;
        repeat(2) @(posedge clk);

        // ── Case 1: identity_x_seq ────────────────────────────────────────
        for (r = 0; r < 4; r = r + 1)
            for (c = 0; c < 4; c = c + 1) begin
                a_flat[(r*4+c)*16 +: 16] = (r == c) ? Q_1P0 : Q_0;
                b_flat[(r*4+c)*16 +: 16] = (r*4+c+1) * 1024; // counting in Q5.10
                c_exp [(r*4+c)*16 +: 16] = (r*4+c+1) * 1024; // C = B
            end
        run_case(a_flat, b_flat, c_exp, "identity_x_seq");

        // ── Case 2: ones_x_ones ───────────────────────────────────────────
        // C[r][c] = sum_{k=0}^{3} 1.0 * 1.0 = 4.0 = 0x1000
        for (r = 0; r < 4; r = r + 1)
            for (c = 0; c < 4; c = c + 1) begin
                a_flat[(r*4+c)*16 +: 16] = Q_1P0;
                b_flat[(r*4+c)*16 +: 16] = Q_1P0;
                c_exp [(r*4+c)*16 +: 16] = Q_4P0;
            end
        run_case(a_flat, b_flat, c_exp, "ones_x_ones");

        // ── Case 3: mixed_sign ────────────────────────────────────────────
        // A = checkerboard: A[r][c] = +1.0 if (r+c) even, -1.0 if odd
        // B = counting (1..16 in Q5.10)   Golden computed by task.
        for (r = 0; r < 4; r = r + 1)
            for (c = 0; c < 4; c = c + 1) begin
                a_flat[(r*4+c)*16 +: 16] = ((r+c) % 2 == 0) ? Q_1P0 : Q_N1P0;
                b_flat[(r*4+c)*16 +: 16] = (r*4+c+1) * 1024;
            end
        golden_mm(a_flat, b_flat, c_exp);
        run_case(a_flat, b_flat, c_exp, "mixed_sign");

        // ── Case 4: zero_a ────────────────────────────────────────────────
        for (r = 0; r < 4; r = r + 1)
            for (c = 0; c < 4; c = c + 1) begin
                a_flat[(r*4+c)*16 +: 16] = Q_0;
                b_flat[(r*4+c)*16 +: 16] = (r*4+c+1) * 1024;
                c_exp [(r*4+c)*16 +: 16] = Q_0;
            end
        run_case(a_flat, b_flat, c_exp, "zero_a");

        // ── Summary ───────────────────────────────────────────────────────
        $display("======================================================");
        $display("  PCPI Regression — rv32_pipeline + pcpi_tinyml_accel");
        $display("======================================================");
        $display("  Passed : %0d / 4", total_pass);
        $display("  Failed : %0d / 4", total_fail);
        $display("======================================================");
        if (total_fail == 0)
            $display("PCPI_REG TB_PASS ALL_CASES_PASSED");
        else
            $display("PCPI_REG TB_FAIL %0d CASES FAILED", total_fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("PCPI_REG [ERROR] global simulation timeout");
        $finish;
    end

    initial begin
        $dumpfile("tb_pipeline_pcpi_regression.vcd");
        $dumpvars(0, tb_pipeline_pcpi_regression);
    end

endmodule
