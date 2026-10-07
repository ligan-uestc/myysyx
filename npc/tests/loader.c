// ============================================================================
// loader.c —— 复现"加载器导致的缓存一致性问题" (B4 讲义)
//
// 讲义把这个场景抽象成"程序 A 和程序 B 被加载到同一个内存位置":
//   1. 先在目标内存位置 (SRAM) 放一串 nop, 以一条 ret 结束 —— 这就是程序 A;
//   2. 用函数调用的方式执行它, 它会立刻返回 (但此时 icache 已经把这段
//      指令缓存起来了);
//   3. 再把真正的程序 B 拷贝到同一个位置, 然后跳过去执行。
//   如果 icache 还留着程序 A 的旧指令, 程序 B 就取不到真正的指令 —— 表现为
//   这次调用没有输出 'A'。
//
//   -DWITH_FENCEI : 在"加载"之后加 fence.i (正确版本, 会输出 'A')
//   不带该宏      : 复现问题 (不会输出 'A')
//
// 需要 icache 能容纳过程中的所有指令, 因此用
//   make soc ICACHE_SRAM=1 ICACHE_BLOCKS=64
// 构建仿真环境。
// ============================================================================
#define SRAM_BASE 0x0f000000

void _start(void) __attribute__((naked));
void _start(void) {
  asm volatile(
      /* ---- 1) 在 SRAM 放"程序 A": 一串 nop + ret ---- */
      "li   a3, 0x0f000000\n"
      "li   t0, 0x00000013\n"     /* nop = addi x0, x0, 0 */
      "li   t1, 0x00008067\n"     /* ret = jalr x0, 0(ra) */
      "li   t2, 8\n"
      "1:\n"
      "  sw   t0, 0(a3)\n"
      "  addi a3, a3, 4\n"
      "  addi t2, t2, -1\n"
      "  bnez t2, 1b\n"
      "  sw   t1, 0(a3)\n"         /* 第 9 个字是 ret */

      /* ---- 2) 调用"程序 A" (会立刻返回, 但指令进了 icache) ---- */
      "li   a3, 0x0f000000\n"
      "jalr ra, 0(a3)\n"

      /* ---- 3) 把"程序 B"拷到同一位置 ---- */
      "la   a0, prog_b\n"
      "li   a1, 0x0f000000\n"
      "la   a2, prog_b_end\n"
      "2:\n"
      "  lw   t0, 0(a0)\n"
      "  sw   t0, 0(a1)\n"
      "  addi a0, a0, 4\n"
      "  addi a1, a1, 4\n"
      "  bltu a0, a2, 2b\n"
#ifdef WITH_FENCEI
      "fence.i\n"                 /* 让之后的取指看到新加载的指令 */
#endif
      /* ---- 4) 执行"程序 B" ---- */
      "li   a3, 0x0f000000\n"
      "jalr ra, 0(a3)\n"
      "ebreak\n"

      /* ---- 程序 B: 输出 'A' 然后返回 ---- */
      "prog_b:\n"
      "  li   a1, 0x10000000\n"    /* UART_TX */
      "  li   t1, 65\n"
      "  sb   t1, 0(a1)\n"
      "  jalr x0, 0(ra)\n"
      "prog_b_end:\n"
  );
}
