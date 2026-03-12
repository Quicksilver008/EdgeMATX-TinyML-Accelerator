`timescale 1ns/1ps

module rv32_pipeline_top #(
    parameter IMEM_DEPTH = 256,
    parameter IMEM_FILE  = "",   // hex file for ROM init (Vivado $readmemh)
    parameter DMEM_ADDR_BITS = 8,
    parameter [6:0] CUSTOM_OPCODE = 7'b0001011,
    parameter [2:0] CUSTOM_FUNCT3 = 3'b000,
    parameter [6:0] CUSTOM_FUNCT7 = 7'b0101010
) (
    input wire clk,
    input wire rst,
    input wire [31:0] ext_instr_word,
    input wire ext_instr_valid,
    input wire use_ext_instr,

    output reg        pcpi_valid,
    output reg [31:0] pcpi_insn,
    output reg [31:0] pcpi_rs1,
    output reg [31:0] pcpi_rs2,
    input wire        pcpi_wait,
    input wire        pcpi_ready,
    input wire        pcpi_wr,
    input wire [31:0] pcpi_rd,

    output wire [31:0] dbg_pc_if,
    output wire [31:0] dbg_instr_if,
    output wire [31:0] dbg_instr_id,
    output wire dbg_stall,
    output wire dbg_custom_inflight,
    output wire dbg_wb_regwrite,
    output wire [4:0] dbg_wb_rd,
    output wire [31:0] dbg_wb_data
);

    reg [31:0] imem [0:IMEM_DEPTH-1];

    // Vivado-supported ROM initialisation via $readmemh.
    // Synthesis honours this when IMEM_FILE is non-empty; simulation does too.
    initial begin
        if (IMEM_FILE != "") $readmemh(IMEM_FILE, imem);
    end

    // IF stage
    reg [31:0] pc_if;
    wire [31:0] instr_if_mem;
    wire [31:0] instr_if;
    wire [31:0] pc_plus4_if;

    // IF/ID
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg if_id_valid;

    // ID decode
    wire [6:0] id_opcode;
    wire [4:0] id_rd;
    wire [2:0] id_funct3;
    wire [4:0] id_rs1;
    wire [4:0] id_rs2;
    wire [6:0] id_funct7;
    wire [31:0] id_imm;

    wire id_ALUSrc;
    wire id_MemtoReg;
    wire id_RegWrite;
    wire id_MemRead;
    wire id_MemWrite;
    wire id_Branch;
    wire id_JumpReg;
    wire [1:0] id_ALUOP;

    wire [31:0] id_rs1_data;
    wire [31:0] id_rs2_data;
    wire [6:0] raw_opcode;
    wire [4:0] raw_rd;
    wire [4:0] raw_rs1;
    wire [4:0] raw_rs2;
    wire [2:0] raw_funct3;
    wire [6:0] raw_funct7;
    wire [4:0] id_read_rs1;
    wire [4:0] id_read_rs2;

    wire id_is_custom_matmul;
    reg [4:0] custom_rd_latched;
    reg custom_wb_pending;
    reg [31:0] pcpi_rd_latched;

    wire id_hazard_stall;
    wire global_stall;

    // ID/EX
    reg id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_imm;
    reg [31:0] id_ex_rs1_data;
    reg [31:0] id_ex_rs2_data;
    reg [4:0] id_ex_rs1;
    reg [4:0] id_ex_rs2;
    reg [4:0] id_ex_rd;
    reg [2:0] id_ex_funct3;
    reg id_ex_sign_bit;
    reg id_ex_ALUSrc;
    reg id_ex_MemtoReg;
    reg id_ex_RegWrite;
    reg id_ex_MemRead;
    reg id_ex_MemWrite;
    reg id_ex_Branch;
    reg [1:0] id_ex_ALUOP;

    // EX
    wire [1:0] fwd_a_sel;
    wire [1:0] fwd_b_sel;
    wire [31:0] ex_fwd_a_data;
    wire [31:0] ex_fwd_b_data;
    wire [31:0] ex_alu_in_a;
    wire [31:0] ex_alu_in_b;
    wire [4:0] ex_alu_sel;
    wire [31:0] ex_alu_out;
    wire ex_zero_flag;
    wire [31:0] ex_branch_target;
    wire ex_branch_taken;

    // EX/MEM
    reg ex_mem_valid;
    reg [31:0] ex_mem_alu_out;
    reg [31:0] ex_mem_store_data;
    reg [4:0] ex_mem_rd;
    reg [2:0] ex_mem_funct3;
    reg ex_mem_MemtoReg;
    reg ex_mem_RegWrite;
    reg ex_mem_MemRead;
    reg ex_mem_MemWrite;
    reg ex_mem_BranchTaken;
    reg [31:0] ex_mem_branch_target;

    // MEM
    wire [31:0] mem_rd_data;

    // MEM/WB
    reg mem_wb_valid;
    reg [31:0] mem_wb_mem_data;
    reg [31:0] mem_wb_alu_out;
    reg [4:0] mem_wb_rd;
    reg mem_wb_MemtoReg;
    reg mem_wb_RegWrite;

    // WB
    wire [31:0] wb_data;
    wire wb_regwrite;
    wire [4:0] wb_rd;
    wire [31:0] wb_wdata;

    assign instr_if_mem = imem[pc_if[31:2]];
    assign instr_if = use_ext_instr ? ext_instr_word : instr_if_mem;
    assign pc_plus4_if = pc_if + 32'd4;

    assign dbg_pc_if = pc_if;
    assign dbg_instr_if = instr_if;
    assign dbg_instr_id = if_id_instr;
    assign dbg_custom_inflight = pcpi_valid;
    assign dbg_wb_regwrite = wb_regwrite;
    assign dbg_wb_rd = wb_rd;
    assign dbg_wb_data = wb_wdata;
    assign raw_opcode = if_id_instr[6:0];
    assign raw_rd = if_id_instr[11:7];
    assign raw_funct3 = if_id_instr[14:12];
    assign raw_rs1 = if_id_instr[19:15];
    assign raw_rs2 = if_id_instr[24:20];
    assign raw_funct7 = if_id_instr[31:25];

    instruction_decoder id_decoder (
        .machine_code(if_id_instr),
        .opcode(id_opcode),
        .rd(id_rd),
        .funct3(id_funct3),
        .rs1(id_rs1),
        .rs2(id_rs2),
        .funct7(id_funct7),
        .imm(id_imm)
    );

    control_unit id_ctrl (
        .opcode(id_opcode),
        .ALUSrc(id_ALUSrc),
        .MemtoReg(id_MemtoReg),
        .RegWrite(id_RegWrite),
        .MemRead(id_MemRead),
        .MemWrite(id_MemWrite),
        .Branch(id_Branch),
        .JumpReg(id_JumpReg),
        .ALUOP(id_ALUOP)
    );

    assign wb_data = mem_wb_MemtoReg ? mem_wb_mem_data : mem_wb_alu_out;
    assign wb_regwrite = mem_wb_RegWrite || custom_wb_pending;
    assign wb_rd = custom_wb_pending ? custom_rd_latched : mem_wb_rd;
    assign wb_wdata = custom_wb_pending ? pcpi_rd_latched : wb_data;

    register_bank regs (
        .Clk(clk),
        .Rst(rst),
        .Rd_reg_1(id_read_rs1),
        .Rd_reg_2(id_read_rs2),
        .Wr_reg(wb_rd),
        .Wr_data(wb_wdata),
        .Rd_data_1(id_rs1_data),
        .Rd_data_2(id_rs2_data),
        .Reg_write(wb_regwrite)
    );

    hazard_detection_unit hdu (
        .ID_EXMemRead(id_ex_MemRead),
        .IF_IDRegisterRs1(id_read_rs1),
        .IF_IDRegisterRs2(id_read_rs2),
        .ID_EXRegisterRd(id_ex_rd),
        .stall(id_hazard_stall)
    );

    assign id_is_custom_matmul = if_id_valid &&
                                 (raw_opcode == CUSTOM_OPCODE) &&
                                 (raw_funct3 == CUSTOM_FUNCT3) &&
                                 (raw_funct7 == CUSTOM_FUNCT7);

    assign id_read_rs1 = id_is_custom_matmul ? raw_rs1 : id_rs1;
    assign id_read_rs2 = id_is_custom_matmul ? raw_rs2 : id_rs2;

    assign global_stall = id_hazard_stall || pcpi_valid;
    assign dbg_stall = global_stall;

    forwarding_unit fwd_u (
        .ID_EXRs1(id_ex_rs1),
        .ID_EXRs2(id_ex_rs2),
        .EX_MEMRegRd(ex_mem_rd),
        .EX_MEMRegWrite(ex_mem_RegWrite),
        .MEM_WBRegWrite(mem_wb_RegWrite),
        .MEM_WBRegRd(mem_wb_rd),
        .Fwd_A(fwd_a_sel),
        .Fwd_B(fwd_b_sel)
    );

    assign ex_fwd_a_data = (fwd_a_sel == 2'b10) ? ex_mem_alu_out :
                           (fwd_a_sel == 2'b01) ? wb_data :
                                                  id_ex_rs1_data;

    assign ex_fwd_b_data = (fwd_b_sel == 2'b10) ? ex_mem_alu_out :
                           (fwd_b_sel == 2'b01) ? wb_data :
                                                  id_ex_rs2_data;

    assign ex_alu_in_a = ex_fwd_a_data;
    assign ex_alu_in_b = id_ex_ALUSrc ? id_ex_imm : ex_fwd_b_data;

    alu_control alu_ctrl (
        .alu_op(id_ex_ALUOP),
        .func3(id_ex_funct3),
        .sign_bit(id_ex_sign_bit),
        .alu_select(ex_alu_sel)
    );

    ALU ex_alu (
        .in1(ex_alu_in_a),
        .in2(ex_alu_in_b),
        .op_select(ex_alu_sel),
        .out(ex_alu_out),
        .zero_flag(ex_zero_flag)
    );

    assign ex_branch_target = id_ex_pc + id_ex_imm;
    assign ex_branch_taken = id_ex_Branch && ex_zero_flag;

    data_memory #(.n_addr(DMEM_ADDR_BITS)) dmem (
        .Clk(clk),
        .Rst(rst),
        .Rd_data(mem_rd_data),
        .Addr(ex_mem_alu_out[DMEM_ADDR_BITS+1:2]),  // byte addr -> word index
        .byte_sel(ex_mem_alu_out[1:0]),             // byte lane select
        .funct3(ex_mem_funct3),
        .Wr_data(ex_mem_store_data),
        .MemWrite(ex_mem_MemWrite),
        .MemRead(ex_mem_MemRead)
    );

    always @(posedge clk) begin
        if (!rst) begin
            pc_if <= 32'd0;
            if_id_pc <= 32'd0;
            if_id_instr <= 32'd0;
            if_id_valid <= 1'b0;

            id_ex_valid <= 1'b0;
            id_ex_pc <= 32'd0;
            id_ex_imm <= 32'd0;
            id_ex_rs1_data <= 32'd0;
            id_ex_rs2_data <= 32'd0;
            id_ex_rs1 <= 5'd0;
            id_ex_rs2 <= 5'd0;
            id_ex_rd <= 5'd0;
            id_ex_funct3 <= 3'd0;
            id_ex_sign_bit <= 1'b0;
            id_ex_ALUSrc <= 1'b0;
            id_ex_MemtoReg <= 1'b0;
            id_ex_RegWrite <= 1'b0;
            id_ex_MemRead <= 1'b0;
            id_ex_MemWrite <= 1'b0;
            id_ex_Branch <= 1'b0;
            id_ex_ALUOP <= 2'd0;

            ex_mem_valid <= 1'b0;
            ex_mem_alu_out <= 32'd0;
            ex_mem_store_data <= 32'd0;
            ex_mem_rd <= 5'd0;
            ex_mem_funct3 <= 3'd0;
            ex_mem_MemtoReg <= 1'b0;
            ex_mem_RegWrite <= 1'b0;
            ex_mem_MemRead <= 1'b0;
            ex_mem_MemWrite <= 1'b0;
            ex_mem_BranchTaken <= 1'b0;
            ex_mem_branch_target <= 32'd0;

            mem_wb_valid <= 1'b0;
            mem_wb_mem_data <= 32'd0;
            mem_wb_alu_out <= 32'd0;
            mem_wb_rd <= 5'd0;
            mem_wb_MemtoReg <= 1'b0;
            mem_wb_RegWrite <= 1'b0;

            pcpi_valid <= 1'b0;
            pcpi_insn <= 32'd0;
            pcpi_rs1 <= 32'd0;
            pcpi_rs2 <= 32'd0;
            custom_rd_latched <= 5'd0;
            custom_wb_pending <= 1'b0;
            pcpi_rd_latched <= 32'd0;
        end else begin
            custom_wb_pending <= 1'b0;

            if (pcpi_valid && pcpi_ready) begin
                pcpi_valid <= 1'b0;
                custom_wb_pending <= pcpi_wr;
                pcpi_rd_latched <= pcpi_rd;
            end

            // WB pipeline register advance
            mem_wb_valid <= ex_mem_valid;
            mem_wb_mem_data <= mem_rd_data;
            mem_wb_alu_out <= ex_mem_alu_out;
            mem_wb_rd <= ex_mem_rd;
            mem_wb_MemtoReg <= ex_mem_MemtoReg;
            mem_wb_RegWrite <= ex_mem_RegWrite;

            // MEM pipeline register advance
            ex_mem_valid <= id_ex_valid;
            ex_mem_alu_out <= ex_alu_out;
            ex_mem_store_data <= ex_fwd_b_data;
            ex_mem_rd <= id_ex_rd;
            ex_mem_funct3 <= id_ex_funct3;
            ex_mem_MemtoReg <= id_ex_MemtoReg;
            ex_mem_RegWrite <= id_ex_RegWrite;
            ex_mem_MemRead <= id_ex_MemRead;
            ex_mem_MemWrite <= id_ex_MemWrite;
            ex_mem_BranchTaken <= ex_branch_taken;
            ex_mem_branch_target <= ex_branch_target;

            // PC update
            if (ex_branch_taken) begin
                pc_if <= ex_branch_target;
            end else if (!global_stall) begin
                if (use_ext_instr && !ext_instr_valid) begin
                    pc_if <= pc_if;
                end else begin
                    pc_if <= pc_plus4_if;
                end
            end

            // IF/ID update
            if (ex_branch_taken) begin
                if_id_valid <= 1'b0;
                if_id_instr <= 32'd0;
                if_id_pc <= 32'd0;
            end else if (!global_stall) begin
                if_id_valid <= use_ext_instr ? ext_instr_valid : 1'b1;
                if_id_instr <= instr_if;
                if_id_pc <= pc_if;
            end

            // Launch custom accelerator op from ID stage and insert bubble into EX
            if (id_is_custom_matmul && !pcpi_valid && !id_hazard_stall) begin
                pcpi_valid <= 1'b1;
                pcpi_insn <= if_id_instr;
                pcpi_rs1 <= id_rs1_data;
                pcpi_rs2 <= id_rs2_data;
                custom_rd_latched <= raw_rd;

                id_ex_valid <= 1'b0;
                id_ex_pc <= 32'd0;
                id_ex_imm <= 32'd0;
                id_ex_rs1_data <= 32'd0;
                id_ex_rs2_data <= 32'd0;
                id_ex_rs1 <= 5'd0;
                id_ex_rs2 <= 5'd0;
                id_ex_rd <= 5'd0;
                id_ex_funct3 <= 3'd0;
                id_ex_sign_bit <= 1'b0;
                id_ex_ALUSrc <= 1'b0;
                id_ex_MemtoReg <= 1'b0;
                id_ex_RegWrite <= 1'b0;
                id_ex_MemRead <= 1'b0;
                id_ex_MemWrite <= 1'b0;
                id_ex_Branch <= 1'b0;
                id_ex_ALUOP <= 2'd0;
            end else if (ex_branch_taken) begin
                id_ex_valid <= 1'b0;
                id_ex_pc <= 32'd0;
                id_ex_imm <= 32'd0;
                id_ex_rs1_data <= 32'd0;
                id_ex_rs2_data <= 32'd0;
                id_ex_rs1 <= 5'd0;
                id_ex_rs2 <= 5'd0;
                id_ex_rd <= 5'd0;
                id_ex_funct3 <= 3'd0;
                id_ex_sign_bit <= 1'b0;
                id_ex_ALUSrc <= 1'b0;
                id_ex_MemtoReg <= 1'b0;
                id_ex_RegWrite <= 1'b0;
                id_ex_MemRead <= 1'b0;
                id_ex_MemWrite <= 1'b0;
                id_ex_Branch <= 1'b0;
                id_ex_ALUOP <= 2'd0;
            end else if (id_hazard_stall || pcpi_valid) begin
                id_ex_valid <= 1'b0;
                id_ex_pc <= 32'd0;
                id_ex_imm <= 32'd0;
                id_ex_rs1_data <= 32'd0;
                id_ex_rs2_data <= 32'd0;
                id_ex_rs1 <= 5'd0;
                id_ex_rs2 <= 5'd0;
                id_ex_rd <= 5'd0;
                id_ex_funct3 <= 3'd0;
                id_ex_sign_bit <= 1'b0;
                id_ex_ALUSrc <= 1'b0;
                id_ex_MemtoReg <= 1'b0;
                id_ex_RegWrite <= 1'b0;
                id_ex_MemRead <= 1'b0;
                id_ex_MemWrite <= 1'b0;
                id_ex_Branch <= 1'b0;
                id_ex_ALUOP <= 2'd0;
            end else if (if_id_valid) begin
                id_ex_valid <= 1'b1;
                id_ex_pc <= if_id_pc;
                id_ex_imm <= id_imm;
                id_ex_rs1_data <= id_rs1_data;
                id_ex_rs2_data <= id_rs2_data;
                id_ex_rs1 <= id_rs1;
                id_ex_rs2 <= id_rs2;
                id_ex_rd <= id_rd;
                id_ex_funct3 <= id_funct3;
                id_ex_sign_bit <= id_funct7[5];
                id_ex_ALUSrc <= id_ALUSrc;
                id_ex_MemtoReg <= id_MemtoReg;
                id_ex_RegWrite <= id_RegWrite;
                id_ex_MemRead <= id_MemRead;
                id_ex_MemWrite <= id_MemWrite;
                id_ex_Branch <= id_Branch;
                id_ex_ALUOP <= id_ALUOP;
            end else begin
                id_ex_valid <= 1'b0;
            end
        end
    end

endmodule
