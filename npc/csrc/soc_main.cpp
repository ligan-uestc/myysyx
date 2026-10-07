// ============================================================================
// ysyxSoC 仿真环境 (B2 SoC 讲义)
//
// 与 B1 的独立仿真环境 (main.cpp) 不同, 这里 verilator 的顶层模块是
// ysyxSoC/build/ysyxSoCFull.v 中的 ysyxSoCFull, 我们的 NPC 只是它内部
// 的一个子模块 (ysyx_22040000)。因此:
//   * 存储器 / UART / 各种外设都由 ysyxSoC 提供, 仿真环境不再实现 pmem;
//   * 只需要为 ysyxSoC 的 MROM 与 flash 颗粒提供内容 (mrom_read/flash_read);
//   * NPC 执行 ebreak 时仍然通过 DPI-C 的 ebreak() 通知本环境结束仿真。
// ============================================================================
#include <verilated.h>
#include "VysyxSoCFull.h"

#include "npc_sim.hpp"   // N_GPR 与 difftest_* (csrc/difftest.cpp)

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// ysyxSoC 的 MROM (0x2000_0000 ~ 0x2000_0fff) 与 flash (0x3000_0000 ~ ...)
// 的内容由本仿真环境提供 (它们通过 DPI-C 的 mrom_read / flash_read 读回)。
// ---------------------------------------------------------------------------
static const uint32_t MROM_SIZE  = 0x1000;         // 4 KiB
static const uint32_t FLASH_SIZE = 16u * 1024 * 1024;

static uint8_t mrom[MROM_SIZE];
static uint8_t flash[FLASH_SIZE];

// 仿真控制
static bool     s_stop    = false;
static int      s_trap    = 0;
static uint64_t s_cycles  = 0;
static uint64_t s_max_cyc = 0;      // 0: 不限

extern "C" void mrom_read(int raddr, int *rdata) {
  uint32_t a = ((uint32_t)raddr) & (MROM_SIZE - 1);
  uint32_t w = 0;
  memcpy(&w, &mrom[a & ~0x3u], sizeof(w));
  *rdata = (int)w;
}

extern "C" void flash_read(int addr, int *data) {
  uint32_t a = ((uint32_t)addr) & (FLASH_SIZE - 1);
  uint32_t w = 0;
  memcpy(&w, &flash[a & ~0x3u], sizeof(w));
  *data = (int)w;
}

// NPC 的 ebreak 指令 (AM 的 nemu_trap) 走这里
extern "C" void ebreak(int code) {
  s_trap = code;
  s_stop = true;
}

// ---------------------------------------------------------------------------
// 指令退休回调 (RTL 通过 DPI-C 调用)
//
// 与独立流程从顶层端口采样不同, ysyxSoCFull 只暴露少量外部引脚, 拿不到 NPC
// 的内部信号, 因此由 RTL 主动上报每条退休指令的 PC、通用寄存器与访存信息。
// ---------------------------------------------------------------------------
static const uint32_t MROM_BASE = 0x20000000u;
static const uint32_t SRAM_BASE = 0x0f000000u;
static const uint32_t SRAM_SIZE = 0x2000u;

static bool     s_retire_pending = false;
static uint32_t s_retire_pc = 0, s_retire_inst = 0, s_retire_next_pc = 0;
static uint32_t s_retire_gpr[N_GPR] = {};
static bool     s_retire_mem_valid = false, s_retire_mem_we = false;
static uint32_t s_retire_maddr = 0, s_retire_mdata = 0, s_retire_msize = 0;

// B4: itrace (只记录 PC, 供 cachesim 做性能测试的 DiffTest)
static std::vector<uint32_t> s_itrace;
static bool                  s_itrace_on = false;

extern "C" void npc_retire(int pc, int inst,
    int x1, int x2, int x3, int x4, int x5, int x6, int x7, int x8,
    int x9, int x10, int x11, int x12, int x13, int x14, int x15,
    int next_pc, int mem_valid, int mem_we,
    int mem_addr, int mem_data, int mem_size) {
  s_retire_gpr[0]  = 0;   // x0 恒为 0
  s_retire_gpr[1]  = (uint32_t)x1;   s_retire_gpr[2]  = (uint32_t)x2;
  s_retire_gpr[3]  = (uint32_t)x3;   s_retire_gpr[4]  = (uint32_t)x4;
  s_retire_gpr[5]  = (uint32_t)x5;   s_retire_gpr[6]  = (uint32_t)x6;
  s_retire_gpr[7]  = (uint32_t)x7;   s_retire_gpr[8]  = (uint32_t)x8;
  s_retire_gpr[9]  = (uint32_t)x9;   s_retire_gpr[10] = (uint32_t)x10;
  s_retire_gpr[11] = (uint32_t)x11;  s_retire_gpr[12] = (uint32_t)x12;
  s_retire_gpr[13] = (uint32_t)x13;  s_retire_gpr[14] = (uint32_t)x14;
  s_retire_gpr[15] = (uint32_t)x15;
  s_retire_pc      = (uint32_t)pc;
  s_retire_inst    = (uint32_t)inst;
  s_retire_next_pc = (uint32_t)next_pc;
  s_retire_mem_valid = mem_valid != 0;
  s_retire_mem_we    = mem_we != 0;
  s_retire_maddr     = (uint32_t)mem_addr;
  s_retire_mdata     = (uint32_t)mem_data;
  s_retire_msize     = (uint32_t)mem_size;
  s_retire_pending   = true;
  // itrace 只记录"程序真正执行过"的指令: ebreak 之后仿真可能还会多跑几个
  // 周期 (为了让 RTL 打印性能计数器), 那些指令不进 itrace。
  // ebreak 本身要记录, 这样 itrace 的长度与 RTL 的动态指令数完全一致。
  if (s_itrace_on && (!s_stop || (uint32_t)inst == 0x00100073u))
    s_itrace.push_back((uint32_t)pc);
}

// 处理一条退休指令: trace 与 DiffTest
static void handle_retire(bool difftest_on, bool verbose, uint64_t *nr_inst) {
  (*nr_inst) ++;
  if (verbose && (*nr_inst <= 40 || s_retire_inst == 0x00100073u)) {
    fprintf(stderr, "[retire] #%llu pc=0x%08x inst=%08x next=0x%08x a0=0x%08x\n",
        (unsigned long long)*nr_inst, s_retire_pc, s_retire_inst,
        s_retire_next_pc, s_retire_gpr[10]);
  }

  if (!difftest_on) return;
  if (s_retire_inst == 0x00100073u) return;   // ebreak 不比对 (见下)

  // 访问设备 (地址不在 MROM/SRAM 内) 的指令无法在 REF 上执行,
  // 采用 skip 策略: 用 DUT 的状态重新同步 REF。
  bool device = s_retire_mem_valid
             && !((s_retire_maddr >= MROM_BASE && s_retire_maddr < MROM_BASE + MROM_SIZE)
               || (s_retire_maddr >= SRAM_BASE && s_retire_maddr < SRAM_BASE + SRAM_SIZE));
  if (device) {
    difftest_sync_regs(s_retire_gpr, s_retire_next_pc);
  }
  else if (!difftest_check(s_retire_gpr, s_retire_next_pc)) {
    s_stop = true;
    s_trap = -2;
  }
}

// NPU 的仿真环境里可能还引用到独立仿真环境的这两个 DPI 函数 (axi_mem.sv),
// 在 SoC 构建里它们没有被实例化, 但为了链接安全这里给出空实现。
extern "C" int  pmem_read(int) { return 0; }
extern "C" void pmem_write(int, int, char) {}

static bool load_file(const char *path, uint8_t *dst, size_t cap, size_t *out_size) {
  FILE *fp = fopen(path, "rb");
  if (fp == nullptr) { perror(path); return false; }
  size_t n = fread(dst, 1, cap, fp);
  fclose(fp);
  if (out_size) *out_size = n;
  return true;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *img = nullptr;
  const char *ref_so = nullptr;
  const char *itrace_path = nullptr;
  uint32_t    img_base = 0x20000000u;   // 镜像在 MROM 中的加载地址
  bool        verbose = false;
  for (int i = 1; i < argc; i ++) {
    if (strcmp(argv[i], "-n") == 0 && i + 1 < argc)      s_max_cyc = strtoull(argv[++i], nullptr, 0);
    else if (strcmp(argv[i], "--mrom") == 0 && i + 1 < argc) img = argv[++i];
    else if ((strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--diff") == 0) && i + 1 < argc)
                                                         ref_so = argv[++i];
    else if (strcmp(argv[i], "-v") == 0)                 verbose = true;
    else if (strcmp(argv[i], "--itrace") == 0 && i + 1 < argc) { itrace_path = argv[++i]; s_itrace_on = true; }
    else if (strcmp(argv[i], "--mrom-base") == 0 && i + 1 < argc) img_base = (uint32_t)strtoul(argv[++i], nullptr, 0);
    else if (argv[i][0] != '-')                          img = argv[i];
  }

  // MROM 默认内容 = 一条 ebreak 指令 (0x00100073) 反复填充。
  // 这样即使没有加载任何程序, NPC 从 MROM 取到的第一条指令就是 ebreak,
  // 仿真会立刻结束 —— 这正是讲义"测试MROM的访问"要做的检查。
  for (uint32_t i = 0; i < MROM_SIZE; i += 4) {
    mrom[i + 0] = 0x73; mrom[i + 1] = 0x00; mrom[i + 2] = 0x10; mrom[i + 3] = 0x00;
  }

  if (img != nullptr) {
    size_t n = 0;
    uint32_t off = (img_base - MROM_BASE) & (MROM_SIZE - 1);
    if (!load_file(img, mrom + off, MROM_SIZE - off, &n)) return 1;
    printf("[soc] MROM <- %s @ 0x%08x (%zu bytes)\n", img, img_base, n);
  }

  VysyxSoCFull *dut = new VysyxSoCFull;

  // ysyxSoC 要求复位至少维持若干周期 (ChipLink 打开时需要 10 个周期以上)
  dut->clock = 0;
  dut->reset = 1;
  dut->externalPins_gpio_in  = 0;
  dut->externalPins_ps2_clk  = 1;
  dut->externalPins_ps2_data = 1;
  dut->externalPins_uart_rx  = 1;
  for (int i = 0; i < 20; i ++) { dut->clock = 0; dut->eval(); dut->clock = 1; dut->eval(); }
  dut->reset = 0;

  // ---- DiffTest: 把 REF 初始化成与 DUT 复位后一致的状态 ----
  bool difftest_on = false;
  if (ref_so != nullptr) {
    if (!difftest_init(ref_so)) return 1;
    uint32_t init_gpr[N_GPR] = {};
    difftest_sync_mem(MROM_BASE, mrom, MROM_SIZE);   // 把 MROM 内容同步给 NEMU
    difftest_sync_regs(init_gpr, MROM_BASE);         // 初始 PC = 0x2000_0000
    difftest_on = true;
    printf("[soc] DiffTest enabled with %s\n", ref_so);
  }

  uint64_t nr_inst = 0;
  while (!Verilated::gotFinish() && !s_stop) {
    dut->clock = 0; dut->eval();
    dut->clock = 1; dut->eval();
    if (s_retire_pending) { s_retire_pending = false; handle_retire(difftest_on, verbose, &nr_inst); }
    s_cycles ++;
    if (s_max_cyc != 0 && s_cycles >= s_max_cyc) break;
    if (s_cycles % (1ull << 30) == 0) fprintf(stderr, "[soc] %llu cycles\n", (unsigned long long)s_cycles);
  }

  // 多跑几个周期: 让 RTL 有机会把性能计数器打印出来 (它在 halt 后一拍输出)
  for (int i = 0; i < 4; i ++) { dut->clock = 0; dut->eval(); dut->clock = 1; dut->eval(); }
  dut->final();

  if (itrace_path != nullptr) {
    FILE *fp = fopen(itrace_path, "w");
    if (fp != nullptr) {
      for (uint32_t pc : s_itrace) fprintf(fp, "%08x\n", pc);
      fclose(fp);
      fprintf(stderr, "[soc] itrace -> %s (%zu entries)\n", itrace_path, s_itrace.size());
    }
  }

  if (s_stop) printf("\n[soc] NPC halted with code %d after %llu cycles (%llu instructions)\n",
                     s_trap, (unsigned long long)s_cycles, (unsigned long long)nr_inst);
  else        printf("\n[soc] simulation ended after %llu cycles\n", (unsigned long long)s_cycles);
  delete dut;
  return s_stop ? (s_trap & 0xff) : 0;
}
