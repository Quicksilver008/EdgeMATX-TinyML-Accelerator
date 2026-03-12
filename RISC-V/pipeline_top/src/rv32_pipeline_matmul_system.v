`timescale 1ns/1ps

// rv32_pipeline_matmul_system.v — synthesizable system wrapper
//
// Changes from previous version:
//   - Replaced simulation-only for-loop A/B loads with a sequential FSM.
//     One element is loaded per clock cycle (distributed RAM single-port read).
//   - Replaced for-loop C writeback with sequential FSM stores.
//     Full 32-bit word writes only — no partial (halfword) writes.
//   - Dropped descriptor-pointer interface (rs2 was always checked for 0,
//     breaking the benchmark).  Now: rs1 = A base byte addr, rs2 = B base.
//   - Memory marked (* ram_style = "distributed" *) so Vivado uses LUT RAM
//     (async reads, full-word registered writes) rather than BRAM.
//
// Timing per matmul call (8 A-loads + 8 B-loads + 1 kick +
//                         ~12 systolic + 8 C-stores + 1 resp):
//   Estimated ~38 cycles from pcpi_valid to pcpi_ready.
//
// Memory layout (default MEM_WORDS=1024, each word = 4 bytes):
//   Byte 0x000.. : general / scratch
//   Byte 0x100.. : Matrix A  (8 words, 2 Q5.10 elements packed per word)
//   Byte 0x140.. : Matrix B  (8 words, 2 Q5.10 elements packed per word)
//   Byte 0x200.. : Matrix C  (8 words, 2 Q5.10 elements packed per word, written here)
//
// Packing convention per 32-bit word:
//   bits [15:0]  = element at even column index (col = 0 or 2)
//   bits [31:16] = element at odd  column index (col = 1 or 3)

module rv32_pipeline_matmul_system #(
    parameter MEM_WORDS   = 1024,           // depth of internal RAM in 32-bit words
    parameter C_BASE_ADDR = 32'h0000_0200   // byte address where C is written
) (
    input  wire        clk,
    input  wire        rst,                 // 0 = reset, 1 = running

    input  wire [31:0] ext_instr_word,
    input  wire        ext_instr_valid,
    input  wire        use_ext_instr,

    // Host memory preload / readback  (simulation / debug only)
    input  wire        host_mem_we,
    input  wire [31:0] host_mem_addr,
    input  wire [31:0] host_mem_wdata,
    output wire [31:0] host_mem_rdata,

    output wire [255:0] mat_c_flat,
    output wire [7:0]   matmul_cycle_count,
    output wire         dbg_matmul_busy,
    output wire         dbg_matmul_done,
    output wire [31:0]  dbg_pc_if,
    output wire [31:0]  dbg_instr_if,
    output wire [31:0]  dbg_instr_id,
    output wire         dbg_stall,
    output wire         dbg_custom_inflight,
    output wire         dbg_wb_regwrite,
    output wire [4:0]   dbg_wb_rd,
    output wire [31:0]  dbg_wb_data,
    output wire signed [15:0] dbg_a00, dbg_a01, dbg_a02, dbg_a03,
    output wire signed [15:0] dbg_b00, dbg_b01, dbg_b02, dbg_b03,
    output wire signed [15:0] dbg_c00, dbg_c01, dbg_c02, dbg_c03
);

    // ── Internal memory ────────────────────────────────────────────────────
    // (* ram_style = "distributed" *) prevents BRAM inference and ensures
    // single-cycle combinatorial reads are synthesisable.
    (* ram_style = "distributed" *)
    reg [31:0] mem [0:MEM_WORDS-1];

    // Combinatorial read — address driven from FSM registers (see below)
    wire [9:0]  mem_rd_waddr;               // 10-bit word index (1024 words)
    wire [31:0] mem_rd_data  = mem[mem_rd_waddr];

    assign host_mem_rdata = mem[host_mem_addr[31:2]];

    // ── PCPI interface from CPU ─────────────────────────────────────────────
    wire        core_pcpi_valid;
    wire [31:0] core_pcpi_insn;
    wire [31:0] core_pcpi_rs1;   // A base byte address
    wire [31:0] core_pcpi_rs2;   // B base byte address

    wire insn_match = (core_pcpi_insn[6:0]  == 7'b0001011) &&
                      (core_pcpi_insn[14:12] == 3'b000)    &&
                      (core_pcpi_insn[31:25] == 7'b0101010);

    // ── Accelerator registers ───────────────────────────────────────────────
    reg  [255:0] a_flat_reg;
    reg  [255:0] b_flat_reg;
    reg          array_start;
    wire         array_busy;
    wire         array_done;
    wire [255:0] c_flat_wire;
    wire [7:0]   cycle_count_wire;

    // ── Controller FSM ─────────────────────────────────────────────────────
    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_LOAD_A   = 3'd1;
    localparam [2:0] S_LOAD_B   = 3'd2;
    localparam [2:0] S_KICK     = 3'd3;
    localparam [2:0] S_WAIT_ACC = 3'd4;
    localparam [2:0] S_STORE_C  = 3'd5;
    localparam [2:0] S_RESP     = 3'd6;

    reg [2:0]  state;
    reg [3:0]  pair_idx;    // 0..7  (each pair = 2 packed Q5.10 elements per 32-bit word)
    reg [31:0] a_base;
    reg [31:0] b_base;
    reg        ctrl_busy;
    reg        accel_done_pulse;
    reg [31:0] accel_result_reg;

    // ── Read-address mux (combinatorial) ───────────────────────────────────
    // Two Q5.10 elements packed per 32-bit word; stride = 4 bytes per pair.
    // pair_idx 0..7: byte offset = pair_idx * 4.
    wire [31:0] a_rd_byte = a_base + {26'd0, pair_idx, 2'b00};  // 26+4+2=32 bits
    wire [31:0] b_rd_byte = b_base + {26'd0, pair_idx, 2'b00};

    assign mem_rd_waddr = (state == S_LOAD_A) ? a_rd_byte[11:2] :
                          (state == S_LOAD_B) ? b_rd_byte[11:2] : 10'd0;

    // ── Write-address / data for C store (combinatorial) ───────────────────
    // Two C elements packed per word: even index in [15:0], odd in [31:16].
    wire [31:0] c_wr_byte  = C_BASE_ADDR + {26'd0, pair_idx, 2'b00};
    wire [9:0]  c_wr_waddr = c_wr_byte[11:2];
    wire [15:0] c_elem_lo  = c_flat_wire[(pair_idx * 32)      +: 16];  // even element
    wire [15:0] c_elem_hi  = c_flat_wire[(pair_idx * 32 + 16) +: 16];  // odd element

    // ── Sequential FSM ─────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (!rst) begin
            state            <= S_IDLE;
            pair_idx         <= 4'd0;
            a_base           <= 32'd0;
            b_base           <= 32'd0;
            ctrl_busy        <= 1'b0;
            accel_done_pulse <= 1'b0;
            accel_result_reg <= 32'd0;
            array_start      <= 1'b0;
            a_flat_reg       <= 256'd0;
            b_flat_reg       <= 256'd0;
        end else begin
            // defaults
            accel_done_pulse <= 1'b0;
            array_start      <= 1'b0;

            // Host preload write (always available for simulation preloading)
            if (host_mem_we)
                mem[host_mem_addr[31:2]] <= host_mem_wdata;

            case (state)

                // ── Wait for custom instruction ──────────────────────────
                S_IDLE: begin
                    if (core_pcpi_valid && insn_match) begin
                        a_base    <= core_pcpi_rs1;
                        b_base    <= core_pcpi_rs2;
                        pair_idx  <= 4'd0;
                        ctrl_busy <= 1'b1;
                        state     <= S_LOAD_A;
                    end
                end

                // ── Load 16 elements of A, two per clock (packed) ───────
                // mem_rd_data is combinatorial from registered pair_idx;
                // both packed elements are valid on the same cycle and
                // captured into a_flat_reg on the following posedge.
                S_LOAD_A: begin
                    a_flat_reg[(pair_idx * 32) +: 32] <= mem_rd_data;
                    if (pair_idx == 4'd7) begin
                        pair_idx <= 4'd0;
                        state    <= S_LOAD_B;
                    end else begin
                        pair_idx <= pair_idx + 4'd1;
                    end
                end

                // ── Load 16 elements of B, two per clock (packed) ───────
                S_LOAD_B: begin
                    b_flat_reg[(pair_idx * 32) +: 32] <= mem_rd_data;
                    if (pair_idx == 4'd7) begin
                        pair_idx <= 4'd0;
                        state    <= S_KICK;
                    end else begin
                        pair_idx <= pair_idx + 4'd1;
                    end
                end

                // ── Pulse start to systolic array ────────────────────────
                S_KICK: begin
                    array_start <= 1'b1;
                    state       <= S_WAIT_ACC;
                end

                // ── Wait for systolic array to finish ────────────────────
                S_WAIT_ACC: begin
                    if (array_done) begin
                        pair_idx <= 4'd0;
                        state    <= S_STORE_C;
                    end
                end

                // ── Write 16 C elements back to memory, two per clock ───
                // Pack even element in [15:0] and odd element in [31:16];
                // one full-word write per clock — directly synthesisable.
                S_STORE_C: begin
                    mem[c_wr_waddr] <= {c_elem_hi, c_elem_lo};
                    if (pair_idx == 4'd7) begin
                        state <= S_RESP;
                    end else begin
                        pair_idx <= pair_idx + 4'd1;
                    end
                end

                // ── Signal completion to CPU via pcpi_ready pulse ────────
                S_RESP: begin
                    accel_result_reg <= 32'd0;
                    accel_done_pulse <= 1'b1;
                    ctrl_busy        <= 1'b0;
                    state            <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // ── Submodule instances ─────────────────────────────────────────────────
    rv32_pipeline_top core (
        .clk               (clk),
        .rst               (rst),
        .ext_instr_word    (ext_instr_word),
        .ext_instr_valid   (ext_instr_valid),
        .use_ext_instr     (use_ext_instr),
        .pcpi_valid        (core_pcpi_valid),
        .pcpi_insn         (core_pcpi_insn),
        .pcpi_rs1          (core_pcpi_rs1),
        .pcpi_rs2          (core_pcpi_rs2),
        .pcpi_wait         (ctrl_busy),
        .pcpi_ready        (accel_done_pulse),
        .pcpi_wr           (accel_done_pulse),
        .pcpi_rd           (accel_result_reg),
        .dbg_pc_if         (dbg_pc_if),
        .dbg_instr_if      (dbg_instr_if),
        .dbg_instr_id      (dbg_instr_id),
        .dbg_stall         (dbg_stall),
        .dbg_custom_inflight(dbg_custom_inflight),
        .dbg_wb_regwrite   (dbg_wb_regwrite),
        .dbg_wb_rd         (dbg_wb_rd),
        .dbg_wb_data       (dbg_wb_data)
    );

    matrix_accel_4x4_q5_10 matmul_accel (
        .clk        (clk),
        .rst        (~rst),
        .start      (array_start),
        .a_flat     (a_flat_reg),
        .b_flat     (b_flat_reg),
        .busy       (array_busy),
        .done       (array_done),
        .c_flat     (c_flat_wire),
        .cycle_count(cycle_count_wire)
    );

    // ── Outputs ─────────────────────────────────────────────────────────────
    assign mat_c_flat        = c_flat_wire;
    assign matmul_cycle_count = cycle_count_wire;
    assign dbg_matmul_busy   = ctrl_busy;
    assign dbg_matmul_done   = accel_done_pulse;
    assign dbg_a00 = a_flat_reg[15:0];
    assign dbg_a01 = a_flat_reg[31:16];
    assign dbg_a02 = a_flat_reg[47:32];
    assign dbg_a03 = a_flat_reg[63:48];
    assign dbg_b00 = b_flat_reg[15:0];
    assign dbg_b01 = b_flat_reg[31:16];
    assign dbg_b02 = b_flat_reg[47:32];
    assign dbg_b03 = b_flat_reg[63:48];
    assign dbg_c00 = c_flat_wire[15:0];
    assign dbg_c01 = c_flat_wire[31:16];
    assign dbg_c02 = c_flat_wire[47:32];
    assign dbg_c03 = c_flat_wire[63:48];

endmodule
