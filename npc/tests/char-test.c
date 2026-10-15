// ============================================================================
// char-test —— ysyxSoC 上最简单的输出程序 (B2 讲义 "输出第一个字符")
//
// 复位后 NPC 从 MROM (0x2000_0000) 取出第一条指令, 这个程序向 ysyxSoC 的
// UART16550 数据寄存器写入字符 'A', 然后执行 ebreak 结束仿真。
//
// UART16550 的寄存器 (见 ysyxSoC/perip/uart16550/rtl/uart_defines.v):
//   `UART_REG_RB = 0  ->  偏移 0 = 接收缓冲/发送保持寄存器 (RBR/THR)
//   基地址 = 0x1000_0000, 因此发送寄存器就是 0x1000_0000。
//
// 这里用 naked 函数, 避免 gcc 生成函数序言 (会访问栈, 而复位时还没有栈)。
// ============================================================================

#ifndef WITH_NEWLINE
#define WITH_NEWLINE 1
#endif
#ifndef WITH_SPIN
#define WITH_SPIN 0
#endif

void _start(void) __attribute__((naked));
void _start(void) {
  asm volatile(
      "li   t0, 0x10000000\n"   // UART16550 THR
      "li   t1, 65\n"           // 'A'
      "sb   t1, 0(t0)\n"
#if WITH_NEWLINE
      "li   t1, 10\n"           // '\n'
      "sb   t1, 0(t0)\n"
#endif
#if WITH_SPIN
      "1:   j 1b\n"             // 不再结束, 用于观察 stdout 缓冲行为
#else
      "ebreak\n"                // 结束仿真 (AM 的 nemu_trap)
#endif
  );
}
