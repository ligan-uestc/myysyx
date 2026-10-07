// TRM: ysyxSoC 平台的运行时环境 (B2 讲义)
//
// 与 npc 平台的区别:
//   * 堆区、栈区都在 SRAM (0x0f00_0000 ~ 0x0f00_1fff), 由链接脚本给出边界;
//   * 输出通过 ysyxSoC 自带的 UART16550 (0x1000_0000) 完成;
//   * 退出仍然借助 ebreak (AM 的 nemu_trap), 由仿真环境结束仿真。
#include <am.h>
#include <klib-macros.h>
#include <riscv/riscv.h>
#include <stdio.h>

extern char _heap_start;
extern char _stack_top;
int main(const char *args);

// 堆区: 从 SRAM 起始处到栈顶 (栈在 SRAM 末尾, 向低地址增长)
Area heap = RANGE(&_heap_start, &_stack_top);
static const char mainargs[MAINARGS_MAX_LEN] = TOSTRING(MAINARGS_PLACEHOLDER); // defined in CFLAGS

// ---- UART16550 (ysyxSoC) ----
// 寄存器偏移见 ysyxSoC/perip/uart16550/rtl/uart_defines.v:
//   UART_REG_RB = 0 (接收缓冲/发送保持), UART_REG_LC = 3 (线路控制),
//   UART_REG_LS = 5 (线路状态), UART_REG_DL = 0/1 (除数寄存器, 受 LCR.DLAB 控制)
#define UART16550_BASE 0x10000000u
#define UART_REG_RB    0x0u
#define UART_REG_DL1   0x0u   /* 除数寄存器低字节 (LCR.DLAB = 1 时) */
#define UART_REG_DL2   0x1u   /* 除数寄存器高字节 (LCR.DLAB = 1 时) */
#define UART_REG_LC    0x3u
#define UART_REG_LS    0x5u

#define UART_LC_DLAB   0x80u  /* LCR 的最高位: 除数寄存器锁存 */
#define UART_LS_THRE   0x20u  /* LSR bit5: 发送保持寄存器空 */

// 串口初始化: 设置除数寄存器。
//
// 为什么要设置除数? UART16550 的发送器只有在"除数不为 0 且分频计数器计到 0"
// 时才会产生 enable 信号 (见 uart_regs.v 的 Enable signal generation logic)。
// 没有 enable, 发送 FIFO 永远不会被取空, 写满 16 个字节之后后续的字符就被丢弃
// —— 这正是"NPC 没有输出全部字符"的原因。
// 在 verilator 中没有频率的概念, 除数取多少并不影响正确性, 只要非 0 即可。
static void uart_init(void) {
  outb(UART16550_BASE + UART_REG_LC,  UART_LC_DLAB);   // DLAB=1, 访问除数寄存器
  outb(UART16550_BASE + UART_REG_DL1, 0x01);           // 除数低字节
  outb(UART16550_BASE + UART_REG_DL2, 0x00);           // 除数高字节
  outb(UART16550_BASE + UART_REG_LC,  0x03);           // DLAB=0, 8n1
}

void putch(char ch) {
  // 输出前轮询线路状态寄存器的 THRE 位, 确认发送保持寄存器已空
  while (!(inb(UART16550_BASE + UART_REG_LS) & UART_LS_THRE)) ;
  outb(UART16550_BASE + UART_REG_RB, (uint8_t)ch);
}

static inline void nemu_trap(int code) {
  asm volatile("mv a0, %0; ebreak" : : "r"(code) : "a0");
}

void halt(int code) {
  nemu_trap(code);
  while (1);
}

#if defined(__ARCH_RISCV32E_YSYXSOC) || defined(__ARCH_RISCV32E_NPC)
// 在进入 main() 之前读出处理器的两个标识 CSR 并打印:
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
  uart_init();
#if defined(__ARCH_RISCV32E_YSYXSOC) || defined(__ARCH_RISCV32E_NPC)
  print_npc_id();
#endif
  int ret = main(mainargs);
  halt(ret);
}
