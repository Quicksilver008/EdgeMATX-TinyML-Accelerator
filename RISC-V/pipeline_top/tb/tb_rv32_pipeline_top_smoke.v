`timescale 1ns/1ps

module tb_rv32_pipeline_top_smoke;

    localparam [31:0] NOP = 32'h00000013;
    localparam [31:0] CUSTOM_MATMUL = 32'b0101010_00010_00001_000_00101_0001011;

    reg clk;
    reg rst;
    reg [31:0] ext_instr_word;
    reg ext_instr_valid;
    reg use_ext_instr;

    reg accel_busy;
    reg accel_done;
    reg [31:0] accel_result;

    wire accel_start;
    wire [31:0] accel_src0;
    wire [31:0] accel_src1;
    wire [4:0] accel_rd;
    wire [31:0] dbg_pc_if;
    wire [31:0] dbg_instr_if;
    wire [31:0] dbg_instr_id;
    wire dbg_stall;
    wire dbg_custom_inflight;
    wire dbg_wb_regwrite;
    wire [4:0] dbg_wb_rd;
    wire [31:0] dbg_wb_data;

    integer i;

    rv32_pipeline_top dut (
        .clk(clk),
        .rst(rst),
        .ext_instr_word(ext_instr_word),
        .ext_instr_valid(ext_instr_valid),
        .use_ext_instr(use_ext_instr),
        .accel_busy(accel_busy),
        .accel_done(accel_done),
        .accel_result(accel_result),
        .accel_start(accel_start),
        .accel_src0(accel_src0),
        .accel_src1(accel_src1),
        .accel_rd(accel_rd),
        .dbg_pc_if(dbg_pc_if),
        .dbg_instr_if(dbg_instr_if),
        .dbg_instr_id(dbg_instr_id),
        .dbg_stall(dbg_stall),
        .dbg_custom_inflight(dbg_custom_inflight),
        .dbg_wb_regwrite(dbg_wb_regwrite),
        .dbg_wb_rd(dbg_wb_rd),
        .dbg_wb_data(dbg_wb_data)
    );

    task automatic issue_ext_instr(input [31:0] instr);
        begin
            @(posedge clk);
            ext_instr_word <= instr;
            ext_instr_valid <= 1'b1;
            @(posedge clk);
            ext_instr_valid <= 1'b0;
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
        accel_busy = 1'b0;
        accel_done = 1'b0;
        accel_result = 32'h12345678;

        repeat (4) @(posedge clk);
        rst = 1'b1;

        // Warm up
        issue_ext_instr(NOP);
        issue_ext_instr(NOP);

        // Trigger custom instruction
        issue_ext_instr(CUSTOM_MATMUL);

        // Hold accelerator busy for a few cycles, then complete
        repeat (2) @(posedge clk);
        accel_busy <= 1'b1;
        repeat (4) @(posedge clk);
        accel_busy <= 1'b0;
        accel_done <= 1'b1;
        @(posedge clk);
        accel_done <= 1'b0;

        // Continue with NOPs
        for (i = 0; i < 4; i = i + 1) begin
            issue_ext_instr(NOP);
        end

        $display("TB_PASS smoke test completed.");
        $finish;
    end

    initial begin
        $dumpfile("tb_rv32_pipeline_top_smoke.vcd");
        $dumpvars(0, tb_rv32_pipeline_top_smoke);
    end

endmodule
