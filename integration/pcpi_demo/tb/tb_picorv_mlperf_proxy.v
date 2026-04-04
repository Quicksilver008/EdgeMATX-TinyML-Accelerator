`timescale 1ns/1ps

// ============================================================================
//  tb_picorv_mlperf_proxy.v
//
//  MLCommons Tiny AD proxy benchmark for the PicoRV32 + EdgeMATX integration.
//
//  Three DUT instances share a single clock and run sequentially:
//
//  SW PATH  (u_sw)      -- bare PicoRV32 (ENABLE_PCPI=0, no MUL),
//                          single-tile Q5.10 matmul via shift-and-add.
//                          firmware_sw_picorv_mlperf.hex
//                          A @ 0x800, B @ 0x840, C @ 0x900
//
//  SW MUL PATH (u_sw_mul) -- bare PicoRV32 (ENABLE_PCPI=0, ENABLE_MUL=1),
//                            same single-tile software Q5.10 matmul but
//                            compiled for rv32im / MUL-enabled core.
//                            firmware_sw_picorv_mlperf_mul.hex
//                            A @ 0x800, B @ 0x840, C @ 0x900
//
//  HW PATH  (u_hw_cpu + u_hw_accel)
//                        -- PicoRV32 (ENABLE_PCPI=1) + pcpi_tinyml_accel,
//                          N_TILES=32 back-to-back MATMUL_ACCEL tiles.
//                          firmware_mlperf_proxy_picorv.hex
//                          A @ 0x100, B @ 0x140, C @ 0x200
//
//  Run from repo root so $readmemh paths resolve:
//      vvp integration/pcpi_demo/results/picorv_mlperf.out
// ============================================================================

module tb_picorv_mlperf_proxy;

    localparam integer N_TILES  = 32;
    localparam integer AD_TILES = 5120;   // tiles per full Anomaly Detection inference
    localparam real    CLK_MHZ  = 100.0;
    localparam integer TIMEOUT  = 500_000;

    // ----------------------------------------------------------------
    // Clock  (10 ns period = 100 MHz)
    // ----------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ================================================================
    // SW PATH  --  bare PicoRV32, single tile software Q5.10 matmul
    // ================================================================
    reg  resetn_sw;
    reg  resetn_sw_mul;

    wire        sw_mem_valid;
    wire        sw_mem_instr;
    wire        sw_mem_ready;
    wire [31:0] sw_mem_addr;
    wire [31:0] sw_mem_wdata;
    wire [3:0]  sw_mem_wstrb;
    wire [31:0] sw_mem_rdata;

    reg [31:0] sw_mem [0:1023];
    reg [31:0] sw_mul_mem [0:1023];

    assign sw_mem_ready = 1'b1;
    assign sw_mem_rdata = sw_mem[sw_mem_addr[11:2]];

    wire        sw_mul_mem_valid;
    wire        sw_mul_mem_instr;
    wire        sw_mul_mem_ready;
    wire [31:0] sw_mul_mem_addr;
    wire [31:0] sw_mul_mem_wdata;
    wire [3:0]  sw_mul_mem_wstrb;
    wire [31:0] sw_mul_mem_rdata;

    assign sw_mul_mem_ready = 1'b1;
    assign sw_mul_mem_rdata = sw_mul_mem[sw_mul_mem_addr[11:2]];

    picorv32 #(
        .ENABLE_PCPI(0),
        .ENABLE_MUL(0),
        .ENABLE_FAST_MUL(0),
        .ENABLE_DIV(0),
        .COMPRESSED_ISA(0),
        .PROGADDR_RESET(32'h0000_0000),
        .STACKADDR(32'h0000_0800)
    ) u_sw (
        .clk(clk),
        .resetn(resetn_sw),
        .trap(),
        .mem_valid(sw_mem_valid),
        .mem_instr(sw_mem_instr),
        .mem_ready(sw_mem_ready),
        .mem_addr(sw_mem_addr),
        .mem_wdata(sw_mem_wdata),
        .mem_wstrb(sw_mem_wstrb),
        .mem_rdata(sw_mem_rdata),
        .mem_la_read(),
        .mem_la_write(),
        .mem_la_addr(),
        .mem_la_wdata(),
        .mem_la_wstrb(),
        .pcpi_valid(),
        .pcpi_insn(),
        .pcpi_rs1(),
        .pcpi_rs2(),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(32'd0),
        .eoi()
    );

    picorv32 #(
        .ENABLE_PCPI(0),
        .ENABLE_MUL(1),
        .ENABLE_FAST_MUL(0),
        .ENABLE_DIV(0),
        .COMPRESSED_ISA(0),
        .PROGADDR_RESET(32'h0000_0000),
        .STACKADDR(32'h0000_0800)
    ) u_sw_mul (
        .clk(clk),
        .resetn(resetn_sw_mul),
        .trap(),
        .mem_valid(sw_mul_mem_valid),
        .mem_instr(sw_mul_mem_instr),
        .mem_ready(sw_mul_mem_ready),
        .mem_addr(sw_mul_mem_addr),
        .mem_wdata(sw_mul_mem_wdata),
        .mem_wstrb(sw_mul_mem_wstrb),
        .mem_rdata(sw_mul_mem_rdata),
        .mem_la_read(),
        .mem_la_write(),
        .mem_la_addr(),
        .mem_la_wdata(),
        .mem_la_wstrb(),
        .pcpi_valid(),
        .pcpi_insn(),
        .pcpi_rs1(),
        .pcpi_rs2(),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(32'd0),
        .eoi()
    );

    // Memory write controller for SW path
    reg        sw_done;
    reg [31:0] sw_sentinel_val;
    reg        sw_mul_done;
    reg [31:0] sw_mul_sentinel_val;

    always @(posedge clk) begin
        if (sw_mem_valid && (|sw_mem_wstrb)) begin
            if (sw_mem_wstrb[0]) sw_mem[sw_mem_addr[11:2]][7:0]   <= sw_mem_wdata[7:0];
            if (sw_mem_wstrb[1]) sw_mem[sw_mem_addr[11:2]][15:8]  <= sw_mem_wdata[15:8];
            if (sw_mem_wstrb[2]) sw_mem[sw_mem_addr[11:2]][23:16] <= sw_mem_wdata[23:16];
            if (sw_mem_wstrb[3]) sw_mem[sw_mem_addr[11:2]][31:24] <= sw_mem_wdata[31:24];
            // Sentinel: firmware writes C[0][0] to address 0 when done
            if (sw_mem_addr == 32'h0000_0000) begin
                sw_sentinel_val <= sw_mem_wdata;
                sw_done         <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (sw_mul_mem_valid && (|sw_mul_mem_wstrb)) begin
            if (sw_mul_mem_wstrb[0]) sw_mul_mem[sw_mul_mem_addr[11:2]][7:0]   <= sw_mul_mem_wdata[7:0];
            if (sw_mul_mem_wstrb[1]) sw_mul_mem[sw_mul_mem_addr[11:2]][15:8]  <= sw_mul_mem_wdata[15:8];
            if (sw_mul_mem_wstrb[2]) sw_mul_mem[sw_mul_mem_addr[11:2]][23:16] <= sw_mul_mem_wdata[23:16];
            if (sw_mul_mem_wstrb[3]) sw_mul_mem[sw_mul_mem_addr[11:2]][31:24] <= sw_mul_mem_wdata[31:24];
            if (sw_mul_mem_addr == 32'h0000_0000) begin
                sw_mul_sentinel_val <= sw_mul_mem_wdata;
                sw_mul_done         <= 1'b1;
            end
        end
    end

    // ================================================================
    // HW PATH  --  PicoRV32 + pcpi_tinyml_accel, N_TILES tiles
    // ================================================================
    reg  resetn_hw;

    wire        hw_mem_valid;
    wire        hw_mem_instr;
    wire        hw_mem_ready;
    wire [31:0] hw_mem_addr;
    wire [31:0] hw_mem_wdata;
    wire [3:0]  hw_mem_wstrb;
    wire [31:0] hw_mem_rdata;

    wire        hw_pcpi_valid;
    wire [31:0] hw_pcpi_insn;
    wire [31:0] hw_pcpi_rs1;
    wire [31:0] hw_pcpi_rs2;
    wire        hw_pcpi_wr;
    wire [31:0] hw_pcpi_rd;
    wire        hw_pcpi_wait;
    wire        hw_pcpi_ready;

    wire        hw_accel_mem_valid;
    wire        hw_accel_mem_we;
    wire        hw_accel_mem_ready;
    wire [31:0] hw_accel_mem_addr;
    wire [31:0] hw_accel_mem_wdata;
    wire [31:0] hw_accel_mem_rdata;

    reg [31:0] hw_mem [0:1023];

    assign hw_mem_ready       = 1'b1;
    assign hw_mem_rdata       = hw_mem[hw_mem_addr[11:2]];
    assign hw_accel_mem_ready = 1'b1;
    assign hw_accel_mem_rdata = hw_mem[hw_accel_mem_addr[11:2]];

    picorv32 #(
        .ENABLE_PCPI(1),
        .ENABLE_MUL(0),
        .ENABLE_FAST_MUL(0),
        .ENABLE_DIV(0),
        .COMPRESSED_ISA(0),
        .PROGADDR_RESET(32'h0000_0000),
        .STACKADDR(32'h0000_0800)
    ) u_hw_cpu (
        .clk(clk),
        .resetn(resetn_hw),
        .trap(),
        .mem_valid(hw_mem_valid),
        .mem_instr(hw_mem_instr),
        .mem_ready(hw_mem_ready),
        .mem_addr(hw_mem_addr),
        .mem_wdata(hw_mem_wdata),
        .mem_wstrb(hw_mem_wstrb),
        .mem_rdata(hw_mem_rdata),
        .mem_la_read(),
        .mem_la_write(),
        .mem_la_addr(),
        .mem_la_wdata(),
        .mem_la_wstrb(),
        .pcpi_valid(hw_pcpi_valid),
        .pcpi_insn(hw_pcpi_insn),
        .pcpi_rs1(hw_pcpi_rs1),
        .pcpi_rs2(hw_pcpi_rs2),
        .pcpi_wr(hw_pcpi_wr),
        .pcpi_rd(hw_pcpi_rd),
        .pcpi_wait(hw_pcpi_wait),
        .pcpi_ready(hw_pcpi_ready),
        .irq(32'd0),
        .eoi()
    );

    pcpi_tinyml_accel u_hw_accel (
        .clk(clk),
        .resetn(resetn_hw),
        .pcpi_valid(hw_pcpi_valid),
        .pcpi_insn(hw_pcpi_insn),
        .pcpi_rs1(hw_pcpi_rs1),
        .pcpi_rs2(hw_pcpi_rs2),
        .pcpi_wr(hw_pcpi_wr),
        .pcpi_rd(hw_pcpi_rd),
        .pcpi_wait(hw_pcpi_wait),
        .pcpi_ready(hw_pcpi_ready),
        .accel_mem_valid(hw_accel_mem_valid),
        .accel_mem_we(hw_accel_mem_we),
        .accel_mem_addr(hw_accel_mem_addr),
        .accel_mem_wdata(hw_accel_mem_wdata),
        .accel_mem_rdata(hw_accel_mem_rdata),
        .accel_mem_ready(hw_accel_mem_ready)
    );

    // Memory write controller for HW path (CPU + accelerator sideband)
    reg        hw_done;
    reg [31:0] hw_sentinel_val;

    always @(posedge clk) begin
        if (hw_mem_valid && (|hw_mem_wstrb)) begin
            if (hw_mem_wstrb[0]) hw_mem[hw_mem_addr[11:2]][7:0]   <= hw_mem_wdata[7:0];
            if (hw_mem_wstrb[1]) hw_mem[hw_mem_addr[11:2]][15:8]  <= hw_mem_wdata[15:8];
            if (hw_mem_wstrb[2]) hw_mem[hw_mem_addr[11:2]][23:16] <= hw_mem_wdata[23:16];
            if (hw_mem_wstrb[3]) hw_mem[hw_mem_addr[11:2]][31:24] <= hw_mem_wdata[31:24];
            // Sentinel: firmware writes N_TILES to address 0 when all tiles done
            if (hw_mem_addr == 32'h0000_0000) begin
                hw_sentinel_val <= hw_mem_wdata;
                hw_done         <= 1'b1;
            end
        end else if (hw_accel_mem_valid && hw_accel_mem_we) begin
            hw_mem[hw_accel_mem_addr[11:2]] <= hw_accel_mem_wdata;
        end
    end

    // ================================================================
    // Stimulus, cycle counting, and comparison table
    // ================================================================
    integer sw_cycles;
    integer sw_mul_cycles;
    integer hw_cycles;
    integer guard;
    integer i;

    initial begin
        resetn_sw           = 1'b0;
        resetn_sw_mul       = 1'b0;
        resetn_hw           = 1'b0;
        sw_done             = 1'b0;
        sw_mul_done         = 1'b0;
        hw_done             = 1'b0;
        sw_sentinel_val     = 32'd0;
        sw_mul_sentinel_val = 32'd0;
        hw_sentinel_val     = 32'd0;
        sw_cycles           = 0;
        sw_mul_cycles       = 0;
        hw_cycles           = 0;
        guard               = 0;

        // ============================================================
        // SW PHASE: bare PicoRV32, one tile, software shift-and-add
        // ============================================================
        for (i = 0; i < 1024; i = i + 1)
            sw_mem[i] = 32'h0000_0013;   // fill with addi x0,x0,0 (NOP)
        $readmemh("integration/pcpi_demo/firmware/firmware_sw_picorv_mlperf.hex", sw_mem);

        repeat (8) @(posedge clk);
        resetn_sw = 1'b1;

        guard = 0;
        while (!sw_done) begin
            @(posedge clk);
            sw_cycles = sw_cycles + 1;
            guard     = guard     + 1;
            if (guard > TIMEOUT) begin
                $display("PICORV_MLPERF [ERROR] SW path timeout -- sentinel never written");
                $finish;
            end
        end

        resetn_sw = 1'b0;
        @(posedge clk);  // let any in-flight updates settle

        if (sw_sentinel_val === 32'h0000_0400)
            $display("PICORV_MLPERF [PASS]  SW C[0][0] = 0x%08h  (correct Q5.10 result)",
                     sw_sentinel_val);
        else
            $display("PICORV_MLPERF [WARN]  SW C[0][0] = 0x%08h  (expected 0x00000400)",
                     sw_sentinel_val);

        // ============================================================
        // SW MUL PHASE: bare PicoRV32, one tile, MUL-enabled core
        // ============================================================
        for (i = 0; i < 1024; i = i + 1)
            sw_mul_mem[i] = 32'h0000_0013;
        $readmemh("integration/pcpi_demo/firmware/firmware_sw_picorv_mlperf_mul.hex", sw_mul_mem);

        repeat (8) @(posedge clk);
        resetn_sw_mul = 1'b1;

        guard = 0;
        while (!sw_mul_done) begin
            @(posedge clk);
            sw_mul_cycles = sw_mul_cycles + 1;
            guard         = guard         + 1;
            if (guard > TIMEOUT) begin
                $display("PICORV_MLPERF [ERROR] SW MUL path timeout -- sentinel never written");
                $finish;
            end
        end

        resetn_sw_mul = 1'b0;
        @(posedge clk);

        if (sw_mul_sentinel_val === 32'h0000_0400)
            $display("PICORV_MLPERF [PASS]  SW MUL C[0][0] = 0x%08h  (correct Q5.10 result)",
                     sw_mul_sentinel_val);
        else
            $display("PICORV_MLPERF [WARN]  SW MUL C[0][0] = 0x%08h  (expected 0x00000400)",
                     sw_mul_sentinel_val);

        // ============================================================
        // HW PHASE: PicoRV32 + EdgeMATX PCPI, N_TILES=32 tiles
        // ============================================================
        for (i = 0; i < 1024; i = i + 1)
            hw_mem[i] = 32'h0000_0013;
        $readmemh("integration/pcpi_demo/firmware/firmware_mlperf_proxy_picorv.hex", hw_mem, 0, 255);

        repeat (8) @(posedge clk);
        resetn_hw = 1'b1;

        guard = 0;
        while (!hw_done) begin
            @(posedge clk);
            hw_cycles = hw_cycles + 1;
            guard     = guard     + 1;
            if (guard > TIMEOUT) begin
                $display("PICORV_MLPERF [ERROR] HW path timeout -- sentinel never written");
                $finish;
            end
        end

        resetn_hw = 1'b0;
        @(posedge clk);

        if (hw_sentinel_val === 32'd32)
            $display("PICORV_MLPERF [PASS]  HW sentinel = 0x%08h  (%0d = N_TILES, correct)",
                     hw_sentinel_val, hw_sentinel_val);
        else
            $display("PICORV_MLPERF [WARN]  HW sentinel = 0x%08h  (expected 0x00000020 = N_TILES)",
                     hw_sentinel_val);

        // ============================================================
        // Comparison table
        // ============================================================
        begin : cmp_tbl
            real hw_cpt;         // HW cycles per tile
            real sw_cpt;         // SW no-MUL cycles for 1 tile
            real sw_mul_cpt;     // SW MUL cycles for 1 tile
            real speedup_sw;
            real speedup_sw_mul;
            real mul_core_gain;
            real proxy_sw_cyc;
            real proxy_sw_mul_cyc;
            real proj_hw_cyc;
            real proj_sw_cyc;
            real proj_sw_mul_cyc;
            real proj_hw_ms;
            real proj_sw_ms;
            real proj_sw_mul_ms;
            reg [8*8-1:0] hw_tgt;
            reg [8*8-1:0] sw_tgt;
            reg [8*8-1:0] sw_mul_tgt;

            hw_cpt         = (1.0 * hw_cycles) / N_TILES;
            sw_cpt         =  1.0 * sw_cycles;
            sw_mul_cpt     =  1.0 * sw_mul_cycles;
            speedup_sw     = sw_cpt / hw_cpt;
            speedup_sw_mul = sw_mul_cpt / hw_cpt;
            mul_core_gain  = sw_cpt / sw_mul_cpt;
            proxy_sw_cyc   = sw_cpt      * N_TILES;
            proxy_sw_mul_cyc = sw_mul_cpt * N_TILES;
            proj_hw_cyc    = hw_cpt      * AD_TILES;
            proj_sw_cyc    = sw_cpt      * AD_TILES;
            proj_sw_mul_cyc= sw_mul_cpt  * AD_TILES;
            proj_hw_ms     = proj_hw_cyc      / (CLK_MHZ * 1000.0);
            proj_sw_ms     = proj_sw_cyc      / (CLK_MHZ * 1000.0);
            proj_sw_mul_ms = proj_sw_mul_cyc  / (CLK_MHZ * 1000.0);

            if (proj_hw_ms < 10.0) hw_tgt = "MEETS   "; else hw_tgt = "EXCEEDS ";
            if (proj_sw_ms < 10.0) sw_tgt = "MEETS   "; else sw_tgt = "EXCEEDS ";
            if (proj_sw_mul_ms < 10.0) sw_mul_tgt = "MEETS   "; else sw_mul_tgt = "EXCEEDS ";

            $display("");
            $display("============================================================================");
            $display("PicoRV32 AD Proxy: HW vs SW vs SW_MUL");
            $display("============================================================================");
            $display("Metric                 |    HW |   SW_I | SW_IM");
            $display("---------------------- | ----- | ------ | -----");
            $display("Cycles / 4x4 tile      | %5.1f | %6.1f | %5.1f",
                     hw_cpt, sw_cpt, sw_mul_cpt);
            $display("Speedup vs HW          | %5s | %5.1fx | %4.1fx",
                     "1x", speedup_sw, speedup_sw_mul);
            $display("Proxy cycles (%0d)      | %5d | %6.0f | %5.0f",
                     N_TILES, hw_cycles, proxy_sw_cyc, proxy_sw_mul_cyc);
            $display("AD cycles              | %5.0f | %6.0f | %5.0f",
                     proj_hw_cyc, proj_sw_cyc, proj_sw_mul_cyc);
            $display("AD ms @ %0.0f MHz       | %5.2f | %6.2f | %5.2f",
                     CLK_MHZ, proj_hw_ms, proj_sw_ms, proj_sw_mul_ms);
            $display("AD target (<10ms)      | %5s | %6s | %5s",
                     hw_tgt, sw_tgt, sw_mul_tgt);
            $display("SW_I / SW_IM benefit   |    -- |     -- | %4.1fx",
                     mul_core_gain);
            $display("============================================================================");
            $display("+30%% ovhd ms           | %5.2f | %6.2f | %5.2f",
                     proj_hw_ms * 1.3, proj_sw_ms * 1.3, proj_sw_mul_ms * 1.3);
            $display("============================================================================");
        end

        $finish;
    end

endmodule
