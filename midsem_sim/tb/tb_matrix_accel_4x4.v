`timescale 1ns/1ps

module tb_matrix_accel_4x4;

    localparam integer N = 4;
    localparam integer RANDOM_TESTS = 12;

    reg clk;
    reg rst;
    reg start;
    reg [255:0] a_flat;
    reg [255:0] b_flat;
    wire busy;
    wire done;
    wire [255:0] c_flat;
    wire [7:0] cycle_count;

    integer r;
    integer c;
    integer pass_count;
    integer total_count;
    integer seed;
    integer rand_idx;

    reg [255:0] a_case;
    reg [255:0] b_case;

    matrix_accel_4x4_q5_10 dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .a_flat(a_flat),
        .b_flat(b_flat),
        .busy(busy),
        .done(done),
        .c_flat(c_flat),
        .cycle_count(cycle_count)
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
        input signed [15:0] a;
        input signed [15:0] b;
        reg signed [31:0] full;
        begin
            full = $signed(a) * $signed(b);
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
                    set_elem(c_exp, rr, cc, acc[15:0]); // Current RTL wraps/truncates to low 16 bits
                end
            end
        end
    endtask

    task automatic pulse_start;
        begin
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
        end
    endtask

    task automatic wait_done;
        integer guard;
        begin
            guard = 0;
            while (!done) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 1000) begin
                    $display("TB_FAIL test=timeout reason=done_not_seen");
                    $fatal(1, "Timeout waiting for done.");
                end
            end
            @(posedge clk);
        end
    endtask

    task automatic compare_and_report;
        input [8*48-1:0] test_name;
        input [255:0] expected;
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
                    exp_v = get_elem(expected, rr, cc);
                    if (got_v !== exp_v) begin
                        case_ok = 0;
                        $display("MISMATCH test=%0s row=%0d col=%0d got=%0d expected=%0d",
                                 test_name, rr, cc, got_v, exp_v);
                    end
                end
            end
            if (case_ok) begin
                $display("TB_PASS test=%0s", test_name);
            end else begin
                $display("TB_FAIL test=%0s", test_name);
            end
        end
    endtask

    task automatic run_case_named;
        input [8*48-1:0] test_name;
        input [255:0] a_in;
        input [255:0] b_in;
        reg [255:0] expected;
        integer case_ok;
        begin
            $display("TB_INFO test=%0s status=START", test_name);
            a_flat = a_in;
            b_flat = b_in;
            golden_mm_4x4(a_in, b_in, expected);
            pulse_start();
            wait_done();
            compare_and_report(test_name, expected, case_ok);

            total_count = total_count + 1;
            if (case_ok) begin
                pass_count = pass_count + 1;
            end

            $display("RESULT test=%0s pass=%0d accel_cycles=%0d", test_name, case_ok, cycle_count);
        end
    endtask

    task automatic run_case_with_extra_start;
        input [8*48-1:0] test_name;
        input [255:0] a_in;
        input [255:0] b_in;
        reg [255:0] expected;
        integer case_ok;
        begin
            $display("TB_INFO test=%0s status=START", test_name);
            a_flat = a_in;
            b_flat = b_in;
            golden_mm_4x4(a_in, b_in, expected);

            pulse_start();
            repeat (2) @(posedge clk);
            $display("TB_INFO test=%0s action=EXTRA_START_WHILE_BUSY", test_name);
            pulse_start(); // should be ignored while busy
            wait_done();

            compare_and_report(test_name, expected, case_ok);
            if (cycle_count !== 8'd10) begin
                case_ok = 0;
                $display("TB_FAIL test=%0s reason=unexpected_cycle_count got=%0d expected=10",
                         test_name, cycle_count);
            end

            total_count = total_count + 1;
            if (case_ok) begin
                pass_count = pass_count + 1;
            end

            $display("RESULT test=%0s pass=%0d accel_cycles=%0d", test_name, case_ok, cycle_count);
        end
    endtask

    task automatic run_reset_abort_case;
        input [255:0] a_in;
        input [255:0] b_in;
        integer case_ok;
        begin
            $display("TB_INFO test=reset_abort status=START");
            a_flat = a_in;
            b_flat = b_in;
            pulse_start();
            repeat (3) @(posedge clk);
            $display("TB_INFO test=reset_abort action=ASSERT_RESET_MID_RUN");
            rst <= 1'b1;
            repeat (2) @(posedge clk);
            rst <= 1'b0;
            @(posedge clk);

            case_ok = 1;
            if (busy !== 1'b0) begin
                case_ok = 0;
                $display("TB_FAIL test=reset_abort reason=busy_not_cleared busy=%b", busy);
            end
            if (done !== 1'b0) begin
                case_ok = 0;
                $display("TB_FAIL test=reset_abort reason=done_not_low done=%b", done);
            end
            if (cycle_count !== 8'd0) begin
                case_ok = 0;
                $display("TB_FAIL test=reset_abort reason=cycle_not_reset cycle_count=%0d", cycle_count);
            end

            if (case_ok) begin
                $display("TB_PASS test=reset_abort");
            end else begin
                $display("TB_FAIL test=reset_abort");
            end

            total_count = total_count + 1;
            if (case_ok) begin
                pass_count = pass_count + 1;
            end

            $display("RESULT test=reset_abort pass=%0d accel_cycles=%0d", case_ok, cycle_count);
        end
    endtask

    task automatic fill_random_matrix;
        output reg [255:0] mat;
        inout integer seed_io;
        integer rr;
        integer cc;
        integer raw;
        reg signed [15:0] val;
        begin
            mat = 256'd0;
            for (rr = 0; rr < N; rr = rr + 1) begin
                for (cc = 0; cc < N; cc = cc + 1) begin
                    raw = $random(seed_io);
                    val = (raw & 16'h7fff) - 16384; // ~[-16, +16) in Q5.10
                    set_elem(mat, rr, cc, val);
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst = 1'b1;
        start = 1'b0;
        a_flat = 256'd0;
        b_flat = 256'd0;
        pass_count = 0;
        total_count = 0;
        seed = 32'h20260303;

        $display("TB_INFO status=BEGIN_HARDENING_REGRESSION random_seed=0x%08h", seed);

        repeat (3) @(posedge clk);
        rst = 1'b0;

        // Directed 1: identity
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
        run_case_named("identity", a_case, b_case);

        // Directed 2: ones x ones
        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, (1 <<< 10));
                set_elem(b_case, r, c, (1 <<< 10));
            end
        end
        run_case_named("ones", a_case, b_case);

        // Directed 3: signed mixed values
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
        run_case_named("signed_mixed", a_case, b_case);

        // Directed 4: overflow/wrap behavior check
        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, 16'sd20000);
                set_elem(b_case, r, c, 16'sd20000);
            end
        end
        run_case_named("overflow_wrap", a_case, b_case);

        // Corner 1: start while busy must not retrigger
        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, ((r + c + 1) <<< 10));
                if (r == c) begin
                    set_elem(b_case, r, c, (1 <<< 10));
                end
            end
        end
        run_case_with_extra_start("start_while_busy", a_case, b_case);

        // Corner 2: reset asserted during active compute
        fill_random_matrix(a_case, seed);
        fill_random_matrix(b_case, seed);
        run_reset_abort_case(a_case, b_case);

        // Corner 2b: post-reset recovery
        a_case = 256'd0;
        b_case = 256'd0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                set_elem(a_case, r, c, ((r * N + c + 2) <<< 10));
                if (r == c) begin
                    set_elem(b_case, r, c, (1 <<< 10));
                end
            end
        end
        run_case_named("post_reset_recovery", a_case, b_case);

        // Random regression
        for (rand_idx = 0; rand_idx < RANDOM_TESTS; rand_idx = rand_idx + 1) begin
            fill_random_matrix(a_case, seed);
            fill_random_matrix(b_case, seed);
            $display("TB_INFO test=random_%0d status=START", rand_idx);
            a_flat = a_case;
            b_flat = b_case;
            begin : RAND_CASE
                reg [255:0] expected_rand;
                integer rand_ok;
                golden_mm_4x4(a_case, b_case, expected_rand);
                pulse_start();
                wait_done();
                compare_and_report("random", expected_rand, rand_ok);
                if (rand_ok) begin
                    $display("TB_PASS test=random_%0d", rand_idx);
                end else begin
                    $display("TB_FAIL test=random_%0d", rand_idx);
                end
                total_count = total_count + 1;
                if (rand_ok) begin
                    pass_count = pass_count + 1;
                end
                $display("RESULT test=random_%0d pass=%0d accel_cycles=%0d", rand_idx, rand_ok, cycle_count);
            end
        end

        $display("SUMMARY pass=%0d total=%0d", pass_count, total_count);
        if (pass_count != total_count) begin
            $display("TB_FAIL summary pass=%0d total=%0d", pass_count, total_count);
            $fatal(1, "Simulation failed one or more checks.");
        end else begin
            $display("TB_PASS summary pass=%0d total=%0d", pass_count, total_count);
        end
        $finish;
    end

endmodule
