// AXI4-Lite 交叉开关 (Xbar): 把上游的一个 slave 端口按地址译码到三个从设备
// (存储器 / CLINT / UART)。
//
// 由于仲裁器保证同一时刻只有一个上游 master 在通信, 这里只需要实现
// "按地址选择下游端口"的逻辑:
//   * 空闲时用组合逻辑译码出目标端口, 并在第一次握手时锁定;
//   * 事务结束 (最后一拍 R 或 B) 后解锁;
//   * 未选中的下游端口 valid/ready 全部置 0。
module axi_xbar (
  input  logic        clk,
  input  logic        rst,
  axi4lite_if.slave   s,        // 上游 (来自仲裁器)
  axi4lite_if.master  m_mem,    // 0x8000_0000 ~ 0x8fff_ffff : 存储器
  axi4lite_if.master  m_clint,  // 0x0200_0000 ~ 0x0200_ffff : CLINT
  axi4lite_if.master  m_uart,   // 其它 (0xa000_0000...)      : UART
  output logic [1:0]  state_dbg
);
  typedef enum logic [1:0] { X_IDLE, X_MEM, X_CLINT, X_UART } xstate_t;
  xstate_t st;
  assign state_dbg = st;

  function automatic xstate_t decode(input logic [31:0] addr);
    if (addr >= 32'h8000_0000 && addr < 32'h9000_0000) return X_MEM;
    if (addr >= 32'h0200_0000 && addr < 32'h0201_0000) return X_CLINT;
    return X_UART;
  endfunction

  // 空闲时组合译码; 锁定时保持
  wire        use_ar = s.arvalid && !s.awvalid;
  wire [31:0] req_addr = use_ar ? s.araddr : s.awaddr;
  wire [1:0]  sel = (st == X_IDLE) ? decode(req_addr) : st;   // 连续赋值

  wire start = (st == X_IDLE) && ((s.arvalid && s.arready) || (s.awvalid && s.awready));
  wire done  = (s.rvalid && s.rready) || (s.bvalid && s.bready);

  always_ff @(posedge clk) begin
    if (rst) st <= X_IDLE;
    else if (st == X_IDLE) begin
      if (start) st <= decode(req_addr);
    end
    else if (done) st <= X_IDLE;
  end

  // ---------------- 上游 <- 被选中的下游 ----------------
  assign s.arready = (sel == X_MEM) ? m_mem.arready : (sel == X_CLINT) ? m_clint.arready : m_uart.arready;
  assign s.awready = (sel == X_MEM) ? m_mem.awready : (sel == X_CLINT) ? m_clint.awready : m_uart.awready;
  assign s.wready  = (sel == X_MEM) ? m_mem.wready  : (sel == X_CLINT) ? m_clint.wready  : m_uart.wready;
  assign s.rvalid  = (sel == X_MEM) ? m_mem.rvalid  : (sel == X_CLINT) ? m_clint.rvalid  : m_uart.rvalid;
  assign s.bvalid  = (sel == X_MEM) ? m_mem.bvalid  : (sel == X_CLINT) ? m_clint.bvalid  : m_uart.bvalid;
  assign s.rdata   = (sel == X_MEM) ? m_mem.rdata   : (sel == X_CLINT) ? m_clint.rdata   : m_uart.rdata;
  assign s.rresp   = (sel == X_MEM) ? m_mem.rresp   : (sel == X_CLINT) ? m_clint.rresp   : m_uart.rresp;
  assign s.bresp   = (sel == X_MEM) ? m_mem.bresp   : (sel == X_CLINT) ? m_clint.bresp   : m_uart.bresp;

  // ---------------- 上游 -> 被选中的下游 ----------------
  assign m_mem.arvalid   = (sel == X_MEM)   ? s.arvalid : 1'b0;
  assign m_mem.awvalid   = (sel == X_MEM)   ? s.awvalid : 1'b0;
  assign m_mem.wvalid    = (sel == X_MEM)   ? s.wvalid  : 1'b0;
  assign m_mem.rready    = (sel == X_MEM)   ? s.rready  : 1'b0;
  assign m_mem.bready    = (sel == X_MEM)   ? s.bready  : 1'b0;

  assign m_clint.arvalid = (sel == X_CLINT) ? s.arvalid : 1'b0;
  assign m_clint.awvalid = (sel == X_CLINT) ? s.awvalid : 1'b0;
  assign m_clint.wvalid  = (sel == X_CLINT) ? s.wvalid  : 1'b0;
  assign m_clint.rready  = (sel == X_CLINT) ? s.rready  : 1'b0;
  assign m_clint.bready  = (sel == X_CLINT) ? s.bready  : 1'b0;

  assign m_uart.arvalid  = (sel == X_UART)  ? s.arvalid : 1'b0;
  assign m_uart.awvalid  = (sel == X_UART)  ? s.awvalid : 1'b0;
  assign m_uart.wvalid   = (sel == X_UART)  ? s.wvalid  : 1'b0;
  assign m_uart.rready   = (sel == X_UART)  ? s.rready  : 1'b0;
  assign m_uart.bready   = (sel == X_UART)  ? s.bready  : 1'b0;

  // 地址/数据广播 (只有被选中的端口会使用)
  assign m_mem.araddr = s.araddr;   assign m_clint.araddr = s.araddr;   assign m_uart.araddr = s.araddr;
  assign m_mem.awaddr = s.awaddr;   assign m_clint.awaddr = s.awaddr;   assign m_uart.awaddr = s.awaddr;
  assign m_mem.wdata  = s.wdata;    assign m_clint.wdata  = s.wdata;    assign m_uart.wdata  = s.wdata;
  assign m_mem.wstrb  = s.wstrb;    assign m_clint.wstrb  = s.wstrb;    assign m_uart.wstrb  = s.wstrb;
endmodule
