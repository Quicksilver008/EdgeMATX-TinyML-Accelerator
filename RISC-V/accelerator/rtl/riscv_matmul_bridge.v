`timescale 1ns/1ps

module riscv_matmul_bridge (
    input wire clk,
    input wire rst,
    input wire instr_valid,
    input wire [31:0] instr_word,
    input wire accel_busy,
    input wire accel_done,
    output reg accel_start,
    output wire cpu_stall,
    output wire custom_hit,
    output reg custom_accept,
    output reg custom_complete
);

    localparam [6:0] CUSTOM_OPCODE = 7'b0001011;
    localparam [2:0] CUSTOM_FUNCT3 = 3'b000;
    localparam [6:0] CUSTOM_FUNCT7 = 7'b0101010;

    reg start_pending;
    reg done_pending;

    wire is_custom_matmul;

    assign is_custom_matmul = (instr_word[6:0] == CUSTOM_OPCODE) &&
                              (instr_word[14:12] == CUSTOM_FUNCT3) &&
                              (instr_word[31:25] == CUSTOM_FUNCT7);

    assign custom_hit = instr_valid && is_custom_matmul;
    assign cpu_stall = start_pending || done_pending;

    always @(posedge clk) begin
        if (rst) begin
            start_pending <= 1'b0;
            done_pending <= 1'b0;
            accel_start <= 1'b0;
            custom_accept <= 1'b0;
            custom_complete <= 1'b0;
        end else begin
            accel_start <= 1'b0;
            custom_accept <= 1'b0;
            custom_complete <= 1'b0;

            if (!start_pending && !done_pending && instr_valid && is_custom_matmul) begin
                start_pending <= 1'b1;
            end

            if (start_pending && !accel_busy) begin
                accel_start <= 1'b1;
                custom_accept <= 1'b1;
                start_pending <= 1'b0;
                done_pending <= 1'b1;
            end

            if (done_pending && accel_done) begin
                done_pending <= 1'b0;
                custom_complete <= 1'b1;
            end
        end
    end

endmodule
