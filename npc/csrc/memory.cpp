// Physical memory model of the NPC simulation environment.
//
// The RTL accesses this memory through DPI-C:
//   * pmem_read(addr)          -> aligned 32-bit word
//   * pmem_write(addr, data, wmask) -> 4-byte lane with a per-byte write mask
// ebreak() is called by the RTL when the guest executes the AM nemu_trap.
#include "npc_sim.hpp"

#include <cstring>

static uint8_t pmem[PMEM_SIZE];
static bool    s_stop = false;
static int     s_trap = 0;

// 简化的串口设备: AM 的 putch() 往这个地址写一个字节, 仿真环境把它打到 stdout.
// 地址与 NEMU 的 SERIAL_PORT 保持一致, 方便复用同一套 AM 代码.
static const uint32_t SERIAL_ADDR = 0xa00003f8u;

static inline uint32_t pmem_off(uint32_t addr) {
  return (addr - PMEM_BASE) & (PMEM_SIZE - 1);
}

extern "C" int pmem_read(int raddr) {
  uint32_t raw = (uint32_t)raddr;
  if (raw == SERIAL_ADDR) { return 0; }   // 串口只写
  uint32_t addr = raw & ~0x3u;
  uint32_t data;
  memcpy(&data, &pmem[pmem_off(addr)], sizeof(data));
  return (int)data;
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
  uint32_t raw = (uint32_t)waddr;
  if (raw == SERIAL_ADDR) {
    putchar((int)((uint32_t)wdata & 0xffu));
    fflush(stdout);
    return;
  }
  uint32_t addr = raw & ~0x3u;
  uint32_t off  = pmem_off(addr);
  uint8_t  mask = (uint8_t)wmask;
  for (int i = 0; i < 4; i ++) {
    if ((mask >> i) & 1) {
      pmem[off + i] = (uint8_t)(((uint32_t)wdata) >> (8 * i));
    }
  }
}

extern "C" void ebreak(int code) {
  s_trap = code;
  s_stop = true;
}

void npc_load_image(const char *path, size_t *size) {
  FILE *fp = fopen(path, "rb");
  if (fp == nullptr) {
    perror("open image");
    exit(1);
  }
  *size = fread(pmem, 1, PMEM_SIZE, fp);
  fclose(fp);
  if (*size == 0) {
    fprintf(stderr, "error: empty image '%s'\n", path);
    exit(1);
  }
}

uint32_t npc_pmem_read(uint32_t addr, int len) {
  uint32_t off  = pmem_off(addr & ~0x3u);
  uint32_t word;
  memcpy(&word, &pmem[off], sizeof(word));
  switch (len) {
    case 1: return (word >> (8 * (addr & 3))) & 0xffu;
    case 2: return (word >> (8 * (addr & 2))) & 0xffffu;
    default: return word;
  }
}

bool npc_stopped()      { return s_stop; }
void npc_stop(int code) { s_trap = code; s_stop = true; }
int  npc_trap_code()    { return s_trap; }
const uint8_t *npc_pmem_ptr() { return pmem; }
