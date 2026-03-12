`timescale 1ns/1ps

module tb_rv32_pipeline_matmul_system;

    localparam integer N = 4;
    localparam [31:0] NOP = 32'h00000013;
    // funct7=0101010, rs2=x0, rs1=x0, funct3=000, rd=x5, opcode=0001011
    localparam [31:0] CUSTOM_MATMUL_X5 = 32'b0101010_00000_00000_000_00101_0001011;

    localparam [31:0] DESC_BASE = 32'h00000000;
    localparam [31:0] A_BASE = 32'h00000100;
    localparam [31:0] B_BASE = 32'h00000200;
    localparam [31:0] C_BASE = 32'h00000300;

    reg clk;
    reg rst;
    reg [31:0] ext_instr_word;
    reg ext_instr_valid;
    reg use_ext_instr;
    reg host_mem_we;
    reg [31:0] host_mem_addr;
    reg [31:0] host_mem_wdata;

    wire [31:0] host_mem_rdata;
    wire [255:0] mat_c_flat;
    wire [7:0] matmul_cycle_count;
    wire dbg_matmul_busy;
    wire dbg_matmul_done;
    wire [31:0] dbg_pc_if;
    wire [31:0] dbg_instr_if;
    wire [31:0] dbg_instr_id;
    wire dbg_stall;
    wire dbg_custom_inflight;
    wire dbg_wb_regwrite;
    wire [4:0] dbg_wb_rd;
    wire [31:0] dbg_wb_data;
    wire signed [15:0] dbg_a00;
    wire signed [15:0] dbg_a01;
    wire signed [15:0] dbg_a02;
    wire signed [15:0] dbg_a03;
    wire signed [15:0] dbg_b00;
    wire signed [15:0] dbg_b01;
    wire signed [15:0] dbg_b02;
    wire signed [15:0] dbg_b03;
    wire signed [15:0] dbg_c00;
    wire signed [15:0] dbg_c01;
    wire signed [15:0] dbg_c02;
    wire signed [15:0] dbg_c03;

    integer pass_count;
    integer total_count;

    integer r;
    integer c;
    integer guard;
    integer case_ok;

    reg [255:0] a_case;
    reg [255:0] b_case;
    reg [255:0] c_exp;
    reg [31:0] rd_word;

    reg stall_seen;
    reg wb11_seen_during_stall;
    reg wb_status_seen;
    reg wb_pre_seen;
    reg wb_post_seen;
    reg matmul_done_seen;
    reg prev_dbg_stall;
    reg prev_dbg_matmul_busy;
    reg prev_dbg_wb_regwrite;
    integer cycle_ctr;

    rv32_pipeline_matmul_system dut (
        .clk(clk),
        .rst(rst),
        .ext_instr_word(ext_instr_word),
        .ext_instr_valid(ext_instr_valid),
        .use_ext_instr(use_ext_instr),
        .host_mem_we(host_mem_we),
        .host_mem_addr(host_mem_addr),
        .host_mem_wdata(host_mem_wdata),
        .host_mem_rdata(host_mem_rdata),
        .mat_c_flat(mat_c_flat),
        .matmul_cycle_count(matmul_cycle_count),
        .dbg_matmul_busy(dbg_matmul_busy),
        .dbg_matmul_done(dbg_matmul_done),
        .dbg_pc_if(dbg_pc_if),
        .dbg_instr_if(dbg_instr_if),
        .dbg_instr_id(dbg_instr_id),
        .dbg_stall(dbg_stall),
        .dbg_custom_inflight(dbg_custom_inflight),
        .dbg_wb_regwrite(dbg_wb_regwrite),
        .dbg_wb_rd(dbg_wb_rd),
        .dbg_wb_data(dbg_wb_data),
        .dbg_a00(dbg_a00),
        .dbg_a01(dbg_a01),
        .dbg_a02(dbg_a02),
        .dbg_a03(dbg_a03),
        .dbg_b00(dbg_b00),
        .dbg_b01(dbg_b01),
        .dbg_b02(dbg_b02),
        .dbg_b03(dbg_b03),
        .dbg_c00(dbg_c00),
        .dbg_c01(dbg_c01),
        .dbg_c02(dbg_c02),
        .dbg_c03(dbg_c03)
    );

    function automatic [31:0] pack_q5_10_pair;
        input signed [15:0] low_elem;
        input signed [15:0] high_elem;
        begin
            pack_q5_10_pair = {high_elem, low_elem};
        end
    endfunction

    function automatic [31:0] encode_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm12;
        begin
            encode_addi = {imm12, rs1, 3'b000, rd, 7'b0010011};
        end
    endfunction

    task automatic set_elem;
        inout [255:0] mat;
        input integer row;
        input integer col;
        input signed [15:0] val;
        integer base;
        begin
            base = ((row * N) + col) * 16;
            mat[base +: 16] = val;
        end
    endtask

    function automatic signed [15:0] get_elem;
        input [255:0] mat;
        input integer row;
        input integer col;
        integer base;
        begin
            base = ((row * N) + col) * 16;
            get_elem = mat[base +: 16];
        end
    endfunction

    function automatic signed [31:0] q5_10_mul;
        input signed [15:0] aval;
        input signed [15:0] bval;
        reg signed [31:0] full;
        begin
            full = $signed(aval) * $signed(bval);
            q5_10_mul = full >>> 10;
        end
    endfunction

    task automatic golden_mm_4x4;
        input [255:0] a_in;
        input [255:0] b_in;
        output reg [255:0] c_out;
        integer rr;
        integer cc;
        integer kk;
        reg signed [31:0] acc;
        reg signed [15:0] aval;
        reg signed [15:0] bval;
        begin
            c_out = 256'd0;
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (cc = 0; cc < N; cc = cc + 1) begin
                    acc = 32'sd0;
                    for (kk = 0; kk < N; kk = kk + 1) begin
                        aval = get_elem(a_in, rr, kk);
                        bval = get_elem(b_in, kk, cc);
                        acc = acc + q5_10_mul(aval, bval);
                    end
                    set_elem(c_out, rr, cc, acc[15:0]);
                end
            end
        end
    endtask

    task automatic host_write_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            host_mem_addr <= addr;
            host_mem_wdata <= data;
            host_mem_we <= 1'b1;
            @(posedge clk);
            host_mem_we <= 1'b0;
        end
    endtask

    task automatic host_read_word;
        input [31:0] addr;
        output [31:0] data;
        begin
            host_mem_addr <= addr;
            #1;
            data = host_mem_rdata;
        end
    endtask

    task automatic issue_ext_instr;
        input [31:0] instr;
        input [8*32-1:0] tag;
        begin
            $display("TB_TRACE instr_issue tag=%0s instr=0x%08h opcode=0x%02h rd=%0d rs1=%0d rs2=%0d funct3=0x%0h funct7=0x%02h time=%0t",
                     tag, instr, instr[6:0], instr[11:7], instr[19:15], instr[24:20], instr[14:12], instr[31:25], $time);
            @(posedge clk);
            ext_instr_word <= instr;
            ext_instr_valid <= 1'b1;
            @(posedge clk);
            ext_instr_valid <= 1'b0;
        end
    endtask

    task automatic print_matrix_q5_10;
        input [8*32-1:0] name_tag;
        input [255:0] mat;
        integer rr;
        begin
            $display("TB_MATRIX name=%0s (Q5.10 raw int)", name_tag);
            for (rr = 0; rr < N; rr = rr + 1) begin
                $display("TB_MATRIX_ROW name=%0s row=%0d vals=[%0d %0d %0d %0d]",
                         name_tag, rr,
                         get_elem(mat, rr, 0), get_elem(mat, rr, 1),
                         get_elem(mat, rr, 2), get_elem(mat, rr, 3));
            end
        end
    endtask

    task automatic program_descriptor_defaults;
        begin
            host_write_word(DESC_BASE + 32'h00, A_BASE);
            host_write_word(DESC_BASE + 32'h04, B_BASE);
            host_write_word(DESC_BASE + 32'h08, C_BASE);
            host_write_word(DESC_BASE + 32'h0C, 32'h0004_0004);
            host_write_word(DESC_BASE + 32'h10, 32'h0000_0004);
            host_write_word(DESC_BASE + 32'h14, 32'd8);
            host_write_word(DESC_BASE + 32'h18, 32'd8);
            host_write_word(DESC_BASE + 32'h1C, 32'd8);
            $display("TB_DESC base=0x%08h A=0x%08h B=0x%08h C=0x%08h M=4 N=4 K=4 strideA=8 strideB=8 strideC=8",
                     DESC_BASE, A_BASE, B_BASE, C_BASE);
        end
    endtask

    task automatic load_matrix_to_mem;
        input [31:0] base_addr;
        input [255:0] mat;
        integer rr;
        integer word_col;
        reg signed [15:0] lo;
        reg signed [15:0] hi;
        begin
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (word_col = 0; word_col < 2; word_col = word_col + 1) begin
                    lo = get_elem(mat, rr, word_col * 2);
                    hi = get_elem(mat, rr, (word_col * 2) + 1);
                    host_write_word(base_addr + (rr * 8) + (word_col * 4), pack_q5_10_pair(lo, hi));
                end
            end
        end
    endtask

    task automatic compare_c_mem_against_expected;
        input [255:0] expected;
        input [8*40-1:0] case_name;
        output integer ok;
        integer rr;
        integer cc;
        reg [31:0] word_val;
        reg signed [15:0] got_v;
        reg signed [15:0] exp_v;
        begin
            ok = 1;
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (cc = 0; cc < N; cc = cc + 1) begin
                    host_read_word(C_BASE + (rr * 8) + ((cc >> 1) * 4), word_val);
                    if ((cc & 1) == 0) begin
                        got_v = word_val[15:0];
                    end else begin
                        got_v = word_val[31:16];
                    end
                    exp_v = get_elem(expected, rr, cc);
                    if (got_v !== exp_v) begin
                        ok = 0;
                        $display("MISMATCH test=%0s row=%0d col=%0d got=%0d expected=%0d",
                                 case_name, rr, cc, got_v, exp_v);
                    end
                end
            end
        end
    endtask

    task automatic run_case;
        input [8*40-1:0] case_name;
        input [255:0] a_in;
        input [255:0] b_in;
        input [11:0] pre_imm;
        input [11:0] during_imm;
        input [11:0] post_imm;
        integer cmp_ok;
        begin
            $display("TB_INFO test=%0s status=START", case_name);
            total_count = total_count + 1;

            a_case = a_in;
            b_case = b_in;
            golden_mm_4x4(a_case, b_case, c_exp);
            print_matrix_q5_10({"A_", case_name}, a_case);
            print_matrix_q5_10({"B_", case_name}, b_case);
            print_matrix_q5_10({"EXP_C_", case_name}, c_exp);

            load_matrix_to_mem(A_BASE, a_case);
            load_matrix_to_mem(B_BASE, b_case);
            $display("TB_INFO test=%0s action=MEMORY_PROGRAMMED A_BASE=0x%08h B_BASE=0x%08h C_BASE=0x%08h", case_name, A_BASE, B_BASE, C_BASE);

            stall_seen = 0;
            wb11_seen_during_stall = 0;
            wb_status_seen = 0;
            wb_pre_seen = 0;
            wb_post_seen = 0;
            matmul_done_seen = 0;
            case_ok = 1;

            // Simple instruction before MATMUL
            issue_ext_instr(encode_addi(5'd10, 5'd0, pre_imm), {"ADDI_PRE_", case_name});
            guard = 0;
            while (!wb_pre_seen) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 200) begin
                    case_ok = 0;
                    $display("TB_CHECK_FAIL test=%0s signal=wb_pre reason=timeout", case_name);
                    disable run_case;
                end
            end
            $display("TB_CHECK_PASS test=%0s signal=wb_pre reason=addi_before_matmul_committed", case_name);

            // Trigger MATMUL
            issue_ext_instr(CUSTOM_MATMUL_X5, {"MATMUL_", case_name});
            $display("TB_INFO test=%0s dbg_a_row0=[%0d %0d %0d %0d] dbg_b_row0=[%0d %0d %0d %0d]",
                     case_name, dbg_a00, dbg_a01, dbg_a02, dbg_a03, dbg_b00, dbg_b01, dbg_b02, dbg_b03);

            // Try an instruction while stall is expected
            repeat (2) @(posedge clk);
            issue_ext_instr(encode_addi(5'd11, 5'd0, during_imm), {"ADDI_DURING_", case_name});

            guard = 0;
            while (!matmul_done_seen) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 2000) begin
                    case_ok = 0;
                    $display("TB_CHECK_FAIL test=%0s signal=dbg_matmul_done reason=timeout", case_name);
                    disable run_case;
                end
            end

            if (stall_seen) begin
                $display("TB_CHECK_PASS test=%0s signal=dbg_stall reason=stall_observed_during_matmul", case_name);
            end else begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=dbg_stall reason=stall_not_observed", case_name);
            end

            if (!wb11_seen_during_stall) begin
                $display("TB_CHECK_PASS test=%0s signal=wb_during reason=no_x11_commit_while_stalled", case_name);
            end else begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=wb_during reason=x11_committed_during_stall", case_name);
            end

            guard = 0;
            while (!wb_status_seen) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 300) begin
                    case_ok = 0;
                    $display("TB_CHECK_FAIL test=%0s signal=wb_status reason=timeout_waiting_for_status", case_name);
                    disable run_case;
                end
            end

            if (wb_status_seen) begin
                $display("TB_CHECK_PASS test=%0s signal=wb_status reason=status_ok_written_to_x5", case_name);
            end else begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=wb_status reason=status_not_written", case_name);
            end

            // Simple instruction after MATMUL
            issue_ext_instr(encode_addi(5'd12, 5'd0, post_imm), {"ADDI_POST_", case_name});
            guard = 0;
            while (!wb_post_seen) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 300) begin
                    case_ok = 0;
                    $display("TB_CHECK_FAIL test=%0s signal=wb_post reason=timeout", case_name);
                    disable run_case;
                end
            end
            $display("TB_CHECK_PASS test=%0s signal=wb_post reason=addi_after_matmul_committed", case_name);

            compare_c_mem_against_expected(c_exp, case_name, cmp_ok);
            if (cmp_ok) begin
                $display("TB_CHECK_PASS test=%0s signal=C_mem reason=matrix_matches_golden", case_name);
            end else begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=C_mem reason=matrix_mismatch", case_name);
            end

            if (matmul_cycle_count == 8'd10) begin
                $display("TB_CHECK_PASS test=%0s signal=matmul_cycle_count reason=expected_10_cycles", case_name);
            end else begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=matmul_cycle_count reason=unexpected got=%0d expected=10",
                         case_name, matmul_cycle_count);
            end

            if (case_ok) begin
                pass_count = pass_count + 1;
                $display("TB_PASS test=%0s", case_name);
            end else begin
                $display("TB_FAIL test=%0s", case_name);
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst = 1'b0;
        ext_instr_word = NOP;
        ext_instr_valid = 1'b0;
        use_ext_instr = 1'b1;
        host_mem_we = 1'b0;
        host_mem_addr = 32'd0;
        host_mem_wdata = 32'd0;
        pass_count = 0;
        total_count = 0;
        a_case = 256'd0;
        b_case = 256'd0;
        c_exp = 256'd0;
        prev_dbg_stall = 1'b0;
        prev_dbg_matmul_busy = 1'b0;
        prev_dbg_wb_regwrite = 1'b0;
        cycle_ctr = 0;

        $display("TB_INFO status=BEGIN_MIXED_INSTR_MATMUL_REGRESSION");

        repeat (4) @(posedge clk);
        rst = 1'b1;
        program_descriptor_defaults();

        // Case 1: identity (A * I = A)
        a_case = 256'd0; b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, ((r * N + c + 1) <<< 10));
                if (r == c) begin
                    set_elem(b_case, r, c, (1 <<< 10));
                end
            end
        end
        run_case("identity", a_case, b_case, 12'd5, 12'd9, 12'd13);

        // Case 2: ones x ones
        a_case = 256'd0; b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, (1 <<< 10));
                set_elem(b_case, r, c, (1 <<< 10));
            end
        end
        run_case("ones_x_ones", a_case, b_case, 12'd6, 12'd10, 12'd14);

        // Case 3: mixed signed
        a_case = 256'd0; b_case = 256'd0;
        set_elem(a_case, 0, 0, (1 <<< 10));   set_elem(a_case, 0, 1, (-2 <<< 10));  set_elem(a_case, 0, 2, (3 <<< 10));   set_elem(a_case, 0, 3, (-4 <<< 10));
        set_elem(a_case, 1, 0, (-1 <<< 10));  set_elem(a_case, 1, 1, (2 <<< 10));   set_elem(a_case, 1, 2, (-3 <<< 10));  set_elem(a_case, 1, 3, (4 <<< 10));
        set_elem(a_case, 2, 0, (5 <<< 10));   set_elem(a_case, 2, 1, (-6 <<< 10));  set_elem(a_case, 2, 2, (7 <<< 10));   set_elem(a_case, 2, 3, (-8 <<< 10));
        set_elem(a_case, 3, 0, (-5 <<< 10));  set_elem(a_case, 3, 1, (6 <<< 10));   set_elem(a_case, 3, 2, (-7 <<< 10));  set_elem(a_case, 3, 3, (8 <<< 10));
        set_elem(b_case, 0, 0, (1 <<< 10));   set_elem(b_case, 0, 1, 16'sd0);       set_elem(b_case, 0, 2, (-1 <<< 10));  set_elem(b_case, 0, 3, (2 <<< 10));
        set_elem(b_case, 1, 0, (2 <<< 10));   set_elem(b_case, 1, 1, (-1 <<< 10));  set_elem(b_case, 1, 2, 16'sd0);       set_elem(b_case, 1, 3, (1 <<< 10));
        set_elem(b_case, 2, 0, (-2 <<< 10));  set_elem(b_case, 2, 1, (1 <<< 10));   set_elem(b_case, 2, 2, (1 <<< 10));   set_elem(b_case, 2, 3, 16'sd0);
        set_elem(b_case, 3, 0, 16'sd0);       set_elem(b_case, 3, 1, (2 <<< 10));   set_elem(b_case, 3, 2, (-1 <<< 10));  set_elem(b_case, 3, 3, (-2 <<< 10));
        run_case("signed_mixed", a_case, b_case, 12'd7, 12'd11, 12'd15);

        // Case 4: zero matrix x random
        a_case = 256'd0; b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, 16'sd0);
                set_elem(b_case, r, c, ((r + c + 1) <<< 10));
            end
        end
        run_case("zero_x_rand", a_case, b_case, 12'd8, 12'd12, 12'd16);

        // Case 5: random x zero matrix
        a_case = 256'd0; b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, ((r * 3 + c + 2) <<< 10));
                set_elem(b_case, r, c, 16'sd0);
            end
        end
        run_case("rand_x_zero", a_case, b_case, 12'd9, 12'd13, 12'd17);

        // Case 6: diagonal scale x identity
        a_case = 256'd0; b_case = 256'd0;
        set_elem(a_case, 0, 0, (2 <<< 10));
        set_elem(a_case, 1, 1, (3 <<< 10));
        set_elem(a_case, 2, 2, (4 <<< 10));
        set_elem(a_case, 3, 3, (5 <<< 10));
        for (r = 0; r < N; r = r + 1) begin
            set_elem(b_case, r, r, (1 <<< 10));
        end
        run_case("diag_x_identity", a_case, b_case, 12'd10, 12'd14, 12'd18);

        // Case 7: upper triangular x lower triangular
        a_case = 256'd0; b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = r; c < N; c = c + 1) begin
                set_elem(a_case, r, c, ((r + c + 1) <<< 10));
            end
            for (c = 0; c <= r; c = c + 1) begin
                set_elem(b_case, r, c, ((r + c + 1) <<< 10));
            end
        end
        run_case("upper_x_lower", a_case, b_case, 12'd11, 12'd15, 12'd19);

        // Case 8: checkerboard signed pattern
        a_case = 256'd0; b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                if ((r + c) & 1) begin
                    set_elem(a_case, r, c, (-1 <<< 10));
                    set_elem(b_case, r, c, (2 <<< 10));
                end else begin
                    set_elem(a_case, r, c, (1 <<< 10));
                    set_elem(b_case, r, c, (-2 <<< 10));
                end
            end
        end
        run_case("checker_signed", a_case, b_case, 12'd12, 12'd16, 12'd20);

        $display("SUMMARY pass=%0d total=%0d", pass_count, total_count);
        if (pass_count == total_count) begin
            $display("TB_PASS summary pass=%0d total=%0d", pass_count, total_count);
        end else begin
            $display("TB_FAIL summary pass=%0d total=%0d", pass_count, total_count);
            $fatal(1, "One or more mixed instruction/matmul cases failed.");
        end
        $finish;
    end

    always @(posedge clk) begin
        cycle_ctr <= cycle_ctr + 1;

        if (!prev_dbg_stall && dbg_stall) begin
            $display("TB_EVENT cycle=%0d signal=dbg_stall edge=RISE pc_if=0x%08h instr_if=0x%08h instr_id=0x%08h time=%0t",
                     cycle_ctr, dbg_pc_if, dbg_instr_if, dbg_instr_id, $time);
        end
        if (prev_dbg_stall && !dbg_stall) begin
            $display("TB_EVENT cycle=%0d signal=dbg_stall edge=FALL pc_if=0x%08h time=%0t",
                     cycle_ctr, dbg_pc_if, $time);
        end

        if (!prev_dbg_matmul_busy && dbg_matmul_busy) begin
            $display("TB_EVENT cycle=%0d signal=dbg_matmul_busy edge=RISE dbg_a_row0=[%0d %0d %0d %0d] dbg_b_row0=[%0d %0d %0d %0d] time=%0t",
                     cycle_ctr, dbg_a00, dbg_a01, dbg_a02, dbg_a03, dbg_b00, dbg_b01, dbg_b02, dbg_b03, $time);
        end
        if (prev_dbg_matmul_busy && !dbg_matmul_busy) begin
            $display("TB_EVENT cycle=%0d signal=dbg_matmul_busy edge=FALL dbg_c_row0=[%0d %0d %0d %0d] time=%0t",
                     cycle_ctr, dbg_c00, dbg_c01, dbg_c02, dbg_c03, $time);
        end

        if (dbg_stall) begin
            stall_seen <= 1'b1;
        end

        if (dbg_wb_regwrite && dbg_stall && (dbg_wb_rd == 5'd11)) begin
            wb11_seen_during_stall <= 1'b1;
        end
        if (dbg_wb_regwrite && !prev_dbg_wb_regwrite && dbg_stall && (dbg_wb_rd == 5'd11)) begin
            wb11_seen_during_stall <= 1'b1;
            $display("TB_EVENT cycle=%0d wb=1 while_stall=1 rd=%0d data=0x%08h time=%0t",
                     cycle_ctr, dbg_wb_rd, dbg_wb_data, $time);
        end

        if (dbg_wb_regwrite && (dbg_wb_rd == 5'd5) && (dbg_wb_data == 32'd0)) begin
            wb_status_seen <= 1'b1;
        end
        if (dbg_wb_regwrite && !prev_dbg_wb_regwrite && (dbg_wb_rd == 5'd5) && (dbg_wb_data == 32'd0)) begin
            wb_status_seen <= 1'b1;
            $display("TB_EVENT cycle=%0d wb_status rd=x5 data=%0d (OK) time=%0t", cycle_ctr, dbg_wb_data, $time);
        end

        if (dbg_wb_regwrite && (dbg_wb_rd == 5'd10)) begin
            wb_pre_seen <= 1'b1;
        end
        if (dbg_wb_regwrite && !prev_dbg_wb_regwrite && (dbg_wb_rd == 5'd10)) begin
            wb_pre_seen <= 1'b1;
            $display("TB_EVENT cycle=%0d wb_pre rd=x10 data=%0d time=%0t", cycle_ctr, $signed(dbg_wb_data), $time);
        end

        if (dbg_wb_regwrite && (dbg_wb_rd == 5'd12)) begin
            wb_post_seen <= 1'b1;
        end
        if (dbg_wb_regwrite && !prev_dbg_wb_regwrite && (dbg_wb_rd == 5'd12)) begin
            wb_post_seen <= 1'b1;
            $display("TB_EVENT cycle=%0d wb_post rd=x12 data=%0d time=%0t", cycle_ctr, $signed(dbg_wb_data), $time);
        end

        if (dbg_wb_regwrite && !prev_dbg_wb_regwrite && (dbg_wb_rd == 5'd11) && !dbg_stall) begin
            $display("TB_EVENT cycle=%0d wb_during_rd_committed_after_stall rd=x11 data=%0d time=%0t",
                     cycle_ctr, $signed(dbg_wb_data), $time);
        end

        if (dbg_matmul_done) begin
            matmul_done_seen <= 1'b1;
            $display("TB_EVENT cycle=%0d signal=dbg_matmul_done pulse=1 matmul_cycle_count=%0d time=%0t",
                     cycle_ctr, matmul_cycle_count, $time);
        end

        prev_dbg_stall <= dbg_stall;
        prev_dbg_matmul_busy <= dbg_matmul_busy;
        prev_dbg_wb_regwrite <= dbg_wb_regwrite;
    end

endmodule
