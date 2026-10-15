// ============================================================================
// ysyx_22040000 —— 接入 ysyxSoC 的 NPC 顶层 (B2 SoC 讲义)
//
// 与 B1 的独立仿真顶层 (top.sv) 的区别:
//   * 顶层接口严格遵循 ysyxSoC/spec/cpu-interface.md 的命名规范
//     (clock / reset / io_interrupt / io_master_* / io_slave_*);
//   * 对外只暴露一个 AXI4 master, IFU 和 LSU 在内部通过仲裁器合流;
//   * 不再包含作为习题的 AXI4-Lite SRAM 和 UART (改用 ysyxSoC 里的
//     存储器与 UART16550); 但保留 CLINT, 因为它将作为流片工程的一部分,
//     而 ysyxSoC 并不包含 CLINT。
//
// 访存路径:
//   NPC 核心 (IFU/LSU) --> 仲裁器 --> 地址译码 --+--> CLINT (0x0200_0000, 内部)
//                                              \--> io_master (其余全部地址,
//                                                   交给 ysyxSoC 的 Xbar)
// ============================================================================
module ysyx_22040000 (
  input  logic        clock,
  input  logic        reset,
  input  logic        io_interrupt,
  // ---------------- AXI4 master (CPU 是 master, 方向同 spec/cpu-interface.md) ----
  input  logic        io_master_awready,
  output logic        io_master_awvalid,
  output logic [31:0] io_master_awaddr,
  output logic [3:0]  io_master_awid,
  output logic [7:0]  io_master_awlen,
  output logic [2:0]  io_master_awsize,
  output logic [1:0]  io_master_awburst,
  input  logic        io_master_wready,
  output logic        io_master_wvalid,
  output logic [31:0] io_master_wdata,
  output logic [3:0]  io_master_wstrb,
  output logic        io_master_wlast,
  output logic        io_master_bready,
  input  logic        io_master_bvalid,
  input  logic [1:0]  io_master_bresp,
  input  logic [3:0]  io_master_bid,
  input  logic        io_master_arready,
  output logic        io_master_arvalid,
  output logic [31:0] io_master_araddr,
  output logic [3:0]  io_master_arid,
  output logic [7:0]  io_master_arlen,
  output logic [2:0]  io_master_arsize,
  output logic [1:0]  io_master_arburst,
  output logic        io_master_rready,
  input  logic        io_master_rvalid,
  input  logic [1:0]  io_master_rresp,
  input  logic [31:0] io_master_rdata,
  input  logic        io_master_rlast,
  input  logic [3:0]  io_master_rid,
  // ---------------- AXI4 slave (ChipLink 用; 未打开时输出常数 0) ----------------
  output logic        io_slave_awready,
  input  logic        io_slave_awvalid,
  input  logic [31:0] io_slave_awaddr,
  input  logic [3:0]  io_slave_awid,
  input  logic [7:0]  io_slave_awlen,
  input  logic [2:0]  io_slave_awsize,
  input  logic [1:0]  io_slave_awburst,
  output logic        io_slave_wready,
  input  logic        io_slave_wvalid,
  input  logic [31:0] io_slave_wdata,
  input  logic [3:0]  io_slave_wstrb,
  input  logic        io_slave_wlast,
  input  logic        io_slave_bready,
  output logic        io_slave_bvalid,
  output logic [1:0]  io_slave_bresp,
  output logic [3:0]  io_slave_bid,
  output logic        io_slave_arready,
  input  logic        io_slave_arvalid,
  input  logic [31:0] io_slave_araddr,
  input  logic [3:0]  io_slave_arid,
  input  logic [7:0]  io_slave_arlen,
  input  logic [2:0]  io_slave_arsize,
  input  logic [1:0]  io_slave_arburst,
  input  logic        io_slave_rready,
  output logic        io_slave_rvalid,
  output logic [1:0]  io_slave_rresp,
  output logic [31:0] io_slave_rdata,
  output logic        io_slave_rlast,
  output logic [3:0]  io_slave_rid
);
  axi4_if ifu_bus (), lsu_bus (), arb_bus (), clint_bus ();
  logic        mtip;

  // ---------------- 处理器核心 ----------------
  // B5: CORE=multi 时用多周期核心 (B2/B4 的实现), 默认用五级流水线核心
`ifdef NPC_MULTICYCLE
  npc_core #(.PC_INIT(32'h2000_0000)) u_core (
`else
  npc_pipe_core #(.PC_INIT(32'h2000_0000)) u_core (
`endif
    .clk (clock), .rst (reset),
    .pc (), .inst (), .gpr_dbg (), .inst_done (),
    .mem_valid (), .mem_we (), .mem_size (), .mem_addr (),
    .mem_wdata (), .mem_rdata (),
    .ifu_mem (ifu_bus), .lsu_axi (lsu_bus),
    .state_dbg ()
  );

  // ---------------- IFU + LSU -> 一个 AXI4 master ----------------
  axi_arbiter u_arb (
    .clk (clock), .rst (reset),
    .m0 (ifu_bus), .m1 (lsu_bus), .s (arb_bus),
    .state_dbg ()
  );

  // ---------------- 地址译码: CLINT (内部) vs 其它 (SoC) ----------------
  localparam logic [31:0] CLINT_BASE = 32'h0200_0000;
  localparam logic [31:0] CLINT_END  = 32'h0201_0000;

  wire [31:0] req_addr = arb_bus.arvalid ? arb_bus.araddr : arb_bus.awaddr;
  wire        hit_clint = (req_addr >= CLINT_BASE) && (req_addr < CLINT_END);

  // 一次事务只服务一个目标, 因此在第一次地址握手时锁定目标, 事务结束时解锁
  logic sel_clint, sel_valid;
  always_ff @(posedge clock) begin
    if (reset) begin
      sel_clint <= 1'b0;
      sel_valid <= 1'b0;
    end
    else begin
      if (!sel_valid && (arb_bus.arvalid || arb_bus.awvalid)
                     && (arb_bus.arready || arb_bus.awready)) begin
        sel_clint <= hit_clint;
        sel_valid <= 1'b1;
      end
      if (sel_valid && ((arb_bus.bvalid && arb_bus.bready)
                     || (arb_bus.rvalid && arb_bus.rlast && arb_bus.rready)))
        sel_valid <= 1'b0;
    end
  end
  // 尚未锁定目标时用组合译码 (保证第一次握手就能走到正确的从设备);
  // 已锁定后沿用锁存值, 直到事务结束。
  wire cur_clint = sel_valid ? sel_clint : hit_clint;
  wire to_clint  = cur_clint;
  wire to_ext    = !cur_clint;

  // 上游 -> 被选中的目标
  assign clint_bus.arid    = arb_bus.arid;
  assign clint_bus.arlen   = arb_bus.arlen;
  assign clint_bus.arsize  = arb_bus.arsize;
  assign clint_bus.arburst = arb_bus.arburst;
  assign clint_bus.arvalid = arb_bus.arvalid && to_clint;
  assign clint_bus.araddr  = arb_bus.araddr;
  assign clint_bus.awid    = arb_bus.awid;
  assign clint_bus.awlen   = arb_bus.awlen;
  assign clint_bus.awsize  = arb_bus.awsize;
  assign clint_bus.awburst = arb_bus.awburst;
  assign clint_bus.awvalid = arb_bus.awvalid && to_clint;
  assign clint_bus.awaddr  = arb_bus.awaddr;
  assign clint_bus.wdata   = arb_bus.wdata;
  assign clint_bus.wstrb   = arb_bus.wstrb;
  assign clint_bus.wlast   = arb_bus.wlast;
  assign clint_bus.wvalid  = arb_bus.wvalid && to_clint;
  assign clint_bus.rready  = arb_bus.rready && to_clint;
  assign clint_bus.bready  = arb_bus.bready && to_clint;

  // 被选中的目标 -> 上游 (外部目标的响应来自 ysyxSoC 的 io_master_* 输入)
  assign arb_bus.arready = to_clint ? clint_bus.arready : io_master_arready;
  assign arb_bus.awready = to_clint ? clint_bus.awready : io_master_awready;
  assign arb_bus.wready  = to_clint ? clint_bus.wready  : io_master_wready;
  assign arb_bus.rvalid  = to_clint ? clint_bus.rvalid  : io_master_rvalid;
  assign arb_bus.rdata   = to_clint ? clint_bus.rdata   : io_master_rdata;
  assign arb_bus.rresp   = to_clint ? clint_bus.rresp   : io_master_rresp;
  assign arb_bus.rlast   = to_clint ? clint_bus.rlast   : io_master_rlast;
  assign arb_bus.rid     = to_clint ? clint_bus.rid     : io_master_rid;
  assign arb_bus.bvalid  = to_clint ? clint_bus.bvalid  : io_master_bvalid;
  assign arb_bus.bresp   = to_clint ? clint_bus.bresp   : io_master_bresp;
  assign arb_bus.bid     = to_clint ? clint_bus.bid     : io_master_bid;

  // ---------------- 内部 CLINT ----------------
  axi_clint u_clint (.clk (clock), .rst (reset), .s (clint_bus), .mtip (mtip));
  // 目前还没有把 mtip / io_interrupt 接进 CSR 的中断机制 (与 B1 一致),
  // 用一根 dummy 线避免综合出同名未使用告警。
  logic unused_intr;
  assign unused_intr = mtip ^ io_interrupt;

  // ---------------- 对外 AXI4 master ----------------
  // 只有目标不在 CPU 内部 (不是 CLINT) 时, 才把请求驱动到 SoC 总线上。
  assign io_master_awvalid = arb_bus.awvalid && to_ext;
  assign io_master_awaddr  = arb_bus.awaddr;
  assign io_master_awid    = arb_bus.awid;
  assign io_master_awlen   = arb_bus.awlen;
  assign io_master_awsize  = arb_bus.awsize;
  assign io_master_awburst = arb_bus.awburst;
  assign io_master_wvalid  = arb_bus.wvalid && to_ext;
  assign io_master_wdata   = arb_bus.wdata;
  assign io_master_wstrb   = arb_bus.wstrb;
  assign io_master_wlast   = arb_bus.wlast;
  assign io_master_bready  = arb_bus.bready && to_ext;
  assign io_master_arvalid = arb_bus.arvalid && to_ext;
  assign io_master_araddr  = arb_bus.araddr;
  assign io_master_arid    = arb_bus.arid;
  assign io_master_arlen   = arb_bus.arlen;
  assign io_master_arsize  = arb_bus.arsize;
  assign io_master_arburst = arb_bus.arburst;
  assign io_master_rready  = arb_bus.rready && to_ext;

  // ---------------- 未使用的 AXI4 slave: 输出全部置 0 ----------------
`ifdef NPC_SOC_DEBUG
  logic [31:0] dbg_cyc;
  always_ff @(posedge clock) dbg_cyc <= dbg_cyc + 32'd1;
  always_ff @(posedge clock) if (dbg_cyc < 80)
    $display("[soc-dbg] cyc=%0d rst=%b arvalid=%b araddr=%h arready=%b to_ext=%b to_clint=%b rvalid=%b rdata=%h rlast=%b sel_valid=%b sel_clint=%b",
      dbg_cyc, reset, arb_bus.arvalid, arb_bus.araddr, arb_bus.arready, to_ext, to_clint,
      arb_bus.rvalid, arb_bus.rdata, arb_bus.rlast, sel_valid, sel_clint);
`endif
  assign io_slave_awready = 1'b0;
  assign io_slave_wready  = 1'b0;
  assign io_slave_bvalid  = 1'b0;
  assign io_slave_bresp   = 2'b0;
  assign io_slave_bid     = 4'b0;
  assign io_slave_arready = 1'b0;
  assign io_slave_rvalid  = 1'b0;
  assign io_slave_rresp   = 2'b0;
  assign io_slave_rdata   = 32'b0;
  assign io_slave_rlast   = 1'b0;
  assign io_slave_rid     = 4'b0;
endmodule
