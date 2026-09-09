// 7-segment decoder for a hex digit.
// seg output is ACTIVE LOW, bit order: {a, b, c, d, e, f, g, dp}
// (bit 7 = a, bit 0 = dp), which matches the NVBoard segN pins.
module seg7 (
  input  wire [3:0] hex,
  output reg  [7:0] seg
);

  always @(*) begin
    case (hex)
      4'h0: seg = 8'h03; // 0
      4'h1: seg = 8'h9F; // 1
      4'h2: seg = 8'h25; // 2
      4'h3: seg = 8'h0D; // 3
      4'h4: seg = 8'h99; // 4
      4'h5: seg = 8'h49; // 5
      4'h6: seg = 8'h41; // 6
      4'h7: seg = 8'h1F; // 7
      4'h8: seg = 8'h00; // 8
      4'h9: seg = 8'h09; // 9
      4'hA: seg = 8'h11; // A
      4'hB: seg = 8'hC1; // b
      4'hC: seg = 8'h61; // C
      4'hD: seg = 8'h85; // d
      4'hE: seg = 8'h60; // E
      4'hF: seg = 8'h71; // F
      default: seg = 8'hFF;
    endcase
  end

endmodule
