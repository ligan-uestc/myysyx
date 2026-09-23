// AXI4-Lite 从设备: 存储器 (128MiB @ 0x8000_0000)
//
// 物理存储仍然由仿真环境的 DPI-C 模型提供 (pmem_read/pmem_write), 本模块
// 只负责实现 AXI4-Lite 的握手协议。
//
// 参数 RAND_DELAY=1 时, 读/写都会插入由 LFSR 产生的 0~7 周期随机延迟,
// 用来测试 master 端的握手实现是否能在任意延迟下正确工作 (讲义"测试
// SimpleBus 的实现").
module axi_mem #(
  parameter bit RAND_DELAY = 1'b0
) (
  input  logic        clk,
  input  logic        rst,
  axi4lite_if.slave   s,
  output logic [1:0]  rstate_dbg,
  output logic [1:0]  wstate_dbg
);
  import "DPI-C" function int  pmem_read(input int raddr);
  import "DPI-C" function void pmem_write(input int waddr, input int wdata, input byte wmask);

  // ---------------- LFSR: 随机延迟 ----------------
  logic [15:0] lfsr_q;
  wire  [15:0] lfsr_d = {lfsr_q[14:0], lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]};
  always_ff @(posedge clk) begin
    if (rst) lfsr_q <= 16'hace1;
    else     lfsr_q <= lfsr_d;
  end
  wire [3:0] rand_dly = RAND_DELAY ? {1'b0, lfsr_q[2:0]} : 4'd0;   // 0~7 周期

  // ---------------- 读通道 ----------------
  typedef enum logic [1:0] { R_IDLE, R_WAIT, R_DATA } rstate_t;
  rstate_t     rstate;
  assign rstate_dbg = rstate;
  logic [31:0] raddr_q, rdata_q;
  logic [3:0]  rcnt;

  always_ff @(posedge clk) begin
    if (rst) begin
      rstate <= R_IDLE;
      rcnt   <= 4'd0;
    end
    else begin
      unique case (rstate)
        R_IDLE: if (s.arvalid && s.arready) begin
          raddr_q <= s.araddr;
          if (rand_dly == 4'd0) begin
            // 无延迟: 下一拍就能返回数据 (1 周期延迟, 与讲义一致)
            rdata_q <= 32'(pmem_read(int'(s.araddr)));
            rstate  <= R_DATA;
          end
          else begin
            rcnt   <= rand_dly - 4'd1;
            rstate <= R_WAIT;
          end
        end
        R_WAIT: begin
          if (rcnt == 4'd0) begin
            rdata_q <= 32'(pmem_read(int'(raddr_q)));
            rstate  <= R_DATA;
          end
          else rcnt <= rcnt - 4'd1;
        end
        R_DATA: if (s.rvalid && s.rready) rstate <= R_IDLE;
      endcase
    end
  end

  assign s.arready = (rstate == R_IDLE);
  assign s.rvalid  = (rstate == R_DATA);
  assign s.rdata   = rdata_q;
  assign s.rresp   = 2'b00;   // OKAY

  // ---------------- 写通道 ----------------
  typedef enum logic [1:0] { W_IDLE, W_WAIT, W_RESP } wstate_t;
  wstate_t     wstate;
  assign wstate_dbg = wstate;
  logic [31:0] waddr_q, wdata_q;
  logic [3:0]  wstrb_q, wcnt;
  logic        aw_got, w_got;

  wire aw_fire = s.awvalid && s.awready;
  wire w_fire  = s.wvalid  && s.wready;

  always_ff @(posedge clk) begin
    if (rst) begin
      wstate <= W_IDLE;
      aw_got <= 1'b0;
      w_got  <= 1'b0;
      wcnt   <= 4'd0;
    end
    else begin
      unique case (wstate)
        W_IDLE: begin
          if (aw_fire && !aw_got) begin waddr_q <= s.awaddr; aw_got <= 1'b1; end
          if (w_fire  && !w_got)  begin wdata_q <= s.wdata; wstrb_q <= s.wstrb; w_got <= 1'b1; end
          // AW 和 W 都到齐后才开始处理 (两者顺序任意)
          if ((aw_got || aw_fire) && (w_got || w_fire)) begin
            aw_got <= 1'b0;
            w_got  <= 1'b0;
            wcnt   <= rand_dly;
            wstate <= W_WAIT;
          end
        end
        W_WAIT: begin
          if (wcnt == 4'd0) begin
            pmem_write(int'(waddr_q), int'(wdata_q), byte'(wstrb_q));
            wstate <= W_RESP;
          end
          else wcnt <= wcnt - 4'd1;
        end
        W_RESP: if (s.bvalid && s.bready) wstate <= W_IDLE;
      endcase
    end
  end

  assign s.awready = (wstate == W_IDLE) && !aw_got;
  assign s.wready  = (wstate == W_IDLE) && !w_got;
  assign s.bvalid  = (wstate == W_RESP);
  assign s.bresp   = 2'b00;   // OKAY
endmodule
