// ============================================================================
// NPC simulation environment (C2 lecture: 支持RV32E的单周期NPC)
//
//   * physical memory model (see memory.cpp)
//   * DPI-C plumbing between the RTL and the memory model
//   * single-step / sdb (see sdb.cpp)
//   * itrace / mtrace / ftrace (see trace.cpp)
//   * Differential Testing against NEMU (see difftest.cpp)
//
// Usage: npc [OPTION]... IMAGE
//   -b, --batch          run until the program stops (no sdb)
//   -l, --log=FILE       write trace output to FILE (default: stdout)
//   -e, --elf=FILE       ELF image, needed by ftrace
//   -d, --diff=REF_SO    enable DiffTest with the NEMU shared library REF_SO
//   -t, --trace          enable itrace + mtrace + ftrace
//   -i, --itrace         enable instruction trace
//   -m, --mtrace         enable memory access trace
//   -f, --ftrace         enable function call trace
//   -n, --max-inst=N     stop after N instructions (default 100000000)
//   -h, --help           print this message
// ============================================================================
#include <verilated.h>
#include "Vtop.h"

#include "npc_sim.hpp"

#include <getopt.h>

static Vtop     top;
static uint64_t g_nr_inst = 0;
static bool     g_print_step = false;
static uint64_t g_max_inst = 100000000ull;

// ---------------------------------------------------------------------------
// simulation control
// ---------------------------------------------------------------------------
static void collect_gpr(uint32_t *out) {
  for (int i = 0; i < N_GPR; i ++) { out[i] = (uint32_t)top.gpr_dbg[i]; }
}

void sim_reset(int n) {
  top.rst = 1;
  while (n -- > 0) {
    top.clk = 0; top.eval();
    top.clk = 1; top.eval();
  }
  top.rst = 0;
  top.clk = 0; top.eval();   // settle the first instruction
}

void sim_step() {
  // 1) combinational phase: the instruction at the current PC is decoded
  //    (the RTL fetches it from the DPI-C memory), and load/store + ebreak
  //    are evaluated.
  top.clk = 0;
  top.eval();

  uint32_t pc    = (uint32_t)top.pc;
  uint32_t inst  = (uint32_t)top.inst;
  bool     mv    = top.mem_valid;
  bool     mwe   = top.mem_we;
  uint32_t maddr = (uint32_t)top.mem_addr;
  uint32_t mdata = mwe ? (uint32_t)top.mem_wdata : (uint32_t)top.mem_rdata;
  uint32_t msize = (uint32_t)top.mem_size;

  if (g_print_step) {
    std::string text = trace_disasm(pc, inst);
    printf("0x%08x: %08x  %s\n", pc, inst, text.c_str());
  }

  // 2) clock edge: commit (PC / GPR update)
  top.clk = 1;
  top.eval();
  g_nr_inst ++;
  uint32_t next_pc = (uint32_t)top.pc;

  // 3) observe the retired instruction (itrace/mtrace/ftrace)
  trace_observe(pc, inst, next_pc, mv, mwe, maddr, mdata, msize);

  // 4) Differential Testing
  //    * 最后一条 ebreak 不比对: NPC 在 ebreak 处冻结 PC, 而 NEMU 的
  //      nemu_trap 会把 PC 置为 pc+4, 两者约定不同;
  //    * 访问设备的指令 (地址不在 REF 的内存范围内, 例如串口输出) 无法在
  //      REF 上执行, 采用 skip 策略: 用 DUT 的状态重新同步 REF
  //      (与 NEMU difftest_skip_ref() 的思路一致)。
  if (inst != EBREAK_INST) {
    uint32_t gpr[N_GPR];
    collect_gpr(gpr);
    bool is_device_access = mv && (maddr < PMEM_BASE || maddr >= PMEM_BASE + PMEM_SIZE);
    if (is_device_access) {
      difftest_sync_regs(gpr, next_pc);
    }
    else if (!difftest_check(gpr, next_pc)) {
      npc_stop(-2);   // difftest mismatch
    }
  }
}

void sim_run(long n) {
  g_print_step = (n >= 0 && n < 10);
  while (!npc_stopped() && n != 0 && g_nr_inst < g_max_inst) {
    sim_step();
    if (n > 0) { n --; }
  }
  g_print_step = false;
}

uint32_t sim_pc()         { return (uint32_t)top.pc; }
uint32_t sim_inst()       { return (uint32_t)top.inst; }
uint32_t sim_gpr(int i)   { return (uint32_t)top.gpr_dbg[i]; }
uint64_t sim_inst_count() { return g_nr_inst; }
void     sim_set_print_step(bool on) { g_print_step = on; }
void     sim_set_max_inst(uint64_t n) { g_max_inst = n; }

void sim_report_result() {
  if (!npc_stopped()) {
    printf("nemu: TIME OUT after %llu instructions\n",
        (unsigned long long)g_nr_inst);
    return;
  }
  int code = npc_trap_code();
  if (code == -2) {
    printf("nemu: HIT BAD TRAP (DiffTest mismatch) at pc = 0x%08x, inst = %llu\n",
        sim_pc(), (unsigned long long)g_nr_inst);
  }
  else if (code == 0) {
    printf("nemu: HIT GOOD TRAP at pc = 0x%08x, inst = %llu\n",
        sim_pc(), (unsigned long long)g_nr_inst);
  }
  else {
    printf("nemu: HIT BAD TRAP (code = %d) at pc = 0x%08x, inst = %llu\n",
        code, sim_pc(), (unsigned long long)g_nr_inst);
  }
}

// ---------------------------------------------------------------------------
// command line
// ---------------------------------------------------------------------------
static void usage(const char *argv0) {
  printf("Usage: %s [OPTION]... IMAGE\n\n", argv0);
  printf("\t-b, --batch          run until the program stops (no sdb)\n");
  printf("\t-l, --log=FILE       write trace output to FILE (default stdout)\n");
  printf("\t-e, --elf=FILE       ELF image (needed by ftrace)\n");
  printf("\t-d, --diff=REF_SO    enable DiffTest with NEMU shared library REF_SO\n");
  printf("\t-t, --trace          enable itrace + mtrace + ftrace\n");
  printf("\t-i, --itrace         enable instruction trace\n");
  printf("\t-m, --mtrace         enable memory access trace\n");
  printf("\t-f, --ftrace         enable function trace\n");
  printf("\t-n, --max-inst=N     stop after N instructions\n");
  printf("\t-h, --help           print this message\n");
}

int main(int argc, char *argv[]) {
  bool batch = false, itrace = false, mtrace = false, ftrace = false;
  const char *log_file = nullptr, *elf_file = nullptr, *ref_so = nullptr;
  const char *img_file = nullptr;
  uint64_t max_inst = 100000000ull;

  static const struct option table[] = {
    {"batch"   , no_argument      , nullptr, 'b'},
    {"log"     , required_argument, nullptr, 'l'},
    {"elf"     , required_argument, nullptr, 'e'},
    {"diff"    , required_argument, nullptr, 'd'},
    {"trace"   , no_argument      , nullptr, 't'},
    {"itrace"  , no_argument      , nullptr, 'i'},
    {"mtrace"  , no_argument      , nullptr, 'm'},
    {"ftrace"  , no_argument      , nullptr, 'f'},
    {"max-inst", required_argument, nullptr, 'n'},
    {"help"    , no_argument      , nullptr, 'h'},
    {nullptr   , 0                , nullptr,  0 },
  };

  int o;
  while ((o = getopt_long(argc, argv, "-bl:e:d:timfn:h", table, nullptr)) != -1) {
    switch (o) {
      case 'b': batch = true; break;
      case 'l': log_file = optarg; break;
      case 'e': elf_file = optarg; break;
      case 'd': ref_so = optarg; break;
      case 't': itrace = mtrace = ftrace = true; break;
      case 'i': itrace = true; break;
      case 'm': mtrace = true; break;
      case 'f': ftrace = true; break;
      case 'n': max_inst = strtoull(optarg, nullptr, 0); break;
      case 1: img_file = optarg; break;
      default: usage(argv[0]); return 0;
    }
  }
  if (img_file == nullptr) { usage(argv[0]); return 1; }

  // ---- load the program image into the physical memory ----
  size_t img_size = 0;
  npc_load_image(img_file, &img_size);
  printf("Load image: %s (%zu bytes)\n", img_file, img_size);

  sim_set_max_inst(max_inst);
  sim_reset(4);

  // ---- trace ----
  FILE *log_fp = stdout;
  if (log_file != nullptr) {
    log_fp = fopen(log_file, "w");
    if (log_fp == nullptr) { perror("open log"); return 1; }
  }
  trace_init(log_fp, itrace, mtrace, ftrace, elf_file);

  // ---- DiffTest ----
  if (ref_so != nullptr) {
    if (!difftest_init(ref_so)) { return 1; }
    difftest_sync_mem(PMEM_BASE, npc_pmem_ptr(), img_size);
    uint32_t gpr[N_GPR];
    collect_gpr(gpr);
    difftest_sync_regs(gpr, sim_pc());
    printf("DiffTest: DUT = NPC, REF = %s\n", ref_so);
  }

  // ---- run ----
  if (batch) {
    sim_run(-1);
    sim_report_result();
  }
  else {
    sdb_mainloop();
  }
  if (log_fp != stdout && log_fp != nullptr) { fclose(log_fp); }
  return (npc_stopped() && npc_trap_code() == 0) ? 0 : 1;
}
