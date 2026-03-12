`timescale 1ns/1ps

module systolic_array_4x4_q5_10 (
    input wire clk,
    input wire rst,
    input wire clear_acc,
    input wire [63:0] row_inject_flat,
    input wire [63:0] col_inject_flat,
    output wire [255:0] c_flat
);

    wire signed [15:0] row_inject [0:3];
    wire signed [15:0] col_inject [0:3];

    wire signed [15:0] x_bus [0:3][0:4];
    wire signed [15:0] y_bus [0:4][0:3];
    wire signed [31:0] z_acc [0:3][0:3];

    genvar r;
    genvar c;

    generate
        for (r = 0; r < 4; r = r + 1) begin : INJECT_UNPACK
            assign row_inject[r] = row_inject_flat[(r * 16) +: 16];
            assign col_inject[r] = col_inject_flat[(r * 16) +: 16];
            assign x_bus[r][0] = row_inject[r];
            assign y_bus[0][r] = col_inject[r];
        end
    endgenerate

    generate
        for (r = 0; r < 4; r = r + 1) begin : PE_ROWS
            for (c = 0; c < 4; c = c + 1) begin : PE_COLS
                pe_cell_q5_10 pe_inst (
                    .clk(clk),
                    .rst(rst),
                    .clear_acc(clear_acc),
                    .x_in(x_bus[r][c]),
                    .y_in(y_bus[r][c]),
                    .x_out(x_bus[r][c + 1]),
                    .y_out(y_bus[r + 1][c]),
                    .z_acc(z_acc[r][c])
                );
            end
        end
    endgenerate

    generate
        for (r = 0; r < 4; r = r + 1) begin : OUT_ROWS
            for (c = 0; c < 4; c = c + 1) begin : OUT_COLS
                assign c_flat[((r * 4 + c) * 16) +: 16] = z_acc[r][c][15:0];
            end
        end
    endgenerate

endmodule
