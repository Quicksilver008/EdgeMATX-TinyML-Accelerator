//Project: RISC-V 32 bit Architecture
//Module: Instruction Decoder (ID)
//Author: Ayesha S. Ahmad
//Updated: 05/28/2020
//RV32I Base Integer Instructions RISC-V which consists of 6 types of instructions: R-type, I-type, S-type, B-type, U-type and J-type
//Input: 32 bit machine code is obtained as input to (ID)
//Output: Based on the type of instruction, decided by decoding opcode i.e last 7 bits of 
//machine code, ID divides 32 bits into opcode, rd, funct3, rs1, rs2, funct7 and imm

//Updates:
//imm [31:0] ->imm[31:12] ->imm[31:0]
//Added the Environment Call & Break instructions
//Added Jump And Link Reg instruction
//always block from opcode -> machine_code


module instruction_decoder(machine_code, opcode, rd, funct3, rs1, rs2, funct7, imm);

input [31:0] machine_code; //instruction32

output reg[6:0] opcode; // goes to control unit
output reg[4:0] rd,rs1,rs2; //to the register bank
output reg[2:0] funct3;
output reg[6:0] funct7;
output reg[31:0] imm; // jump address to be calculated

always @ (machine_code)
   begin
	if (machine_code[6:0] == 7'b0110011) //R-type
	   begin
		opcode = machine_code[6:0];
		rd = machine_code[11:7];
		funct3 = machine_code[14:12];
		rs1 = machine_code[19:15];
		rs2 = machine_code[24:20];
		funct7 = machine_code[31:25];
		imm = imm;
	   end
	else if (machine_code[6:0] == 7'b0010011 || machine_code[6:0] == 7'b0000011 || machine_code[6:0] == 7'b1100111 || machine_code[6:0] == 7'b1110011 ) //I-type
	   // immediate inst, load inst, jalr, envirnoment call & break
	     begin
		opcode = machine_code[6:0];
		rd = machine_code[11:7];
		funct3 = machine_code[14:12];
		rs1 = machine_code[19:15];
		rs2 = 5'bxxxxx;
		funct7 = 7'bxxxxxxx;
		imm[11:0] = machine_code[31:20];
		imm[31:12] = {20{machine_code[31]}};  // sign-extend
	   end
	else if (machine_code[6:0] == 7'b0100011 ) //S-type 
	   begin
		opcode = machine_code[6:0];
		rd = 5'bxxxxx;
		funct3 = machine_code[14:12];
		rs1 = machine_code[19:15];
		rs2 = machine_code[24:20];
		funct7 = 7'bxxxxxxx;
		imm[4:0] = machine_code[11:7];
		imm[11:5] = machine_code[31:25];
		imm[31:12] = {20{machine_code[31]}};  // sign-extend
	   end
	else if (machine_code[6:0] == 7'b1100011 ) //B-type 
	   begin
		opcode = machine_code[6:0];
		rd = 5'bxxxxx;
		imm[0]    = 1'b0;                     // always 0 for B-type
		imm[4:1]  = machine_code[11:8];
		imm[11]   = machine_code[7];
		funct3 = machine_code[14:12];
		rs1 = machine_code[19:15];
		rs2 = machine_code[24:20];
		funct7 = 7'bxxxxxxx;
		imm[10:5]  = machine_code[30:25];
		imm[12]    = machine_code[31];
		imm[31:13] = {19{machine_code[31]}}; // sign-extend from bit 12
	   end
	else if (machine_code[6:0] == 7'b0110111 || machine_code[6:0] == 7'b0010111) //U-type (LUI / AUIPC)
	   begin
		opcode  = machine_code[6:0];
		rd      = machine_code[11:7];  // destination register
		funct3  = 3'bxxx;
		rs1     = 5'b00000;            // rs1=x0 so ALU computes 0+imm=imm
		rs2     = 5'bxxxxx;
		funct7  = 7'bxxxxxxx;
		imm[11:0]  = 12'b0;            // lower 12 bits = 0 for U-type
		imm[31:12] = machine_code[31:12];
	   end
	else if (machine_code[6:0] == 7'b1101111) //J-type (JAL)
	   begin
		opcode  = machine_code[6:0];
		rd      = machine_code[11:7];  // return-address register
		funct3  = 3'bxxx;
		rs1     = 5'bxxxxx;
		rs2     = 5'bxxxxx;
		funct7  = 7'bxxxxxxx;
		imm[0]     = 1'b0;             // always 0 (2-byte aligned)
		imm[10:1]  = machine_code[30:21];
		imm[11]    = machine_code[20];
		imm[19:12] = machine_code[19:12];
		imm[20]    = machine_code[31];
		imm[31:21] = {11{machine_code[31]}}; // sign-extend from bit 20
	   end
	else
	//default case
	   begin
		opcode = opcode;
		rd = rd;
		funct3 = funct3;
		rs1 = rs1;
		rs2 = rs2;
		funct7 = funct7;
		imm = imm;
	   end
   end
endmodule

