// Top module for the NVBoard demo:
// the sCPU computes 1 + 2 + ... + 10 and displays the result R[1] = 55
// (0x37) in hex on the leftmost 7-segment digits of the NVBoard N4 board
// (seg7 = high nibble, seg6 = low nibble, read left to right as "37").
module top(
  input  clk,
  input  rst,
  output [7:0] seg0,
  output [7:0] seg1,
  output [7:0] seg2,
  output [7:0] seg3,
  output [7:0] seg4,
  output [7:0] seg5,
  output [7:0] seg6,
  output [7:0] seg7
);

  wire [3:0] pc;
  wire [7:0] out_value;

  /* verilator lint_off PINCONNECTEMPTY */
  /* verilator lint_off UNUSEDSIGNAL */
  scpu u_scpu(
    .clk       (clk),
    .rst       (rst),
    .pc        (pc),
    .out_value (out_value),
    .dbg_raddr (2'd0),
    .dbg_rdata ()
  );
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on PINCONNECTEMPTY */

  // result in hex: high nibble on seg7, low nibble on seg6
  seg7 u_hex_hi(
    .hex (out_value[7:4]),
    .seg (seg7)
  );

  seg7 u_hex_lo(
    .hex (out_value[3:0]),
    .seg (seg6)
  );

  // remaining digits are off
  assign seg0 = 8'hFF;
  assign seg1 = 8'hFF;
  assign seg2 = 8'hFF;
  assign seg3 = 8'hFF;
  assign seg4 = 8'hFF;
  assign seg5 = 8'hFF;

endmodule
