`timescale 1ns/1ps

module matrix_accel_4x4_q5_10 (
    input wire clk,
    input wire rst,
    input wire start,
    input wire [255:0] a_flat,
    input wire [255:0] b_flat,
    output reg busy,
    output reg done,
    output wire [255:0] c_flat,
    output reg [7:0] cycle_count
);

    localparam integer COMPUTE_CYCLES = 10;

    reg [255:0] a_latched;
    reg [255:0] b_latched;
    reg [3:0] issue_cycle;
    reg clear_acc;
    reg primed;

    wire [3:0] cycle_for_issue;
    wire [63:0] row_inject_flat;
    wire [63:0] col_inject_flat;
    wire [255:0] a_issue;
    wire [255:0] b_issue;

    assign cycle_for_issue = busy ? issue_cycle : 4'd0;
    assign a_issue = busy ? a_latched : 256'd0;
    assign b_issue = busy ? b_latched : 256'd0;

    issue_logic_4x4_q5_10 issue_inst (
        .a_flat(a_issue),
        .b_flat(b_issue),
        .cycle_idx(cycle_for_issue),
        .row_inject_flat(row_inject_flat),
        .col_inject_flat(col_inject_flat)
    );

    systolic_array_4x4_q5_10 systolic_inst (
        .clk(clk),
        .rst(rst),
        .clear_acc(clear_acc),
        .row_inject_flat(row_inject_flat),
        .col_inject_flat(col_inject_flat),
        .c_flat(c_flat)
    );

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            cycle_count <= 8'd0;
            issue_cycle <= 4'd0;
            clear_acc <= 1'b0;
            primed <= 1'b0;
            a_latched <= 256'd0;
            b_latched <= 256'd0;
        end else begin
            done <= 1'b0;
            clear_acc <= 1'b0;

            if (start && !busy) begin
                busy <= 1'b1;
                issue_cycle <= 4'd0;
                cycle_count <= 8'd0;
                clear_acc <= 1'b1;
                primed <= 1'b0;
                a_latched <= a_flat;
                b_latched <= b_flat;
            end else if (busy) begin
                if (!primed) begin
                    primed <= 1'b1;
                end else begin
                    cycle_count <= cycle_count + 8'd1;
                    if (issue_cycle == (COMPUTE_CYCLES - 1)) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        primed <= 1'b0;
                    end else begin
                        issue_cycle <= issue_cycle + 4'd1;
                    end
                end
            end
        end
    end

endmodule
