`timescale 1ns/1ps

module simple_instruction_test;

reg Clk;
reg Rst;

// Register bank interface
reg [4:0] Rd_reg_1;
reg [4:0] Rd_reg_2;
reg [4:0] Wr_reg;
reg [31:0] Wr_data;
reg Reg_write;
wire [31:0] Rd_data_1;
wire [31:0] Rd_data_2;

// ALU interface
reg [31:0] alu_in1;
reg [31:0] alu_in2;
reg [4:0] alu_op;
wire [31:0] alu_out;
wire zero_flag;

// Data memory interface
reg [7:0] mem_addr;
reg [31:0] mem_wr_data;
reg mem_write;
reg mem_read;
wire [31:0] mem_rd_data;

integer pass_count;
integer test_count;

register_bank reg_bank(
    .Clk(Clk),
    .Rst(Rst),
    .Rd_reg_1(Rd_reg_1),
    .Rd_reg_2(Rd_reg_2),
    .Wr_reg(Wr_reg),
    .Wr_data(Wr_data),
    .Rd_data_1(Rd_data_1),
    .Rd_data_2(Rd_data_2),
    .Reg_write(Reg_write)
);

ALU alu(
    .in1(alu_in1),
    .in2(alu_in2),
    .op_select(alu_op),
    .out(alu_out),
    .zero_flag(zero_flag)
);

data_memory mem(
    .Clk(Clk),
    .Rst(Rst),
    .Rd_data(mem_rd_data),
    .Addr(mem_addr),
    .byte_sel(2'b00),
    .funct3(3'b010),
    .Wr_data(mem_wr_data),
    .MemWrite(mem_write),
    .MemRead(mem_read)
);

always #5 Clk = ~Clk;

task automatic wr_register(input [4:0] reg_addr, input [31:0] data);
begin
    Wr_reg = reg_addr;
    Wr_data = data;
    Reg_write = 1'b1;
    @(posedge Clk);
    #1;
    Reg_write = 1'b0;
end
endtask

task automatic rd_registers(input [4:0] reg1, input [4:0] reg2);
begin
    Rd_reg_1 = reg1;
    Rd_reg_2 = reg2;
    #1;
end
endtask

task automatic verify_register(input [4:0] reg_addr, input [31:0] expected, input [8*96-1:0] test_name);
begin
    test_count = test_count + 1;
    Rd_reg_1 = reg_addr;
    #1;
    if (Rd_data_1 === expected) begin
        $display("PASS: x%0d = 0x%08h (expected 0x%08h)", reg_addr, Rd_data_1, expected);
        pass_count = pass_count + 1;
    end else begin
        $display("FAIL: x%0d = 0x%08h (expected 0x%08h) - %s", reg_addr, Rd_data_1, expected, test_name);
    end
end
endtask

task automatic mem_store(input [7:0] addr, input [31:0] data);
begin
    mem_addr = addr;
    mem_wr_data = data;
    mem_write = 1'b1;
    mem_read = 1'b0;
    @(posedge Clk);
    #1;
    mem_write = 1'b0;
end
endtask

task automatic mem_load(input [7:0] addr, output [31:0] data_out);
begin
    mem_addr = addr;
    mem_write = 1'b0;
    mem_read = 1'b1;
    @(posedge Clk);
    #1;
    data_out = mem_rd_data;
    mem_read = 1'b0;
end
endtask

reg [31:0] temp_data;

initial begin
    Clk = 1'b0;
    Rst = 1'b0;
    Rd_reg_1 = 5'd0;
    Rd_reg_2 = 5'd0;
    Wr_reg = 5'd0;
    Wr_data = 32'd0;
    Reg_write = 1'b0;
    alu_in1 = 32'd0;
    alu_in2 = 32'd0;
    alu_op = 5'd0;
    mem_addr = 8'd0;
    mem_wr_data = 32'd0;
    mem_write = 1'b0;
    mem_read = 1'b0;
    pass_count = 0;
    test_count = 0;

    $display("\n====== RISC-V Simple Instruction Test ======\n");

    repeat (2) @(posedge Clk);
    Rst = 1'b1;
    @(posedge Clk);

    $display("\n--- Test 1: ADDI x1, x0, 10 ---");
    alu_in1 = 32'd0;
    alu_in2 = 32'd10;
    alu_op = 5'd0;
    #1;
    wr_register(5'd1, alu_out);
    verify_register(5'd1, 32'd10, "x1 should be 10");

    $display("\n--- Test 2: ADDI x2, x0, 20 ---");
    alu_in1 = 32'd0;
    alu_in2 = 32'd20;
    alu_op = 5'd0;
    #1;
    wr_register(5'd2, alu_out);
    verify_register(5'd2, 32'd20, "x2 should be 20");

    $display("\n--- Test 3: ADD x3, x1, x2 ---");
    rd_registers(5'd1, 5'd2);
    alu_in1 = Rd_data_1;
    alu_in2 = Rd_data_2;
    alu_op = 5'd0;
    #1;
    wr_register(5'd3, alu_out);
    verify_register(5'd3, 32'd30, "x3 should be 30");

    $display("\n--- Test 4: SW x3, 0(x0) ---");
    rd_registers(5'd3, 5'd0);
    mem_store(8'd0, Rd_data_1);
    test_count = test_count + 1;
    pass_count = pass_count + 1;
    $display("PASS: stored 0x%08h to memory address 0x%02h", Rd_data_1, mem_addr);

    $display("\n--- Test 5: LW x4, 0(x0) ---");
    mem_load(8'd0, temp_data);
    wr_register(5'd4, temp_data);
    verify_register(5'd4, 32'd30, "x4 should be 30 (loaded from memory)");

    $display("\n--- Test 6: ADDI x5, x1, 15 ---");
    rd_registers(5'd1, 5'd0);
    alu_in1 = Rd_data_1;
    alu_in2 = 32'd15;
    alu_op = 5'd0;
    #1;
    wr_register(5'd5, alu_out);
    verify_register(5'd5, 32'd25, "x5 should be 25");

    $display("\n--- Test 7: SUB x6, x3, x1 ---");
    rd_registers(5'd3, 5'd1);
    alu_in1 = Rd_data_1;
    alu_in2 = Rd_data_2;
    alu_op = 5'd1;
    #1;
    wr_register(5'd6, alu_out);
    verify_register(5'd6, 32'd20, "x6 should be 20");

    $display("\n====== Test Summary ======");
    $display("Total Tests: %0d", test_count);
    $display("Passed Tests: %0d", pass_count);
    if (pass_count == test_count) begin
        $display("ALL TESTS PASSED!");
    end else begin
        $display("SOME TESTS FAILED!");
    end
    $display("==========================\n");

    #10;
    $finish;
end

endmodule
