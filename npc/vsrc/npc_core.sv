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

module npc_core #(
  parameter logic [31:0] PC_INIT = 32'h8000_0000
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
  // ---- AXI4-Lite master ----
  axi4lite_if.master  ifu_axi,     // 取指
  axi4lite_if.master  lsu_axi,     // 访存
  output logic [2:0]  state_dbg    // (调试) 状态机
);
  import "DPI-C" function void ebreak(input int code);

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
      7'b0001111: begin                       // fence: nop
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
        S_FETCH_AR: if (ifu_axi.arvalid && ifu_axi.arready) st <= S_FETCH_R;
        S_FETCH_R:  if (ifu_axi.rvalid && ifu_axi.rready) begin
          inst_q <= ifu_axi.rdata;
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
  // AXI4-Lite: IFU (只读)
  // ------------------------------------------------------------------
  assign ifu_axi.arvalid = (st == S_FETCH_AR);
  assign ifu_axi.araddr  = pc_q;
  assign ifu_axi.rready  = (st == S_FETCH_R);
  // IFU 不写存储器, 写通道全部置 0 (讲义要求)
  assign ifu_axi.awvalid = 1'b0;
  assign ifu_axi.awaddr  = 32'b0;
  assign ifu_axi.wvalid  = 1'b0;
  assign ifu_axi.wdata   = 32'b0;
  assign ifu_axi.wstrb   = 4'b0;
  assign ifu_axi.bready  = 1'b0;

  // ------------------------------------------------------------------
  // AXI4-Lite: LSU (读 + 写)
  // ------------------------------------------------------------------
  assign lsu_axi.arvalid = (st == S_LD_AR);
  assign lsu_axi.araddr  = lsu_addr_q;
  assign lsu_axi.rready  = (st == S_LD_R);

  assign lsu_axi.awvalid = (st == S_ST_AW) && !aw_done;
  assign lsu_axi.awaddr  = lsu_addr_q;
  assign lsu_axi.wvalid  = (st == S_ST_AW) && !w_done;
  assign lsu_axi.wdata   = lsu_wdata_q;
  assign lsu_axi.wstrb   = lsu_wstrb_q;
  assign lsu_axi.bready  = (st == S_ST_B);

  // ------------------------------------------------------------------
  // 调试端口 (trace / DiffTest)
  // ------------------------------------------------------------------
  assign inst_done = ex_done || ld_fire || st_fire;
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
endmodule
