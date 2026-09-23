// ============================================================================
// NPC 顶层 (B1 总线讲义)
//
//            +---------+   AXI4-Lite   +----------+            +----------+
//            |  NPC    |-------------->|  仲裁器  |----------->|   Xbar   |
//            | (多周期)|  IFU / LSU    | (2 -> 1) |            | (1 -> 3) |
//            +---------+               +----------+            +----+-----+
//                                                            /      |      \
//                                                    +------+   +--------+  +--------+
//                                                    | 存储器|   | CLINT  |  |  UART  |
//                                                    +------+   +--------+  +--------+
//
// 参数 RAND_DELAY 打开后, 存储器会用 LFSR 产生 0~7 周期的随机延迟, 用来
// 验证 master 端的握手实现是否与延迟无关 (讲义"测试SimpleBus的实现")。
// ============================================================================
module top #(
  parameter bit RAND_DELAY = 1'b0
) (
  input  logic clk,
  input  logic rst,
  // ---- 调试/仿真端口 ----
  output logic [31:0] pc,
  output logic [31:0] inst,
  output logic [512-1:0] gpr_dbg,
  output logic        inst_done,
  output logic        mem_valid,
  output logic        mem_we,
  output logic [1:0]  mem_size,
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata,
  // ---- (调试用) ----
  output logic [2:0]  dbg_state,
  output logic [1:0]  dbg_arb_state, dbg_xbar_state, dbg_mem_rstate, dbg_mem_wstate,
  output logic        dbg_arvalid, dbg_arready, dbg_rvalid, dbg_rready,
  output logic [31:0] dbg_araddr, dbg_rdata
);
  axi4lite_if ifu_bus (), lsu_bus (), arb_out (), mem_bus (), clint_bus (), uart_bus ();
  logic        mtip_unused;

  npc_core u_core (
    .clk (clk), .rst (rst),
    .pc (pc), .inst (inst), .gpr_dbg (gpr_dbg), .inst_done (inst_done),
    .mem_valid (mem_valid), .mem_we (mem_we), .mem_size (mem_size),
    .mem_addr (mem_addr), .mem_wdata (mem_wdata), .mem_rdata (mem_rdata),
    .ifu_axi (ifu_bus), .lsu_axi (lsu_bus),
    .state_dbg (dbg_state)
  );

  // IFU + LSU -> 仲裁器
  axi_arbiter u_arb (
    .clk (clk), .rst (rst),
    .m0 (ifu_bus), .m1 (lsu_bus), .s (arb_out),
    .state_dbg (dbg_arb_state)
  );

  // 仲裁器 -> 地址译码 (Xbar)
  axi_xbar u_xbar (
    .clk (clk), .rst (rst),
    .s (arb_out),
    .m_mem (mem_bus), .m_clint (clint_bus), .m_uart (uart_bus),
    .state_dbg (dbg_xbar_state)
  );

  axi_mem #(.RAND_DELAY(RAND_DELAY)) u_mem (.clk (clk), .rst (rst), .s (mem_bus),
    .rstate_dbg (dbg_mem_rstate), .wstate_dbg (dbg_mem_wstate));
  axi_clint u_clint (.clk (clk), .rst (rst), .s (clint_bus), .mtip (mtip_unused));
  axi_uart  u_uart  (.clk (clk), .rst (rst), .s (uart_bus));

  assign dbg_arvalid = ifu_bus.arvalid;
  assign dbg_arready = ifu_bus.arready;
  assign dbg_rvalid  = ifu_bus.rvalid;
  assign dbg_rready  = ifu_bus.rready;
  assign dbg_araddr  = ifu_bus.araddr;
  assign dbg_rdata   = ifu_bus.rdata;

  // IFU 只读: 它的写通道必须一直为 0 (讲义建议用 assert 检查)
  always_comb begin
    if (!rst) begin
      assert (!ifu_bus.awvalid && !ifu_bus.wvalid && !ifu_bus.bready);
    end
  end
endmodule
