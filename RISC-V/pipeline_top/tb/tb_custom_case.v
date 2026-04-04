`timescale 1ns/1ps

// tb_custom_case.v
//
// Custom-case cycle benchmark for rv32_pipeline + PCPI accelerator.
// Matrix A and B are supplied via the generated include file:
//   RISC-V/pipeline_top/tb/custom_case_data.vh
// which is produced by gen_custom_case.py before compilation.
//
// Runs both paths and prints results parseable by run_custom_case.ps1:
//   CUSTOM_CASE [ACCEL] cycles=<N>
//   CUSTOM_CASE [ACCEL] C[r][c] exp=0xXXXX got=0xXXXX PASS|FAIL
//   CUSTOM_CASE [ACCEL] verify: <N>/16 PASS|FAIL
//   CUSTOM_CASE [SW]    cycles=<N>
//   CUSTOM_CASE [SW]    C[r][c] exp=0xXXXX got=0xXXXX PASS|FAIL
//   CUSTOM_CASE [SW]    verify: <N>/16 PASS|FAIL
//   CUSTOM_CASE speedup_int=<N>  speedup_frac=<D>  cycles_accel=<N>  cycles_sw=<N>
//
// Compile with:  iverilog -g2012 -I RISC-V/pipeline_top/tb ...rtl... tb_custom_case.v
// Run from:      RISC-V/pipeline_top/   (so firmware/... hex path resolves)

`include "custom_case_data.vh"

module tb_custom_case;

    // ─── Clock ────────────────────────────────────────────────────────────
    reg clk;
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ─── Instruction encodings ────────────────────────────────────────────
    localparam [31:0] NOP           = 32'h00000013;
    localparam [31:0] ADDI_X1_256  = 32'h10000093;  // ADDI x1, x0, 256 (A_BASE=0x100)
    localparam [31:0] ADDI_X2_320  = 32'h14000113;  // ADDI x2, x0, 320 (B_BASE=0x140)
    // custom-0: funct7=0101010 rs2=x2 rs1=x1 funct3=000 rd=x3 opcode=0001011
    localparam [31:0] CUSTOM_MATMUL = 32'h5420818B;

    // ─── A/B packed words (from include) ─────────────────────────────────
    reg [31:0] A_packed [0:7];
    reg [31:0] B_packed [0:7];

    // ─── Expected C (from include) ────────────────────────────────────────
    reg [15:0] exp_c [0:15];

    integer i, r, c;
    integer accel_cycles, sw_cycles, guard;

    // ─── ACCEL DUT ────────────────────────────────────────────────────────
    reg        rst_a;
    reg [31:0] ext_instr_word_a;
    reg        ext_instr_valid_a;
    reg        host_mem_we_a;
    reg [31:0] host_mem_addr_a;
    reg [31:0] host_mem_wdata_a;

    wire [31:0]  host_mem_rdata_a;
    wire [31:0]  dbg_pc_if_a;
    wire [31:0]  dbg_instr_if_a;
    wire [31:0]  dbg_instr_id_a;
    wire         dbg_stall_a;
    wire         dbg_custom_inflight_a;
    wire         dbg_wb_regwrite_a;
    wire [4:0]   dbg_wb_rd_a;
    wire [31:0]  dbg_wb_data_a;
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

    // ─── SW DUT ───────────────────────────────────────────────────────────
    reg        rst_sw;
    wire [31:0] dbg_pc_if_sw;
    wire [31:0] dbg_instr_if_sw;
    wire [31:0] dbg_instr_id_sw;
    wire        dbg_stall_sw;
    wire        dbg_custom_inflight_sw;
    wire        dbg_wb_regwrite_sw;
    wire [4:0]  dbg_wb_rd_sw;
    wire [31:0] dbg_wb_data_sw;

    rv32_pipeline_top u_sw (
        .clk             (clk),
        .rst             (rst_sw),
        .ext_instr_word  (32'h00000013),
        .ext_instr_valid (1'b0),
        .use_ext_instr   (1'b0),
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

    // ─── Tasks ────────────────────────────────────────────────────────────
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

    // ─── Main stimulus ────────────────────────────────────────────────────
    initial begin

        // Initialise packed arrays from localparams (generated by gen_custom_case.py)
        A_packed[0] = A_WORD_0; A_packed[1] = A_WORD_1;
        A_packed[2] = A_WORD_2; A_packed[3] = A_WORD_3;
        A_packed[4] = A_WORD_4; A_packed[5] = A_WORD_5;
        A_packed[6] = A_WORD_6; A_packed[7] = A_WORD_7;

        B_packed[0] = B_WORD_0; B_packed[1] = B_WORD_1;
        B_packed[2] = B_WORD_2; B_packed[3] = B_WORD_3;
        B_packed[4] = B_WORD_4; B_packed[5] = B_WORD_5;
        B_packed[6] = B_WORD_6; B_packed[7] = B_WORD_7;

        exp_c[ 0] = EXP_C_00; exp_c[ 1] = EXP_C_01;
        exp_c[ 2] = EXP_C_02; exp_c[ 3] = EXP_C_03;
        exp_c[ 4] = EXP_C_04; exp_c[ 5] = EXP_C_05;
        exp_c[ 6] = EXP_C_06; exp_c[ 7] = EXP_C_07;
        exp_c[ 8] = EXP_C_08; exp_c[ 9] = EXP_C_09;
        exp_c[10] = EXP_C_10; exp_c[11] = EXP_C_11;
        exp_c[12] = EXP_C_12; exp_c[13] = EXP_C_13;
        exp_c[14] = EXP_C_14; exp_c[15] = EXP_C_15;

        // Defaults
        rst_a             = 1'b0; rst_sw = 1'b0;
        ext_instr_word_a  = NOP;  ext_instr_valid_a = 1'b0;
        host_mem_we_a     = 1'b0; host_mem_addr_a   = 32'd0;
        host_mem_wdata_a  = 32'd0;
        accel_cycles = 0; sw_cycles = 0;

        // ══ ACCEL RUN ════════════════════════════════════════════════════
        repeat(4) @(posedge clk);
        rst_a = 1'b1;
        repeat(2) @(posedge clk);

        // Pre-load A and B (packed 2 Q5.10 per 32-bit word)
        for (i = 0; i < 8; i = i + 1)
            host_write(32'h100 + (i << 2), A_packed[i]);
        for (i = 0; i < 8; i = i + 1)
            host_write(32'h140 + (i << 2), B_packed[i]);

        // Inject: set rs1=A_BASE, rs2=B_BASE, then custom instruction
        inject(ADDI_X1_256);
        inject(ADDI_X2_320);
        inject(NOP); inject(NOP); inject(NOP); inject(NOP); inject(NOP);
        inject(CUSTOM_MATMUL);
        inject(NOP); inject(NOP);

        // Wait for pcpi_valid to assert
        guard = 0;
        while (!dbg_custom_inflight_a) begin
            @(posedge clk); guard = guard + 1;
            if (guard > 200) begin $display("CUSTOM_CASE [ERROR] ACCEL pcpi_valid timeout"); $finish; end
        end

        // Count stall cycles until pcpi_ready
        guard = 0; accel_cycles = 0;
        while (!dbg_accel_done_a) begin
            @(posedge clk);
            accel_cycles = accel_cycles + 1;
            guard = guard + 1;
            if (guard > 200) begin $display("CUSTOM_CASE [ERROR] ACCEL pcpi_ready timeout"); $finish; end
        end

        $display("CUSTOM_CASE [ACCEL] cycles=%0d", accel_cycles);

        // Verify all 16 C elements against expected
        begin : accel_verify
            reg [15:0] c_got [0:15];
            integer elem, accel_fails;
            @(posedge clk); // let memory settle
            for (elem = 0; elem < 8; elem = elem + 1) begin
                c_got[elem*2  ] = u_accel.mem[(32'h200>>2) + elem][15:0];
                c_got[elem*2+1] = u_accel.mem[(32'h200>>2) + elem][31:16];
            end
            accel_fails = 0;
            for (elem = 0; elem < 16; elem = elem + 1) begin
                if (c_got[elem] === exp_c[elem])
                    $display("CUSTOM_CASE [ACCEL] C[%0d][%0d] exp=0x%04h got=0x%04h PASS",
                        elem/4, elem%4, exp_c[elem], c_got[elem]);
                else begin
                    $display("CUSTOM_CASE [ACCEL] C[%0d][%0d] exp=0x%04h got=0x%04h FAIL",
                        elem/4, elem%4, exp_c[elem], c_got[elem]);
                    accel_fails = accel_fails + 1;
                end
            end
            if (accel_fails == 0)
                $display("CUSTOM_CASE [ACCEL] verify: 16/16 PASS");
            else
                $display("CUSTOM_CASE [ACCEL] verify: %0d/16 FAIL", 16 - accel_fails);
        end

        // ══ SW RUN ═══════════════════════════════════════════════════════
        begin : fw_load
            reg [31:0] fw_buf [0:255];
            $readmemh("firmware/firmware_sw_bench.hex", fw_buf);
            for (i = 0; i < 256; i = i + 1)
                u_sw.imem[i] = fw_buf[i];
        end
        if (u_sw.imem[0] === 32'bx) begin
            $display("CUSTOM_CASE [ERROR] imem load failed"); $finish;
        end

        // Pre-load A and B directly into u_sw dmem
        for (i = 0; i < 8; i = i + 1) begin
            u_sw.dmem.MEM[64 + i] = A_packed[i];
            u_sw.dmem.MEM[80 + i] = B_packed[i];
        end
        u_sw.dmem.MEM[0] = 32'd0;  // clear sentinel

        repeat(4) @(posedge clk);
        rst_sw = 1'b1;

        // Count cycles until sentinel written
        guard = 0;
        while (u_sw.dmem.MEM[0] === 32'd0) begin
            @(posedge clk);
            sw_cycles = sw_cycles + 1;
            guard = guard + 1;
            if (guard > 50000) begin
                $display("CUSTOM_CASE [ERROR] SW timeout PC=%0h", u_sw.dbg_pc_if); $finish;
            end
        end

        $display("CUSTOM_CASE [SW]    cycles=%0d", sw_cycles);

        // Verify all 16 C elements (SW result)
        begin : sw_verify
            reg [15:0] c_got_sw [0:15];
            integer elem, sw_fails;
            for (elem = 0; elem < 8; elem = elem + 1) begin
                c_got_sw[elem*2  ] = u_sw.dmem.MEM[128 + elem][15:0];
                c_got_sw[elem*2+1] = u_sw.dmem.MEM[128 + elem][31:16];
            end
            sw_fails = 0;
            for (elem = 0; elem < 16; elem = elem + 1) begin
                if (c_got_sw[elem] === exp_c[elem])
                    $display("CUSTOM_CASE [SW]    C[%0d][%0d] exp=0x%04h got=0x%04h PASS",
                        elem/4, elem%4, exp_c[elem], c_got_sw[elem]);
                else begin
                    $display("CUSTOM_CASE [SW]    C[%0d][%0d] exp=0x%04h got=0x%04h FAIL",
                        elem/4, elem%4, exp_c[elem], c_got_sw[elem]);
                    sw_fails = sw_fails + 1;
                end
            end
            if (sw_fails == 0)
                $display("CUSTOM_CASE [SW]    verify: 16/16 PASS");
            else
                $display("CUSTOM_CASE [SW]    verify: %0d/16 FAIL", 16 - sw_fails);
        end

        // ══ Summary ═══════════════════════════════════════════════════════
        $display("CUSTOM_CASE speedup_int=%0d  speedup_frac=%01d  cycles_accel=%0d  cycles_sw=%0d",
            sw_cycles / accel_cycles,
            (sw_cycles * 10 / accel_cycles) % 10,
            accel_cycles,
            sw_cycles);
        $finish;
    end

    initial begin
        #5000000;
        $display("CUSTOM_CASE [ERROR] Global simulation timeout");
        $finish;
    end

    initial begin
        $dumpfile("tb_custom_case.vcd");
        $dumpvars(0, tb_custom_case);
    end

endmodule
