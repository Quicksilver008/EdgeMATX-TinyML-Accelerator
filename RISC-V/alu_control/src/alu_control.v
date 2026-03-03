//Project: RISC-V 32 bit Architecture
//Module: ALU_control
//Author: Sistla Manojna, Shreyas Poyrekar
//Updated: 07/20/2020
//takes the ALU OP, func3 and func7 to select the operation performed by ALU
//NOTE: Please change jump opcode as 11 for both jal and jalr 

module alu_control(alu_op, func3, sign_bit, alu_select);

input[1:0] alu_op; // alu opcode form the control unit
input[2:0] func3; // function 3 input
input sign_bit; //bit 30 in machine code, if it is one then func7 is 0x20.  Which is for operations like sub, sra
output reg[4:0] alu_select; // operation select output given to the alu.

always @(alu_op, func3, sign_bit) begin
	case(alu_op)
		// LOAD & STORE instructions
			2'b00: alu_select = 5'h00; 					// ADD RS1, IMM
			// BRANCH instructions
        	2'b01: begin
           		case(func3)
               		3'h00: alu_select = 5'h0A; 				// BEQ 
               		3'h01: alu_select = 5'h0B; 				// BNE
               		3'h04: alu_select = 5'h0C; 				// BLT
               		3'h05: alu_select = 5'h0D; 				// BGE
               		3'h06: alu_select = 5'h0E; 				// BLTU
               		3'h07: alu_select = 5'h0F; 				// BGEU
               		default: alu_select = 5'bxxxxx; 				// DEFAULT UNKNOW
	   		endcase
        	end
		// R-FORMAT instructions
        	2'b10: begin
           		case(func3)
				3'h00: begin 
                   			if(sign_bit) alu_select = 5'h01; 	// SUB
                   			else alu_select = 5'h00; 		// ADD  and  // JALR (RS1 + IMM)
				end
				3'h04: alu_select =  5'h02; 			// XOR
				3'h06: alu_select =  5'h03; 			// OR
				3'h7: alu_select = 5'h04; 			// AND
               		3'h01: alu_select = 5'h05; 			// SLL
				3'h05: begin 
					if(sign_bit) alu_select = 5'h07; 	// SRA
                   			else alu_select = 5'h06; 		// SRL
               		end
               		3'h02: alu_select = 5'h08; 			// SLT
               		3'h03: alu_select = 5'h09; 			// SLTU
               			default: alu_select = 5'bxxxxx; 			// DEFAULT UNKOWN
           		endcase 
        	end
		//The register JAL register do not use the ALU , JALR uses ADD.
        	2'b11: begin
			case(func3)
			3'h00:	alu_select = 5'h00; //JALR
			default: alu_select = 5'bxxxxx; // JAL no ALU operation 
			endcase
		end	
		// DEFAULT UNKOWN
        	default: alu_select = 5'bxxxxx; 					// DEFAULT UNKOWN
    	endcase
end

endmodule
