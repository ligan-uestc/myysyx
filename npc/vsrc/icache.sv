// ============================================================================
// icache —— 简易指令缓存 (B4 讲义 "简易指令缓存")
//
// 结构: 直接映射 (direct-mapped)
//   tag   = addr[31 : m+n]
//   index = addr[m+n-1 : m]
//   offset= addr[m-1 : 0]
// 其中块大小 b = 2^m = BLOCK_BYTES, 块数 k = 2^n = NBLOCKS。
// 存储阵列用触发器实现 (讲义: 先不引入 SRAM, 提高灵活性), 参数可配置,
// 方便后面做块大小/容量的设计空间探索。
//
// 访存流程 (讲义里那 5 步):
//   1. IFU 发来取指请求 (req_valid/req_addr/req_ready)
//   2. 用 index 索引出 cache 块, 比较 tag 并检查 valid
//   3. 命中 -> 直接返回; 缺失 -> 通过 AXI4 从存储器读出整个块
//   4. 填入 cache 块并更新元数据
//   5. 向 IFU 返回指令 (resp_valid/resp_data)
//
// 另外实现了讲义"适合缓存的地址空间"的要求: 只有存储器类型的地址空间
// 才走 cache, 设备 (UART/CLINT 等) 一律旁路 (bypass)。
// ============================================================================
module icache #(
  parameter int  BLOCK_BYTES = 4,               // 块大小 (字节), 4 的幂
  parameter int  NBLOCKS     = 16,              // cache 块数, 2 的幂
  // 可缓存的地址区间: MROM / flash / PSRAM / SDRAM 都属于存储器类型
  parameter logic [31:0] CACHE_RANGES [0:7] = '{
    32'h2000_0000, 32'h2000_1000,   // MROM
    32'h3000_0000, 32'h4000_0000,   // flash
    32'h8000_0000, 32'hA000_0000,   // PSRAM
    32'hA000_0000, 32'hC000_0000    // SDRAM
  },
  // SRAM (0x0f00_0000) 访问延迟只有 1 周期, 按讲义不需要缓存;
  // 但复现缓存一致性实验时程序要放在可写内存里, 这时可以打开它。
  parameter bit  CACHE_SRAM  = 1'b0
) (
  input  logic        clk,
  input  logic        rst,
  // ---- IFU 侧 ----
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [31:0] req_addr,
  output logic        resp_valid,
  output logic [31:0] resp_data,
  // ---- fence.i: 冲刷整个 icache ----
  input  logic        flush,
  // ---- 性能事件 ----
  output logic        ev_hit,
  output logic        ev_miss,
  output logic        ev_bypass,
  output logic [31:0] miss_len,     // 本次缺失花费的周期数 (与 ev_miss 同拍)
  // ---- 存储器侧: AXI4 读 ----
  axi4_if.master      mem
);
  localparam int NW    = BLOCK_BYTES / 4;          // 每块的 4 字节字数
  localparam int OFFW  = $clog2(BLOCK_BYTES);      // offset 位宽
  localparam int IDXW  = $clog2(NBLOCKS);          // index 位宽
  localparam int TAGW  = 32 - OFFW - IDXW;         // tag 位宽

  logic [BLOCK_BYTES*8-1:0] data_q  [NBLOCKS];
  logic [TAGW-1:0]          tag_q   [NBLOCKS];
  logic                     valid_q [NBLOCKS];

  // ------------------------------------------------------------------
  // 地址划分
  // ------------------------------------------------------------------
  function automatic logic [IDXW-1:0] idx_of(input logic [31:0] a);
    idx_of = a[OFFW +: IDXW];
  endfunction
  function automatic logic [TAGW-1:0] tag_of(input logic [31:0] a);
    tag_of = a[31 -: TAGW];
  endfunction
  function automatic logic [31:0] blk_base(input logic [31:0] a);
    blk_base = {a[31:OFFW], {OFFW{1'b0}}};
  endfunction

  // 该地址是否属于"存储器类型"的地址空间
  function automatic logic cacheable(input logic [31:0] a);
    cacheable = 1'b0;
    for (int i = 0; i < 4; i ++)
      if (a >= CACHE_RANGES[2*i] && a < CACHE_RANGES[2*i+1]) cacheable = 1'b1;
    if (CACHE_SRAM && a >= 32'h0f00_0000 && a < 32'h0f00_2000) cacheable = 1'b1;
  endfunction

  // ------------------------------------------------------------------
  // 状态机
  // ------------------------------------------------------------------
  typedef enum logic [2:0] { C_IDLE, C_AR, C_R, C_RESP, C_BAR, C_BR } st_t;
  st_t st;

  logic [31:0] req_addr_q;        // 本事务的访存地址
  logic [31:0] fill_addr;         // 当前正在读的块内字地址
  logic [IDXW-1:0] fill_idx;      // 目标 cache 块号
  logic [TAGW-1:0] fill_tag;
  logic [4:0]  fill_cnt;          // 还要读几个字
  logic [3:0]  req_word;          // 请求的 4 字节字在块内的序号
  logic [31:0] miss_cyc;          // 本次缺失已经花掉的周期
  logic        is_miss_q;         // 本次事务是命中(0)还是缺失(1)
  logic        bypass_q;          // 本事务是否为旁路 (设备访问)
  logic [31:0] resp_data_q;

  wire hit_now  = valid_q[idx_of(req_addr)] && (tag_q[idx_of(req_addr)] == tag_of(req_addr));
  wire cachable = cacheable(req_addr);

  // 复位的初值: 所有块无效 (讲义: 复位时 cache 中无任何数据)
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < NBLOCKS; i ++) begin
        valid_q[i] <= 1'b0;
        tag_q[i]   <= '0;
        data_q[i]  <= '0;
      end
    end
    else begin
      if (st == C_R && mem.rvalid && mem.rready) begin
        // 把读回的 4 字节写进 cache 块 (offset 由 fill_cnt 决定)
        data_q[fill_idx][(NW - int'(fill_cnt)) * 32 +: 32] <= mem.rdata;
      end
      if (st == C_RESP && cacheable(req_addr_q) && !bypass_q) begin
        valid_q[fill_idx] <= 1'b1;
        tag_q[fill_idx]   <= fill_tag;
      end
      if (flush) begin                       // fence.i: 冲刷整个 icache
        for (int i = 0; i < NBLOCKS; i ++) valid_q[i] <= 1'b0;
      end
    end
  end

  // 状态迁移
  always_ff @(posedge clk) begin
    if (rst) begin
      st <= C_IDLE;
      req_addr_q <= 32'b0;
      fill_idx <= '0;
      fill_tag <= '0;
      fill_cnt <= 5'd0;
      fill_addr <= 32'b0;
      bypass_q <= 1'b0;
      is_miss_q <= 1'b0;
      miss_cyc <= 32'd0;
      resp_data_q <= 32'b0;
    end
    else begin
      case (st)
        C_IDLE: begin
          if (req_valid && req_ready) begin
            req_addr_q <= req_addr;
            if (cacheable(req_addr) && hit_now) begin
              // 命中: 当拍就返回 (组合逻辑响应), 停留在 C_IDLE。
              // 这样命中一次取指只需要 1 个周期, 不会比不加 cache 更慢。
              bypass_q    <= 1'b0;
              is_miss_q   <= 1'b0;
              miss_cyc    <= 32'd0;
            end
            else if (cacheable(req_addr)) begin
              fill_idx  <= idx_of(req_addr);
              fill_tag  <= tag_of(req_addr);
              fill_cnt  <= NW[4:0];
              fill_addr <= blk_base(req_addr);
              bypass_q  <= 1'b0;
              is_miss_q <= 1'b1;
              miss_cyc  <= 32'd0;
              req_word  <= req_addr[OFFW-1:0] >> 2;
              st        <= C_AR;
            end
            else begin
              bypass_q  <= 1'b1;
              is_miss_q <= 1'b0;
              miss_cyc  <= 32'd0;
              fill_addr <= req_addr;
              st        <= C_BAR;
            end
          end
        end
        C_AR: begin
          miss_cyc <= miss_cyc + 32'd1;
          if (mem.arvalid && mem.arready) st <= C_R;
        end
        C_R: begin
          miss_cyc <= miss_cyc + 32'd1;
          if (mem.rvalid && mem.rready) begin
            if (fill_cnt == 5'd1) begin
              // 读完整个块: 取出请求真正要的那个 4 字节字
              // (块大小 >4 字节时, 请求的字不一定是块内最后一个字)
              resp_data_q <= (int'(req_word) == NW - 1)
                             ? mem.rdata
                             : data_q[fill_idx][int'(req_word) * 32 +: 32];
              st          <= C_RESP;
            end
            else begin
              fill_cnt  <= fill_cnt - 5'd1;
              fill_addr <= fill_addr + 32'd4;
              st        <= C_AR;
            end
          end
        end
        C_RESP: st <= C_IDLE;
        C_BAR: if (mem.arvalid && mem.arready) st <= C_BR;
        C_BR:  if (mem.rvalid && mem.rready) begin
                 resp_data_q <= mem.rdata;
                 st          <= C_RESP;
               end
        default: st <= C_IDLE;
      endcase
    end
  end

  assign req_ready  = (st == C_IDLE) && !rst;
  // 命中走组合逻辑 (当拍返回), 缺失/旁路走状态机 (C_RESP)
  wire hit_comb = (st == C_IDLE) && req_valid && req_ready
                  && cacheable(req_addr) && hit_now;
  assign resp_valid = ((st == C_RESP) || hit_comb) && !rst;
  assign resp_data  = (st == C_RESP) ? resp_data_q
                     : data_q[idx_of(req_addr)][req_addr[OFFW-1:0] * 8 +: 32];

  // ------------------------------------------------------------------
  // 性能事件
  // ------------------------------------------------------------------
  assign ev_hit    = hit_comb || ((st == C_RESP) && !bypass_q && !is_miss_q);
  assign ev_miss   = (st == C_RESP) && !bypass_q &&  is_miss_q;
  assign ev_bypass = (st == C_RESP) && bypass_q;
  assign miss_len  = miss_cyc;

  // ------------------------------------------------------------------
  // 存储器侧 AXI4: 只读, 单拍传输
  // ------------------------------------------------------------------
  assign mem.arid    = 4'd0;
  assign mem.arlen   = 8'd0;
  assign mem.arsize  = 3'd2;        // 4 字节
  assign mem.arburst = 2'b01;       // INCR
  assign mem.arvalid = (st == C_AR || st == C_BAR) && !rst;
  assign mem.araddr  = (st == C_BAR) ? req_addr_q : fill_addr;
  assign mem.rready  = (st == C_R || st == C_BR) && !rst;

  assign mem.awid    = 4'd0;
  assign mem.awlen   = 8'd0;
  assign mem.awsize  = 3'd2;
  assign mem.awburst = 2'b01;
  assign mem.awvalid = 1'b0;
  assign mem.awaddr  = 32'b0;
  assign mem.wvalid  = 1'b0;
  assign mem.wdata   = 32'b0;
  assign mem.wstrb   = 4'b0;
  assign mem.wlast   = 1'b1;
  assign mem.bready  = 1'b0;
endmodule
