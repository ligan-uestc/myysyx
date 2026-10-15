// ============================================================================
// trap.c —— 流水线处理器的异常处理测试 (B5 "实现支持异常处理的流水线")
//
// 程序流程:
//   1. 把 mtvec 指向 handler;
//   2. 连续执行 3 次 ecall, 每次 handler 把 a1 加 1, 把 mepc+4 写回后 mret;
//   3. 检查 a1 == 3, 正确则 ebreak(0) 结束, 否则 ebreak(1)。
//
// 这个测试同时覆盖了流水线中的几个要点:
//   * 异常要"精确": 写入 mepc 的必须是 ecall 自己的 PC (PC 随流水线传递);
//   * ecall 和 mret 都要冲刷流水线 (它们改变了执行流);
//   * mret 返回后要继续执行 mepc 指向的指令。
// ============================================================================

void _start(void) __attribute__((naked));
void _start(void) {
  asm volatile(
      "la   t0, handler\n"
      "csrw mtvec, t0\n"
      "li   a1, 0\n"

      "ecall\n"                       // 1
      "ecall\n"                       // 2
      "ecall\n"                       // 3

      "li   t2, 3\n"
      "bne  a1, t2, fail\n"
      "li   a0, 0\n"                  // 成功
      "ebreak\n"

      "fail:\n"
      "li   a0, 1\n"                  // 失败
      "ebreak\n"

      "handler:\n"
      "addi a1, a1, 1\n"              // 统计进入异常的次数
      "csrr t0, mepc\n"
      "addi t0, t0, 4\n"              // 跳过 ecall 本身
      "csrw mepc, t0\n"
      "mret\n"
  );
}
