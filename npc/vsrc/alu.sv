// Combinational ALU of the single-cycle NPC.
//
// References are all done with two's complement arithmetic:
//   * subtraction is addition of the two's complement,
//   * comparisons are derived from subtraction (signed / unsigned),
//   * shifts use the low 5 bits of the second operand.
`include "alu_ops.svh"

module alu (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [3:0]  op,
  output logic [31:0] y
);
  always_comb begin
    case (op)
      `ALU_ADD : y = a + b;
      `ALU_SUB : y = a - b;
      `ALU_SLL : y = a << b[4:0];
      `ALU_SLT : y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
      `ALU_SLTU: y = (a < b) ? 32'd1 : 32'd0;
      `ALU_XOR : y = a ^ b;
      `ALU_SRL : y = a >> b[4:0];
      `ALU_SRA : y = $signed(a) >>> b[4:0];
      `ALU_OR  : y = a | b;
      `ALU_AND : y = a & b;
      default  : y = 32'b0;
    endcase
  end
endmodule
