// ============================================================================
// fence-smc.c —— fence.i 的反例 (B5 "设计反例" / "在流水线中正确实现 fence.i")
//
// 程序先把一段代码 (body) 拷贝到可写的 SRAM, 然后在 SRAM 里执行:
//   把 target 处的指令改写成 ebreak, 执行 fence.i, 再"穿过"两条 nop 到达 target
//
//   修改指令 -> fence.i -> nop -> nop -> target
//
// 在多周期处理器上, fence.i 会冲刷 icache, 之后的取指一定拿到新的 ebreak,
// 因此程序正常结束 (前提是 icache 也缓存 SRAM, 即 ICACHE_SRAM=1, 否则谈不上
// "副本不一致")。
// 在流水线处理器上, 执行 fence.i 的时候, 它后面的 nop 和 target 已经被取进
// 流水线了 (它们是"过时的"指令)。如果 fence.i 不冲刷流水线, target 处的旧指令
// (j target) 就会继续执行, 从而陷入死循环 —— 这就是反例。
// 正确实现 (执行 fence.i 时冲刷流水线) 之后, 这些过时指令被清除并重新取指,
// 程序输出正确、正常结束。
//
// 复现错误的方法: 仿真环境用 make EXTRA_DEFS=+define+NPC_FENCE_NO_FLUSH 构建,
// 只冲刷 icache 而不冲刷流水线。
// ============================================================================

void _start(void) __attribute__((naked));
void _start(void) {
  asm volatile(
      /* 1) 把 body 拷到 SRAM */
      "la   a0, body\n"
      "li   a1, 0x0f000000\n"
      "la   a2, body_end\n"
      "1:\n"
      "  lw   t0, 0(a0)\n"
      "  sw   t0, 0(a1)\n"
      "  addi a0, a0, 4\n"
      "  addi a1, a1, 4\n"
      "  bltu a0, a2, 1b\n"

      /* 2) 跳进 SRAM 执行 */
      "li   a3, 0x0f000000\n"
      "jalr ra, 0(a3)\n"
      "ebreak\n"

      /* 3) 会被拷贝到 SRAM 并在那里执行的代码 */
      "body:\n"
      "la   a2, target\n"         // PC 相对: 在 SRAM 中会算出 SRAM 地址
      "li   t2, 0x00100073\n"     // ebreak (新指令)
      "sw   t2, 0(a2)\n"          // 改写 target 处的指令
      "fence.i\n"                 // 让之后的取指看到新指令
      "target:\n"
      // target 紧跟在 fence.i 之后: 执行 fence.i 的时候, 这条指令已经被取进
      // 流水线了 (它是"过时的"旧指令), 这正是要复现的场景。
      "j    target\n"             // 旧指令: 死循环 (会被改写成 ebreak)
      "body_end:\n"
  );
}
