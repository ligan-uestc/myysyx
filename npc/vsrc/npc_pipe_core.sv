// ============================================================================
// npc_pipe_core —— 五级流水线处理器 (B5 流水线讲义)
//
//   IF  ->  ID  ->  EX  ->  MEM(LS)  ->  WB
//
// 各种冒险的处理方式 (讲义 "用最简单的方式处理各种冒险"):
//   * 结构冒险: IF 走 icache 的 AXI 通道, MEM 走 LSU 的 AXI 通道, 两者由
//     总线仲裁器分开; 但 MEM 阶段独占 LSU, 访存期间需要冻结前面的流水段;
//   * 数据冒险: 转发 (EX/MEM -> ID, MEM/WB -> ID), 选择最年轻的转发源;
//     load-use 冒险因为 load 会阻塞访存而自然被覆盖, 只需检测 EX 段的 load;
//   * 控制冒险: "总是推测执行下一条静态指令" (预测不跳转), 在 EX 段得到真实
//     的跳转结果后检查, 不一致就冲刷 IF/ID 与 ID/EX;
//   * 异常: ecall / mret 在 EX 段处理, 更新 CSR 并冲刷流水线 (精确异常:
//     指令的 PC 随流水线一起传递, 因此 mepc 是精确的);
//   * fence.i: 冲刷流水线 + 冲刷 icache, 保证之后的取指看到新的指令。
//
// 与 npc_core (多周期) 的接口完全一致, 便于在两者之间切换。
// ============================================================================
`include "alu_ops.svh"

`ifndef NPC_ICACHE_BLOCK
`define NPC_ICACHE_BLOCK 4
`endif
`ifndef NPC_ICACHE_BLOCKS
`define NPC_ICACHE_BLOCKS 16
`endif
`ifndef NPC_ICACHE_SRAM
`define NPC_ICACHE_SRAM 0
`endif

module npc_pipe_core #(
  parameter logic [31:0] PC_INIT = 32'h8000_0000,
  parameter int  ICACHE_BLOCK  = `NPC_ICACHE_BLOCK,
  parameter int  ICACHE_BLOCKS = `NPC_ICACHE_BLOCKS,
  parameter bit  ICACHE_SRAM   = `NPC_ICACHE_SRAM
) (
  input  logic clk,
  input  logic rst,
  // ---- 调试/仿真端口 (与 npc_core 相同) ----
  output logic [31:0] pc,
  output logic [31:0] inst,
  output logic [31:0] next_pc,
  output logic [512-1:0] gpr_dbg,
  output logic        inst_done,
  output logic        mem_valid,
  output logic        mem_we,
  output logic [1:0]  mem_size,
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata,
  // ---- AXI4 master ----
  axi4_if.master      ifu_mem,
  axi4_if.master      lsu_axi,
  output logic [2:0]  state_dbg
);
  import "DPI-C" function void ebreak(input int code);
  import "DPI-C" function void npc_retire(
    input int pc, input int inst,
    input int x1,  input int x2,  input int x3,  input int x4,
    input int x5,  input int x6,  input int x7,  input int x8,
    input int x9,  input int x10, input int x11, input int x12,
    input int x13, input int x14, input int x15,
    input int next_pc,
    input int mem_valid, input int mem_we,
    input int mem_addr, input int mem_data, input int mem_size);

  // ------------------------------------------------------------------
  // 流水段寄存器
  // ------------------------------------------------------------------
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] inst;
  } ifid_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] inst;
    logic [31:0] rs1_v, rs2_v, imm;
    logic [3:0]  rs1, rs2, rd;
    logic [2:0]  funct3;
    logic        rf_we;
    logic [1:0]  wb_sel;
    logic [3:0]  alu_op;
    logic [1:0]  alu_a_sel, alu_b_sel;
    logic        mem_read, mem_write;
    logic [1:0]  mem_size;
    logic [2:0]  dnpc;
    logic        csr_we;
    logic [11:0] csr_waddr;
    logic [1:0]  csr_op;
    logic [31:0] csr_rdata;
    logic        is_csr;
    logic        is_fence_i;
  } idex_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] inst;
    logic [31:0] alu;
    logic [31:0] stdata;
    logic [31:0] next_pc;
    logic [3:0]  rd;
    logic        rf_we;
    logic [1:0]  wb_sel;
    logic        mem_read, mem_write;
    logic [1:0]  mem_size;
    logic        csr_we;
    logic [11:0] csr_waddr;
    logic        is_fence_i;
  } exmem_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] inst;
    logic [31:0] result;
    logic [31:0] next_pc;
    logic [3:0]  rd;
    logic        rf_we;
    logic        mem_valid, mem_we;
    logic [31:0] mem_addr, mem_data;
    logic [1:0]  mem_size;
  } memwb_t;

  ifid_t  ifid;
  idex_t  idex;
  exmem_t exmem;
  memwb_t memwb;

  // ------------------------------------------------------------------
  // 寄存器堆 / ALU
  // ------------------------------------------------------------------
  logic [31:0] rf_rdata1, rf_rdata2, gpr_a0;
  logic        rf_we_wb;
  logic [3:0]  rf_wa_wb;
  logic [31:0] rf_wd_wb;

  regfile #(.ADDR_WIDTH(4), .DATA_WIDTH(32)) u_rf (
    .clk (clk), .rst (rst),
    .wen (rf_we_wb), .waddr (rf_wa_wb), .wdata (rf_wd_wb),
    .raddr1 (ifid.inst[18:15]), .rdata1 (rf_rdata1),
    .raddr2 (ifid.inst[23:20]), .rdata2 (rf_rdata2),
    .raddr3 (4'd10), .rdata3 (gpr_a0),
    .dbg (gpr_dbg)
  );

  logic [31:0] alu_a, alu_b, alu_y;
  logic [3:0]  alu_op;
  alu u_alu (.a (alu_a), .b (alu_b), .op (alu_op), .y (alu_y));

  // ------------------------------------------------------------------
  // CSR
  // ------------------------------------------------------------------
  localparam logic [31:0] MSTATUS_MIE  = 32'h0000_0008;
  localparam logic [31:0] MSTATUS_MPIE = 32'h0000_0080;
  localparam logic [11:0] CSR_MSTATUS = 12'h300, CSR_MTVEC = 12'h305,
                          CSR_MEPC = 12'h341, CSR_MCAUSE = 12'h342,
                          CSR_MCYCLE = 12'hB00, CSR_MCYCLEH = 12'hB80,
                          CSR_MVENDORID = 12'hF11, CSR_MARCHID = 12'hF12;
  localparam logic [31:0] MVENDORID_VALUE = 32'h7973_7978;   // "ysyx"
  localparam logic [31:0] MARCHID_VALUE   = 32'h0150_4dc0;   // ysyx_22040000

  logic [31:0] csr_mstatus, csr_mtvec, csr_mepc, csr_mcause;
  logic [63:0] csr_mcycle;

  always_ff @(posedge clk) begin
    if (rst) csr_mcycle <= 64'd0;
    else     csr_mcycle <= csr_mcycle + 64'd1;
  end

  // ------------------------------------------------------------------
  // IF 段
  // ------------------------------------------------------------------
  logic [31:0] pc_q, pc_next_q;
  logic        ifu_req_valid, ifu_req_ready, ifu_resp_valid, ifu_resp_ready;
  logic [31:0] ifu_req_addr, ifu_resp_data;
  logic        icache_flush;
  logic        ic_hit, ic_miss, ic_bypass;
  logic [31:0] ic_miss_len;
  logic        if_waiting;      // 取指请求已发出, 正在等待回复
  logic        if_drain;        // 重定向后需要丢弃一个在途的取指回复

  icache #(
    .BLOCK_BYTES (ICACHE_BLOCK),
    .NBLOCKS     (ICACHE_BLOCKS),
    .CACHE_SRAM  (ICACHE_SRAM)
  ) u_icache (
    .clk (clk), .rst (rst),
    .req_valid (ifu_req_valid), .req_ready (ifu_req_ready), .req_addr (ifu_req_addr),
    .resp_valid (ifu_resp_valid), .resp_data (ifu_resp_data), .resp_ready (ifu_resp_ready),
    .flush (icache_flush),
    .ev_hit (ic_hit), .ev_miss (ic_miss), .ev_bypass (ic_bypass), .miss_len (ic_miss_len),
    .mem (ifu_mem)
  );

  // ------------------------------------------------------------------
  // ID 段: 译码
  // ------------------------------------------------------------------
  wire [6:0] id_opcode = ifid.inst[6:0];
  wire [3:0] id_rd     = ifid.inst[10:7];
  wire [2:0] id_funct3 = ifid.inst[14:12];
  wire [3:0] id_rs1    = ifid.inst[18:15];
  wire [3:0] id_rs2    = ifid.inst[23:20];

  wire [31:0] id_imm_i = {{20{ifid.inst[31]}}, ifid.inst[31:20]};
  wire [31:0] id_imm_s = {{20{ifid.inst[31]}}, ifid.inst[31:25], ifid.inst[11:7]};
  wire [31:0] id_imm_b = {{19{ifid.inst[31]}}, ifid.inst[31], ifid.inst[7],
                          ifid.inst[30:25], ifid.inst[11:8], 1'b0};
  wire [31:0] id_imm_u = {ifid.inst[31:12], 12'b0};
  wire [31:0] id_imm_j = {{11{ifid.inst[31]}}, ifid.inst[31], ifid.inst[19:12],
                          ifid.inst[20], ifid.inst[30:21], 1'b0};

  logic [31:0] id_imm;
  logic        id_rf_we, id_mem_read, id_mem_write;
  logic [1:0]  id_wb_sel, id_mem_size, id_alu_a_sel, id_alu_b_sel, id_csr_op;
  logic [3:0]  id_alu_op;
  logic [2:0]  id_dnpc;
  logic        id_csr_we, id_is_csr, id_is_fence_i, id_invalid;
  logic [11:0] id_csr_waddr;

  localparam logic [1:0] WB_ALU = 2'd0, WB_MEM = 2'd1, WB_PC4 = 2'd2, WB_CSR = 2'd3;
  localparam logic [2:0] DNPC_PC4 = 3'd0, DNPC_JAL = 3'd1, DNPC_JALR = 3'd2,
                         DNPC_BRANCH = 3'd3, DNPC_TRAP = 3'd4, DNPC_MRET = 3'd5;
  localparam logic [1:0] A_RS1 = 2'd0, A_PC = 2'd1, A_ZERO = 2'd2;
  localparam logic [1:0] B_RS2 = 2'd0, B_IMM = 2'd1;

  always_comb begin
    id_rf_we = 1'b0; id_wb_sel = WB_ALU; id_alu_op = `ALU_ADD;
    id_alu_a_sel = A_RS1; id_alu_b_sel = B_IMM;
    id_mem_read = 1'b0; id_mem_write = 1'b0; id_mem_size = 2'd2;
    id_dnpc = DNPC_PC4; id_imm = id_imm_i;
    id_csr_we = 1'b0; id_csr_op = 2'd0; id_csr_waddr = ifid.inst[31:20];
    id_is_csr = 1'b0; id_is_fence_i = 1'b0; id_invalid = 1'b0;

    case (id_opcode)
      7'b0110111: begin id_rf_we = 1'b1; id_alu_a_sel = A_ZERO; id_alu_b_sel = B_IMM; id_imm = id_imm_u; end
      7'b0010111: begin id_rf_we = 1'b1; id_alu_a_sel = A_PC;   id_alu_b_sel = B_IMM; id_imm = id_imm_u; end
      7'b1101111: begin id_rf_we = 1'b1; id_wb_sel = WB_PC4; id_dnpc = DNPC_JAL;
                        id_alu_a_sel = A_PC; id_alu_b_sel = B_IMM; id_imm = id_imm_j; end
      7'b1100111: begin id_rf_we = 1'b1; id_wb_sel = WB_PC4; id_dnpc = DNPC_JALR;
                        id_alu_a_sel = A_RS1; id_alu_b_sel = B_IMM; id_imm = id_imm_i;
                        if (id_funct3 != 3'b000) id_invalid = 1'b1; end
      7'b1100011: begin id_alu_a_sel = A_RS1; id_alu_b_sel = B_RS2;
                        id_dnpc = DNPC_BRANCH; id_imm = id_imm_b;
                        if (id_funct3 == 3'b010 || id_funct3 == 3'b011) id_invalid = 1'b1; end
      7'b0000011: begin id_rf_we = 1'b1; id_mem_read = 1'b1; id_wb_sel = WB_MEM;
                        id_alu_a_sel = A_RS1; id_alu_b_sel = B_IMM; id_imm = id_imm_i;
                        case (id_funct3)
                          3'b000, 3'b100: id_mem_size = 2'd0;
                          3'b001, 3'b101: id_mem_size = 2'd1;
                          3'b010:         id_mem_size = 2'd2;
                          default:        id_invalid = 1'b1;
                        endcase end
      7'b0100011: begin id_mem_write = 1'b1; id_alu_a_sel = A_RS1; id_alu_b_sel = B_IMM;
                        id_imm = id_imm_s;
                        case (id_funct3)
                          3'b000: id_mem_size = 2'd0;
                          3'b001: id_mem_size = 2'd1;
                          3'b010: id_mem_size = 2'd2;
                          default: id_invalid = 1'b1;
                        endcase end
      7'b0010011: begin id_rf_we = 1'b1; id_alu_a_sel = A_RS1; id_alu_b_sel = B_IMM;
                        id_imm = id_imm_i;
                        case (id_funct3)
                          3'b000: id_alu_op = `ALU_ADD;
                          3'b010: id_alu_op = `ALU_SLT;
                          3'b011: id_alu_op = `ALU_SLTU;
                          3'b100: id_alu_op = `ALU_XOR;
                          3'b110: id_alu_op = `ALU_OR;
                          3'b111: id_alu_op = `ALU_AND;
                          3'b001: begin id_alu_op = `ALU_SLL; id_imm = {27'b0, ifid.inst[24:20]}; end
                          3'b101: begin id_imm = {27'b0, ifid.inst[24:20]};
                                        id_alu_op = ifid.inst[30] ? `ALU_SRA : `ALU_SRL; end
                          default: id_invalid = 1'b1;
                        endcase end
      7'b0110011: begin id_rf_we = 1'b1; id_alu_a_sel = A_RS1; id_alu_b_sel = B_RS2;
                        case (id_funct3)
                          3'b000: id_alu_op = ifid.inst[30] ? `ALU_SUB : `ALU_ADD;
                          3'b001: id_alu_op = `ALU_SLL;
                          3'b010: id_alu_op = `ALU_SLT;
                          3'b011: id_alu_op = `ALU_SLTU;
                          3'b100: id_alu_op = `ALU_XOR;
                          3'b101: id_alu_op = ifid.inst[30] ? `ALU_SRA : `ALU_SRL;
                          3'b110: id_alu_op = `ALU_OR;
                          3'b111: id_alu_op = `ALU_AND;
                          default: id_invalid = 1'b1;
                        endcase end
      7'b0001111: begin
                        // fence.i = 0001111 + funct3=001
                        if (id_funct3 == 3'b001) id_is_fence_i = 1'b1;
                        else if (id_funct3 != 3'b000) id_invalid = 1'b1;
                      end
      7'b1110011: begin
                        if (id_funct3 == 3'b000) begin
                          if (ifid.inst != 32'h0010_0073 &&      // ebreak
                              ifid.inst != 32'h0000_0073 &&      // ecall
                              ifid.inst != 32'h3020_0073)        // mret
                            id_invalid = 1'b1;
                          if (ifid.inst == 32'h0000_0073) id_dnpc = DNPC_TRAP;
                          if (ifid.inst == 32'h3020_0073) id_dnpc = DNPC_MRET;
                        end
                        else begin
                          id_is_csr = 1'b1;
                          id_rf_we  = 1'b1; id_wb_sel = WB_CSR;
                          id_csr_waddr = ifid.inst[31:20];
                          id_csr_op = id_funct3[1:0];
                          id_csr_we = (id_funct3 == 3'b001) || (id_funct3 == 3'b101)
                                   || (id_rs1 != 4'd0 && id_funct3 != 3'b001 && id_funct3 != 3'b101);
                        end
                      end
      default: id_invalid = 1'b1;
    endcase
  end

  // CSR 读 (组合)
  logic [31:0] id_csr_rdata;
  always_comb begin
    case (id_csr_waddr)
      CSR_MSTATUS:   id_csr_rdata = csr_mstatus;
      CSR_MTVEC:     id_csr_rdata = csr_mtvec;
      CSR_MEPC:      id_csr_rdata = csr_mepc;
      CSR_MCAUSE:    id_csr_rdata = csr_mcause;
      CSR_MCYCLE:    id_csr_rdata = csr_mcycle[31:0];
      CSR_MCYCLEH:   id_csr_rdata = csr_mcycle[63:32];
      CSR_MVENDORID: id_csr_rdata = MVENDORID_VALUE;
      CSR_MARCHID:   id_csr_rdata = MARCHID_VALUE;
      default:       id_csr_rdata = 32'h0;
    endcase
  end

  // ---- 数据冒险: 转发到 ID (讲义推荐的方案) ----
  // 转发源 1: EX/MEM。计算类指令的结果在 EX 就算好了; load 的数据要在总线的
  // R 通道握手的那一拍才拿到, 因此只有在 ld_done 的当拍才能转发。
  logic [31:0] exmem_fwd_data;
  always_comb begin
    if (exmem.mem_read) exmem_fwd_data = ld_ext;   // load: 数据当拍从总线返回
    else                exmem_fwd_data = exmem.alu;
  end
  wire exmem_fwd_ok = exmem.valid && exmem.rf_we && (!exmem.mem_read || ld_done);
  wire exmem_hit1   = exmem_fwd_ok && (exmem.rd != 4'd0) && (exmem.rd == id_rs1);
  wire exmem_hit2   = exmem_fwd_ok && (exmem.rd != 4'd0) && (exmem.rd == id_rs2);
  // 转发源 2: MEM/WB (最终结果, load 的数据此时已经回来)
  wire memwb_fwd_ok = memwb.valid && memwb.rf_we;
  wire memwb_hit1   = memwb_fwd_ok && (memwb.rd != 4'd0) && (memwb.rd == id_rs1);
  wire memwb_hit2   = memwb_fwd_ok && (memwb.rd != 4'd0) && (memwb.rd == id_rs2);

  wire [31:0] id_rs1_v = exmem_hit1 ? exmem_fwd_data : memwb_hit1 ? memwb.result : rf_rdata1;
  wire [31:0] id_rs2_v = exmem_hit2 ? exmem_fwd_data : memwb_hit2 ? memwb.result : rf_rdata2;

  // ------------------------------------------------------------------
  // EX 段
  // ------------------------------------------------------------------
  assign alu_op = idex.alu_op;
  always_comb begin
    alu_a = (idex.alu_a_sel == A_PC)   ? idex.pc
          : (idex.alu_a_sel == A_ZERO) ? 32'b0 : idex.rs1_v;
    alu_b = (idex.alu_b_sel == B_RS2)  ? idex.rs2_v : idex.imm;
  end

  logic branch_taken;
`ifdef NPC_PIPE_DEBUG
  always_ff @(posedge clk) begin
    if (!rst && ((ifid.valid && ifid.pc == 32'h80000204) || (idex.valid && idex.pc == 32'h80000204) ||
                 (exmem.valid && exmem.pc == 32'h80000204) || (memwb.valid && memwb.pc == 32'h80000204)))
      $display("[pipe-walk] cyc=%0d pcq=%h ifid=%b idex=%b exmem=%b memwb=%b flush=%b stall_all=%b stall_front=%b rm=%b",
        dbg_cyc, pc_q, ifid.valid && ifid.pc == 32'h80000204, idex.valid && idex.pc == 32'h80000204,
        exmem.valid && exmem.pc == 32'h80000204, memwb.valid && memwb.pc == 32'h80000204,
        flush, stall_all, stall_front, raw_stall);
  end
  always_ff @(posedge clk) if (!rst && exmem.valid && exmem.pc == 32'h80000204)
    $display("[pipe-exmem] pc=%h inst=%h rf_we=%b stall=%b flush=%b", exmem.pc, exmem.inst, exmem.rf_we, stall_all, flush);
  always_ff @(posedge clk) if (!rst && memwb.valid && memwb.pc == 32'h80000204)
    $display("[pipe-memwb] pc=%h inst=%h wb_retire=%b stall_all=%b lsu_st=%b mem_op=%b", memwb.pc, memwb.inst, wb_retire, stall_all, lsu_st, mem_op);
  always_ff @(posedge clk) if (wb_retire)
    $display("[pipe-ret] pc=%h inst=%h next=%h s0=%h", memwb.pc, memwb.inst, memwb.next_pc, gpr_dbg[8*32 +: 32]);
  always_ff @(posedge clk) if (ld_done)
    $display("[pipe-ld] pc=%h addr=%h raw=%h ext=%h", exmem.pc, exmem.alu, lsu_axi.rdata, ld_ext);
  // 临时调试: 打印流水段寄存器 (只看关心地址附近的指令)
  logic [31:0] dbg_cyc;
  always_ff @(posedge clk) dbg_cyc <= rst ? 32'd0 : dbg_cyc + 32'd1;
  always_ff @(posedge clk) begin
    if ((ifid.pc  >= 32'h800003d0 && ifid.pc  <= 32'h80000420) ||
        (idex.pc  >= 32'h800003d0 && idex.pc  <= 32'h80000420) ||
        (exmem.pc >= 32'h800003d0 && exmem.pc <= 32'h80000420) ||
        (memwb.pc >= 32'h800003d0 && memwb.pc <= 32'h80000420))
      $display("[pipe-reg] cyc=%0d pcq=%h | ifid v=%b pc=%h inst=%h | idex v=%b pc=%h inst=%h | exmem v=%b pc=%h inst=%h | memwb v=%b pc=%h inst=%h | flush=%b stall=%b",
        dbg_cyc, pc_q, ifid.valid, ifid.pc, ifid.inst, idex.valid, idex.pc, idex.inst,
        exmem.valid, exmem.pc, exmem.inst, memwb.valid, memwb.pc, memwb.inst, flush, stall_pipe);
  end
  // 临时调试: 观察取指结果
  always_ff @(posedge clk) if (ifu_resp_valid && pc_q >= 32'h800003d0 && pc_q <= 32'h800003e0)
    $display("[pipe-if] pc=%h data=%h hit=%b miss=%b drain=%b stall=%b", pc_q, ifu_resp_data, ic_hit, ic_miss, if_drain, stall_pipe);
  // 临时调试: 观察某个分支指令的源操作数与判定结果
  always_ff @(posedge clk) if (!stall_all && idex.valid && idex.pc[31:12] == 20'h80000 && idex.dnpc == DNPC_BRANCH)
    $display("[pipe-br] pc=%h inst=%h rs1=%h rs2=%h taken=%b", idex.pc, idex.inst, idex.rs1_v, idex.rs2_v, branch_taken);
  // 临时调试: 观察 printf 十六进制转换循环附近的数据流
  always_ff @(posedge clk) if (!stall_all && idex.valid &&
      ((idex.pc >= 32'h800007c0 && idex.pc <= 32'h80000808) ||
       (idex.pc >= 32'h80000420 && idex.pc <= 32'h80000460)))
    $display("[pipe-trace] pc=%h inst=%h a=%h b=%h fwd1=%b fwd2=%b", idex.pc, idex.inst, idex.rs1_v, idex.rs2_v,
             exmem_hit1|exmem_hit2, memwb_hit1|memwb_hit2);
`endif
  always_comb begin
    branch_taken = 1'b0;
    unique case (idex.funct3)
      3'b000: branch_taken = (idex.rs1_v == idex.rs2_v);
      3'b001: branch_taken = (idex.rs1_v != idex.rs2_v);
      3'b100: branch_taken = ($signed(idex.rs1_v) <  $signed(idex.rs2_v));
      3'b101: branch_taken = !($signed(idex.rs1_v) < $signed(idex.rs2_v));
      3'b110: branch_taken = (idex.rs1_v < idex.rs2_v);
      3'b111: branch_taken = !(idex.rs1_v < idex.rs2_v);
      default: ;
    endcase
  end

  // csr 指令的源操作数: csrrw/csrrs/csrrc 用 rs1, csrrwi/... 用 uimm
  wire [31:0] ex_csr_src = idex.inst[14] ? {27'b0, idex.inst[19:15]} : idex.rs1_v;
  logic [31:0] ex_csr_new;
  always_comb begin
    unique case (idex.inst[13:12])
      2'b01:   ex_csr_new = ex_csr_src;                              // csrrw(i)
      2'b10:   ex_csr_new = idex.csr_rdata | ex_csr_src;             // csrrs(i)
      default: ex_csr_new = idex.csr_rdata & ~ex_csr_src;            // csrrc(i)
    endcase
  end

  wire ex_is_ecall = (idex.inst == 32'h0000_0073);
  wire ex_is_mret  = (idex.inst == 32'h3020_0073);
  wire ex_is_ebreak= (idex.inst == 32'h0010_0073);

  // 跳转目标 / 下一条 PC
  logic [31:0] ex_next_pc;
  always_comb begin
    unique case (idex.dnpc)
      DNPC_JAL:    ex_next_pc = idex.pc + idex.imm;
      DNPC_JALR:   ex_next_pc = (idex.rs1_v + idex.imm) & 32'hffff_fffe;
      DNPC_BRANCH: ex_next_pc = branch_taken ? (idex.pc + idex.imm) : (idex.pc + 32'd4);
      DNPC_TRAP:   ex_next_pc = csr_mtvec;
      DNPC_MRET:   ex_next_pc = csr_mepc;
      default:     ex_next_pc = idex.pc + 32'd4;
    endcase
  end

  // 需要冲刷流水线的两种情况
  wire ex_redirect = idex.valid && !idex.is_fence_i &&
                     ((idex.dnpc != DNPC_PC4 && ex_next_pc != idex.pc + 32'd4) ||
                      ex_is_ecall || ex_is_mret);
  wire ex_fence_flush = idex.valid && idex.is_fence_i;
  logic [31:0] ex_redirect_pc;
  always_comb begin
    if (ex_is_ecall)     ex_redirect_pc = csr_mtvec;
    else if (ex_is_mret) ex_redirect_pc = csr_mepc;
    else                 ex_redirect_pc = ex_next_pc;
  end

  // ------------------------------------------------------------------
  // MEM 段: LSU (AXI4, 一次一个事务, 访问期间冻结前面三个流水段)
  // ------------------------------------------------------------------
  typedef enum logic [2:0] { L_IDLE, L_AR, L_R, L_AW, L_B } lsu_st_t;
  lsu_st_t     lsu_st;
  logic        aw_done, w_done;
  logic [31:0] ld_data;
  logic        mem_op;

  assign mem_op = exmem.valid && (exmem.mem_read || exmem.mem_write);

  wire ld_done = (lsu_st == L_R) && lsu_axi.rvalid && lsu_axi.rready;
  wire st_done = (lsu_st == L_B) && lsu_axi.bvalid && lsu_axi.bready;
  wire mem_done = !mem_op || ld_done || st_done;
  wire mem_busy = mem_op && !mem_done;

  logic [1:0]  lsu_size_q;
  logic [31:0] lsu_addr_q, lsu_wdata_q;
  logic [3:0]  lsu_wstrb_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      lsu_st <= L_IDLE;
      aw_done <= 1'b0; w_done <= 1'b0;
      lsu_addr_q <= 32'b0; lsu_wdata_q <= 32'b0; lsu_wstrb_q <= 4'b0;
      lsu_size_q <= 2'd0; ld_data <= 32'b0;
    end
    else begin
      unique case (lsu_st)
        L_IDLE: if (mem_op && exmem.mem_read) begin
                  lsu_addr_q <= exmem.alu;
                  lsu_size_q <= exmem.mem_size;
                  lsu_st     <= L_AR;
                end
                else if (mem_op && exmem.mem_write) begin
                  lsu_addr_q <= exmem.alu;
                  lsu_size_q <= exmem.mem_size;
                  // 把数据对齐到对应的字节通道 (AXI: WSTRB[i] 对应 WDATA[8i+:8])
                  unique case (exmem.mem_size)
                    2'd0: begin
                            lsu_wdata_q <= exmem.stdata << (8 * exmem.alu[1:0]);
                            lsu_wstrb_q <= 4'h1 << exmem.alu[1:0];
                          end
                    2'd1: begin
                            lsu_wdata_q <= exmem.alu[1] ? (exmem.stdata << 16) : exmem.stdata;
                            lsu_wstrb_q <= exmem.alu[1] ? 4'hc : 4'h3;
                          end
                    default: begin
                            lsu_wdata_q <= exmem.stdata;
                            lsu_wstrb_q <= 4'hf;
                          end
                  endcase
                  aw_done <= 1'b0;
                  w_done  <= 1'b0;
                  lsu_st  <= L_AW;
                end
        L_AR: if (lsu_axi.arvalid && lsu_axi.arready) lsu_st <= L_R;
        L_R:  if (lsu_axi.rvalid && lsu_axi.rready) begin
                ld_data <= lsu_axi.rdata;
                lsu_st  <= L_IDLE;
              end
        L_AW: begin
                if (lsu_axi.awready) aw_done <= 1'b1;
                if (lsu_axi.wready)  w_done  <= 1'b1;
                if ((aw_done || lsu_axi.awready) && (w_done || lsu_axi.wready)) begin
                  aw_done <= 1'b0; w_done <= 1'b0;
                  lsu_st  <= L_B;
                end
              end
        L_B:  if (lsu_axi.bvalid && lsu_axi.bready) lsu_st <= L_IDLE;
        default: lsu_st <= L_IDLE;
      endcase
    end
  end

  // load 结果的符号/零扩展
  // load 数据: 在 R 通道握手的那一拍直接用总线上的数据 (ld_data 要到下一个
  // 时钟沿才更新, 否则会写回"上一条 load"的数据)
  wire  [31:0] ld_word = (lsu_st == L_R) ? lsu_axi.rdata : ld_data;
  logic [31:0] ld_ext;
  always_comb begin
    if (exmem.mem_size == 2'd0) begin
      // lb / lbu: 按地址的低 2 位选出所在字节, 再做符号/零扩展
      logic [7:0] b;
      b = ld_word[8 * exmem.alu[1:0] +: 8];
      ld_ext = exmem.inst[14] ? {24'b0, b} : {{24{b[7]}}, b};
    end
    else if (exmem.mem_size == 2'd1) begin
      // lh / lhu
      logic [15:0] h;
      h = ld_word[16 * exmem.alu[1] +: 16];
      ld_ext = exmem.inst[14] ? {16'b0, h} : {{16{h[15]}}, h};
    end
    else ld_ext = ld_word;
  end

  // ------------------------------------------------------------------
  // WB 段: 写回 + 退休上报
  // ------------------------------------------------------------------
  assign rf_we_wb = memwb.valid && memwb.rf_we && (memwb.rd != 4'd0);
  assign rf_wa_wb = memwb.rd;
  assign rf_wd_wb = memwb.result;

  // ------------------------------------------------------------------
  // 冒险检测与流水线控制
  // ------------------------------------------------------------------
  // RAW 冒险: ID 段的指令依赖还在 EX 段的那条指令。
  // 由于转发源是 EX/MEM 和 MEM/WB (讲义推荐的"转发到 ID"方案), 生产者还在 EX
  // 时结果尚未进入任何流水段寄存器, 因此需要停顿一拍, 等它进入 EX/MEM 后再转发。
  // (load-use 是其中一种特殊情况: load 的数据要等到访存结束才能转发)
  wire raw_stall = ifid.valid && idex.valid && idex.rf_we && (idex.rd != 4'd0) &&
                   ((idex.rd == id_rs1) || (idex.rd == id_rs2));
  wire lduse_stall = raw_stall && idex.mem_read;   // 供性能计数器区分
  // CSR 冒险: ID 是 CSR 指令, 而 EX 段的指令要写 CSR
  wire csr_stall = ifid.valid && id_is_csr && idex.valid && idex.csr_we;

  wire stall_front = raw_stall || csr_stall;
  wire stall_all   = mem_busy;
`ifdef NPC_FENCE_NO_FLUSH
  // 仅用于复现 fence.i 的反例: 只冲刷 icache, 不冲刷流水线
  wire flush       = ex_redirect;
`else
  wire flush       = ex_redirect || ex_fence_flush;
`endif
  wire stall_pipe  = stall_all || stall_front;

  assign state_dbg = stall_all ? 3'd1 : stall_front ? 3'd2 : flush ? 3'd3
                   : if_waiting ? 3'd4 : 3'd0;

  // ------------------------------------------------------------------
  // IF 段推进
  // ------------------------------------------------------------------
  wire if_fetch_done = ifu_resp_valid && !if_drain;
  assign ifu_resp_ready = if_drain || (ifu_resp_valid && !stall_pipe);
  assign ifu_req_valid  = !rst && !stall_pipe && !if_waiting && !if_drain;
  assign ifu_req_addr   = pc_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_q      <= PC_INIT;
      if_waiting<= 1'b0;
      if_drain  <= 1'b0;
      ifid.valid<= 1'b0;
      ifid.pc   <= 32'b0;
      ifid.inst <= 32'h0000_0013;
    end
    else if (flush) begin
      // 冲刷: 丢掉 IF/ID, PC 跳到正确位置; 若还有在途的取指请求, 标记丢弃
      pc_q       <= ex_redirect_pc;
      if_waiting <= 1'b0;
      // 有在途取指请求 (已经发出但还没拿到指令) -> 下个周期把它收下并丢弃,
      // 否则 icache 稍后返回的、属于错误路径的数据会被当成重定向目标的指令。
      // 注意: 如果这一拍已经拿到指令 (命中), 请求已经结束, 不需要丢弃。
      if_drain   <= !ifu_resp_valid && (if_waiting || (ifu_req_valid && ifu_req_ready));
      ifid.valid <= 1'b0;
      ifid.pc    <= 32'b0;
    end
    else if (if_drain) begin
      if (ifu_resp_valid) if_drain <= 1'b0;   // 丢弃在途的旧取指回复
    end
    else if (!stall_pipe) begin
      if (ifu_resp_valid) begin
        ifid.valid <= 1'b1;
        ifid.pc    <= pc_q;
        ifid.inst  <= ifu_resp_data;
        pc_q       <= pc_q + 32'd4;
        if_waiting <= 1'b0;
      end
      else begin
        if (ifu_req_valid && ifu_req_ready) if_waiting <= 1'b1;
        ifid.valid <= 1'b0;           // 取不到指令就送一个气泡
      end
    end
  end

  // ------------------------------------------------------------------
  // ID/EX
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      idex.valid <= 1'b0;
    end
    else if (stall_all) begin
      // 冻结。注意这里把 flush 也一起冻结: 如果这一拍既要冲刷、MEM 段又有访存
      // 没完成, 那么产生重定向的指令 (它就在 ID/EX 里) 必须留在原地等访存结束,
      // 否则它会被气泡覆盖而永远不会退休。
    end
    else if (flush) begin
      idex.valid <= 1'b0;          // 冲刷: 给 ID/EX 插入气泡
    end
    else if (stall_front) begin
      idex.valid <= 1'b0;           // 插入气泡
    end
    else begin
      idex.valid      <= ifid.valid;
      idex.pc         <= ifid.pc;
      idex.inst       <= ifid.inst;
      idex.rs1_v      <= id_rs1_v;
      idex.rs2_v      <= id_rs2_v;
      idex.imm        <= id_imm;
      idex.rs1        <= id_rs1;
      idex.rs2        <= id_rs2;
      idex.rd         <= id_rd;
      idex.funct3     <= id_funct3;
      idex.rf_we      <= id_rf_we && !id_invalid;
      idex.wb_sel     <= id_wb_sel;
      idex.alu_op     <= id_alu_op;
      idex.alu_a_sel  <= id_alu_a_sel;
      idex.alu_b_sel  <= id_alu_b_sel;
      idex.mem_read   <= id_mem_read;
      idex.mem_write  <= id_mem_write;
      idex.mem_size   <= id_mem_size;
      idex.dnpc       <= id_dnpc;
      idex.csr_we     <= id_csr_we;
      idex.csr_waddr  <= id_csr_waddr;
      idex.csr_op     <= id_csr_op;
      idex.csr_rdata  <= id_csr_rdata;
      idex.is_csr     <= id_is_csr;
      idex.is_fence_i <= id_is_fence_i;
    end
  end

  // ------------------------------------------------------------------
  // EX/MEM
  // ------------------------------------------------------------------
  logic [31:0] ex_alu_result;
  always_comb begin
    if (idex.is_csr)               ex_alu_result = idex.csr_rdata;  // 读回旧值
    else if (idex.wb_sel == WB_PC4) ex_alu_result = idex.pc + 32'd4; // 链接值 (转发时也要用它)
    else                            ex_alu_result = alu_y;
  end

  always_ff @(posedge clk) begin
    // 注意: 冲刷只影响"比出错指令年轻的指令", 正在 EX 段执行的那条指令 (它在
    // idex 里, 本轮已经算出跳转结果/异常) 必须继续流向 EX/MEM, 否则不会退休。
    if (rst) begin
      exmem.valid <= 1'b0;
    end
    else if (stall_all) begin
      // 冻结: MEM 段还有访存没完成, EX/MEM 不能被覆盖 (否则那条更老的指令
      // 会丢失)。产生重定向的指令会留在 ID/EX 等访存结束 (见 ID/EX 的逻辑)。
    end
    else begin
      exmem.valid     <= idex.valid;
      exmem.pc        <= idex.pc;
      exmem.inst      <= idex.inst;
      exmem.alu       <= ex_alu_result;
      exmem.stdata    <= idex.rs2_v;
      exmem.next_pc   <= ex_next_pc;
      exmem.rd        <= idex.rd;
      exmem.rf_we     <= idex.rf_we;
      exmem.wb_sel    <= idex.wb_sel;
      exmem.mem_read  <= idex.mem_read;
      exmem.mem_write <= idex.mem_write;
      exmem.mem_size  <= idex.mem_size;
      exmem.csr_we    <= idex.csr_we;
      exmem.csr_waddr <= idex.csr_waddr;
      exmem.is_fence_i<= idex.is_fence_i;
    end
  end

  // CSR 写 (在 EX 段)
  always_ff @(posedge clk) begin
    if (rst) begin
      csr_mstatus <= 32'd0;
      csr_mtvec   <= 32'd0;
      csr_mepc    <= 32'd0;
      csr_mcause  <= 32'd0;
    end
    else if (!stall_all && idex.valid) begin
      if (idex.csr_we) begin
        unique case (idex.csr_waddr)
          CSR_MSTATUS: csr_mstatus <= ex_csr_new;
          CSR_MTVEC:   csr_mtvec   <= ex_csr_new;
          CSR_MEPC:    csr_mepc    <= ex_csr_new;
          CSR_MCAUSE:  csr_mcause  <= ex_csr_new;
          default: ;   // mvendorid/marchid 只读, mcycle 由硬件维护
        endcase
      end
      if (ex_is_ecall) begin
        csr_mcause  <= 32'd11;         // Environment call from M-mode
        csr_mepc    <= idex.pc;
        csr_mstatus <= (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                     | (((csr_mstatus & MSTATUS_MIE) != 0) ? MSTATUS_MPIE : 32'd0);
      end
      if (ex_is_mret) begin
        csr_mstatus <= (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                     | (((csr_mstatus & MSTATUS_MPIE) != 0) ? MSTATUS_MIE : 32'd0)
                     | MSTATUS_MPIE;
      end
    end
  end

  assign icache_flush = ex_fence_flush && !stall_all;

  // ------------------------------------------------------------------
  // MEM/WB
  // ------------------------------------------------------------------
  logic [31:0] wb_result;
  always_comb begin
    unique case (exmem.wb_sel)
      WB_MEM: wb_result = ld_ext;
      WB_PC4: wb_result = exmem.pc + 32'd4;
      default: wb_result = exmem.alu;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      memwb.valid <= 1'b0;
      memwb.pc    <= PC_INIT;   // 复位后 top.pc 就是程序的入口 (DiffTest 初始化要用)
      memwb.inst  <= 32'h0000_0013;
    end
    else if (stall_all) begin
      // 冻结
    end
    else begin
      memwb.valid     <= exmem.valid;
      memwb.pc        <= exmem.pc;
      memwb.inst      <= exmem.inst;
      memwb.result    <= wb_result;
      memwb.next_pc   <= exmem.next_pc;
      memwb.rd        <= exmem.rd;
      memwb.rf_we     <= exmem.rf_we;
      memwb.mem_valid <= exmem.mem_read || exmem.mem_write;
      memwb.mem_we    <= exmem.mem_write;
      memwb.mem_addr  <= exmem.alu;
      memwb.mem_data  <= exmem.mem_write ? exmem.stdata : ld_ext;
      memwb.mem_size  <= exmem.mem_size;
    end
  end

  // ------------------------------------------------------------------
  // 退休上报 (延迟一拍, 让寄存器堆完成写回) —— trace / DiffTest
  // ------------------------------------------------------------------
  // 注意: memwb.valid 在流水线被冻结时会一直保持, 因此"退休"必须定义成
  // "这条指令这一拍离开 WB" (一个脉冲), 否则同一条指令会被重复上报。
  wire wb_retire = memwb.valid && !stall_all && !rst;

  logic        retire_valid_q;
  logic [31:0] retire_next_pc_q;
  logic [31:0] retire_pc_q, retire_inst_q, retire_next_q;
  logic        retire_mvalid_q, retire_mwe_q;
  logic [31:0] retire_maddr_q, retire_mdata_q;
  logic [1:0]  retire_msize_q;

  always_ff @(posedge clk) begin
    retire_valid_q <= wb_retire;
    if (wb_retire) retire_next_pc_q <= memwb.next_pc;
    retire_pc_q    <= memwb.pc;
    retire_inst_q  <= memwb.inst;
    retire_next_q  <= memwb.next_pc;
    retire_mvalid_q<= memwb.mem_valid;
    retire_mwe_q   <= memwb.mem_we;
    retire_maddr_q <= memwb.mem_addr;
    retire_mdata_q <= memwb.mem_data;
    retire_msize_q <= memwb.mem_size;
  end

  always_ff @(posedge clk) begin
    if (retire_valid_q && !rst)
      npc_retire(int'(retire_pc_q), int'(retire_inst_q),
        int'(gpr_dbg[1 *32 +: 32]), int'(gpr_dbg[2 *32 +: 32]),
        int'(gpr_dbg[3 *32 +: 32]), int'(gpr_dbg[4 *32 +: 32]),
        int'(gpr_dbg[5 *32 +: 32]), int'(gpr_dbg[6 *32 +: 32]),
        int'(gpr_dbg[7 *32 +: 32]), int'(gpr_dbg[8 *32 +: 32]),
        int'(gpr_dbg[9 *32 +: 32]), int'(gpr_dbg[10*32 +: 32]),
        int'(gpr_dbg[11*32 +: 32]), int'(gpr_dbg[12*32 +: 32]),
        int'(gpr_dbg[13*32 +: 32]), int'(gpr_dbg[14*32 +: 32]),
        int'(gpr_dbg[15*32 +: 32]),
        int'(retire_next_q),              // 这条指令执行后的 PC
        int'(retire_mvalid_q), int'(retire_mwe_q),
        int'(retire_maddr_q), int'(retire_mdata_q), int'({1'b0, retire_msize_q}));
  end

  // ------------------------------------------------------------------
  // 调试端口 / ebreak
  // ------------------------------------------------------------------
  assign pc       = memwb.pc;
  assign inst     = memwb.inst;
  // 退休指令执行后的 PC (在指令离开 WB 的那一拍寄存下来)
  assign next_pc  = retire_next_pc_q;
  assign inst_done= wb_retire;
  assign mem_valid= wb_retire && memwb.mem_valid;
  assign mem_we   = memwb.mem_we;
  assign mem_size = memwb.mem_size;
  assign mem_addr = memwb.mem_addr;
  assign mem_wdata= memwb.mem_data;
  assign mem_rdata= ld_ext;

  always_comb begin
    if (!rst && retire_valid_q) begin
      if (retire_inst_q == 32'h0010_0073) ebreak(int'(gpr_a0));   // ebreak
    end
  end

  // ------------------------------------------------------------------
  // AXI4: LSU
  // ------------------------------------------------------------------
  assign lsu_axi.arid    = 4'd0;
  assign lsu_axi.arlen   = 8'd0;
  assign lsu_axi.arsize  = {1'b0, lsu_size_q};
  assign lsu_axi.arburst = 2'b01;
  assign lsu_axi.arvalid = (lsu_st == L_AR) && !rst;
  assign lsu_axi.araddr  = lsu_addr_q;
  assign lsu_axi.rready  = (lsu_st == L_R) && !rst;

  assign lsu_axi.awid    = 4'd0;
  assign lsu_axi.awlen   = 8'd0;
  assign lsu_axi.awsize  = {1'b0, lsu_size_q};
  assign lsu_axi.awburst = 2'b01;
  assign lsu_axi.awvalid = (lsu_st == L_AW) && !aw_done && !rst;
  assign lsu_axi.awaddr  = lsu_addr_q;
  assign lsu_axi.wvalid  = (lsu_st == L_AW) && !w_done && !rst;
  assign lsu_axi.wdata   = lsu_wdata_q;
  assign lsu_axi.wstrb   = lsu_wstrb_q;
  assign lsu_axi.wlast   = 1'b1;
  assign lsu_axi.bready  = (lsu_st == L_B) && !rst;

`ifdef NPC_PERF
  // ==================================================================
  // 性能计数器 (与 npc_core 相同的口径, 另外加上流水线特有的统计)
  // ==================================================================
  logic [63:0] pf_cyc, pf_inst, pf_ifu, pf_ifu_stall_req, pf_ifu_stall_mem;
  logic [63:0] pf_ld, pf_st, pf_lsu_cyc, pf_exu;
  logic [63:0] pf_alu, pf_load, pf_store, pf_branch, pf_jump, pf_csr, pf_sys;
  logic [63:0] pf_ic_hit, pf_ic_miss, pf_ic_bypass, pf_ic_miss_cyc;
  logic [63:0] pf_c_alu, pf_c_load, pf_c_store, pf_c_branch, pf_c_jump, pf_c_csr, pf_c_sys;
  logic [63:0] pf_cyc_last;
  logic [63:0] pf_stall_mem, pf_stall_lduse, pf_stall_csr, pf_flush_br, pf_flush_sys, pf_fwd;
  logic        pf_reported, pf_report_pending;

  always_ff @(posedge clk) begin
    if (rst) begin
      pf_cyc <= '0; pf_inst <= '0; pf_ifu <= '0;
      pf_ifu_stall_req <= '0; pf_ifu_stall_mem <= '0;
      pf_ld <= '0; pf_st <= '0; pf_lsu_cyc <= '0; pf_exu <= '0;
      pf_alu <= '0; pf_load <= '0; pf_store <= '0;
      pf_branch <= '0; pf_jump <= '0; pf_csr <= '0; pf_sys <= '0;
      pf_ic_hit <= '0; pf_ic_miss <= '0; pf_ic_bypass <= '0; pf_ic_miss_cyc <= '0;
      pf_c_alu <= '0; pf_c_load <= '0; pf_c_store <= '0; pf_c_branch <= '0;
      pf_c_jump <= '0; pf_c_csr <= '0; pf_c_sys <= '0; pf_cyc_last <= '0;
      pf_stall_mem <= '0; pf_stall_lduse <= '0; pf_stall_csr <= '0;
      pf_flush_br <= '0; pf_flush_sys <= '0; pf_fwd <= '0;
    end
    else begin
      pf_cyc <= pf_cyc + 64'd1;
      if (ifu_resp_valid) pf_ifu <= pf_ifu + 64'd1;
      if (!stall_pipe && if_waiting && !ifu_resp_valid) pf_ifu_stall_mem <= pf_ifu_stall_mem + 64'd1;
      if (stall_all)   pf_stall_mem   <= pf_stall_mem + 64'd1;
      if (lduse_stall) pf_stall_lduse <= pf_stall_lduse + 64'd1;
      if (csr_stall)   pf_stall_csr   <= pf_stall_csr + 64'd1;
      if (ic_hit)  pf_ic_hit  <= pf_ic_hit + 64'd1;
      if (ic_miss) begin
        pf_ic_miss <= pf_ic_miss + 64'd1;
        pf_ic_miss_cyc <= pf_ic_miss_cyc + {32'd0, ic_miss_len};
      end
      if (ic_bypass) pf_ic_bypass <= pf_ic_bypass + 64'd1;

      if (exmem_hit1 || exmem_hit2 || memwb_hit1 || memwb_hit2) pf_fwd <= pf_fwd + 64'd1;

      if (wb_retire) pf_inst <= pf_inst + 64'd1;
      if (ld_done)     pf_ld   <= pf_ld + 64'd1;
      if (st_done)     pf_st   <= pf_st + 64'd1;
      if (lsu_st == L_AR || lsu_st == L_R) pf_lsu_cyc <= pf_lsu_cyc + 64'd1;
      if (idex.valid && !idex.mem_read && !idex.mem_write && !idex.is_fence_i
          && !ex_is_ecall && !ex_is_mret) pf_exu <= pf_exu + 64'd1;

      if (idex.valid && !stall_all) begin
        unique case (idex.inst[6:0])
          7'b0110111, 7'b0010111, 7'b0010011, 7'b0110011: pf_alu    <= pf_alu    + 64'd1;
          7'b0000011:                                    pf_load   <= pf_load   + 64'd1;
          7'b0100011:                                    pf_store  <= pf_store  + 64'd1;
          7'b1100011:                                    pf_branch <= pf_branch + 64'd1;
          7'b1101111, 7'b1100111:                        pf_jump   <= pf_jump   + 64'd1;
          7'b1110011: begin
            if (idex.inst[14:12] == 3'b000) pf_sys <= pf_sys + 64'd1;
            else                            pf_csr <= pf_csr + 64'd1;
          end
          default: ;
        endcase
      end

      if (wb_retire) begin
        logic [63:0] delta;
        delta = pf_cyc - pf_cyc_last;
        pf_cyc_last <= pf_cyc;
        unique case (memwb.inst[6:0])
          7'b0110111, 7'b0010111, 7'b0010011, 7'b0110011: pf_c_alu    <= pf_c_alu    + delta;
          7'b0000011:                                    pf_c_load   <= pf_c_load   + delta;
          7'b0100011:                                    pf_c_store  <= pf_c_store  + delta;
          7'b1100011:                                    pf_c_branch <= pf_c_branch + delta;
          7'b1101111, 7'b1100111:                        pf_c_jump   <= pf_c_jump   + delta;
          7'b1110011: begin
            if (memwb.inst[14:12] == 3'b000) pf_c_sys <= pf_c_sys + delta;
            else                             pf_c_csr <= pf_c_csr + delta;
          end
          default: ;
        endcase
      end

      if (ex_redirect && !(ex_is_ecall || ex_is_mret)) pf_flush_br  <= pf_flush_br  + 64'd1;
      if (ex_is_ecall || ex_is_mret)                   pf_flush_sys <= pf_flush_sys + 64'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pf_reported <= 1'b0;
      pf_report_pending <= 1'b0;
    end
    else begin
      pf_report_pending <= !pf_reported && retire_valid_q && (retire_inst_q == 32'h0010_0073);
      if (pf_report_pending) begin
        pf_reported <= 1'b1;
        $display("PERF cyc=%0d inst=%0d ifu=%0d ifu_stall_req=%0d ifu_stall_mem=%0d ld=%0d st=%0d lsu_cyc=%0d exu=%0d alu=%0d load=%0d store=%0d branch=%0d jump=%0d csr=%0d sys=%0d ic_hit=%0d ic_miss=%0d ic_bypass=%0d ic_miss_cyc=%0d c_alu=%0d c_load=%0d c_store=%0d c_branch=%0d c_jump=%0d c_csr=%0d c_sys=%0d stall_mem=%0d stall_lduse=%0d stall_csr=%0d flush_br=%0d flush_sys=%0d fwd=%0d",
          pf_cyc, pf_inst, pf_ifu, pf_ifu_stall_req, pf_ifu_stall_mem,
          pf_ld, pf_st, pf_lsu_cyc, pf_exu,
          pf_alu, pf_load, pf_store, pf_branch, pf_jump, pf_csr, pf_sys,
          pf_ic_hit, pf_ic_miss, pf_ic_bypass, pf_ic_miss_cyc,
          pf_c_alu, pf_c_load, pf_c_store, pf_c_branch, pf_c_jump, pf_c_csr, pf_c_sys,
          pf_stall_mem, pf_stall_lduse, pf_stall_csr, pf_flush_br, pf_flush_sys, pf_fwd);
      end
    end
  end
`endif
endmodule
