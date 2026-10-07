// ============================================================================
// NPC 核心 (B1 总线讲义): 多周期 + AXI4-Lite master
//
// 与之前单周期版本的区别:
//   * IFU/LSU 不再直接调用 DPI-C 读写存储器, 而是通过 AXI4-Lite 总线;
//   * 存储器需要至少 1 个周期才能返回数据, 因此一条指令被拆成多个周期:
//       S_FETCH_AR -> S_FETCH_R  : 取指 (AR/R 握手)
//       S_EXEC                   : 译码 + 执行 (无访存的指令到此结束)
//       S_LD_AR -> S_LD_R        : load  (AR/R 握手)
//       S_ST_AW -> S_ST_B        : store (AW/W 握手 + B 响应)
//   * 新增 inst_done (retire) 信号, 供仿真环境在"指令完成的那个周期"
//     做 itrace/mtrace/ftrace 和 DiffTest (讲义"让DiffTest适配多周期处理器");
//   * 保留 C5 的 CSR / ecall / mret 功能, 以及 IMR 调试端口。
//
// ISA: RV32E (RV32I 的整数指令 + 16 个寄存器) + Zicsr。
// ============================================================================
`include "alu_ops.svh"

// B4: icache 的可配置参数 (可用 verilator 的 +define+ 覆盖, 便于设计空间探索)
//   NPC_ICACHE_BLOCK  : 块大小 (字节)
//   NPC_ICACHE_BLOCKS : cache 块数
//   NPC_ICACHE_SRAM   : 是否缓存 SRAM (0/1, 仅用于缓存一致性实验)
`ifndef NPC_ICACHE_BLOCK
`define NPC_ICACHE_BLOCK 4
`endif
`ifndef NPC_ICACHE_BLOCKS
`define NPC_ICACHE_BLOCKS 16
`endif
`ifndef NPC_ICACHE_SRAM
`define NPC_ICACHE_SRAM 0
`endif

module npc_core #(
  parameter logic [31:0] PC_INIT = 32'h8000_0000,
  // B4: icache 参数 (可配置, 便于设计空间探索)
  parameter int  ICACHE_BLOCK  = `NPC_ICACHE_BLOCK,   // 块大小 (字节)
  parameter int  ICACHE_BLOCKS = `NPC_ICACHE_BLOCKS,  // cache 块数
  parameter bit  ICACHE_SRAM   = `NPC_ICACHE_SRAM     // 是否缓存 SRAM (一致性实验)
) (
  input  logic clk,
  input  logic rst,
  // ---- 调试/仿真端口 (sdb / trace / DiffTest) ----
  output logic [31:0] pc,          // 当前正在取指/执行的 PC
  output logic [31:0] inst,        // 当前正在执行的指令
  output logic [512-1:0] gpr_dbg,  // 通用寄存器 (16 x 32)
  output logic        inst_done,   // 本周期有一条指令完成 (retire)
  output logic        mem_valid,   // 完成的指令是否访存 (mtrace)
  output logic        mem_we,
  output logic [1:0]  mem_size,    // 0: 1B, 1: 2B, 2: 4B
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata,
  // ---- AXI4 master (B2: 由 AXI4-Lite 扩展而来) ----
  axi4_if.master      ifu_mem,     // 取指 (经 icache 之后连到总线)
  axi4_if.master      lsu_axi,     // 访存
  output logic [2:0]  state_dbg    // (调试) 状态机
);
  import "DPI-C" function void ebreak(input int code);
  // B2: 每 retire 一条指令就通知仿真环境 (trace / DiffTest 用)。
  // ysyxSoCFull 只暴露少量外部引脚, 拿不到 NPC 的内部信号, 因此这里用 DPI-C
  // 主动把 "退休的 PC、指令、16 个通用寄存器、访存信息" 报给仿真环境。
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
  // 状态机
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_FETCH_AR, S_FETCH_R, S_EXEC, S_LD_AR, S_LD_R, S_ST_AW, S_ST_B
  } state_t;
  state_t st;
  assign state_dbg = st;

  logic [31:0] pc_q, inst_q, next_pc_q;
  logic [31:0] lsu_addr_q, lsu_wdata_q;
  logic [3:0]  lsu_wstrb_q, lsu_rd_q;
  logic [1:0]  lsu_size_q;
  logic        aw_done, w_done;

  assign pc   = pc_q;
  assign inst = inst_q;

  // ------------------------------------------------------------------
  // CSR 文件 (与 C5 相同: 只实例化需要的)
  // ------------------------------------------------------------------
  localparam logic [31:0] MSTATUS_MIE  = 32'h0000_0008;
  localparam logic [31:0] MSTATUS_MPIE = 32'h0000_0080;

  localparam logic [11:0] CSR_MSTATUS   = 12'h300,
                          CSR_MTVEC     = 12'h305,
                          CSR_MEPC      = 12'h341,
                          CSR_MCAUSE    = 12'h342,
                          CSR_MCYCLE    = 12'hB00,
                          CSR_MCYCLEH   = 12'hB80,
                          CSR_MVENDORID = 12'hF11,
                          CSR_MARCHID   = 12'hF12;
  localparam logic [31:0] MVENDORID_VALUE = 32'h7973_7978;  // "ysyx"
  localparam logic [31:0] MARCHID_VALUE   = 32'h0150_4dc0;  // ysyx_22040000

  logic [31:0] csr_mstatus, csr_mtvec, csr_mepc, csr_mcause;
  logic [63:0] csr_mcycle;

  always_ff @(posedge clk) begin
    if (rst) csr_mcycle <= 64'd0;
    else     csr_mcycle <= csr_mcycle + 64'd1;
  end

  // ------------------------------------------------------------------
  // 译码 (组合, 针对 inst_q)
  // ------------------------------------------------------------------
  wire [6:0] opcode = inst_q[6:0];
  wire [3:0] rd     = inst_q[10:7];     // RV32E: 只用低 4 位
  wire [2:0] funct3 = inst_q[14:12];
  wire [3:0] rs1    = inst_q[18:15];
  wire [3:0] rs2    = inst_q[23:20];

  wire [31:0] imm_i = {{20{inst_q[31]}}, inst_q[31:20]};
  wire [31:0] imm_s = {{20{inst_q[31]}}, inst_q[31:25], inst_q[11:7]};
  wire [31:0] imm_b = {{19{inst_q[31]}}, inst_q[31], inst_q[7], inst_q[30:25], inst_q[11:8], 1'b0};
  wire [31:0] imm_u = {inst_q[31:12], 12'b0};
  wire [31:0] imm_j = {{11{inst_q[31]}}, inst_q[31], inst_q[19:12], inst_q[20], inst_q[30:21], 1'b0};

  logic [31:0] rv1, rv2, gpr_a0;
  regfile #(.ADDR_WIDTH(4), .DATA_WIDTH(32)) u_rf (
    .clk    (clk),
    .rst    (rst),
    .wen    (rf_we),
    .waddr  (rf_wa),
    .wdata  (rf_wd),
    .raddr1 (rs1),
    .rdata1 (rv1),
    .raddr2 (rs2),
    .rdata2 (rv2),
    .raddr3 (4'd10),
    .rdata3 (gpr_a0),
    .dbg    (gpr_dbg)
  );

  // 写回
  logic        rf_we;
  logic [3:0]  rf_wa;
  logic [31:0] rf_wd;

  // CSR 读 (组合)
  logic [31:0] csr_rdata;
  always_comb begin
    case (inst_q[31:20])
      CSR_MSTATUS:   csr_rdata = csr_mstatus;
      CSR_MTVEC:     csr_rdata = csr_mtvec;
      CSR_MEPC:      csr_rdata = csr_mepc;
      CSR_MCAUSE:    csr_rdata = csr_mcause;
      CSR_MCYCLE:    csr_rdata = csr_mcycle[31:0];
      CSR_MCYCLEH:   csr_rdata = csr_mcycle[63:32];
      CSR_MVENDORID: csr_rdata = MVENDORID_VALUE;
      CSR_MARCHID:   csr_rdata = MARCHID_VALUE;
      default:       csr_rdata = 32'h0;
    endcase
  end

  // 执行阶段的控制信号
  localparam logic [1:0] WB_ALU = 2'd0, WB_MEM = 2'd1, WB_PC4 = 2'd2, WB_CSR = 2'd3;
  localparam logic [2:0] DNPC_PC4 = 3'd0, DNPC_JAL = 3'd1, DNPC_JALR = 3'd2,
                         DNPC_BRANCH = 3'd3, DNPC_TRAP = 3'd4, DNPC_MRET = 3'd5;

  logic [31:0] alu_a, alu_b, alu_y;
  logic [3:0]  alu_op;
  logic [1:0]  wb_sel;
  logic [2:0]  dnpc_sel;
  logic        ex_mem_read, ex_mem_write;
  logic [1:0]  ex_mem_size;
  logic        ex_ebreak, ex_ecall, ex_mret, ex_invalid;
  logic        ex_fence_i;      // B4: fence.i (冲刷 icache)
  logic        ex_rf_we;
  logic        csr_we;
  logic [11:0] csr_waddr;
  logic [31:0] csr_wdata, ex_next_pc;
  logic [31:0] ex_lsu_addr, ex_lsu_wdata;
  logic [3:0]  ex_lsu_wstrb;
  logic        branch_taken;

  alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

  always_comb begin
    // 默认值
    alu_a        = rv1;
    alu_b        = imm_i;
    alu_op       = `ALU_ADD;
    wb_sel       = WB_ALU;
    dnpc_sel     = DNPC_PC4;
    ex_mem_read  = 1'b0;
    ex_mem_write = 1'b0;
    ex_mem_size  = 2'd2;
    ex_ebreak    = 1'b0;
    ex_ecall     = 1'b0;
    ex_mret      = 1'b0;
    ex_fence_i   = 1'b0;
    ex_invalid   = 1'b0;
    ex_rf_we     = 1'b0;
    csr_we       = 1'b0;
    csr_waddr    = inst_q[31:20];
    csr_wdata    = 32'b0;
    ex_lsu_addr  = rv1 + imm_i;
    ex_lsu_wdata = rv2;
    ex_lsu_wstrb = 4'h0;
    branch_taken = 1'b0;

    case (opcode)
      7'b0110111: begin                       // lui
        ex_rf_we = 1'b1; alu_a = 32'b0; alu_b = imm_u;
      end
      7'b0010111: begin                       // auipc
        ex_rf_we = 1'b1; alu_a = pc_q; alu_b = imm_u;
      end
      7'b1101111: begin                       // jal
        ex_rf_we = 1'b1; wb_sel = WB_PC4; dnpc_sel = DNPC_JAL;
        alu_a = pc_q; alu_b = imm_j;
      end
      7'b1100111: begin                       // jalr
        if (funct3 == 3'b000) begin
          ex_rf_we = 1'b1; wb_sel = WB_PC4; dnpc_sel = DNPC_JALR;
          alu_a = rv1; alu_b = imm_i;
        end
        else ex_invalid = 1'b1;
      end
      7'b1100011: begin                       // 分支
        alu_a = rv1; alu_b = rv2; alu_op = `ALU_SUB; dnpc_sel = DNPC_BRANCH;
        case (funct3)
          3'b000: branch_taken = (rv1 == rv2);
          3'b001: branch_taken = (rv1 != rv2);
          3'b100: branch_taken = ($signed(rv1) <  $signed(rv2));
          3'b101: branch_taken = !($signed(rv1) < $signed(rv2));
          3'b110: branch_taken = (rv1 < rv2);
          3'b111: branch_taken = !(rv1 < rv2);
          default: ex_invalid = 1'b1;
        endcase
      end
      7'b0000011: begin                       // 取数
        ex_lsu_addr  = rv1 + imm_i;
        ex_lsu_wstrb = 4'h0;
        case (funct3)
          3'b000: begin ex_rf_we = 1'b1; ex_mem_read = 1'b1; ex_mem_size = 2'd0; wb_sel = WB_MEM; end // lb
          3'b001: begin ex_rf_we = 1'b1; ex_mem_read = 1'b1; ex_mem_size = 2'd1; wb_sel = WB_MEM; end // lh
          3'b010: begin ex_rf_we = 1'b1; ex_mem_read = 1'b1; ex_mem_size = 2'd2; wb_sel = WB_MEM; end // lw
          3'b100: begin ex_rf_we = 1'b1; ex_mem_read = 1'b1; ex_mem_size = 2'd0; wb_sel = WB_MEM; end // lbu
          3'b101: begin ex_rf_we = 1'b1; ex_mem_read = 1'b1; ex_mem_size = 2'd1; wb_sel = WB_MEM; end // lhu
          default: ex_invalid = 1'b1;
        endcase
      end
      7'b0100011: begin                       // 存数
        ex_lsu_addr = rv1 + imm_s;
        case (funct3)
          3'b000: begin // sb
            ex_mem_write = 1'b1; ex_mem_size = 2'd0;
            ex_lsu_wdata = rv2 << (8 * ex_lsu_addr[1:0]);
            ex_lsu_wstrb = 4'h1 << ex_lsu_addr[1:0];
          end
          3'b001: begin // sh
            ex_mem_write = 1'b1; ex_mem_size = 2'd1;
            ex_lsu_wdata = ex_lsu_addr[1] ? (rv2 << 16) : rv2;
            ex_lsu_wstrb = ex_lsu_addr[1] ? 4'hc : 4'h3;
          end
          3'b010: begin // sw
            ex_mem_write = 1'b1; ex_mem_size = 2'd2;
            ex_lsu_wdata = rv2; ex_lsu_wstrb = 4'hf;
          end
          default: ex_invalid = 1'b1;
        endcase
      end
      7'b0010011: begin                       // OP-IMM
        ex_rf_we = 1'b1; alu_a = rv1; alu_b = imm_i;
        case (funct3)
          3'b000: alu_op = `ALU_ADD;
          3'b010: alu_op = `ALU_SLT;
          3'b011: alu_op = `ALU_SLTU;
          3'b100: alu_op = `ALU_XOR;
          3'b110: alu_op = `ALU_OR;
          3'b111: alu_op = `ALU_AND;
          3'b001: begin alu_op = `ALU_SLL; alu_b = {27'b0, inst_q[24:20]}; end
          3'b101: begin
            alu_b  = {27'b0, inst_q[24:20]};
            alu_op = inst_q[30] ? `ALU_SRA : `ALU_SRL;
          end
          default: ex_invalid = 1'b1;
        endcase
      end
      7'b0110011: begin                       // OP
        ex_rf_we = 1'b1; alu_a = rv1; alu_b = rv2;
        case (funct3)
          3'b000: alu_op = inst_q[30] ? `ALU_SUB : `ALU_ADD;
          3'b001: alu_op = `ALU_SLL;
          3'b010: alu_op = `ALU_SLT;
          3'b011: alu_op = `ALU_SLTU;
          3'b100: alu_op = `ALU_XOR;
          3'b101: alu_op = inst_q[30] ? `ALU_SRA : `ALU_SRL;
          3'b110: alu_op = `ALU_OR;
          3'b111: alu_op = `ALU_AND;
        endcase
      end
      7'b0001111: begin                       // fence / fence.i
        // fence.i: "让之后的取指都能看到之前的 store 修改的数据"。
        // 这里采用讲义的方案 (3): 执行 fence.i 时冲刷整个 icache,
        // 之后的取指必定缺失, 从而从存储器取到新数据。
        if (funct3 == 3'b001) ex_fence_i = 1'b1;
      end
      7'b1110011: begin                       // SYSTEM
        case (funct3)
          3'b000: begin
            if (inst_q == 32'h0010_0073) ex_ebreak = 1'b1;        // ebreak: nemu_trap
            else if (inst_q == 32'h0000_0073) begin               // ecall
              ex_ecall = 1'b1; dnpc_sel = DNPC_TRAP; csr_waddr = 0; csr_wdata = 0;
            end
            else if (inst_q == 32'h3020_0073) begin               // mret
              ex_mret = 1'b1; dnpc_sel = DNPC_MRET;
            end
            else ex_invalid = 1'b1;
          end
          3'b001, 3'b010, 3'b011: begin       // csrrw / csrrs / csrrc
            ex_rf_we  = 1'b1; wb_sel = WB_CSR;
            csr_waddr = inst_q[31:20];
            csr_we    = (funct3 == 3'b001) || (rs1 != 4'd0);
            csr_wdata = (funct3 == 3'b001) ? rv1
                      : (funct3 == 3'b010) ? (csr_rdata | rv1)
                      :                      (csr_rdata & ~rv1);
          end
          3'b101, 3'b110, 3'b111: begin       // csrrwi / csrrsi / csrrci
            ex_rf_we  = 1'b1; wb_sel = WB_CSR;
            csr_waddr = inst_q[31:20];
            csr_we    = (funct3 == 3'b101) || (inst_q[19:15] != 5'd0);
            csr_wdata = (funct3 == 3'b101) ? {27'b0, inst_q[19:15]}
                      : (funct3 == 3'b110) ? (csr_rdata | {27'b0, inst_q[19:15]})
                      :                      (csr_rdata & ~{27'b0, inst_q[19:15]});
          end
          default: ex_invalid = 1'b1;
        endcase
      end
      default: ex_invalid = 1'b1;
    endcase

    // 下一条 PC
    unique case (dnpc_sel)
      DNPC_JAL:    ex_next_pc = pc_q + imm_j;
      DNPC_JALR:   ex_next_pc = alu_y & 32'hffff_fffe;
      DNPC_BRANCH: ex_next_pc = branch_taken ? (pc_q + imm_b) : (pc_q + 4);
      DNPC_TRAP:   ex_next_pc = csr_mtvec;    // ecall -> 异常入口
      DNPC_MRET:   ex_next_pc = csr_mepc;     // mret  -> 异常返回
      default:     ex_next_pc = pc_q + 4;
    endcase
  end

  // 写回数据
  wire [31:0] ex_rf_wd = (wb_sel == WB_PC4) ? (pc_q + 4)
                       : (wb_sel == WB_MEM) ? mem_rdata_sel
                       : (wb_sel == WB_CSR) ? csr_rdata : alu_y;

  // load 数据: 按地址低位选取, 并做符号/零扩展
  logic [31:0] mem_rdata_sel;
  always_comb begin
    unique case (funct3)
      3'b000: mem_rdata_sel = 32'(  signed'(load_word[8*lsu_addr_q[1:0] +: 8]));  // lb
      3'b001: mem_rdata_sel = 32'(  signed'(load_word[16*lsu_addr_q[1] +: 16]));  // lh
      3'b010: mem_rdata_sel = load_word;                                          // lw
      3'b100: mem_rdata_sel = 32'(unsigned'(load_word[8*lsu_addr_q[1:0] +: 8]));  // lbu
      3'b101: mem_rdata_sel = 32'(unsigned'(load_word[16*lsu_addr_q[1] +: 16]));  // lhu
      default: mem_rdata_sel = load_word;
    endcase
  end
  wire [31:0] load_word = lsu_axi.rdata;

  // ------------------------------------------------------------------
  // 写回 / CSR / 异常 (只在指令完成的那个周期生效)
  // ------------------------------------------------------------------
  wire ld_fire = (st == S_LD_R) && lsu_axi.rvalid && lsu_axi.rready;
  wire st_fire = (st == S_ST_B) && lsu_axi.bvalid && lsu_axi.bready;
  wire ex_done = (st == S_EXEC) && !ex_mem_read && !ex_mem_write;

  assign rf_we = (st == S_EXEC) ? ex_rf_we : (st == S_LD_R) ? 1'b1 : 1'b0;
  assign rf_wa = (st == S_LD_R) ? lsu_rd_q : rd;
  assign rf_wd = (st == S_LD_R) ? mem_rdata_sel : ex_rf_wd;

  // CSR 写 / 异常 / mret (在 S_EXEC 周期更新)
  always_ff @(posedge clk) begin
    if (rst) begin
      csr_mstatus <= 32'd0;
      csr_mtvec   <= 32'd0;
      csr_mepc    <= 32'd0;
      csr_mcause  <= 32'd0;
    end
    else if (st == S_EXEC) begin
      if (csr_we) begin
        unique case (csr_waddr)
          CSR_MSTATUS: csr_mstatus <= csr_wdata;
          CSR_MTVEC:   csr_mtvec   <= csr_wdata;
          CSR_MEPC:    csr_mepc    <= csr_wdata;
          CSR_MCAUSE:  csr_mcause  <= csr_wdata;
          default: ;   // mvendorid/marchid 只读, mcycle 由硬件维护
        endcase
      end
      if (ex_ecall) begin
        csr_mcause  <= 32'd11;   // Environment call from M-mode
        csr_mepc    <= pc_q;
        csr_mstatus <= (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                     | (((csr_mstatus & MSTATUS_MIE) != 0) ? MSTATUS_MPIE : 32'd0);
      end
      if (ex_mret) begin
        csr_mstatus <= (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                     | (((csr_mstatus & MSTATUS_MPIE) != 0) ? MSTATUS_MIE : 32'd0)
                     | MSTATUS_MPIE;
      end
    end
  end

  // ------------------------------------------------------------------
  // 主状态机
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      st         <= S_FETCH_AR;
      pc_q       <= PC_INIT;
      inst_q     <= 32'h0000_0013;   // nop (addi x0,x0,0)
      aw_done    <= 1'b0;
      w_done     <= 1'b0;
    end
    else begin
      unique case (st)
        S_FETCH_AR: begin
          // 命中时 icache 当拍就给出数据, 此时只需要 1 个周期
          if (ifu_resp_valid) begin
            inst_q <= ifu_resp_data;
            st     <= S_EXEC;
          end
          else if (ifu_req_valid && ifu_req_ready) st <= S_FETCH_R;
        end
        S_FETCH_R:  if (ifu_resp_valid) begin
          inst_q <= ifu_resp_data;
          st     <= S_EXEC;
        end
        S_EXEC: begin
          if (ex_mem_read) begin
            lsu_addr_q <= ex_lsu_addr;
            lsu_size_q <= ex_mem_size;
            lsu_rd_q   <= rd;
            next_pc_q  <= ex_next_pc;
            st         <= S_LD_AR;
          end
          else if (ex_mem_write) begin
            lsu_addr_q  <= ex_lsu_addr;
            lsu_wdata_q <= ex_lsu_wdata;
            lsu_wstrb_q <= ex_lsu_wstrb;
            lsu_size_q  <= ex_mem_size;
            next_pc_q   <= ex_next_pc;
            aw_done     <= 1'b0;
            w_done      <= 1'b0;
            st          <= S_ST_AW;
          end
          else begin
            pc_q <= ex_next_pc;
            st   <= S_FETCH_AR;
          end
        end
        S_LD_AR: if (lsu_axi.arvalid && lsu_axi.arready) st <= S_LD_R;
        S_LD_R:  if (lsu_axi.rvalid && lsu_axi.rready) begin
          pc_q <= next_pc_q;
          st   <= S_FETCH_AR;
        end
        S_ST_AW: begin
          if (lsu_axi.awready) aw_done <= 1'b1;
          if (lsu_axi.wready)  w_done  <= 1'b1;
          if ((aw_done || lsu_axi.awready) && (w_done || lsu_axi.wready)) begin
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            st      <= S_ST_B;
          end
        end
        S_ST_B: if (lsu_axi.bvalid && lsu_axi.bready) begin
          pc_q <= next_pc_q;
          st   <= S_FETCH_AR;
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // IFU <-> icache (B4 讲义 "简易指令缓存")
  //
  // 取指请求先发给 icache: 命中则很快返回, 缺失则 icache 通过 AXI4 从存储器
  // 读出整个 cache 块再返回。只有存储器类型的地址才会走 cache, 设备访问由
  // icache 直接旁路 (讲义 "适合缓存的地址空间")。
  //
  // 注意: 在 ysyxSoC 中 CPU 的复位会被刻意延迟 10 个周期 (等 ChipLink 初始化),
  // 复位期间不能驱动任何请求, 否则设备会在 CPU 还在复位时就完成一次请求,
  // 之后 CPU 复位结束却等不到第二次握手, 造成死锁。
  // ------------------------------------------------------------------
  logic        ifu_req_valid, ifu_req_ready, ifu_resp_valid, icache_flush;
  logic [31:0] ifu_req_addr, ifu_resp_data;
  logic        ic_hit, ic_miss, ic_bypass;
  logic [31:0] ic_miss_len;

  assign ifu_req_valid = (st == S_FETCH_AR || st == S_FETCH_R) && !rst;
  assign ifu_req_addr  = pc_q;
  assign icache_flush  = ex_fence_i && (st == S_EXEC) && !rst;

  icache #(
    .BLOCK_BYTES (ICACHE_BLOCK),
    .NBLOCKS     (ICACHE_BLOCKS),
    .CACHE_SRAM  (ICACHE_SRAM)
  ) u_icache (
    .clk        (clk),
    .rst        (rst),
    .req_valid  (ifu_req_valid),
    .req_ready  (ifu_req_ready),
    .req_addr   (ifu_req_addr),
    .resp_valid (ifu_resp_valid),
    .resp_data  (ifu_resp_data),
    .flush      (icache_flush),
    .ev_hit     (ic_hit),
    .ev_miss    (ic_miss),
    .ev_bypass  (ic_bypass),
    .miss_len   (ic_miss_len),
    .mem        (ifu_mem)
  );

  // ------------------------------------------------------------------
  // AXI4: LSU (读 + 写)
  //
  // 这里的 arsize 就是讲义里反复强调的"实际数据位宽":
  //   lb/lbu -> 0 (1 字节), lh/lhu -> 1 (2 字节), lw/sw -> 2 (4 字节)
  // 有了它, 设备才能只访问软件真正想要的那一个设备寄存器。
  // ------------------------------------------------------------------
  assign lsu_axi.arid    = 4'd0;
  assign lsu_axi.arlen   = 8'd0;
  assign lsu_axi.arsize  = {1'b0, lsu_size_q};
  assign lsu_axi.arburst = 2'b01;   // INCR
  assign lsu_axi.arvalid = (st == S_LD_AR) && !rst;
  assign lsu_axi.araddr  = lsu_addr_q;
  assign lsu_axi.rready  = (st == S_LD_R) && !rst;

  assign lsu_axi.awid    = 4'd0;
  assign lsu_axi.awlen   = 8'd0;
  assign lsu_axi.awsize  = {1'b0, lsu_size_q};
  assign lsu_axi.awburst = 2'b01;   // INCR
  assign lsu_axi.awvalid = (st == S_ST_AW) && !aw_done && !rst;
  assign lsu_axi.awaddr  = lsu_addr_q;
  assign lsu_axi.wvalid  = (st == S_ST_AW) && !w_done && !rst;
  assign lsu_axi.wdata   = lsu_wdata_q;
  assign lsu_axi.wstrb   = lsu_wstrb_q;
  assign lsu_axi.wlast   = 1'b1;    // 单拍传输
  assign lsu_axi.bready  = (st == S_ST_B) && !rst;

  // ------------------------------------------------------------------
  // 调试端口 (trace / DiffTest)
  // ------------------------------------------------------------------
  assign inst_done = ex_done || ld_fire || st_fire;

  // ------------------------------------------------------------------
  // 通知仿真环境: 一条指令退休 (供 trace 与 DiffTest 使用)
  //
  // 写回发生在时钟沿, 而 gpr_dbg 是组合逻辑读出的寄存器堆, 因此在"退休的
  // 那一刻"组合相里读到的还是旧值。这里把退休事件延迟一拍上报: 下个周期
  // gpr_dbg 已经是写回后的值, 而 pc_q 也正好是下一条指令的 PC。
  // ------------------------------------------------------------------
  logic        retire_d, retire_valid_q;
  logic [31:0] retire_pc_q, retire_inst_q, retire_maddr_q, retire_mdata_q;
  logic        retire_mwe_q, retire_mvalid_q;
  logic [1:0]  retire_msize_q;

  assign retire_d = (ex_done || ld_fire || st_fire) && !rst;

  always_ff @(posedge clk) begin
    retire_valid_q <= retire_d;
    if (retire_d) begin
      retire_pc_q    <= pc_q;
      retire_inst_q  <= inst_q;
      retire_mvalid_q <= ld_fire || st_fire;
      retire_mwe_q   <= st_fire;
      retire_maddr_q <= lsu_addr_q;
      retire_mdata_q <= st_fire ? lsu_wdata_q : mem_rdata_sel;
      retire_msize_q <= lsu_size_q;
    end
  end

  // 用 always_ff 调用 DPI 函数: 保证每次退休只上报一次 (组合逻辑块可能被
  // 反复求值), 而且此时寄存器堆里已经是写回之后的值。
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
        int'(pc_q),                       // 退休后的 PC (下一条指令)
        int'(retire_mvalid_q), int'(retire_mwe_q),
        int'(retire_maddr_q), int'(retire_mdata_q), int'({1'b0, retire_msize_q}));
  end

  assign mem_valid = ld_fire || st_fire;
  assign mem_we    = st_fire;
  assign mem_size  = lsu_size_q;
  assign mem_addr  = lsu_addr_q;
  assign mem_wdata = lsu_wdata_q;
  assign mem_rdata = mem_rdata_sel;

  // ------------------------------------------------------------------
  // 通知仿真环境 (EBREAK = AM nemu_trap; 非法指令 = BAD TRAP)
  // ------------------------------------------------------------------
  always_comb begin
    if (!rst && st == S_EXEC) begin
      if (ex_ebreak) ebreak(int'(gpr_a0));
      else if (ex_invalid) ebreak(-1);
    end
  end

`ifdef NPC_PERF
  // ==================================================================
  // 性能计数器 (B4 讲义 "性能事件和性能计数器")
  //
  // 讲义允许把性能事件通过 DPI-C 接到仿真环境, 或者在仿真结束时用
  // $display() 输出; 并且不要求它们参与流片。这里用 `ifdef NPC_PERF`
  // 包起来: 打开时在仿真结束时打印一行 PERF 统计, 综合时不实例化。
  // ==================================================================
  logic [63:0] pf_cyc, pf_inst, pf_ifu, pf_ifu_stall_req, pf_ifu_stall_mem;
  logic [63:0] pf_ld, pf_st, pf_lsu_cyc, pf_exu;
  logic [63:0] pf_alu, pf_load, pf_store, pf_branch, pf_jump, pf_csr, pf_sys;
  logic [63:0] pf_ic_hit, pf_ic_miss, pf_ic_bypass, pf_ic_miss_cyc;
  // 每类指令各自花费的周期数 (两次 retire 之间的周期数), 用于算"平均执行周期"
  logic [63:0] pf_c_alu, pf_c_load, pf_c_store, pf_c_branch, pf_c_jump, pf_c_csr, pf_c_sys;
  logic [63:0] pf_cyc_last;
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
    end
    else begin
      pf_cyc <= pf_cyc + 64'd1;

      // ---- 前端: 指令供给 ----
      if (ifu_resp_valid)                    pf_ifu <= pf_ifu + 64'd1;   // IFU 取到指令
      // IFU 取不到指令的两类原因:
      //   stall_req: 停在 S_FETCH_AR 还拿不到指令 (icache 正忙/上一个请求未完成)
      //   stall_mem: 请求已发出, 停在 S_FETCH_R 等待回复 (icache 缺失)
      if ((st == S_FETCH_AR) && !ifu_resp_valid) pf_ifu_stall_req <= pf_ifu_stall_req + 64'd1;
      if ((st == S_FETCH_R)  && !ifu_resp_valid) pf_ifu_stall_mem <= pf_ifu_stall_mem + 64'd1;

      // ---- icache ----
      if (ic_hit)    pf_ic_hit  <= pf_ic_hit  + 64'd1;
      if (ic_miss) begin
        pf_ic_miss <= pf_ic_miss + 64'd1;
        pf_ic_miss_cyc <= pf_ic_miss_cyc + {32'd0, ic_miss_len};
      end
      if (ic_bypass) pf_ic_bypass <= pf_ic_bypass + 64'd1;

      // ---- 后端: 数据供给与计算效率 ----
      if (retire_d)  pf_inst <= pf_inst + 64'd1;              // 动态指令数
      if (ld_fire)   pf_ld   <= pf_ld + 64'd1;                // LSU 取到数据
      if (st_fire)   pf_st   <= pf_st + 64'd1;                // LSU 完成写入
      if (st == S_LD_AR || st == S_LD_R) pf_lsu_cyc <= pf_lsu_cyc + 64'd1;
      if (ex_done)   pf_exu  <= pf_exu + 64'd1;               // EXU 完成计算

      // ---- 每条指令花费的周期数 (按所属类别归集) ----
      if (retire_d) begin
        logic [63:0] delta;
        delta = pf_cyc - pf_cyc_last;
        pf_cyc_last <= pf_cyc;
        unique case (opcode)
          7'b0110111, 7'b0010111, 7'b0010011, 7'b0110011: pf_c_alu    <= pf_c_alu    + delta;
          7'b0000011:                                    pf_c_load   <= pf_c_load   + delta;
          7'b0100011:                                    pf_c_store  <= pf_c_store  + delta;
          7'b1100011:                                    pf_c_branch <= pf_c_branch + delta;
          7'b1101111, 7'b1100111:                        pf_c_jump   <= pf_c_jump   + delta;
          7'b1110011: begin
            if (funct3 == 3'b000) pf_c_sys <= pf_c_sys + delta;
            else                  pf_c_csr <= pf_c_csr + delta;
          end
          default: ;
        endcase
      end

      // ---- 指令类别 (在 S_EXEC 译码的那一拍统计) ----
      if (st == S_EXEC && !rst) begin
        unique case (opcode)
          7'b0110111, 7'b0010111, 7'b0010011, 7'b0110011: pf_alu    <= pf_alu    + 64'd1;
          7'b0000011:                                    pf_load   <= pf_load   + 64'd1;
          7'b0100011:                                    pf_store  <= pf_store  + 64'd1;
          7'b1100011:                                    pf_branch <= pf_branch + 64'd1;
          7'b1101111, 7'b1100111:                        pf_jump   <= pf_jump   + 64'd1;
          7'b1110011: begin
            if (funct3 == 3'b000) pf_sys <= pf_sys + 64'd1;
            else                  pf_csr <= pf_csr + 64'd1;
          end
          default: ;   // fence / fence.i 等不计入上述类别
        endcase
      end
    end
  end

  // 退休到 ebreak 时, 延后一拍打印 (那时计数器已经统计到 ebreak 本身),
  // 保证只打印一次。
  always_ff @(posedge clk) begin
    if (rst) begin
      pf_reported <= 1'b0;
      pf_report_pending <= 1'b0;
    end
    else begin
      pf_report_pending <= !pf_reported && (st == S_EXEC) && ex_ebreak;
      if (pf_report_pending) begin
        pf_reported <= 1'b1;
        $display("PERF cyc=%0d inst=%0d ifu=%0d ifu_stall_req=%0d ifu_stall_mem=%0d ld=%0d st=%0d lsu_cyc=%0d exu=%0d alu=%0d load=%0d store=%0d branch=%0d jump=%0d csr=%0d sys=%0d ic_hit=%0d ic_miss=%0d ic_bypass=%0d ic_miss_cyc=%0d c_alu=%0d c_load=%0d c_store=%0d c_branch=%0d c_jump=%0d c_csr=%0d c_sys=%0d",
          pf_cyc, pf_inst, pf_ifu, pf_ifu_stall_req, pf_ifu_stall_mem,
          pf_ld, pf_st, pf_lsu_cyc, pf_exu,
          pf_alu, pf_load, pf_store, pf_branch, pf_jump, pf_csr, pf_sys,
          pf_ic_hit, pf_ic_miss, pf_ic_bypass, pf_ic_miss_cyc,
          pf_c_alu, pf_c_load, pf_c_store, pf_c_branch, pf_c_jump, pf_c_csr, pf_c_sys);
      end
    end
  end
`endif
endmodule
