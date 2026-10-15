// AXI4 从设备: 简化 UART (B2: 由 AXI4-Lite 升级; 接入 ysyxSoC 后由
// ysyxSoC 自带的 UART16550 取代, 这里只在 B1 的独立仿真流程里使用)
//
// 只有一个设备寄存器 (地址与之前仿真环境的串口一致: 0xa000_03f8)。
// 写入时把数据的低 8 位当作字符, 通过 $write 输出到仿真终端。
// 真正的 UART 还要考虑电气细节, 这里只作为总线练习。
module axi_uart (
  input  logic        clk,
  input  logic        rst,
  axi4_if.slave       s
);
  localparam logic [31:0] UART_ADDR = 32'ha000_03f8;

  // ---------------- 读通道 ----------------
  typedef enum logic [1:0] { R_IDLE, R_WAIT, R_DATA } rstate_t;
  rstate_t     rstate;
  logic [31:0] rdata_q;
  logic [3:0]  rid_q;

  always_ff @(posedge clk) begin
    if (rst) rstate <= R_IDLE;
    else begin
      unique case (rstate)
        R_IDLE: if (s.arvalid && s.arready) begin
          rid_q   <= s.arid;
          rdata_q <= 32'h0;            // 该设备寄存器只可写, 读回 0
          rstate  <= R_DATA;
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
  assign s.rid     = rid_q;
  assign s.rlast   = 1'b1;

  // ---------------- 写通道: 输出字符 ----------------
  typedef enum logic [1:0] { W_IDLE, W_RESP } wstate_t;
  wstate_t     wstate;
  logic [31:0] waddr_q, wdata_q;
  logic [3:0]  wid_q;
  logic [3:0]  wstrb_q;
  logic        aw_got, w_got;

  wire aw_fire = s.awvalid && s.awready;
  wire w_fire  = s.wvalid  && s.wready;

  // AW/W 可能分两拍到达, 用"已锁存的值"或"本拍的值"取有效数据
  wire [31:0] eff_waddr = aw_got ? waddr_q : s.awaddr;
  wire [31:0] eff_wdata = w_got  ? wdata_q : s.wdata;
  wire [3:0]  eff_wstrb = w_got  ? wstrb_q  : s.wstrb;

  always_ff @(posedge clk) begin
    if (rst) begin
      wstate <= W_IDLE;
      aw_got <= 1'b0;
      w_got  <= 1'b0;
    end
    else begin
      unique case (wstate)
        W_IDLE: begin
          if (aw_fire && !aw_got) begin waddr_q <= s.awaddr; wid_q <= s.awid; aw_got <= 1'b1; end
          if (w_fire  && !w_got)  begin wdata_q <= s.wdata; wstrb_q <= s.wstrb; w_got <= 1'b1; end
          if ((aw_got || aw_fire) && (w_got || w_fire)) begin
            aw_got <= 1'b0;
            w_got  <= 1'b0;
            if (eff_waddr == UART_ADDR && eff_wstrb[0]) begin
              $write("%c", eff_wdata[7:0]);
            end
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
  assign s.bid     = wid_q;
endmodule
