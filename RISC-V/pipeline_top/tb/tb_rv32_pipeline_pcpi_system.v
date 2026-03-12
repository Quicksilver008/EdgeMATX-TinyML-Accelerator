`timescale 1ns/1ps

// tb_rv32_pipeline_pcpi_system
//
// Testbench for rv32_pipeline_pcpi_system.
//
// Flow:
//  1. Reset
//  2. Preload matrices A (identity) and B (sequential 1..16 in Q5.10) into
//     shared memory via host_mem_we at byte addresses 0x100 and 0x140.
//     Each Q5.10 element occupies its own 32-bit word (lower 16 bits).
//  3. Inject firmware via ext_instr_word:
//       ADDI x1, x0, 0x100    (rs1 = A byte base)
//       ADDI x2, x0, 0x140    (rs2 = B byte base)
//       <5 NOPs to flush pipeline and ensure ADDIs commit>
//       CUSTOM insn (rs1=x1, rs2=x2, rd=x3)
//       <10 NOPs — gives stall + completion time>
//  4. Monitor dbg_stall / dbg_custom_inflight; wait for dbg_accel_done.
//  5. Read C from shared memory via host_mem_rdata (byte base 0x200).
//  6. Compare against software golden result.
//
// Firmware encoding (funct7=0101010, funct3=000, opcode=0001011):
//   ADDI x1, x0, 256  => 0x10000093
//   ADDI x2, x0, 320  => 0x14000113
//   CUSTOM rs1=x1,rs2=x2,rd=x3 => 0x5420818B
//   NOP (ADDI x0,x0,0) => 0x00000013

module tb_rv32_pipeline_pcpi_system;

    // -----------------------------------------------------------------------
    // Parameters / constants
    // -----------------------------------------------------------------------
    localparam integer N = 4;

    // Firmware instruction encodings
    localparam [31:0] NOP           = 32'h00000013;
    localparam [31:0] ADDI_X1_256  = 32'h10000093;  // ADDI x1, x0, 0x100
    localparam [31:0] ADDI_X2_320  = 32'h14000113;  // ADDI x2, x0, 0x140
    // funct7=0101010 rs2=x2 rs1=x1 funct3=000 rd=x3 opcode=0001011
    localparam [31:0] CUSTOM_MATMUL = 32'h5420818B;

    // Shared memory byte base addresses (must match pcpi_tinyml_accel)
    localparam [31:0] A_BASE = 32'h0000_0100;
    localparam [31:0] B_BASE = 32'h0000_0140;
    localparam [31:0] C_BASE = 32'h0000_0200;  // hardcoded in wrapper

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    reg        clk;
    reg        rst;
    reg [31:0] ext_instr_word;
    reg        ext_instr_valid;
    reg        use_ext_instr;
    reg        host_mem_we;
    reg [31:0] host_mem_addr;
    reg [31:0] host_mem_wdata;

    wire [31:0] host_mem_rdata;
    wire [31:0] dbg_pc_if;
    wire [31:0] dbg_instr_if;
    wire [31:0] dbg_instr_id;
    wire        dbg_stall;
    wire        dbg_custom_inflight;
    wire        dbg_wb_regwrite;
    wire [4:0]  dbg_wb_rd;
    wire [31:0] dbg_wb_data;
    wire [255:0] mat_c_flat;
    wire         dbg_accel_done;

    // -----------------------------------------------------------------------
    // Bookkeeping
    // -----------------------------------------------------------------------
    integer pass_count;
    integer total_count;
    integer r, c, guard;
    integer case_ok;
    integer stall_seen;
    integer accel_done_seen;

    reg [255:0] a_case;
    reg [255:0] b_case;
    reg [255:0] c_exp;
    reg [31:0]  rd_word;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    rv32_pipeline_pcpi_system dut (
        .clk             (clk),
        .rst             (rst),
        .ext_instr_word  (ext_instr_word),
        .ext_instr_valid (ext_instr_valid),
        .use_ext_instr   (use_ext_instr),
        .host_mem_we     (host_mem_we),
        .host_mem_addr   (host_mem_addr),
        .host_mem_wdata  (host_mem_wdata),
        .host_mem_rdata  (host_mem_rdata),
        .dbg_pc_if           (dbg_pc_if),
        .dbg_instr_if        (dbg_instr_if),
        .dbg_instr_id        (dbg_instr_id),
        .dbg_stall           (dbg_stall),
        .dbg_custom_inflight (dbg_custom_inflight),
        .dbg_wb_regwrite     (dbg_wb_regwrite),
        .dbg_wb_rd           (dbg_wb_rd),
        .dbg_wb_data         (dbg_wb_data),
        .mat_c_flat      (mat_c_flat),
        .dbg_accel_done  (dbg_accel_done)
    );

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Helper functions
    // -----------------------------------------------------------------------

    // Return the flat bit position for element [row][col] in a packed 256-bit
    // row-major matrix of Q5.10 half-words.
    function automatic integer elem_base;
        input integer row;
        input integer col;
        begin
            elem_base = ((row * N) + col) * 16;
        end
    endfunction

    function automatic signed [15:0] get_elem;
        input [255:0] mat;
        input integer row;
        input integer col;
        begin
            get_elem = mat[elem_base(row, col) +: 16];
        end
    endfunction

    task automatic set_elem;
        inout  [255:0] mat;
        input  integer row;
        input  integer col;
        input  signed [15:0] val;
        begin
            mat[elem_base(row, col) +: 16] = val;
        end
    endtask

    // Q5.10 multiply: (a * b) >> 10, result in Q5.10
    function automatic signed [15:0] q5_10_mul;
        input signed [15:0] a;
        input signed [15:0] b;
        reg   signed [31:0] full;
        begin
            full = $signed(a) * $signed(b);
            q5_10_mul = full[25:10];  // arithmetic right shift by 10
        end
    endfunction

    // Software golden matmul
    task automatic golden_mm_4x4;
        input  [255:0] a_in;
        input  [255:0] b_in;
        output reg [255:0] c_out;
        integer rr, cc, kk;
        reg signed [31:0] acc;
        reg signed [15:0] aval, bval;
        reg signed [31:0] prod;
        begin
            c_out = 256'd0;
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (cc = 0; cc < N; cc = cc + 1) begin
                    acc = 32'sd0;
                    for (kk = 0; kk < N; kk = kk + 1) begin
                        aval = get_elem(a_in, rr, kk);
                        bval = get_elem(b_in, kk, cc);
                        prod = $signed(aval) * $signed(bval);
                        acc  = acc + (prod >>> 10);
                    end
                    set_elem(c_out, rr, cc, acc[15:0]);
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Memory helpers
    // -----------------------------------------------------------------------

    task automatic host_write_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            host_mem_addr  <= addr;
            host_mem_wdata <= data;
            host_mem_we    <= 1'b1;
            @(posedge clk);
            host_mem_we    <= 1'b0;
        end
    endtask

    task automatic host_read_word;
        input  [31:0] addr;
        output [31:0] data;
        begin
            host_mem_addr = addr;
            #1;
            data = host_mem_rdata;
        end
    endtask

    // Load a 4x4 Q5.10 matrix into shared memory at base_byte.
    // Each element occupies its own 32-bit word (lower 16 bits = Q5.10).
    // Element [r][c] is at byte address: base_byte + (r*4+c)*4.
    task automatic load_matrix_pcpi;
        input [31:0]  base_byte;
        input [255:0] mat;
        integer elem;
        begin
            for (elem = 0; elem < 16; elem = elem + 1) begin
                host_write_word(base_byte + (elem << 2),
                                {16'd0, mat[elem*16 +: 16]});
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Firmware injection helper
    // -----------------------------------------------------------------------
    task automatic issue_ext_instr;
        input [31:0]    instr;
        input [8*32-1:0] tag;
        begin
            $display("TB_INSTR tag=%0s instr=0x%08h opcode=0x%02h rs1=%0d rs2=%0d rd=%0d t=%0t",
                     tag, instr, instr[6:0], instr[19:15], instr[24:20],
                     instr[11:7], $time);
            @(posedge clk);
            ext_instr_word  <= instr;
            ext_instr_valid <= 1'b1;
            @(posedge clk);
            ext_instr_valid <= 1'b0;
        end
    endtask

    // Print a packed Q5.10 matrix
    task automatic print_matrix;
        input [8*32-1:0] name_tag;
        input [255:0]    mat;
        integer rr;
        begin
            $display("TB_MATRIX name=%0s", name_tag);
            for (rr = 0; rr < N; rr = rr + 1)
                $display("  row%0d: [%0d  %0d  %0d  %0d]", rr,
                         get_elem(mat, rr, 0), get_elem(mat, rr, 1),
                         get_elem(mat, rr, 2), get_elem(mat, rr, 3));
        end
    endtask

    // Read C back from shared memory and compare with expected.
    // C element [r][c] is at byte 0x200 + (r*4+c)*4, sign-extended 32-bit.
    task automatic compare_c_pcpi;
        input  [255:0]    expected;
        input  [8*32-1:0] case_name;
        output integer    ok;
        integer rr, cc, elem;
        reg [31:0]       raw;
        reg signed [15:0] got_v;
        reg signed [15:0] exp_v;
        begin
            ok = 1;
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (cc = 0; cc < N; cc = cc + 1) begin
                    elem = rr * N + cc;
                    host_read_word(C_BASE + (elem << 2), raw);
                    got_v = raw[15:0];
                    exp_v = get_elem(expected, rr, cc);
                    if (got_v !== exp_v) begin
                        ok = 0;
                        $display("TB_MISMATCH test=%0s row=%0d col=%0d got=%0d exp=%0d",
                                 case_name, rr, cc, got_v, exp_v);
                    end
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test task
    // -----------------------------------------------------------------------
    task automatic run_case;
        input [8*32-1:0] case_name;
        input [255:0]    a_in;
        input [255:0]    b_in;
        integer cmp_ok;
        begin
            $display("TB_CASE test=%0s status=START", case_name);
            total_count = total_count + 1;
            case_ok    = 1;
            stall_seen = 0;
            accel_done_seen = 0;

            golden_mm_4x4(a_in, b_in, c_exp);
            print_matrix({"A_", case_name}, a_in);
            print_matrix({"B_", case_name}, b_in);
            print_matrix({"EXP_C_", case_name}, c_exp);

            // Load matrices into shared memory
            load_matrix_pcpi(A_BASE, a_in);
            load_matrix_pcpi(B_BASE, b_in);
            $display("TB_INFO test=%0s action=MEMORY_LOADED A=0x%08h B=0x%08h C=0x%08h",
                     case_name, A_BASE, B_BASE, C_BASE);

            // Inject firmware ------------------------------------------------
            // ADDI x1 = A byte base, ADDI x2 = B byte base
            issue_ext_instr(ADDI_X1_256,  "ADDI_X1");
            issue_ext_instr(ADDI_X2_320,  "ADDI_X2");

            // 5 NOPs to flush the pipeline so ADDIs reach WB before CUSTOM
            // reaches the ID stage (register-read point).
            issue_ext_instr(NOP, "NOP_0");
            issue_ext_instr(NOP, "NOP_1");
            issue_ext_instr(NOP, "NOP_2");
            issue_ext_instr(NOP, "NOP_3");
            issue_ext_instr(NOP, "NOP_4");

            // Fire the custom matmul instruction (rs1=x1, rs2=x2, rd=x3)
            issue_ext_instr(CUSTOM_MATMUL, "CUSTOM_MATMUL");

            // Keep injecting NOPs so the CPU has something valid to run after
            // the stall releases; also ensures the pcpi_valid flag has time
            // to propagate before we start sampling.
            issue_ext_instr(NOP, "NOP_POST_0");
            issue_ext_instr(NOP, "NOP_POST_1");

            // Wait for PCPI wrapper to complete ---------------------------------
            guard = 0;
            while (!accel_done_seen) begin
                @(posedge clk);
                if (dbg_stall)      stall_seen      = 1;
                if (dbg_accel_done) accel_done_seen = 1;
                // Keep feeding NOPs while waiting
                if (!ext_instr_valid) begin
                    ext_instr_word  <= NOP;
                    ext_instr_valid <= 1'b1;
                    @(posedge clk);
                    ext_instr_valid <= 1'b0;
                end
                guard = guard + 1;
                if (guard > 500) begin
                    case_ok = 0;
                    $display("TB_FAIL test=%0s reason=timeout_waiting_for_accel_done", case_name);
                    disable run_case;
                end
            end

            // Extra cycles to let mat_c_flat register settle after STORE_C
            repeat (5) @(posedge clk);

            // Stall check
            if (stall_seen) begin
                $display("TB_PASS_CHECK test=%0s check=stall_asserted reason=pipeline_held_during_pcpi",
                         case_name);
            end else begin
                case_ok = 0;
                $display("TB_FAIL_CHECK test=%0s check=stall_asserted reason=stall_never_observed",
                         case_name);
            end

            // C matrix correctness check
            compare_c_pcpi(c_exp, case_name, cmp_ok);
            if (cmp_ok) begin
                $display("TB_PASS_CHECK test=%0s check=C_matrix reason=matches_golden",
                         case_name);
            end else begin
                case_ok = 0;
                $display("TB_FAIL_CHECK test=%0s check=C_matrix reason=mismatch", case_name);
            end

            // mat_c_flat port check (should match memory once writes complete)
            begin : c_flat_check
                integer fi;
                integer flat_ok;
                flat_ok = 1;
                for (fi = 0; fi < 16; fi = fi + 1) begin
                    if (mat_c_flat[fi*16 +: 16] !== c_exp[fi*16 +: 16]) begin
                        flat_ok = 0;
                        $display("TB_MISMATCH test=%0s check=mat_c_flat elem=%0d got=%0d exp=%0d",
                                 case_name, fi,
                                 $signed(mat_c_flat[fi*16 +: 16]),
                                 $signed(c_exp[fi*16 +: 16]));
                    end
                end
                if (flat_ok) begin
                    $display("TB_PASS_CHECK test=%0s check=mat_c_flat reason=matches_golden",
                             case_name);
                end else begin
                    case_ok = 0;
                    $display("TB_FAIL_CHECK test=%0s check=mat_c_flat reason=mismatch", case_name);
                end
            end

            if (case_ok) begin
                pass_count = pass_count + 1;
                $display("TB_PASS test=%0s", case_name);
            end else begin
                $display("TB_FAIL test=%0s", case_name);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        // Initialise signals
        rst             = 1'b0;
        ext_instr_word  = NOP;
        ext_instr_valid = 1'b0;
        use_ext_instr   = 1'b1;
        host_mem_we     = 1'b0;
        host_mem_addr   = 32'd0;
        host_mem_wdata  = 32'd0;
        pass_count      = 0;
        total_count     = 0;

        $display("TB_INFO status=BEGIN_PCPI_SYSTEM_REGRESSION");

        // Release reset after a few cycles
        repeat (4) @(posedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);

        // ----------------------------------------------------------------
        // Case 1: identity x sequential  =>  C = B
        // A = diag(1,1,1,1) in Q5.10,  B[r][c] = (r*4+c+1).0 in Q5.10
        // ----------------------------------------------------------------
        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                if (r == c)
                    set_elem(a_case, r, c, 16'sh0400);   // 1.0 in Q5.10
                set_elem(b_case, r, c, ((r * N + c + 1) <<< 10));
            end
        end
        run_case("identity_x_seq", a_case, b_case);

        // ----------------------------------------------------------------
        // Case 2: all-ones x all-ones  =>  C[r][c] = 4.0 (Q5.10 = 0x1000)
        // ----------------------------------------------------------------
        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, 16'sh0400);
                set_elem(b_case, r, c, 16'sh0400);
            end
        end
        run_case("ones_x_ones", a_case, b_case);

        // ----------------------------------------------------------------
        // Case 3: mixed signed
        // ----------------------------------------------------------------
        a_case = 256'd0;
        b_case = 256'd0;
        set_elem(a_case, 0, 0,  (1 <<< 10));  set_elem(a_case, 0, 1, (-2 <<< 10));
        set_elem(a_case, 0, 2,  (3 <<< 10));  set_elem(a_case, 0, 3, (-4 <<< 10));
        set_elem(a_case, 1, 0, (-1 <<< 10));  set_elem(a_case, 1, 1,  (2 <<< 10));
        set_elem(a_case, 1, 2, (-3 <<< 10));  set_elem(a_case, 1, 3,  (4 <<< 10));
        set_elem(a_case, 2, 0,  (5 <<< 10));  set_elem(a_case, 2, 1, (-6 <<< 10));
        set_elem(a_case, 2, 2,  (7 <<< 10));  set_elem(a_case, 2, 3, (-8 <<< 10));
        set_elem(a_case, 3, 0, (-5 <<< 10));  set_elem(a_case, 3, 1,  (6 <<< 10));
        set_elem(a_case, 3, 2, (-7 <<< 10));  set_elem(a_case, 3, 3,  (8 <<< 10));
        set_elem(b_case, 0, 0,  (1 <<< 10));  set_elem(b_case, 0, 1, 16'sd0);
        set_elem(b_case, 0, 2, (-1 <<< 10));  set_elem(b_case, 0, 3,  (2 <<< 10));
        set_elem(b_case, 1, 0,  (2 <<< 10));  set_elem(b_case, 1, 1, (-1 <<< 10));
        set_elem(b_case, 1, 2, 16'sd0);       set_elem(b_case, 1, 3,  (1 <<< 10));
        set_elem(b_case, 2, 0, (-2 <<< 10));  set_elem(b_case, 2, 1,  (1 <<< 10));
        set_elem(b_case, 2, 2,  (1 <<< 10));  set_elem(b_case, 2, 3, 16'sd0);
        set_elem(b_case, 3, 0, 16'sd0);       set_elem(b_case, 3, 1,  (2 <<< 10));
        set_elem(b_case, 3, 2, (-1 <<< 10));  set_elem(b_case, 3, 3, (-2 <<< 10));
        run_case("signed_mixed", a_case, b_case);

        // ----------------------------------------------------------------
        // Summary
        // ----------------------------------------------------------------
        $display("TB_SUMMARY passed=%0d total=%0d", pass_count, total_count);
        if (pass_count == total_count) begin
            $display("TB_PASS ALL_TESTS_PASSED");
        end else begin
            $display("TB_FAIL SOME_TESTS_FAILED failed=%0d", total_count - pass_count);
        end
        $finish;
    end

    // Timeout guard
    initial begin
        #200000;
        $display("TB_FAIL GLOBAL_TIMEOUT");
        $finish;
    end

    initial begin
        $dumpfile("tb_rv32_pipeline_pcpi_system.vcd");
        $dumpvars(0, tb_rv32_pipeline_pcpi_system);
    end

endmodule
