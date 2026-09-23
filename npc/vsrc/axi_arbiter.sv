// AXI4-Lite 仲裁器: 从 IFU 和 LSU 两个 master 中选一个与下游 slave (存储器)
// 通信。
//
// 实现要点:
//   * 空闲时用组合逻辑选出要授予的 master (两个同时请求时按轮转);
//   * 一旦某个通道完成握手, 就"锁定"到该 master, 直到事务结束
//     (读的最后一拍 R, 或写的 B), 然后再解锁;
//   * 锁定期间把该 master 的 5 个通道原样转发给下游, 另一个 master 的
//     ready 保持 0 (它的 valid 会一直等待, 这符合 AXI 的约束)。
module axi_arbiter (
  input  logic        clk,
  input  logic        rst,
  axi4lite_if.slave   m0,     // master 0: IFU
  axi4lite_if.slave   m1,     // master 1: LSU
  axi4lite_if.master  s,      // 下游 (存储器)
  output logic [1:0]  state_dbg
);
  typedef enum logic [1:0] { IDLE, GNT0, GNT1 } state_t;
  state_t st;
  assign state_dbg = st;
  logic   last_q;             // 上一次授予的 master (轮转)

  wire req0 = m0.arvalid || m0.awvalid;
  wire req1 = m1.arvalid || m1.awvalid;

  // 空闲时组合授予; 已锁定时保持
  wire gnt0_now = req0 && (!req1 || !last_q);
  wire gnt1_now = req1 && (!req0 ||  last_q);
  wire sel0 = (st == GNT0) || (st == IDLE && gnt0_now);
  wire sel1 = (st == GNT1) || (st == IDLE && gnt1_now);

  // 事务开始: 被选中的 master 的请求通道完成握手
  wire start0 = sel0 && (m0.arvalid || m0.awvalid) && (s.arready || s.awready);
  wire start1 = sel1 && (m1.arvalid || m1.awvalid) && (s.arready || s.awready);
  // 事务结束: 最后一拍 R 或 B 完成握手
  wire done0 = sel0 && ((s.rvalid && m0.rready) || (s.bvalid && m0.bready));
  wire done1 = sel1 && ((s.rvalid && m1.rready) || (s.bvalid && m1.bready));

  always_ff @(posedge clk) begin
    if (rst) begin
      st     <= IDLE;
      last_q <= 1'b0;
    end
    else begin
      unique case (st)
        IDLE: begin
          if      (start0) begin st <= GNT0; last_q <= 1'b0; end
          else if (start1) begin st <= GNT1; last_q <= 1'b1; end
        end
        GNT0: if (done0) st <= IDLE;
        GNT1: if (done1) st <= IDLE;
      endcase
    end
  end

  // ---------------- 请求通道: 向 slave 转发 ----------------
  assign s.arvalid = sel0 ? m0.arvalid : (sel1 ? m1.arvalid : 1'b0);
  assign s.araddr  = sel0 ? m0.araddr  : m1.araddr;
  assign s.awvalid = sel0 ? m0.awvalid : (sel1 ? m1.awvalid : 1'b0);
  assign s.awaddr  = sel0 ? m0.awaddr  : m1.awaddr;
  assign s.wvalid  = sel0 ? m0.wvalid  : (sel1 ? m1.wvalid  : 1'b0);
  assign s.wdata   = sel0 ? m0.wdata   : m1.wdata;
  assign s.wstrb   = sel0 ? m0.wstrb   : m1.wstrb;
  assign s.rready  = sel0 ? m0.rready  : (sel1 ? m1.rready  : 1'b0);
  assign s.bready  = sel0 ? m0.bready  : (sel1 ? m1.bready  : 1'b0);

  // ---------------- 响应通道: 回到被授予的 master ----------------
  assign m0.arready = sel0 ? s.arready : 1'b0;
  assign m1.arready = sel1 ? s.arready : 1'b0;
  assign m0.awready = sel0 ? s.awready : 1'b0;
  assign m1.awready = sel1 ? s.awready : 1'b0;
  assign m0.wready  = sel0 ? s.wready  : 1'b0;
  assign m1.wready  = sel1 ? s.wready  : 1'b0;

  assign m0.rvalid = sel0 ? s.rvalid : 1'b0;
  assign m1.rvalid = sel1 ? s.rvalid : 1'b0;
  assign m0.rdata  = s.rdata;
  assign m1.rdata  = s.rdata;
  assign m0.rresp  = s.rresp;
  assign m1.rresp  = s.rresp;

  assign m0.bvalid = sel0 ? s.bvalid : 1'b0;
  assign m1.bvalid = sel1 ? s.bvalid : 1'b0;
  assign m0.bresp  = s.bresp;
  assign m1.bresp  = s.bresp;
endmodule
