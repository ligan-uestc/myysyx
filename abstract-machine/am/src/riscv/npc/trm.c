#include <am.h>
#include <klib-macros.h>
#include <stdio.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END  ((uintptr_t)&_pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
static const char mainargs[MAINARGS_MAX_LEN] = TOSTRING(MAINARGS_PLACEHOLDER); // defined in CFLAGS

// NPC 的简化串口: 仿真环境会把写入这个地址的字节输出到终端
#define NPC_SERIAL_ADDR 0xa00003f8

void putch(char ch) {
  *(volatile uint8_t *)NPC_SERIAL_ADDR = ch;
}

static inline void nemu_trap(int code) {
  asm volatile("mv a0, %0; ebreak" : : "r"(code) : "a0");
}

void halt(int code) {
  nemu_trap(code);
  while (1);
}

#ifdef __ARCH_RISCV32E_NPC
// 在进入 main() 之前读出 NPC 的两个标识 CSR 并打印:
//   mvendorid = "ysyx" 的 ASCII 码 (0x79737978)
//   marchid   = 学号的十进制表示 (ysyx_22040000 -> 22040000)
static void print_npc_id(void) {
  uint32_t vendor, arch;
  asm volatile("csrr %0, mvendorid" : "=r"(vendor));
  asm volatile("csrr %0, marchid"   : "=r"(arch));
  char v[5];
  v[0] = (char)(vendor >> 24);
  v[1] = (char)(vendor >> 16);
  v[2] = (char)(vendor >> 8);
  v[3] = (char)vendor;
  v[4] = '\0';
  printf("NPC: mvendorid = 0x%08x ('%s'), marchid = %u (0x%x)\n",
      vendor, v, arch, arch);
}
#endif

void _trm_init() {
#ifdef __ARCH_RISCV32E_NPC
  print_npc_id();
#endif
  int ret = main(mainargs);
  halt(ret);
}
