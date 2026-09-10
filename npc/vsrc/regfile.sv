// GPR of the minirv processor.
//
// The lecture requires "GPR数量与RV32E中定义的GPR数量一致" (16 registers).
// Register 0 is architecturally hardwired to 0:
//   - writes to register 0 are ignored;
//   - reads of register 0 return 0.
//
// Two register read ports are used by instruction decode; a third read port
// is used to obtain $a0 (x10) when the program executes ebreak, so that the
// simulation environment can report HIT GOOD/BAD TRAP.
module RegFile #(
  parameter ADDR_WIDTH = 4,
  parameter DATA_WIDTH = 32
) (
  input  logic                    clk,
  input  logic                    wen,
  input  logic [ADDR_WIDTH-1:0]   waddr,
  input  logic [DATA_WIDTH-1:0]   wdata,
  input  logic [ADDR_WIDTH-1:0]   raddr1,
  output logic [DATA_WIDTH-1:0]   rdata1,
  input  logic [ADDR_WIDTH-1:0]   raddr2,
  output logic [DATA_WIDTH-1:0]   rdata2,
  input  logic [ADDR_WIDTH-1:0]   raddr3,
  output logic [DATA_WIDTH-1:0]   rdata3,
  output logic [DATA_WIDTH*(2**ADDR_WIDTH)-1:0] dbg
);
  logic [DATA_WIDTH-1:0] rf [0:2**ADDR_WIDTH-1];

  always_ff @(posedge clk) begin
    if (wen && waddr != '0) rf[waddr] <= wdata;
  end

  assign rdata1 = (raddr1 == '0) ? '0 : rf[raddr1];
  assign rdata2 = (raddr2 == '0) ? '0 : rf[raddr2];
  assign rdata3 = (raddr3 == '0) ? '0 : rf[raddr3];

  // debug read of the whole register file (x0 forced to 0)
  always_comb begin
    for (int i = 0; i < 2**ADDR_WIDTH; i++) begin
      dbg[i*DATA_WIDTH +: DATA_WIDTH] = (i == 0) ? '0 : rf[i];
    end
  end
endmodule
