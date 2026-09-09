// sCPU: a simple single-cycle CPU implementing the sISA from the ysyx
// lecture "F5 支持数列求和的简单处理器".
//
// sISA (8-bit instruction, little-endian field layout):
//   add    rd, rs1, rs2   | 00 | rd | rs1 | rs2 |  R[rd] = R[rs1] + R[rs2]
//   li     rd, imm        | 10 | rd |   imm    |  R[rd] = imm (zero extended)
//   bner0  addr, rs2      | 11 | addr  | rs2   |  if (R[0] != R[rs2]) PC = addr
//   out    rs             | 01 | rs |  0000    |  display R[rs] in hex on 7-seg
//
// PC: 4 bits, reset value 0.
// GPR: 4 registers, each 8 bits.
module scpu (
  input  wire       clk,
  input  wire       rst,

  // program counter
  output wire [3:0] pc,
  // value latched by the "out" instruction (shown on the 7-seg display)
  output wire [7:0] out_value,

  // debug read port for simulation
  input  wire [1:0] dbg_raddr,
  output wire [7:0] dbg_rdata
);

  // ------------------------------------------------------------------
  // Instruction memory: 16 x 8 ROM
  // The embedded program computes 1 + 2 + ... + 10 and outputs R[1] = 55
  // (0x37) to the 7-segment display.
  //
  //  addr  instruction         encoding   comment
  //  0     li r1, 0            1001 0000  sum = 0        (R[1])
  //  1     li r2, 1            1010 0001  i = 1          (R[2])
  //  2     li r3, 1            1011 0001  step = 1       (R[3])
  //  3     li r0, 11           1000 1011  loop while i != 11
  //  4     add r1, r1, r2      0001 0110  sum += i
  //  5     add r2, r2, r3      0010 1011  i += 1
  //  6     bner0 4, r2         1101 0010  if (R[0] != i) goto 4
  //  7     out r1              0101 0000  display R[1] in hex
  //  8     bner0 8, r1         1110 0001  halt: loop forever
  //  ...
  reg [7:0] imem [0:15];
  integer i;
  initial begin
    imem[ 0] = 8'h90;
    imem[ 1] = 8'hA1;
    imem[ 2] = 8'hB1;
    imem[ 3] = 8'h8B;
    imem[ 4] = 8'h16;
    imem[ 5] = 8'h2B;
    imem[ 6] = 8'hD2;
    imem[ 7] = 8'h50;
    for (i = 8; i < 16; i = i + 1) imem[i] = 8'hE1;
  end

  // ------------------------------------------------------------------
  // GPR: 4 x 8, two read ports + one write port
  reg [7:0] gpr [0:3];

  // ------------------------------------------------------------------
  // Decode
  wire [1:0] op    = imem[pc][7:6];
  wire [1:0] rd    = imem[pc][5:4];
  wire [1:0] rs1   = imem[pc][3:2];
  wire [1:0] rs2   = imem[pc][1:0];
  wire [3:0] imm   = imem[pc][3:0];
  wire [3:0] baddr = imem[pc][5:2];
  wire [1:0] out_rs = imem[pc][5:4];

  wire is_add   = (op == 2'b00);
  wire is_li    = (op == 2'b10);
  wire is_bner0 = (op == 2'b11);
  wire is_out   = (op == 2'b01);

  // ------------------------------------------------------------------
  // Execute
  // bner0 reads R[0] from the first read port; add reads R[rs1]
  wire [1:0] raddr1 = is_bner0 ? 2'd0 : rs1;
  wire [7:0] rdata1 = gpr[raddr1];
  wire [7:0] rdata2 = gpr[rs2];
  wire [7:0] sum    = rdata1 + rdata2;

  // What to write back to the GPR and whether to write at all
  wire [7:0] wdata = is_add ? sum : {4'b0, imm};
  wire       wen   = is_add | is_li;

  // Next PC: branch taken only by bner0 when R[0] != R[rs2]
  wire [3:0] pc_next = (is_bner0 && (rdata1 != rdata2)) ? baddr : pc + 1'b1;

  // ------------------------------------------------------------------
  // State update
  reg [3:0] pc_r;
  reg [7:0] out_value_r;
  integer j;

  assign pc        = pc_r;
  assign out_value = out_value_r;
  assign dbg_rdata = gpr[dbg_raddr];

  always @(posedge clk) begin
    if (rst) begin
      pc_r       <= 4'd0;
      out_value_r <= 8'd0;
      for (j = 0; j < 4; j = j + 1) gpr[j] <= 8'd0;
    end
    else begin
      if (wen) gpr[rd] <= wdata;
      pc_r <= pc_next;
      if (is_out) out_value_r <= gpr[out_rs];
    end
  end

endmodule
