`timescale 1ns/1ps

module issue_logic_4x4_q5_10 (
    input wire [255:0] a_flat,
    input wire [255:0] b_flat,
    input wire [3:0] cycle_idx,
    output reg [63:0] row_inject_flat,
    output reg [63:0] col_inject_flat
);

    function signed [15:0] mat_get;
        input [255:0] mat;
        input integer row;
        input integer col;
        integer base;
        begin
            base = ((row * 4) + col) * 16;
            mat_get = mat[base +: 16];
        end
    endfunction

    integer i;
    integer k;
    reg signed [15:0] row_val;
    reg signed [15:0] col_val;

    always @(*) begin
        row_inject_flat = 64'd0;
        col_inject_flat = 64'd0;

        for (i = 0; i < 4; i = i + 1) begin
            k = $signed({1'b0, cycle_idx}) - i;
            row_val = 16'sd0;
            if ((k >= 0) && (k < 4)) begin
                row_val = mat_get(a_flat, i, k);
            end
            row_inject_flat[(i * 16) +: 16] = row_val;
        end

        for (i = 0; i < 4; i = i + 1) begin
            k = $signed({1'b0, cycle_idx}) - i;
            col_val = 16'sd0;
            if ((k >= 0) && (k < 4)) begin
                col_val = mat_get(b_flat, k, i);
            end
            col_inject_flat[(i * 16) +: 16] = col_val;
        end
    end

endmodule
