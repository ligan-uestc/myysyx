// NPC top: clock/reset plus the debug ports used by the simulation
// environment (sdb, itrace/mtrace, DiffTest).
module top (
  input  logic clk,
  input  logic rst,
  output logic [31:0] pc,
  output logic [31:0] inst,
  output logic [511:0] gpr_dbg,
  output logic        mem_valid,
  output logic        mem_we,
  output logic [1:0]  mem_size,
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata
);
  npc_core u_core (
    .clk (clk),
    .rst (rst),
    .pc  (pc),
    .inst (inst),
    .gpr_dbg (gpr_dbg),
    .mem_valid (mem_valid),
    .mem_we (mem_we),
    .mem_size (mem_size),
    .mem_addr (mem_addr),
    .mem_wdata (mem_wdata),
    .mem_rdata (mem_rdata)
  );
endmodule
