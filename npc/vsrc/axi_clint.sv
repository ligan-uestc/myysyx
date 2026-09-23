// AXI4-Lite 从设备: 简化 CLINT (Core Local INTerrupt controller)
//
// 目前只需要时钟相关的功能 (讲义: 暂时不实现中断):
//   mtime     (只读, 每周期 +1 的 64 位计数器)  0x0200_BFF8 / 0x0200_BFFC
//   mtimecmp  (可读写, 64 位比较值)              0x0200_4000 / 0x0200_4004
// 若想支持时钟中断, 可以用 mtime >= mtimecmp 产生 MTIP 信号.
module axi_clint (
  input  logic        clk,
  input  logic        rst,
  axi4lite_if.slave   s,
  output logic        mtip          // mtime >= mtimecmp (供中断使用, 目前悬空)
);
  localparam logic [31:0] CLINT_BASE   = 32'h0200_0000;
  localparam logic [31:0] MTIMECMP_LO  = CLINT_BASE + 32'h0000_4000;
  localparam logic [31:0] MTIMECMP_HI  = CLINT_BASE + 32'h0000_4004;
  localparam logic [31:0] MTIME_LO     = CLINT_BASE + 32'h0000_bff8;
  localparam logic [31:0] MTIME_HI     = CLINT_BASE + 32'h0000_bffc;

  // ---------------- 时钟计数器 ----------------
  logic [63:0] mtime_q;
  logic [63:0] mtimecmp_q;
  always_ff @(posedge clk) begin
    if (rst) mtime_q <= 64'd0;
    else     mtime_q <= mtime_q + 64'd1;
  end
  assign mtip = (mtime_q >= mtimecmp_q);

  // ---------------- 读通道 ----------------
  typedef enum logic [1:0] { R_IDLE, R_WAIT, R_DATA } rstate_t;
  rstate_t     rstate;
  logic [31:0] raddr_q, rdata_q;

  always_ff @(posedge clk) begin
    if (rst) rstate <= R_IDLE;
    else begin
      unique case (rstate)
        R_IDLE: if (s.arvalid && s.arready) begin
          raddr_q <= s.araddr;
          unique case (s.araddr)
            MTIME_LO:    rdata_q <= mtime_q[31:0];
            MTIME_HI:    rdata_q <= mtime_q[63:32];
            MTIMECMP_LO: rdata_q <= mtimecmp_q[31:0];
            MTIMECMP_HI: rdata_q <= mtimecmp_q[63:32];
            default:     rdata_q <= 32'h0;
          endcase
          rstate <= R_DATA;
        end
        R_DATA: if (s.rvalid && s.rready) rstate <= R_IDLE;
        default: rstate <= R_IDLE;
      endcase
    end
  end

  assign s.arready = (rstate == R_IDLE);
  assign s.rvalid  = (rstate == R_DATA);
  assign s.rdata   = rdata_q;
  assign s.rresp   = 2'b00;

  // ---------------- 写通道 (只写 mtimecmp) ----------------
  typedef enum logic [1:0] { W_IDLE, W_RESP } wstate_t;
  wstate_t     wstate;
  logic [31:0] waddr_q, wdata_q;
  logic [3:0]  wstrb_q;
  logic        aw_got, w_got;

  wire aw_fire = s.awvalid && s.awready;
  wire w_fire  = s.wvalid  && s.wready;

  always_ff @(posedge clk) begin
    if (rst) begin
      wstate <= W_IDLE;
      aw_got <= 1'b0;
      w_got  <= 1'b0;
      mtimecmp_q <= 64'hffff_ffff_ffff_ffff;
    end
    else begin
      unique case (wstate)
        W_IDLE: begin
          if (aw_fire && !aw_got) begin waddr_q <= s.awaddr; aw_got <= 1'b1; end
          if (w_fire  && !w_got)  begin wdata_q <= s.wdata; wstrb_q <= s.wstrb; w_got <= 1'b1; end
          if ((aw_got || aw_fire) && (w_got || w_fire)) begin
            logic [31:0] wa;
            logic [31:0] wd;
            wa = aw_got ? waddr_q : s.awaddr;
            wd = w_got  ? wdata_q : s.wdata;
            if (wa == MTIMECMP_LO) mtimecmp_q[31:0]  <= wd;
            if (wa == MTIMECMP_HI) mtimecmp_q[63:32] <= wd;
            aw_got <= 1'b0;
            w_got  <= 1'b0;
            wstate <= W_RESP;
          end
        end
        W_RESP: if (s.bvalid && s.bready) wstate <= W_IDLE;
      endcase
    end
  end

  assign s.awready = (wstate == W_IDLE) && !aw_got;
  assign s.wready  = (wstate == W_IDLE) && !w_got;
  assign s.bvalid  = (wstate == W_RESP);
  assign s.bresp   = 2'b00;
endmodule
