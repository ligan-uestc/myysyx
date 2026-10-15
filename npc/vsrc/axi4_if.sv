// 完整 AXI4 接口 (B2 SoC 讲义)
//
// 与 B1 的 axi4lite_if 相比, 补上了 AXI4 相对于 AXI4-Lite 多出来的信号:
//   * id     : AWID/BID/ARID/RID, 用于区分不同的事务;
//   * len    : AWLEN/ARLEN, 突发传输的拍数 (本设计只用单拍, 恒为 0);
//   * size   : AWSIZE/ARSIZE, 本次传输的实际数据位宽 (lb=0, lh=1, lw=2);
//   * burst  : AWBURST/ARBURST, 突发类型 (本设计恒为 INCR);
//   * last   : WLAST/RLAST, 表示突发的最后一拍 (单拍传输恒为 1)。
//
// 讲义"接入ysyxSoC"要求把 AXI4-Lite 扩展为完整 AXI4, 原因见讲义:
// 设备寄存器可能只有 1 字节间隔, AXI4-Lite 无法告诉设备"软件只想读 1 字节",
// 于是会读到相邻寄存器并改变设备状态; 有了 arsize, 设备就能只访问目标寄存器。
interface axi4_if;
  // ---- 写地址通道 AW ----
  logic [3:0]  awid;
  logic [31:0] awaddr;
  logic [7:0]  awlen;
  logic [2:0]  awsize;
  logic [1:0]  awburst;
  logic        awvalid;
  logic        awready;
  // ---- 写数据通道 W ----
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wlast;
  logic        wvalid;
  logic        wready;
  // ---- 写响应通道 B ----
  logic [3:0]  bid;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  // ---- 读地址通道 AR ----
  logic [3:0]  arid;
  logic [31:0] araddr;
  logic [7:0]  arlen;
  logic [2:0]  arsize;
  logic [1:0]  arburst;
  logic        arvalid;
  logic        arready;
  // ---- 读数据通道 R ----
  logic [3:0]  rid;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rlast;
  logic        rvalid;
  logic        rready;

  modport master (
    output awid, awaddr, awlen, awsize, awburst, awvalid,
           wdata, wstrb, wlast, wvalid, bready,
           arid, araddr, arlen, arsize, arburst, arvalid, rready,
    input  awready, wready, bid, bresp, bvalid,
           arready, rid, rdata, rresp, rlast, rvalid
  );

  modport slave (
    input  awid, awaddr, awlen, awsize, awburst, awvalid,
           wdata, wstrb, wlast, wvalid, bready,
           arid, araddr, arlen, arsize, arburst, arvalid, rready,
    output awready, wready, bid, bresp, bvalid,
           arready, rid, rdata, rresp, rlast, rvalid
  );
endinterface
