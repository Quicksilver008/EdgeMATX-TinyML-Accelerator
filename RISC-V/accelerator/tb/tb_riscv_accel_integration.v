`timescale 1ns/1ps

module tb_riscv_accel_integration;

    localparam integer N = 4;
    localparam [31:0] CUSTOM_MATMUL_INSTR = 32'b0101010_00000_00000_000_00000_0001011;

    reg clk;
    reg rst;
    reg instr_valid;
    reg [31:0] instr_word;
    reg [255:0] a_flat;
    reg [255:0] b_flat;

    wire cpu_stall;
    wire custom_hit;
    wire custom_accept;
    wire custom_complete;
    wire accel_start;
    wire accel_busy;
    wire accel_done;
    wire [255:0] c_flat;
    wire [7:0] accel_cycle_count;

    integer pass_count;
    integer total_count;
    integer accept_count;
    integer complete_count;

    integer r;
    integer c;

    reg [255:0] a_case;
    reg [255:0] b_case;
    reg [255:0] expected;

    riscv_accel_integration_stub dut (
        .clk(clk),
        .rst(rst),
        .instr_valid(instr_valid),
        .instr_word(instr_word),
        .a_flat(a_flat),
        .b_flat(b_flat),
        .cpu_stall(cpu_stall),
        .custom_hit(custom_hit),
        .custom_accept(custom_accept),
        .custom_complete(custom_complete),
        .accel_start_observe(accel_start),
        .accel_busy(accel_busy),
        .accel_done(accel_done),
        .c_flat(c_flat),
        .accel_cycle_count(accel_cycle_count)
    );

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
        output reg [255:0] c_exp;
        integer rr;
        integer cc;
        integer kk;
        reg signed [31:0] acc;
        reg signed [15:0] aval;
        reg signed [15:0] bval;
        begin
            c_exp = 256'd0;
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (cc = 0; cc < N; cc = cc + 1) begin
                    acc = 32'sd0;
                    for (kk = 0; kk < N; kk = kk + 1) begin
                        aval = get_elem(a_in, rr, kk);
                        bval = get_elem(b_in, kk, cc);
                        acc = acc + q5_10_mul(aval, bval);
                    end
                    set_elem(c_exp, rr, cc, acc[15:0]);
                end
            end
        end
    endtask

    task automatic issue_custom_instr_once;
        output integer hit_seen_now;
        begin
            hit_seen_now = 0;
            @(posedge clk);
            instr_word <= CUSTOM_MATMUL_INSTR;
            instr_valid <= 1'b1;
            #1;
            if (custom_hit) begin
                hit_seen_now = 1;
            end
            @(posedge clk);
            #1;
            if (custom_hit) begin
                hit_seen_now = 1;
            end
            instr_valid <= 1'b0;
        end
    endtask

    task automatic wait_custom_complete;
        integer guard;
        begin
            guard = 0;
            while (!custom_complete) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 1000) begin
                    $display("TB_FAIL test=timeout reason=custom_complete_not_seen");
                    $fatal(1, "Timeout waiting for custom completion.");
                end
            end
        end
    endtask

    task automatic compare_output_matrix;
        input [8*40-1:0] test_name;
        input [255:0] exp_mat;
        output integer case_ok;
        integer rr;
        integer cc;
        reg signed [15:0] got_v;
        reg signed [15:0] exp_v;
        begin
            case_ok = 1;
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (cc = 0; cc < N; cc = cc + 1) begin
                    got_v = get_elem(c_flat, rr, cc);
                    exp_v = get_elem(exp_mat, rr, cc);
                    if (got_v !== exp_v) begin
                        case_ok = 0;
                        $display("MISMATCH test=%0s row=%0d col=%0d got=%0d expected=%0d",
                                 test_name, rr, cc, got_v, exp_v);
                    end
                end
            end
            if (case_ok) begin
                $display("TB_CHECK_PASS test=%0s signal=c_flat reason=matrix_output_matches_golden", test_name);
            end else begin
                $display("TB_CHECK_FAIL test=%0s signal=c_flat reason=matrix_output_mismatch", test_name);
            end
        end
    endtask

    task automatic run_case;
        input [8*40-1:0] test_name;
        input [255:0] a_in;
        input [255:0] b_in;
        input integer issue_twice_while_busy;
        integer case_ok;
        integer start_accept_before;
        integer done_before;
        integer stall_seen;
        integer hit_seen_first_issue;
        integer hit_seen_second_issue;
        integer done_seen;
        integer busy_seen;
        integer busy_drop_seen;
        integer start_seen;
        integer guard;
        begin
            $display("TB_INFO test=%0s status=START", test_name);
            a_flat = a_in;
            b_flat = b_in;
            golden_mm_4x4(a_in, b_in, expected);

            start_accept_before = accept_count;
            done_before = complete_count;
            stall_seen = 0;
            hit_seen_first_issue = 0;
            hit_seen_second_issue = 0;
            done_seen = 0;
            busy_seen = 0;
            busy_drop_seen = 0;
            start_seen = 0;

            issue_custom_instr_once(hit_seen_first_issue);
            repeat (2) begin
                @(posedge clk);
                if (cpu_stall) begin
                    stall_seen = 1;
                end
                if (accel_busy) begin
                    busy_seen = 1;
                end
                if (accel_done) begin
                    done_seen = 1;
                end
                if (accel_start) begin
                    start_seen = 1;
                end
                if (busy_seen && !accel_busy) begin
                    busy_drop_seen = 1;
                end
            end

            if (issue_twice_while_busy != 0) begin
                $display("TB_INFO test=%0s action=ISSUE_WHILE_BUSY", test_name);
                issue_custom_instr_once(hit_seen_second_issue);
            end

            guard = 0;
            while (!custom_complete) begin
                @(posedge clk);
                guard = guard + 1;
                if (cpu_stall) begin
                    stall_seen = 1;
                end
                if (accel_busy) begin
                    busy_seen = 1;
                end
                if (accel_done) begin
                    done_seen = 1;
                end
                if (accel_start) begin
                    start_seen = 1;
                end
                if (busy_seen && !accel_busy) begin
                    busy_drop_seen = 1;
                end
                if (guard > 1000) begin
                    case_ok = 0;
                    $display("TB_CHECK_FAIL test=%0s signal=custom_complete reason=timeout_waiting_for_completion", test_name);
                    $fatal(1, "Timeout waiting for custom completion in run_case.");
                end
            end
            @(posedge clk);
            if (busy_seen && !accel_busy) begin
                busy_drop_seen = 1;
            end
            compare_output_matrix(test_name, expected, case_ok);

            if (hit_seen_first_issue) begin
                $display("TB_CHECK_PASS test=%0s signal=custom_hit reason=matmul_instruction_decoded", test_name);
            end else begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=custom_hit reason=decode_not_observed_on_first_issue", test_name);
            end

            if ((accept_count - start_accept_before) != 1) begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=custom_accept reason=unexpected_accept_delta got=%0d expected=1",
                         test_name, (accept_count - start_accept_before));
            end else begin
                $display("TB_CHECK_PASS test=%0s signal=custom_accept reason=single_accept_pulse_seen", test_name);
            end
            if ((complete_count - done_before) != 1) begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=custom_complete reason=unexpected_complete_delta got=%0d expected=1",
                         test_name, (complete_count - done_before));
            end else begin
                $display("TB_CHECK_PASS test=%0s signal=custom_complete reason=single_complete_pulse_seen", test_name);
            end
            if (!stall_seen) begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=cpu_stall reason=stall_not_observed_during_operation", test_name);
            end else begin
                $display("TB_CHECK_PASS test=%0s signal=cpu_stall reason=stall_observed_while_accelerator_busy", test_name);
            end
            if (!done_seen) begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=accel_done reason=done_pulse_not_observed", test_name);
            end else begin
                $display("TB_CHECK_PASS test=%0s signal=accel_done reason=done_pulse_observed", test_name);
            end
            if (!start_seen) begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=accel_start reason=start_pulse_not_observed", test_name);
            end else begin
                $display("TB_CHECK_PASS test=%0s signal=accel_start reason=start_pulse_observed", test_name);
            end
            if (!(busy_seen && busy_drop_seen)) begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=accel_busy reason=busy_window_not_observed_correctly", test_name);
            end else begin
                $display("TB_CHECK_PASS test=%0s signal=accel_busy reason=busy_assert_and_deassert_observed", test_name);
            end
            if (accel_cycle_count !== 8'd10) begin
                case_ok = 0;
                $display("TB_CHECK_FAIL test=%0s signal=accel_cycle_count reason=unexpected_cycle_count got=%0d expected=10",
                         test_name, accel_cycle_count);
            end else begin
                $display("TB_CHECK_PASS test=%0s signal=accel_cycle_count reason=expected_latency_10_cycles", test_name);
            end

            if (issue_twice_while_busy != 0) begin
                if (hit_seen_second_issue) begin
                    $display("TB_CHECK_PASS test=%0s signal=custom_hit reason=second_issue_decoded_while_busy", test_name);
                end else begin
                    case_ok = 0;
                    $display("TB_CHECK_FAIL test=%0s signal=custom_hit reason=second_issue_decode_not_observed", test_name);
                end
                if ((accept_count - start_accept_before) == 1) begin
                    $display("TB_CHECK_PASS test=%0s signal=custom_accept reason=second_issue_ignored_while_busy", test_name);
                end
            end

            total_count = total_count + 1;
            if (case_ok) begin
                pass_count = pass_count + 1;
                $display("TB_PASS test=%0s", test_name);
            end else begin
                $display("TB_FAIL test=%0s", test_name);
            end

            $display("RESULT test=%0s pass=%0d accel_cycles=%0d",
                     test_name, case_ok, accel_cycle_count);
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            accept_count <= 0;
            complete_count <= 0;
        end else begin
            if (custom_accept) begin
                accept_count <= accept_count + 1;
            end
            if (custom_complete) begin
                complete_count <= complete_count + 1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst = 1'b1;
        instr_valid = 1'b0;
        instr_word = 32'd0;
        a_flat = 256'd0;
        b_flat = 256'd0;
        pass_count = 0;
        total_count = 0;
        accept_count = 0;
        complete_count = 0;

        $display("TB_INFO status=BEGIN_RISCV_INTEGRATION_REGRESSION");

        repeat (3) @(posedge clk);
        rst = 1'b0;

        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, ((r * N + c + 1) <<< 10));
                if (r == c) begin
                    set_elem(b_case, r, c, (1 <<< 10));
                end
            end
        end
        run_case("identity_custom", a_case, b_case, 0);

        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, (1 <<< 10));
                set_elem(b_case, r, c, (1 <<< 10));
            end
        end
        run_case("issue_while_busy", a_case, b_case, 1);

        a_case = 256'd0;
        b_case = 256'd0;
        set_elem(a_case, 0, 0, (1 <<< 10));   set_elem(a_case, 0, 1, (-2 <<< 10));  set_elem(a_case, 0, 2, (3 <<< 10));   set_elem(a_case, 0, 3, (-4 <<< 10));
        set_elem(a_case, 1, 0, (-1 <<< 10));  set_elem(a_case, 1, 1, (2 <<< 10));   set_elem(a_case, 1, 2, (-3 <<< 10));  set_elem(a_case, 1, 3, (4 <<< 10));
        set_elem(a_case, 2, 0, (5 <<< 10));   set_elem(a_case, 2, 1, (-6 <<< 10));  set_elem(a_case, 2, 2, (7 <<< 10));   set_elem(a_case, 2, 3, (-8 <<< 10));
        set_elem(a_case, 3, 0, (-5 <<< 10));  set_elem(a_case, 3, 1, (6 <<< 10));   set_elem(a_case, 3, 2, (-7 <<< 10));  set_elem(a_case, 3, 3, (8 <<< 10));

        set_elem(b_case, 0, 0, (1 <<< 10));   set_elem(b_case, 0, 1, 16'sd0);       set_elem(b_case, 0, 2, (-1 <<< 10));  set_elem(b_case, 0, 3, (2 <<< 10));
        set_elem(b_case, 1, 0, (2 <<< 10));   set_elem(b_case, 1, 1, (-1 <<< 10));  set_elem(b_case, 1, 2, 16'sd0);       set_elem(b_case, 1, 3, (1 <<< 10));
        set_elem(b_case, 2, 0, (-2 <<< 10));  set_elem(b_case, 2, 1, (1 <<< 10));   set_elem(b_case, 2, 2, (1 <<< 10));   set_elem(b_case, 2, 3, 16'sd0);
        set_elem(b_case, 3, 0, 16'sd0);       set_elem(b_case, 3, 1, (2 <<< 10));   set_elem(b_case, 3, 2, (-1 <<< 10));  set_elem(b_case, 3, 3, (-2 <<< 10));
        run_case("signed_mixed_custom", a_case, b_case, 0);

        $display("SUMMARY pass=%0d total=%0d", pass_count, total_count);
        if (pass_count != total_count) begin
            $display("TB_FAIL summary pass=%0d total=%0d", pass_count, total_count);
            $fatal(1, "Integration simulation failed one or more checks.");
        end else begin
            $display("TB_PASS summary pass=%0d total=%0d", pass_count, total_count);
        end

        $finish;
    end

endmodule
