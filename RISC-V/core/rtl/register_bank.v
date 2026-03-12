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

// Combinatorial reads with write-through bypass:
    // If a write is in progress to the same register, return the new data
    // immediately so the ID stage (same cycle as WB) sees the correct value.
    assign Rd_data_1 = (Rd_reg_1 == 0) ? 32'h0 :
                       (Reg_write && (Wr_reg == Rd_reg_1)) ? Wr_data :
                       bank[Rd_reg_1];
    assign Rd_data_2 = (Rd_reg_2 == 0) ? 32'h0 :
                       (Reg_write && (Wr_reg == Rd_reg_2)) ? Wr_data :
                       bank[Rd_reg_2];

integer i;

// Simulation-only initialisation; synthesis ignores initial blocks.
// Removes the synchronous reset fan-out (32×32 FFs) that causes
// timing violations above ~50 MHz on the XC7Z020.
initial begin
	for (i = 0; i < n_reg; i = i + 1)
		bank[i] = 32'h0;
end

always @(posedge Clk) begin
	// Rst active-low: gate writes; no per-FF sync reset needed.
	if (Rst && Reg_write && (Wr_reg != 0))
		bank[Wr_reg] <= Wr_data;
end

endmodule
