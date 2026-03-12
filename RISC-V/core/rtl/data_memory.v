//Project: RISC-V 32 bit Architecture
//Module: data_memory.v
//Author: Shreyas Poyrekar
//Updated: 2026-03-11 - Added byte/halfword access (funct3) and proper byte-addressing
//data memory 256 32-bit word locations (1 KB), byte-addressed via upper address bits

module data_memory #(
    parameter n_addr = 8,           // word-address bits: 256 words = 1 KB
    parameter n_bit  = 32
) (
    input  wire                 Clk,
    input  wire                 Rst,
    input  wire                 MemWrite,
    input  wire                 MemRead,
    input  wire [n_addr-1:0]    Addr,       // word-index (byte_addr >> 2)
    input  wire [1:0]           byte_sel,   // byte_addr[1:0]: selects byte/HW lane
    input  wire [2:0]           funct3,     // RV32 funct3: 000=lb,001=lh,010=lw,
                                            //              100=lbu,101=lhu, sb/sh/sw same
    input  wire [n_bit-1:0]     Wr_data,
    output reg  [n_bit-1:0]     Rd_data
);

    localparam size = 2**n_addr;
    reg [n_bit-1:0] MEM [0:size-1];

    always @(posedge Clk) begin
        if (MemWrite) begin
            // sub-word writes: only touch the relevant byte(s)
            case (funct3[1:0])
                2'b10: MEM[Addr] <= Wr_data;  // sw - full word
                2'b01: begin                   // sh - halfword
                    if (byte_sel[1])
                        MEM[Addr][31:16] <= Wr_data[15:0];
                    else
                        MEM[Addr][15:0]  <= Wr_data[15:0];
                end
                2'b00: begin                   // sb - byte
                    case (byte_sel)
                        2'b00: MEM[Addr][ 7: 0] <= Wr_data[7:0];
                        2'b01: MEM[Addr][15: 8] <= Wr_data[7:0];
                        2'b10: MEM[Addr][23:16] <= Wr_data[7:0];
                        2'b11: MEM[Addr][31:24] <= Wr_data[7:0];
                    endcase
                end
                default: MEM[Addr] <= Wr_data;
            endcase
        end
    end

    // Combinatorial reads — the pipeline expects data to be available
    // in the same cycle the address is presented (distributed-RAM style).
    always @(*) begin
        if (MemRead) begin
            // sub-word reads with sign/zero extension
            case (funct3)
                3'b010: Rd_data = MEM[Addr]; // lw
                3'b001: begin                  // lh - sign-extended
                    Rd_data = byte_sel[1]
                        ? {{16{MEM[Addr][31]}}, MEM[Addr][31:16]}
                        : {{16{MEM[Addr][15]}}, MEM[Addr][15:0]};
                end
                3'b101: begin                  // lhu - zero-extended
                    Rd_data = byte_sel[1]
                        ? {16'd0, MEM[Addr][31:16]}
                        : {16'd0, MEM[Addr][15:0]};
                end
                3'b000: begin                  // lb - sign-extended
                    case (byte_sel)
                        2'b00: Rd_data = {{24{MEM[Addr][ 7]}}, MEM[Addr][ 7: 0]};
                        2'b01: Rd_data = {{24{MEM[Addr][15]}}, MEM[Addr][15: 8]};
                        2'b10: Rd_data = {{24{MEM[Addr][23]}}, MEM[Addr][23:16]};
                        2'b11: Rd_data = {{24{MEM[Addr][31]}}, MEM[Addr][31:24]};
                    endcase
                end
                3'b100: begin                  // lbu - zero-extended
                    case (byte_sel)
                        2'b00: Rd_data = {24'd0, MEM[Addr][ 7: 0]};
                        2'b01: Rd_data = {24'd0, MEM[Addr][15: 8]};
                        2'b10: Rd_data = {24'd0, MEM[Addr][23:16]};
                        2'b11: Rd_data = {24'd0, MEM[Addr][31:24]};
                    endcase
                end
                default: Rd_data = MEM[Addr];
            endcase
        end else begin
            Rd_data = 32'd0;
        end
    end

endmodule
