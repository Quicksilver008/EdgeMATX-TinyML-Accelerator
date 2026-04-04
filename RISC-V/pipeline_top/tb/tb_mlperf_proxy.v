`timescale 1ns/1ps

// tb_mlperf_proxy.v
//
// MLCommons Tiny Anomaly Detection — HW Accelerator vs Software comparison.
//
// Two independent DUT paths share the same clock but have separate resets:
//
//   HW PATH  (u_proxy)  — rv32_pipeline_pcpi_system
//     Runs firmware_mlperf_proxy.hex which issues N_TILES=32 back-to-back
//     MATMUL_ACCEL (PCPI) calls.  Each call drives the real 4×4 Q5.10
//     systolic-array RTL.  Measures total cycles for 32 tiles.
//
//   SW PATH  (u_sw)  — rv32_pipeline_top (bare, no PCPI)
//     Runs firmware_sw_bench.hex which computes one 4×4 matmul entirely in
//     software (RV32I shift-and-add Q5.10 multiply, no MUL extension).
//     Measures cycles for 1 tile; extrapolates to N_TILES and AD inference.
//
// Both paths use the same A=identity, B=counting test matrices.
// After both runs a tabular comparison is printed against the MLPerf Tiny
// Anomaly Detection target (< 10 ms @ 100 MHz).
//
// Run:  cd RISC-V/pipeline_top && vvp mlperf_proxy.vvp
//       (or use run_mlperf_proxy.ps1 which does everything from the root)

module tb_mlperf_proxy;

    // ──────────────────────────────────────────────────────────────────────
    // 10 ns clock (100 MHz)
    // ──────────────────────────────────────────────────────────────────────
    reg clk;
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ──────────────────────────────────────────────────────────────────────
    // Benchmark / MLPerf Tiny constants
    // ──────────────────────────────────────────────────────────────────────
    localparam integer N_TILES      = 32;          // tiles in proxy HW run
    localparam integer AD_TILES_TOT = 5 * 32 * 32; // 5120: full AD inference

    // ──────────────────────────────────────────────────────────────────────
    // HW PATH signals  (rv32_pipeline_pcpi_system)
    // ──────────────────────────────────────────────────────────────────────
    reg        rst_hw;
    reg        host_mem_we;
    reg [31:0] host_mem_addr;
    reg [31:0] host_mem_wdata;
    wire [31:0] host_mem_rdata;
    wire [31:0] dbg_pc_if_hw;
    wire [31:0] dbg_instr_if_hw;
    wire [31:0] dbg_instr_id_hw;
    wire        dbg_stall_hw;
    wire        dbg_custom_inflight_hw;
    wire        dbg_wb_regwrite_hw;
    wire [4:0]  dbg_wb_rd_hw;
    wire [31:0] dbg_wb_data_hw;
    wire [255:0] mat_c_flat;
    wire         dbg_accel_done;

    rv32_pipeline_pcpi_system u_proxy (
        .clk             (clk),
        .rst             (rst_hw),
        .ext_instr_word  (32'h00000013),
        .ext_instr_valid (1'b0),
        .use_ext_instr   (1'b0),
        .host_mem_we     (host_mem_we),
        .host_mem_addr   (host_mem_addr),
        .host_mem_wdata  (host_mem_wdata),
        .host_mem_rdata  (host_mem_rdata),
        .dbg_pc_if           (dbg_pc_if_hw),
        .dbg_instr_if        (dbg_instr_if_hw),
        .dbg_instr_id        (dbg_instr_id_hw),
        .dbg_stall           (dbg_stall_hw),
        .dbg_custom_inflight (dbg_custom_inflight_hw),
        .dbg_wb_regwrite     (dbg_wb_regwrite_hw),
        .dbg_wb_rd           (dbg_wb_rd_hw),
        .dbg_wb_data         (dbg_wb_data_hw),
        .mat_c_flat          (mat_c_flat),
        .dbg_accel_done      (dbg_accel_done)
    );

    // ──────────────────────────────────────────────────────────────────────
    // SW PATH signals  (rv32_pipeline_top, bare — no PCPI)
    // ──────────────────────────────────────────────────────────────────────
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

    // ──────────────────────────────────────────────────────────────────────
    // Test matrices (shared by both paths)
    // A = identity,  B = counting  →  C = B
    // ──────────────────────────────────────────────────────────────────────
    reg [31:0] A_data [0:15];
    reg [31:0] B_data [0:15];

    integer i;
    integer hw_total_cycles;  // HW: rst→sentinel over N_TILES calls
    integer sw_cycles;        // SW: rst→sentinel for 1 tile
    integer guard;

    // ──────────────────────────────────────────────────────────────────────
    // Main stimulus
    // ──────────────────────────────────────────────────────────────────────
    initial begin
        // A = identity (1.0 = 0x0400 in Q5.10)
        A_data[ 0]=32'h00000400; A_data[ 1]=32'h00000000;
        A_data[ 2]=32'h00000000; A_data[ 3]=32'h00000000;
        A_data[ 4]=32'h00000000; A_data[ 5]=32'h00000400;
        A_data[ 6]=32'h00000000; A_data[ 7]=32'h00000000;
        A_data[ 8]=32'h00000000; A_data[ 9]=32'h00000000;
        A_data[10]=32'h00000400; A_data[11]=32'h00000000;
        A_data[12]=32'h00000000; A_data[13]=32'h00000000;
        A_data[14]=32'h00000000; A_data[15]=32'h00000400;
        // B = counting (B[r][c] = r*4+c+1 in Q5.10)
        B_data[ 0]=32'h00000400; B_data[ 1]=32'h00000800;
        B_data[ 2]=32'h00000c00; B_data[ 3]=32'h00001000;
        B_data[ 4]=32'h00001400; B_data[ 5]=32'h00001800;
        B_data[ 6]=32'h00001c00; B_data[ 7]=32'h00002000;
        B_data[ 8]=32'h00002400; B_data[ 9]=32'h00002800;
        B_data[10]=32'h00002c00; B_data[11]=32'h00003000;
        B_data[12]=32'h00003400; B_data[13]=32'h00003800;
        B_data[14]=32'h00003c00; B_data[15]=32'h00004000;

        rst_hw          = 1'b0;
        rst_sw          = 1'b0;
        host_mem_we     = 1'b0;
        host_mem_addr   = 32'd0;
        host_mem_wdata  = 32'd0;
        hw_total_cycles = 0;
        sw_cycles       = 0;
        guard           = 0;

        repeat(4) @(posedge clk);

        // ══════════════════════════════════════════════════════════════════
        // HW RUN  — 32 MATMUL_ACCEL tiles via PCPI systolic array
        // ══════════════════════════════════════════════════════════════════

        // Load firmware
        begin : fw_load_hw
            reg [31:0] fw_buf [0:255];
            $readmemh("firmware/firmware_mlperf_proxy.hex", fw_buf);
            for (i = 0; i < 256; i = i + 1)
                u_proxy.cpu.imem[i] = fw_buf[i];
        end
        if (u_proxy.cpu.imem[0] === 32'bx) begin
            $display("MLPERF_PROXY [ERROR] HW firmware hex not found.  Run from RISC-V/pipeline_top/");
            $finish;
        end

        // Seed PCPI shared memory: A at word 0x40, B at word 0x50
        for (i = 0; i < 8; i = i + 1) begin
            u_proxy.mem[8'h40 + i] = {A_data[i*2+1][15:0], A_data[i*2][15:0]};
            u_proxy.mem[8'h50 + i] = {B_data[i*2+1][15:0], B_data[i*2][15:0]};
        end
        u_proxy.cpu.dmem.MEM[0] = 32'd0;

        // Release HW reset and count until firmware writes sentinel
        rst_hw = 1'b1;
        @(posedge clk);
        hw_total_cycles = 0;
        guard = 0;
        while (u_proxy.cpu.dmem.MEM[0] === 32'd0) begin
            @(posedge clk);
            hw_total_cycles = hw_total_cycles + 1;
            guard = guard + 1;
            if (guard > 200_000) begin
                $display("MLPERF_PROXY [ERROR] HW timeout (PC=0x%08h)", dbg_pc_if_hw);
                $finish;
            end
        end
        @(posedge clk); // settle

        // ── HW correctness check ─────────────────────────────────────────
        begin : hw_check
            reg [15:0] c00;
            c00 = u_proxy.mem[32'h200 >> 2][15:0];
            if (c00 === 16'h0400)
                $display("MLPERF_PROXY [PASS]  HW C[0][0] = 0x%04h (correct)", c00);
            else
                $display("MLPERF_PROXY [WARN]  HW C[0][0] = 0x%04h (exp 0x0400)", c00);
        end

        // ══════════════════════════════════════════════════════════════════
        // SW RUN  — 1 tile in pure software (RV32I, no MUL)
        // ══════════════════════════════════════════════════════════════════

        // Load firmware
        begin : fw_load_sw
            reg [31:0] fw_buf [0:255];
            $readmemh("firmware/firmware_sw_bench.hex", fw_buf);
            for (i = 0; i < 256; i = i + 1)
                u_sw.imem[i] = fw_buf[i];
        end
        if (u_sw.imem[0] === 32'bx) begin
            $display("MLPERF_PROXY [ERROR] SW firmware hex not found.");
            $finish;
        end

        // Seed u_sw dmem directly: A at word 64, B at word 80
        for (i = 0; i < 8; i = i + 1) begin
            u_sw.dmem.MEM[64 + i] = {A_data[i*2+1][15:0], A_data[i*2][15:0]};
            u_sw.dmem.MEM[80 + i] = {B_data[i*2+1][15:0], B_data[i*2][15:0]};
        end
        u_sw.dmem.MEM[0] = 32'd0;

        // Release SW reset and count until sentinel
        rst_sw = 1'b1;
        @(posedge clk);
        sw_cycles = 0;
        guard     = 0;
        while (u_sw.dmem.MEM[0] === 32'd0) begin
            @(posedge clk);
            sw_cycles = sw_cycles + 1;
            guard     = guard + 1;
            if (guard > 200_000) begin
                $display("MLPERF_PROXY [ERROR] SW timeout (PC=0x%08h)", dbg_pc_if_sw);
                $finish;
            end
        end
        @(posedge clk);

        // ── SW correctness check ─────────────────────────────────────────
        begin : sw_check
            reg [31:0] got;
            got = u_sw.dmem.MEM[128];   // C[0][0..1] packed word at byte 0x200
            if (got[15:0] === 16'h0400)
                $display("MLPERF_PROXY [PASS]  SW C[0][0] = 0x%04h (correct)", got[15:0]);
            else
                $display("MLPERF_PROXY [WARN]  SW C[0][0] = 0x%04h (exp 0x0400)", got[15:0]);
        end

        // ══════════════════════════════════════════════════════════════════
        // Comparison table
        // ══════════════════════════════════════════════════════════════════
        begin : cmp_tbl
            real hw_per_tile;
            real sw_per_tile;
            real speedup;

            real hw_proxy_cyc;    // N_TILES measured
            real sw_proxy_cyc;    // N_TILES × sw_per_tile (extrapolated)

            real hw_ad_cyc;
            real sw_ad_cyc;
            real hw_ad_ms;
            real sw_ad_ms;
            reg [7*8:1] hw_tgt;   // "MEETS  " or "EXCEEDS"
            reg [7*8:1] sw_tgt;

            hw_per_tile  = (1.0 * hw_total_cycles) / N_TILES;
            sw_per_tile  = 1.0 * sw_cycles;            // firmware_sw_bench does 1 tile
            speedup      = sw_per_tile / hw_per_tile;

            hw_proxy_cyc = 1.0 * hw_total_cycles;
            sw_proxy_cyc = sw_per_tile * N_TILES;

            hw_ad_cyc    = hw_per_tile  * AD_TILES_TOT;
            sw_ad_cyc    = sw_per_tile  * AD_TILES_TOT;
            hw_ad_ms     = hw_ad_cyc / 100_000.0;
            sw_ad_ms     = sw_ad_cyc / 100_000.0;

            $display("");
            $display("============================================================================");
            $display("   EdgeMATX vs Software  --  MLCommons Tiny AD Benchmark  (rv32_pipeline)  ");
            $display("============================================================================");
            $display("  %-40s  %12s  %12s", "Metric", "HW Accel", "SW (RV32I)");
            $display("  %-40s  %12s  %12s", "----------------------------------------", "------------", "------------");
            $display("  %-40s  %11.1f   %11.1f", "Cycles per 4x4 tile", hw_per_tile, sw_per_tile);
            $display("  %-40s  %12.0f  %12.0f", "Tile speedup (SW/HW)", speedup, 1.0);
            $display("  %-40s  %12s  %12s", "----------------------------------------", "------------", "------------");
            $display("  %-40s  %12d  %12.0f", "Proxy run total cycles  (32 tiles)", hw_total_cycles, sw_proxy_cyc);
            $display("  %-40s  %12.0f  %12.0f", "AD inference cycles     (5120 tiles)", hw_ad_cyc, sw_ad_cyc);
            $display("  %-40s  %11.2f ms %10.2f ms", "AD inference @ 100 MHz", hw_ad_ms, sw_ad_ms);
            if (hw_ad_ms < 10.0) hw_tgt = "MEETS  "; else hw_tgt = "EXCEEDS";
            if (sw_ad_ms < 10.0) sw_tgt = "MEETS  "; else sw_tgt = "EXCEEDS";
            $display("  %-40s  %12s  %12s", "MLPerf Tiny AD target  (< 10 ms)", hw_tgt, sw_tgt);
            $display("  %-40s  %11.1fx   %12s", "End-to-end speedup (HW vs SW)", speedup, "--");
            $display("============================================================================");
            $display("  Note: SW overhead (bias, ReLU, data movement) est. +30%%;");
            $display("        HW projected AD ~%.2f ms  |  SW projected AD ~%.2f ms", hw_ad_ms * 1.3, sw_ad_ms * 1.3);
            $display("============================================================================");
        end

        $finish;
    end

endmodule
