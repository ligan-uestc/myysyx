// ============================================================================
// Single-cycle NPC supporting RV32E (C2 lecture: 支持RV32E的单周期NPC)
//
// ISA: RV32E = RV32I base integer instructions with 16 GPRs.
//      lui auipc jal jalr
//      beq bne blt bge bltu bgeu
//      lb lh lw lbu lhu   sb sh sw
//      addi slti sltiu xori ori andi slli srli srai
//      add sub sll slt sltu xor srl sra or and
//      fence (nop), ecall (nop), ebreak (AM nemu_trap)
//
// The datapath follows the modular organization suggested by the lecture:
//   IFU - program counter + instruction fetch (DPI-C memory)
//   IDU - instruction decode / immediate generation
//   EXU - ALU (see alu.sv)
//   LSU - load / store through DPI-C (aligned word bus + byte write mask)
//   WBU - write-back mux
//   GPR - register file (see regfile.sv, x0 hardwired to 0)
//
// Debug ports exposed to the simulation environment:
//   pc/inst            - itrace, ftrace, DiffTest
//   gpr_dbg            - sdb `info r`, DiffTest
//   mem_* (one cycle)  - mtrace
// ============================================================================
`include "alu_ops.svh"

module npc_core #(
  parameter logic [31:0] PC_INIT = 32'h8000_0000  // npc memory base
) (
  input  logic clk,
  input  logic rst,
  output logic [31:0] pc,
  output logic [31:0] inst,
  output logic [512-1:0] gpr_dbg,
  output logic        mem_valid,
  output logic        mem_we,
  output logic [1:0]  mem_size,   // 0: 1 byte, 1: 2 bytes, 2: 4 bytes
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata
);
  // ---- DPI-C interfaces to the C++ simulation environment ----
  import "DPI-C" function int  pmem_read(input int raddr);
  import "DPI-C" function void pmem_write(input int waddr, input int wdata, input byte wmask);
  import "DPI-C" function void ebreak(input int code);

  // write-back source / next-pc source
  localparam logic [1:0] WB_ALU   = 2'd0, WB_MEM = 2'd1, WB_PC4 = 2'd2;
  localparam logic [1:0] DNPC_PC4 = 2'd0, DNPC_JAL = 2'd1,
                         DNPC_JALR = 2'd2, DNPC_BRANCH = 2'd3;

  // ------------------------------------------------------------------
  // IFU: program counter + instruction fetch
  // ------------------------------------------------------------------
  logic [31:0] next_pc;
  logic        is_ebreak;

  always_comb inst = 32'(pmem_read(int'(pc)));

  always_ff @(posedge clk) begin
    if (rst) pc <= PC_INIT;
    else if (!is_ebreak) pc <= next_pc;   // freeze on ebreak (nemu_trap)
  end

  // ------------------------------------------------------------------
  // IDU: instruction fields and immediates
  // ------------------------------------------------------------------
  wire [6:0] opcode = inst[6:0];
  wire [3:0] rd     = inst[10:7];        // RV32E: only x0-x15 exist (bit 11 unused)
  wire [2:0] funct3 = inst[14:12];
  wire [3:0] rs1    = inst[18:15];       // RV32E: bit 19 unused
  wire [3:0] rs2    = inst[23:20];       // RV32E: bit 24 unused

  wire [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
  wire [31:0] imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
  wire [31:0] imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
  wire [31:0] imm_u = {inst[31:12], 12'b0};
  wire [31:0] imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

  // ------------------------------------------------------------------
  // GPR: 16 x 32 (RV32E), x0 hardwired to 0
  // ------------------------------------------------------------------
  logic [31:0] rv1, rv2, gpr_a0;
  logic        rf_we;
  logic [3:0]  rf_wa;
  logic [31:0] rf_wd;

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
    .raddr3 (4'd10),        // $a0 = x10, read for ebreak
    .rdata3 (gpr_a0),
    .dbg    (gpr_dbg)
  );

  // ------------------------------------------------------------------
  // IDU/EXU: decode + ALU control
  // ------------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_y;
  logic [3:0]  alu_op;
  logic [1:0]  wb_sel, dnpc_sel;
  logic        mem_read, mem_write;
  logic [1:0]  mem_sz;
  logic        is_invalid;
  logic        branch_taken;

  alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

  always_comb begin
    // defaults
    rf_we      = 1'b0;
    rf_wa      = rd;
    alu_a      = rv1;
    alu_b      = imm_i;
    alu_op     = `ALU_ADD;
    wb_sel     = WB_ALU;
    dnpc_sel   = DNPC_PC4;
    mem_read   = 1'b0;
    mem_write  = 1'b0;
    mem_sz     = 2'd2;
    is_invalid = 1'b0;

    if (!rst) begin
      case (opcode)
        7'b0110111: begin                       // lui
          rf_we  = 1'b1;
          alu_a  = 32'b0;
          alu_b  = imm_u;
        end
        7'b0010111: begin                       // auipc
          rf_we  = 1'b1;
          alu_a  = pc;
          alu_b  = imm_u;
        end
        7'b1101111: begin                       // jal
          rf_we    = 1'b1;
          alu_a    = pc;
          alu_b    = imm_j;
          wb_sel   = WB_PC4;
          dnpc_sel = DNPC_JAL;
        end
        7'b1100111: begin                       // jalr
          if (funct3 == 3'b000) begin
            rf_we    = 1'b1;
            alu_a    = rv1;
            alu_b    = imm_i;
            wb_sel   = WB_PC4;
            dnpc_sel = DNPC_JALR;
          end
          else is_invalid = 1'b1;
        end
        7'b1100011: begin                       // branches
          alu_a    = rv1;
          alu_b    = rv2;
          alu_op   = `ALU_SUB;                  // comparison base
          dnpc_sel = DNPC_BRANCH;
          if (funct3 == 3'b010 || funct3 == 3'b011) is_invalid = 1'b1;
        end
        7'b0000011: begin                       // loads
          alu_a = rv1;
          alu_b = imm_i;
          case (funct3)
            3'b000: begin rf_we = 1'b1; mem_read = 1'b1; mem_sz = 2'd0; wb_sel = WB_MEM; end // lb
            3'b001: begin rf_we = 1'b1; mem_read = 1'b1; mem_sz = 2'd1; wb_sel = WB_MEM; end // lh
            3'b010: begin rf_we = 1'b1; mem_read = 1'b1; mem_sz = 2'd2; wb_sel = WB_MEM; end // lw
            3'b100: begin rf_we = 1'b1; mem_read = 1'b1; mem_sz = 2'd0; wb_sel = WB_MEM; end // lbu
            3'b101: begin rf_we = 1'b1; mem_read = 1'b1; mem_sz = 2'd1; wb_sel = WB_MEM; end // lhu
            default: is_invalid = 1'b1;
          endcase
        end
        7'b0100011: begin                       // stores
          alu_a = rv1;
          alu_b = imm_s;
          case (funct3)
            3'b000: begin mem_write = 1'b1; mem_sz = 2'd0; end // sb
            3'b001: begin mem_write = 1'b1; mem_sz = 2'd1; end // sh
            3'b010: begin mem_write = 1'b1; mem_sz = 2'd2; end // sw
            default: is_invalid = 1'b1;
          endcase
        end
        7'b0010011: begin                       // OP-IMM
          rf_we = 1'b1;
          alu_a = rv1;
          alu_b = imm_i;
          case (funct3)
            3'b000: alu_op = `ALU_ADD;
            3'b010: alu_op = `ALU_SLT;
            3'b011: alu_op = `ALU_SLTU;
            3'b100: alu_op = `ALU_XOR;
            3'b110: alu_op = `ALU_OR;
            3'b111: alu_op = `ALU_AND;
            3'b001: begin alu_op = `ALU_SLL; alu_b = {27'b0, inst[24:20]}; end
            3'b101: begin
              alu_b  = {27'b0, inst[24:20]};
              alu_op = inst[30] ? `ALU_SRA : `ALU_SRL;
            end
            default: is_invalid = 1'b1;
          endcase
        end
        7'b0110011: begin                       // OP
          rf_we = 1'b1;
          alu_a = rv1;
          alu_b = rv2;
          case (funct3)
            3'b000: alu_op = inst[30] ? `ALU_SUB : `ALU_ADD;
            3'b001: alu_op = `ALU_SLL;
            3'b010: alu_op = `ALU_SLT;
            3'b011: alu_op = `ALU_SLTU;
            3'b100: alu_op = `ALU_XOR;
            3'b101: alu_op = inst[30] ? `ALU_SRA : `ALU_SRL;
            3'b110: alu_op = `ALU_OR;
            3'b111: alu_op = `ALU_AND;
          endcase
        end
        7'b0001111: begin                       // fence: no-op in this simple NPC
        end
        7'b1110011: begin
          if (inst == 32'h0010_0073) is_ebreak = 1'b1;        // ebreak = nemu_trap
          else if (inst != 32'h0000_0073) is_invalid = 1'b1;  // ecall: no-op (no CSR yet)
        end
        default: is_invalid = 1'b1;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Branch comparator (beq/bne/blt/bge/bltu/bgeu)
  // ------------------------------------------------------------------
  always_comb begin
    branch_taken = 1'b0;
    if (!rst && opcode == 7'b1100011) begin
      case (funct3)
        3'b000: branch_taken = (rv1 == rv2);
        3'b001: branch_taken = (rv1 != rv2);
        3'b100: branch_taken = ($signed(rv1) <  $signed(rv2));
        3'b101: branch_taken = !($signed(rv1) < $signed(rv2));
        3'b110: branch_taken = (rv1 < rv2);
        3'b111: branch_taken = !(rv1 < rv2);
        default: branch_taken = 1'b0;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // LSU: load/store through the DPI-C word bus
  // ------------------------------------------------------------------
  logic [31:0] mem_wword;   // lane-aligned write data
  logic [7:0]  mem_wstrb;   // byte write mask

  always_comb begin
    mem_addr  = alu_y;
    mem_we    = mem_write;
    mem_valid = mem_read | mem_write;
    mem_size  = mem_sz;
    mem_wdata = rv2;
    mem_rdata = 32'b0;
    mem_wword = 32'b0;
    mem_wstrb = 8'b0;

    if (!rst) begin
      if (mem_read) begin
        mem_wword = 32'(pmem_read(int'(alu_y)));
        case (funct3)
          3'b000: mem_rdata = 32'(  signed'(mem_wword[8*alu_y[1:0] +: 8]));  // lb
          3'b001: mem_rdata = 32'(  signed'(mem_wword[16*alu_y[1] +: 16]));  // lh
          3'b010: mem_rdata = mem_wword;                                     // lw
          3'b100: mem_rdata = 32'(unsigned'(mem_wword[8*alu_y[1:0] +: 8]));  // lbu
          3'b101: mem_rdata = 32'(unsigned'(mem_wword[16*alu_y[1] +: 16]));  // lhu
          default: mem_rdata = 32'b0;
        endcase
      end
      if (mem_write) begin
        case (mem_sz)
          2'd0: begin  // sb
            mem_wword = rv2 << (8 * alu_y[1:0]);
            mem_wstrb = 8'h01 << alu_y[1:0];
          end
          2'd1: begin  // sh
            mem_wword = alu_y[1] ? (rv2 << 16) : rv2;
            mem_wstrb = alu_y[1] ? 8'h0c : 8'h03;
          end
          default: begin  // sw
            mem_wword = rv2;
            mem_wstrb = 8'h0f;
          end
        endcase
        mem_wdata = mem_wword;
        pmem_write(int'(alu_y), int'(mem_wword), byte'(mem_wstrb));
      end
    end
  end

  // ------------------------------------------------------------------
  // WBU: write-back mux
  // ------------------------------------------------------------------
  always_comb begin
    case (wb_sel)
      WB_PC4:  rf_wd = pc + 4;
      WB_MEM:  rf_wd = mem_rdata;
      default: rf_wd = alu_y;
    endcase
  end

  // ------------------------------------------------------------------
  // Next PC
  // ------------------------------------------------------------------
  always_comb begin
    case (dnpc_sel)
      DNPC_JAL:    next_pc = pc + imm_j;
      DNPC_JALR:   next_pc = alu_y & 32'hffff_fffe;
      DNPC_BRANCH: next_pc = branch_taken ? (pc + imm_b) : (pc + 4);
      default:     next_pc = pc + 4;
    endcase
  end

  // ------------------------------------------------------------------
  // Notify the simulation environment
  // ------------------------------------------------------------------
  always_comb begin
    if (!rst) begin
      if (is_ebreak) ebreak(int'(gpr_a0));      // $a0 = exit code (AM convention)
      else if (is_invalid) ebreak(-1);          // illegal / unimplemented encoding
    end
  end
endmodule
