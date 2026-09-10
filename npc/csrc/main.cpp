// ============================================================================
// NPC simulation environment (D4: 用RTL实现迷你RISC-V处理器)
//
// The physical memory is modeled here in C++:
//   * an image (.bin) is loaded at guest address 0x80000000;
//   * pmem_read()/pmem_write() simulate an aligned 32-bit memory bus and are
//     called from RTL through DPI-C;
//   * ebreak() is called by RTL when the guest executes the AM nemu_trap,
//     which terminates simulation with the $a0 exit code.
// ============================================================================
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cinttypes>

#include <verilated.h>
#include "Vtop.h"

static const uint32_t PMEM_BASE = 0x80000000u;
static const uint32_t PMEM_SIZE = 128u * 1024u * 1024u;  // 128 MiB
static uint8_t pmem[PMEM_SIZE];                          // zero-initialized

static Vtop top;                                         // the DUT
static bool stop_sim = false;
static int  trap_code = 0;
static uint64_t n_inst = 0;

static const char *reg_names[16] = {
  "zero","ra","sp","gp","tp","t0","t1","t2",
  "s0","s1","a0","a1","a2","a3","a4","a5"
};

static void dump_gpr(uint32_t pc_now, uint32_t insn) {
  printf("pc = 0x%08x inst = 0x%08x |", pc_now, insn);
  for (int i = 0; i < 16; i++) {
    printf(" %s=0x%08x", reg_names[i], (uint32_t)top.gpr_dbg[i]);
  }
  printf("\n");
}

static inline uint32_t pmem_offset(uint32_t addr) {
  return (addr - PMEM_BASE) & (PMEM_SIZE - 1);           // PMEM_SIZE is 2^27
}

// ---- DPI-C functions imported by npc_core.sv --------------------------------

extern "C" int pmem_read(int raddr) {
  uint32_t addr = (uint32_t)raddr;
  uint32_t off  = pmem_offset(addr & ~0x3u);             // aligned 4-byte read
  uint32_t data;
  memcpy(&data, &pmem[off], sizeof(data));
  return (int)data;
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
  uint32_t addr = (uint32_t)waddr;
  uint32_t off  = pmem_offset(addr & ~0x3u);             // aligned 4-byte write
  uint8_t  mask = (uint8_t)wmask;
  for (int i = 0; i < 4; i++) {
    if ((mask >> i) & 1) {
      pmem[off + i] = (uint8_t)(((uint32_t)wdata) >> (8 * i));
    }
  }
}

extern "C" void ebreak(int code) {
  trap_code = code;
  stop_sim  = true;
}

// ---- Simulation driver ------------------------------------------------------

static void single_cycle() {
  top.clk = 0;
  top.eval();
  top.clk = 1;
  top.eval();
  n_inst++;
}

static void reset(int n) {
  top.rst = 1;
  while (n-- > 0) single_cycle();
  top.rst = 0;
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s IMAGE.bin\n", argv[0]);
    return 1;
  }

  uint64_t max_inst = 100000000ull;
  if (argc >= 3) max_inst = strtoull(argv[2], NULL, 10);
  const char *trace = getenv("NPC_TRACE");

  FILE *fp = fopen(argv[1], "rb");
  if (fp == NULL) {
    perror("open image");
    return 1;
  }
  size_t img_size = fread(pmem, 1, PMEM_SIZE, fp);
  fclose(fp);
  if (img_size == 0) {
    fprintf(stderr, "empty image\n");
    return 1;
  }
  printf("Load image: %s (%zu bytes)\n", argv[1], img_size);

  reset(4);

  while (!stop_sim && n_inst < max_inst) {
    if (trace && n_inst < 400) {
      uint32_t pc_now = (uint32_t)top.pc;
      uint32_t insn = (uint32_t)pmem_read((int)pc_now);
      dump_gpr(pc_now, insn);
      if (pc_now == 0x8000009c) {
        for (uint32_t a = 0x80050fb0; a < 0x80050fe0; a += 4) {
          printf("    mem[0x%08x] = 0x%08x\n", a,
                 (uint32_t)pmem_read((int)a));
        }
      }
    }
    single_cycle();
  }

  if (!stop_sim) {
    printf("nemu: TIME OUT after %" PRIu64 " instructions\n", n_inst);
    return 1;
  }

  if (trap_code == 0) {
    printf("nemu: HIT GOOD TRAP at pc = 0x%08x, inst = %" PRIu64 "\n",
           (uint32_t)top.pc, n_inst);
  } else {
    printf("nemu: HIT BAD TRAP (code = %d) at pc = 0x%08x, inst = %" PRIu64 "\n",
           trap_code, (uint32_t)top.pc, n_inst);
  }

  return trap_code == 0 ? 0 : 1;
}
