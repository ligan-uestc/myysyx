// ============================================================================
// smc.c —— 自修改代码 (Self-Modified Code) 与 icache 的一致性 (B4 讲义)
//
// 流程 (对应讲义的 smc.c):
//   1. 把 smc_body 这段代码拷贝到 SRAM (0x0f000000);
//   2. 跳进 SRAM 执行 (此时 icache 会把这段指令缓存起来);
//   3. 循环体往串口写 'A', 然后把 again 处的 sb 指令改写成 ret;
//   4. 跳回 again: 如果 icache 还留着旧指令, 就会一直执行 sb (死循环);
//      如果执行过 fence.i 冲刷了 icache, 就会取到新的 ret 从而返回。
//
// 因为要自己改写自己, 这段代码必须放在可写内存里运行 —— 所以先拷贝到 SRAM,
// 并且仿真时要把 icache 配成也缓存 SRAM (make soc ICACHE_SRAM=1)。
//
//   -DWITH_FENCEI : 在改写之后加上 fence.i (正确版本)
//   不带该宏      : 复现缓存一致性问题 (会死循环)
// ============================================================================

void _start(void) __attribute__((naked));
void _start(void) {
  asm volatile(
      /* 1) 把 smc_body 拷贝到 SRAM */
      "la   a0, smc_body\n"
      "li   a1, 0x0f000000\n"
      "la   a2, smc_body_end\n"
      "1:\n"
      "  lw   t0, 0(a0)\n"
      "  sw   t0, 0(a1)\n"
      "  addi a0, a0, 4\n"
      "  addi a1, a1, 4\n"
      "  bltu a0, a2, 1b\n"

      /* 2) 跳进 SRAM 执行 (ra 记住返回地址) */
      "li   a3, 0x0f000000\n"
      "jalr ra, 0(a3)\n"

      /* 3) 返回后结束仿真 */
      "ebreak\n"

      /* ---- 下面这段会被拷贝到 SRAM 并在那里执行 ---- */
      "smc_body:\n"
      "  li   a1, 0x10000000\n"     /* UART_TX */
      "  li   t1, 65\n"             /* 'A' */
      "  li   t2, 0x00008067\n"     /* ret (jalr x0, 0(ra)) */
      "  la   a2, again\n"          /* PC 相对寻址: 在 SRAM 里会算出 SRAM 地址 */
      "again:\n"
      "  sb   t1, 0(a1)\n"          /* 输出一个字符 'A' */
      "  sw   t2, 0(a2)\n"          /* 把 again 处的 sb 改写成 ret */
#ifdef WITH_FENCEI
      "  fence.i\n"                 /* 让之后的取指能看到刚才的 store */
#endif
      "  j    again\n"
      "smc_body_end:\n"
  );
}
