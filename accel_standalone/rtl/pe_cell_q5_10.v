`timescale 1ns/1ps

module pe_cell_q5_10 (
    input wire clk,
    input wire rst,
    input wire clear_acc,
    input wire signed [15:0] x_in,
    input wire signed [15:0] y_in,
    output reg signed [15:0] x_out,
    output reg signed [15:0] y_out,
    output wire signed [31:0] z_acc
);

    // (* use_dsp = "yes" *) forces Vivado to map z_acc into a DSP48E1
    // multiply-accumulate block instead of fabric LUTs.
    // 16x16 signed MAC maps perfectly to DSP48E1 on XC7Z020 (has 220 DSPs).
    (* use_dsp = "yes" *) reg signed [31:0] z_acc_dsp;

    wire signed [31:0] product_full;
    wire signed [31:0] product_q5_10;

    assign product_full = $signed(x_in) * $signed(y_in);
    assign product_q5_10 = product_full >>> 10;

    always @(posedge clk) begin
        if (rst || clear_acc) begin
            x_out <= 16'sd0;
            y_out <= 16'sd0;
            z_acc_dsp <= 32'sd0;
        end else begin
            x_out <= x_in;
            y_out <= y_in;
            z_acc_dsp <= z_acc_dsp + product_q5_10;
        end
    end

    // Expose as the declared output port
    assign z_acc = z_acc_dsp;

endmodule
