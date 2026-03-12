`timescale 1ns/1ps

module riscv_accel_integration_stub (
    input wire clk,
    input wire rst,
    input wire instr_valid,
    input wire [31:0] instr_word,
    input wire [255:0] a_flat,
    input wire [255:0] b_flat,
    output wire cpu_stall,
    output wire custom_hit,
    output wire custom_accept,
    output wire custom_complete,
    output wire accel_start_observe,
    output wire accel_busy,
    output wire accel_done,
    output wire [255:0] c_flat,
    output wire [7:0] accel_cycle_count
);

    wire accel_start;

    assign accel_start_observe = accel_start;

    riscv_matmul_bridge bridge_inst (
        .clk(clk),
        .rst(rst),
        .instr_valid(instr_valid),
        .instr_word(instr_word),
        .accel_busy(accel_busy),
        .accel_done(accel_done),
        .accel_start(accel_start),
        .cpu_stall(cpu_stall),
        .custom_hit(custom_hit),
        .custom_accept(custom_accept),
        .custom_complete(custom_complete)
    );

    matrix_accel_4x4_q5_10 accel_inst (
        .clk(clk),
        .rst(rst),
        .start(accel_start),
        .a_flat(a_flat),
        .b_flat(b_flat),
        .busy(accel_busy),
        .done(accel_done),
        .c_flat(c_flat),
        .cycle_count(accel_cycle_count)
    );

endmodule
