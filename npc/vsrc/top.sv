// NPC top: only the clock/reset are exposed.
// The core is a modular minirv processor (see npc_core.sv).
module top (
  input  logic clk,
  input  logic rst,
  output logic [31:0] pc,
  output logic [511:0] gpr_dbg
);
  npc_core u_core (
    .clk (clk),
    .rst (rst),
    .pc  (pc),
    .gpr_dbg (gpr_dbg)
  );
endmodule
