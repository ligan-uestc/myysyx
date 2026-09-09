// Testbench for the sCPU: runs the embedded 1+2+...+10 program and
// compares the RTL against a software model of the sISA every cycle.
module scpu_tb;
  reg clk;
  reg rst = 1;
  reg [1:0] dbg_raddr;
  wire [7:0] dbg_rdata;
  wire [3:0] pc;
  wire [7:0] out_value;

  scpu dut(
    .clk        (clk),
    .rst        (rst),
    .pc         (pc),
    .out_value  (out_value),
    .dbg_raddr  (dbg_raddr),
    .dbg_rdata  (dbg_rdata)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // ---------------- software model of the sISA ----------------
  reg [7:0] m_r [0:3];
  reg [3:0] m_pc;
  reg [7:0] m_out;

  task model_step;
    reg [3:0] next_pc;
    begin
      next_pc = m_pc + 1'b1;
      case (m_pc)
        4'd0: m_r[1] = 8'd0;                 // li r1, 0
        4'd1: m_r[2] = 8'd1;                 // li r2, 1
        4'd2: m_r[3] = 8'd1;                 // li r3, 1
        4'd3: m_r[0] = 8'd11;                // li r0, 11
        4'd4: m_r[1] = m_r[1] + m_r[2];      // add r1, r1, r2
        4'd5: m_r[2] = m_r[2] + m_r[3];      // add r2, r2, r3
        4'd6: if (m_r[0] != m_r[2]) next_pc = 4'd4; // bner0 4, r2
        4'd7: m_out = m_r[1];                // out r1
        4'd8: next_pc = 4'd8;                // bner0 8, r1 (halt loop)
        default: ;
      endcase
      m_pc = next_pc;
    end
  endtask

  // ---------------- main sequence ----------------
  integer k;
  integer r;
  reg err = 0;

  initial begin
    $dumpfile("scpu_tb.vcd");
    $dumpvars(0, scpu_tb);

    // reset for 4 cycles
    repeat (4) @(posedge clk);
    rst <= 0;   // nonblocking: guarantees the 4th posedge still saw rst=1
    #1;

    // initial state: PC = 0, all GPR = 0
    m_pc = 4'd0;
    for (r = 0; r < 4; r = r + 1) m_r[r] = 8'd0;
    m_out = 8'd0;

    // run 64 cycles, checking against the model every cycle
    for (k = 0; k < 64; k = k + 1) begin
      if (pc !== m_pc) begin
        $display("FAIL cycle %0d: pc = %0d, expect %0d", k, pc, m_pc);
        err = 1;
      end
      for (r = 0; r < 4; r = r + 1) begin
        dbg_raddr = r[1:0];
        #1;
        if (dbg_rdata !== m_r[r]) begin
          $display("FAIL cycle %0d: r%0d = %0d, expect %0d",
                   k, r, dbg_rdata, m_r[r]);
          err = 1;
        end
      end
      if (out_value !== m_out) begin
        $display("FAIL cycle %0d: out_value = %0d, expect %0d",
                 k, out_value, m_out);
        err = 1;
      end
      @(posedge clk);
      #1;
      model_step();
    end

    // final result checks
    dbg_raddr = 2'd1;
    #1;
    if (err) begin
      $display("scpu_tb: FAILED");
      $fatal(1, "simulation failed");
    end
    else if (pc !== 4'd8 || out_value !== 8'd55 || dbg_rdata !== 8'd55) begin
      $display("FAIL: final state pc=%0d out=%0d r1=%0d", pc, out_value, dbg_rdata);
      $fatal(1, "final result mismatch");
    end
    else begin
      $display("scpu_tb: PASS  1+2+...+10 = %0d (0x%02h), displayed as hex \"37\" on seg7/seg6",
               out_value, out_value);
    end
    $finish;
  end

endmodule
