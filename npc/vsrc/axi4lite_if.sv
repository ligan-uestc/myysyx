// AXI4-Lite 接口 (B1 总线讲义)
//
// 【已被 B2 取代】进入 SoC 阶段后, 讲义要求把 AXI4-Lite 扩展为完整 AXI4
// (增加 id/len/size/burst/last), 新的接口定义在 vsrc/axi4_if.sv。
// 本文件只作为 B1 阶段的历史记录保留, 不再被任何模块实例化。
//
// 5 个独立的通道, 每个通道都用 valid/ready 握手:
//   读地址 AR    : araddr  / arvalid / arready
//   读数据 R     : rdata / rresp / rvalid / rready
//   写地址 AW    : awaddr / awvalid / awready
//   写数据 W     : wdata / wstrb / wvalid / wready
//   写响应 B     : bresp / bvalid / bready
//
// AXI 的约束 (讲义"避免握手的死锁和活锁"要求 RTFM 后遵守):
//   * valid 一旦置 1, 必须保持到 ready 置 1 完成握手 (valid 不能等 ready);
//   * valid 置 1 后不允许撤销, 也不允许在握手前改变 payload;
//   * ready 可以不等 valid (slave 可以提前 ready, 也可以后置 ready)。
interface axi4lite_if;
  logic [31:0] araddr;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;
  logic [31:0] awaddr;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;

  modport master (
    output araddr, arvalid, rready, awaddr, awvalid, wdata, wstrb, wvalid, bready,
    input  arready, rdata, rresp, rvalid, awready, wready, bresp, bvalid
  );

  modport slave (
    input  araddr, arvalid, rready, awaddr, awvalid, wdata, wstrb, wvalid, bready,
    output arready, rdata, rresp, rvalid, awready, wready, bresp, bvalid
  );
endinterface
