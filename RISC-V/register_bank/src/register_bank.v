//Project: RISC-V 32 bit Architecture
//Module: register_bank.v
//Author: Shreyas Poyrekar
//Updated: 06/03/2020
//Register bank module having 32 registers each of 32 bit data behavioural model


module register_bank(Clk, Rst, Rd_reg_1, Rd_reg_2, Wr_reg, Wr_data, Rd_data_1,Rd_data_2, Reg_write);

parameter n_addr = 5;  //number of address bits for a registers
parameter n_reg = 32; // number of registers
parameter n_bit = 2**n_addr; // data bits stored in each registers

input Clk, Rst;
input Reg_write; // signal from the control unit
input [n_addr-1:0] Rd_reg_1, Rd_reg_2, Wr_reg; // address of the registers to read or write (5-bit address)
input [n_bit-1:0] Wr_data; // 32-bit data to be written on the register
output [n_bit-1:0] Rd_data_1, Rd_data_2; // 32-bit datat at given register address.

reg [n_bit-1:0] bank [n_reg-1:0];  // register bank of n_bit's having n_reg's

assign Rd_data_1 = (Rd_reg_1 == 0) ? 32'h0 : bank[Rd_reg_1]; // x0 is hardwired to zero
assign Rd_data_2 = (Rd_reg_2 == 0) ? 32'h0 : bank[Rd_reg_2];

integer i;

always @ (posedge Clk) begin
	if (!Rst) begin
		// Reset: Clear all registers to 0
		for (i = 0; i < n_reg; i = i + 1) begin
			bank[i] <= 32'h0;
		end
	end
	else begin
		// Normal operation: Write if enabled
		if (Reg_write && (Wr_reg != 0)) bank[Wr_reg] <= Wr_data;
	end
end

endmodule
