// ============================================================================
// minirv processor core (D4 lecture: 用RTL实现迷你RISC-V处理器)
//
// minirv ISA (RV32E register file):
//   add, addi, lui, lw, lbu, sw, sb, jalr   (RV32I encodings)
// plus the special ebreak used as the AM "nemu_trap".
//
// Memory is implemented in C++ (csrc/main.cpp).  The core talks to it through
// DPI-C so that both instruction fetch and load/store use the same 32-bit
// "bus": pmem_read() returns the aligned 4-byte word, pmem_write() accepts a
// byte write mask.
//
// The datapath is organized following the lecture's module suggestion:
//   IFU - program counter + instruction fetch  (this file, top section)
//   IDU - instruction decode + operand/imm gen (this file, decode block)
//   EXU - ALU result / effective address        (this file, execute signals)
//   LSU - load/store via DPI-C                  (this file, mem block)
//   WBU - write back + next PC                  (this file, wb/pc blocks)
//   GPR - separate RegFile module
// ============================================================================
module npc_core #(
  parameter logic [31:0] PC_INIT = 32'h8000_0000  // minirv-npc memory base
) (
  input logic clk,
  input logic rst,
  output logic [31:0] pc,
  output logic [512-1:0] gpr_dbg
);
  // ---- DPI-C interfaces to the C++ simulation environment ----
  import "DPI-C" function int pmem_read(input int raddr);
  import "DPI-C" function void pmem_write(input int waddr, input int wdata, input byte wmask);
  import "DPI-C" function void ebreak(input int code);

  // ------------------------------------------------------------------
  // IFU
  // ------------------------------------------------------------------
  logic [31:0] next_pc;
  logic [31:0] inst;

  always_ff @(posedge clk) begin
    if (rst) pc <= PC_INIT;
    else if (!is_ebreak) pc <= next_pc;  // freeze on ebreak
  end

  // Instruction fetch is a (bus) read of the word at pc.
  always_comb inst = 32'(pmem_read(int'(pc)));

  // ------------------------------------------------------------------
  // IDU: instruction fields
  // ------------------------------------------------------------------
  wire [6:0] opcode = inst[6:0];
  wire [4:0] rd     = inst[11:7];
  wire [2:0] funct3 = inst[14:12];
  wire [4:0] rs1    = inst[19:15];
  wire [4:0] rs2    = inst[24:20];
  wire [6:0] funct7 = inst[31:25];

  // I-type sign-extended immediate; U-type immediate (lui)
  wire [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
  // S-type sign-extended immediate (sb/sh/sw)
  wire [31:0] imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
  wire [31:0] imm_u = {inst[31:12], 12'b0};

  // ------------------------------------------------------------------
  // GPR (16 x 32, x0 hardwired to 0)
  // ------------------------------------------------------------------
  logic [31:0] rv1;    // rs1 value
  logic [31:0] rv2;    // rs2 value
  logic [31:0] gpr_a0; // x10 ($a0), read for ebreak
  logic        rf_we;
  logic [3:0]  rf_wa;
  logic [31:0] rf_wd;

  RegFile #(
    .ADDR_WIDTH (4),
    .DATA_WIDTH (32)
  ) u_rf (
    .clk   (clk),
    .wen   (rf_we),
    .waddr (rf_wa),
    .wdata (rf_wd),
    .raddr1 (rs1[3:0]),
    .rdata1 (rv1),
    .raddr2 (rs2[3:0]),
    .rdata2 (rv2),
    .raddr3 (4'd10),
    .rdata3 (gpr_a0),
    .dbg    (gpr_dbg)
  );

  // ------------------------------------------------------------------
  // IDU + EXU: decode and compute ALU result / effective address
  // ------------------------------------------------------------------
  logic        mem_read;   // lw / lbu
  logic        mem_write;  // sw / sb
  logic        mem_word;   // 1: word access; 0: byte access
  logic        is_jalr;
  logic        is_ebreak;
  logic        is_invalid;
  logic [31:0] ex_result;  // ALU result / lui / effective address / jalr target

  always_comb begin
    rf_we      = 1'b0;
    rf_wa      = rd[3:0];
    ex_result  = 32'b0;
    mem_read   = 1'b0;
    mem_write  = 1'b0;
    mem_word   = 1'b1;
    is_jalr    = 1'b0;
    is_ebreak  = 1'b0;
    is_invalid = 1'b0;

    if (!rst) begin
      case (opcode)
        7'b0110111: begin            // lui
          rf_we     = 1'b1;
          rf_wa     = rd[3:0];
          ex_result = imm_u;
        end
        7'b0010011: begin            // addi (only funct3 == 000 is used)
          if (funct3 == 3'b000) begin
            rf_we     = 1'b1;
            rf_wa     = rd[3:0];
            ex_result = rv1 + imm_i;
          end
          else is_invalid = 1'b1;
        end
        7'b0110011: begin            // add (only funct7 == 0, funct3 == 0)
          if (funct3 == 3'b000 && funct7 == 7'b0) begin
            rf_we     = 1'b1;
            rf_wa     = rd[3:0];
            ex_result = rv1 + rv2;
          end
          else is_invalid = 1'b1;
        end
        7'b0000011: begin            // lbu / lw
          if (funct3 == 3'b100) begin
            rf_we     = 1'b1;
            rf_wa     = rd[3:0];
            ex_result = rv1 + imm_i; // effective address
            mem_read  = 1'b1;
            mem_word  = 1'b0;
          end
          else if (funct3 == 3'b010) begin
            rf_we     = 1'b1;
            rf_wa     = rd[3:0];
            ex_result = rv1 + imm_i;
            mem_read  = 1'b1;
            mem_word  = 1'b1;
          end
          else is_invalid = 1'b1;
        end
        7'b0100011: begin            // sb / sw
          if (funct3 == 3'b000) begin
            ex_result = rv1 + imm_s;
            mem_write = 1'b1;
            mem_word  = 1'b0;
          end
          else if (funct3 == 3'b010) begin
            ex_result = rv1 + imm_s;
            mem_write = 1'b1;
            mem_word  = 1'b1;
          end
          else is_invalid = 1'b1;
        end
        7'b1100111: begin            // jalr
          if (funct3 == 3'b000) begin
            rf_we     = 1'b1;
            rf_wa     = rd[3:0];
            is_jalr   = 1'b1;
            ex_result = rv1 + imm_i; // jump target
          end
          else is_invalid = 1'b1;
        end
        7'b1110011: begin            // ebreak (exact encoding 0x00100073)
          if (inst == 32'h0010_0073) is_ebreak = 1'b1;
          else is_invalid = 1'b1;
        end
        default: is_invalid = 1'b1;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // LSU: data memory access through DPI-C
  // ------------------------------------------------------------------
  logic [31:0] mem_rdata;  // aligned 32-bit read data
  logic [31:0] ld_data;    // data selected/extended for the load

  always_comb begin
    mem_rdata = 32'b0;
    ld_data   = 32'b0;

    if (!rst && mem_read) begin
      mem_rdata = 32'(pmem_read(int'(ex_result)));
      if (mem_word) ld_data = mem_rdata;                                  // lw
      else ld_data = (mem_rdata >> (8 * ex_result[1:0])) & 32'hff;        // lbu
    end

    if (!rst && mem_write) begin
      if (mem_word) begin
        pmem_write(int'(ex_result), int'(rv2), 8'h0f);                    // sw
      end
      else begin
        // sb: place the byte in the correct lane and mask only that lane
        pmem_write(int'(ex_result), int'(rv2 << (8 * ex_result[1:0])),
                   byte'(1 << ex_result[1:0]));
      end
    end
  end

  // ------------------------------------------------------------------
  // WBU: register write-back mux
  // ------------------------------------------------------------------
  always_comb begin
    if (is_jalr) rf_wd = pc + 4;        // jalr writes the return address
    else if (mem_read) rf_wd = ld_data; // loads
    else rf_wd = ex_result;             // alu / lui
  end

  // ------------------------------------------------------------------
  // Next PC
  // ------------------------------------------------------------------
  always_comb begin
    if (is_jalr) next_pc = ex_result & 32'hffff_fffe;  // clear bit 0
    else next_pc = pc + 4;
  end

  // ------------------------------------------------------------------
  // Notify the simulation environment
  // ------------------------------------------------------------------
  always_comb begin
    if (!rst) begin
      if (is_ebreak)  ebreak(int'(gpr_a0));  // $a0 = exit code (AM convention)
      else if (is_invalid) ebreak(-1);       // illegal minirv encoding
    end
  end
endmodule
