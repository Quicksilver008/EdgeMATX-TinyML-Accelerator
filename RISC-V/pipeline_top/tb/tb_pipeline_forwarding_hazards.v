`timescale 1ns/1ps
// tb_pipeline_forwarding_hazards.v
//
// Tests four hazard / forwarding scenarios unique to the 5-stage pipeline.
// The DUT is rv32_pipeline_top run from its own imem (use_ext_instr=0).
// A shadow register file captures every writeback via dbg_wb_* ports;
// after 60 cycles all results are checked.
//
// Case 1 — EX/MEM forwarding
//   ADDI x1,x0,10 immediately followed by ADD x2,x1,x1.
//   When ADD x2 is in EX, ADDI x1 is in MEM → EX/MEM forward fires.
//   Expected: x2 = 20
//
// Case 2 — MEM/WB forwarding
//   ADDI x3,x0,5  NOP  ADD x4,x3,x3
//   1-NOP gap: when ADD x4 is in EX, ADDI x3 is in WB → MEM/WB forward fires.
//   Expected: x4 = 10
//
// Case 3 — Load-use stall
//   SW x5,4(x0) stores 42; LW x6,4(x0) immediately followed by ADD x7,x6,x6.
//   Hazard-detection unit inserts 1 bubble; forwarded load value reaches ADD.
//   Expected: x7 = 84
//
// Case 4 — WB→ID write-through bypass (N+3 simultaneous read/write hazard)
//   ADDI x8,x0,100  NOP  NOP  ADDI x9,x8,0
//   At the N+3 distance ADDI x8 WB writes and ADDI x9 ID reads the same cycle.
//   Without the register-file write-through bypass, x9 would read stale x8=0.
//   Expected: x9 = 100

module tb_pipeline_forwarding_hazards;

    localparam [31:0] NOP = 32'h00000013; // ADDI x0, x0, 0

    // Pre-encoded instructions (see MODULE_NOTES above for derivation)
    localparam [31:0] ADDI_X1_10   = 32'h00A00093; // ADDI x1, x0, 10
    localparam [31:0] ADD_X2_X1_X1 = 32'h00108133; // ADD  x2, x1, x1
    localparam [31:0] ADDI_X3_5    = 32'h00500193; // ADDI x3, x0, 5
    localparam [31:0] ADD_X4_X3_X3 = 32'h00318233; // ADD  x4, x3, x3
    localparam [31:0] ADDI_X5_42   = 32'h02A00293; // ADDI x5, x0, 42
    localparam [31:0] SW_X5_4_X0   = 32'h00502223; // SW   x5, 4(x0)
    localparam [31:0] LW_X6_4_X0   = 32'h00402303; // LW   x6, 4(x0)
    localparam [31:0] ADD_X7_X6_X6 = 32'h006303B3; // ADD  x7, x6, x6
    localparam [31:0] ADDI_X8_100  = 32'h06400413; // ADDI x8, x0, 100
    localparam [31:0] ADDI_X9_X8_0 = 32'h00040493; // ADDI x9, x8, 0

    // ── DUT signals ──────────────────────────────────────────────────────
    reg        clk, rst;
    wire       pcpi_valid;
    wire [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
    wire [31:0] dbg_pc_if, dbg_instr_if, dbg_instr_id, dbg_wb_data;
    wire        dbg_stall, dbg_custom_inflight, dbg_wb_regwrite;
    wire [4:0]  dbg_wb_rd;

    // Shadow register file — updated on every WB writeback
    reg [31:0] rf [0:31];
    integer    pass_count, fail_count, i;

    // ── DUT ───────────────────────────────────────────────────────────────
    rv32_pipeline_top dut (
        .clk              (clk),
        .rst              (rst),
        .ext_instr_word   (NOP),   // ignored (use_ext_instr=0)
        .ext_instr_valid  (1'b0),
        .use_ext_instr    (1'b0),  // run from imem
        .pcpi_wait        (1'b0),
        .pcpi_ready       (1'b0),
        .pcpi_wr          (1'b0),
        .pcpi_rd          (32'h0),
        .dbg_pc_if        (dbg_pc_if),
        .dbg_instr_if     (dbg_instr_if),
        .dbg_instr_id     (dbg_instr_id),
        .dbg_stall        (dbg_stall),
        .dbg_custom_inflight (dbg_custom_inflight),
        .dbg_wb_regwrite  (dbg_wb_regwrite),
        .dbg_wb_rd        (dbg_wb_rd),
        .dbg_wb_data      (dbg_wb_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Capture every writeback into the shadow register file
    always @(posedge clk)
        if (dbg_wb_regwrite && dbg_wb_rd != 5'd0)
            rf[dbg_wb_rd] <= dbg_wb_data;

    // ── Check helper ──────────────────────────────────────────────────────
    task automatic check_reg;
        input integer      reg_num;
        input [31:0]       expected;
        input [8*48-1:0]   label;
        begin
            if (rf[reg_num] !== expected) begin
                $display("PIPELINE_HAZARD [FAIL] %-40s  x%0d expected %0d got %0d",
                         label, reg_num, $signed(expected), $signed(rf[reg_num]));
                fail_count = fail_count + 1;
            end else begin
                $display("PIPELINE_HAZARD [PASS] %-40s  x%0d = %0d",
                         label, reg_num, $signed(rf[reg_num]));
                pass_count = pass_count + 1;
            end
        end
    endtask

    // ── Stimulus ──────────────────────────────────────────────────────────
    initial begin : stim
        // Initialise shadow RF and counters
        for (i = 0; i < 32; i = i + 1) rf[i] = 32'd0;
        pass_count = 0; fail_count = 0;

        // Fill entire imem with NOPs so the pipeline never stalls on garbage
        for (i = 0; i < 256; i = i + 1) dut.imem[i] = NOP;

        // ── Case 1: EX/MEM forwarding — back-to-back ──────────────────────
        dut.imem[0] = ADDI_X1_10;    // x1 = 10
        dut.imem[1] = ADD_X2_X1_X1;  // x2 = x1+x1 = 20  (EX/MEM forward)
        dut.imem[2] = NOP;

        // ── Case 2: MEM/WB forwarding — 1 NOP gap ────────────────────────
        dut.imem[3] = ADDI_X3_5;     // x3 = 5
        dut.imem[4] = NOP;            // 1-cycle gap
        dut.imem[5] = ADD_X4_X3_X3;  // x4 = x3+x3 = 10  (MEM/WB forward)
        dut.imem[6] = NOP;

        // ── Case 3: Load-use stall ─────────────────────────────────────────
        dut.imem[7]  = ADDI_X5_42;   // x5 = 42
        dut.imem[8]  = SW_X5_4_X0;   // dmem[1] = 42  (byte addr 4)
        dut.imem[9]  = LW_X6_4_X0;   // x6 = dmem[1]  → load-use hazard with [10]
        dut.imem[10] = ADD_X7_X6_X6; // x7 = x6+x6 = 84  (stall + MEM/WB forward)
        dut.imem[11] = NOP;

        // ── Case 4: WB→ID write-through bypass (N+3 hazard) ───────────────
        dut.imem[12] = ADDI_X8_100;  // x8 = 100
        dut.imem[13] = NOP;           // x8 in EX
        dut.imem[14] = NOP;           // x8 in MEM, x9 in IF: N+3 distance
        dut.imem[15] = ADDI_X9_X8_0; // x9 = x8+0 = 100  (WB bypass fires)
        // imem[16..255] = NOP  (already set above)

        // ── Run pipeline ──────────────────────────────────────────────────
        rst = 1'b0;
        repeat(4) @(posedge clk);
        rst = 1'b1;

        // 60 cycles is easily enough for all instructions to retire
        // (last instruction x9 WB ~22 cycles from rst, plus load-use stall ~+1)
        repeat(60) @(posedge clk);

        // ── Verify ────────────────────────────────────────────────────────
        check_reg(2,  32'd20,  "EX/MEM fwd    ADD x2 = x1+x1");
        check_reg(4,  32'd10,  "MEM/WB fwd    ADD x4 = x3+x3");
        check_reg(7,  32'd84,  "load-use stall ADD x7 = x6+x6");
        check_reg(9,  32'd100, "WB bypass      ADDI x9 = x8+0");

        // ── Summary ───────────────────────────────────────────────────────
        $display("------------------------------------------------------");
        $display("PIPELINE_HAZARD SUMMARY: passed=%0d total=4", pass_count);
        if (fail_count == 0)
            $display("PIPELINE_HAZARD TB_PASS ALL_CHECKS_PASSED");
        else
            $display("PIPELINE_HAZARD TB_FAIL %0d/%0d checks FAILED", fail_count, 4);
        $finish;
    end

    initial begin
        #10000;
        $display("PIPELINE_HAZARD [ERROR] simulation timeout");
        $finish;
    end

    initial begin
        $dumpfile("tb_pipeline_forwarding_hazards.vcd");
        $dumpvars(0, tb_pipeline_forwarding_hazards);
    end

endmodule
