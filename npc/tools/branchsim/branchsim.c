// ============================================================================
// branchsim —— 简单的分支预测模拟器 (B5 "实现branchsim")
//
// 输入是 itrace (每行 "PC INST", 十六进制)。有了 PC 和指令字, branchsim
//   1. 用指令字识别出分支指令 (opcode = 1100011);
//   2. 用"下一条 PC"判断这次分支实际是跳转还是不跳转:
//        下一条 PC == PC + 4  -> 不跳转; 否则 -> 跳转;
//   3. 统计各种静态预测策略的准确率, 并估算它们对流水线 IPC 的影响:
//        总是预测不跳转 (always not-taken)、总是预测跳转、以及
//        "向后跳转就预测跳转" (BTFN, backward taken forward not-taken)。
//
// 用法:  branchsim [OPTION]... TRACE
//   -j N   跳转指令 (jal/jalr) 在流水线中造成冲刷的代价 (周期), 默认 2
//   -b N   分支预测错误造成冲刷的代价 (周期), 默认 2
//   -q     只打印一行结果
//   -p     评估"总是预测不跳转" (默认)
//   -P     额外评估"总是预测跳转"和 BTFN
//
// 输出的关键数字是"分支预测错误率", 以及把它代入
//     IPC = 1 / (1 + 预测错误率 * 冲刷代价 / 平均指令数)
// 得到的理想 IPC —— 这正是讲义要求体会的"分支预测器的重要性"。
// ============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static int is_branch(uint32_t inst) { return (inst & 0x7f) == 0x33; }

int main(int argc, char **argv) {
  const char *path = NULL;
  int quiet = 0, extra = 0;
  int flush_jump = 2, flush_branch = 2;

  for (int i = 1; i < argc; i ++) {
    if      (strcmp(argv[i], "-q") == 0) quiet = 1;
    else if (strcmp(argv[i], "-P") == 0) extra = 1;
    else if (strcmp(argv[i], "-j") == 0 && i + 1 < argc) flush_jump = atoi(argv[++i]);
    else if (strcmp(argv[i], "-b") == 0 && i + 1 < argc) flush_branch = atoi(argv[++i]);
    else if (argv[i][0] != '-') path = argv[i];
    else { fprintf(stderr, "branchsim: 未知选项 %s\n", argv[i]); return 1; }
  }

  FILE *fp = (path == NULL || strcmp(path, "-") == 0) ? stdin : fopen(path, "r");
  if (!fp) { perror(path); return 1; }

  uint64_t n_inst = 0, n_br = 0, n_taken = 0;
  uint64_t ant_ok = 0, at_ok = 0, btfn_ok = 0;
  uint64_t n_jump = 0;      // jal / jalr (无条件跳转)

  uint32_t pc = 0, inst = 0, pc_next = 0;
  int have_pc = 0;
  char buf[512];
  while (fgets(buf, sizeof(buf), fp)) {
    uint32_t p, i = 0;
    if (sscanf(buf, "%x %x", &p, &i) < 1) continue;
    if (have_pc) {
      // 上一条指令: 判断它是不是分支/跳转, 以及是否跳转
      int taken = (p != pc + 4);
      uint32_t op = inst & 0x7f;
      if (op == 0x63) {            // 条件分支
        n_br ++;
        if (taken) n_taken ++;
        if (!taken) ant_ok ++;                       // 总是不跳转
        if (taken)  at_ok ++;                        // 总是跳转
        // BTFN: 向后 (目标 < PC) 预测跳转, 向前预测不跳转
        int backward = taken ? (p < pc) : 0;
        if ((backward && taken) || (!backward && !taken)) btfn_ok ++;
      }
      else if (op == 0x6f || op == 0x67) n_jump ++;  // jal / jalr
      n_inst ++;
    }
    pc = p; inst = i; have_pc = 1;
  }
  n_inst ++;   // 最后一条
  if (fp != stdin) fclose(fp);

  double br_rate   = n_inst ? (double)n_br / (double)n_inst : 0.0;
  double miss_ant  = n_br ? (double)(n_br - ant_ok) / (double)n_br : 0.0;
  double miss_at   = n_br ? (double)(n_br - at_ok) / (double)n_br : 0.0;
  double miss_btfn = n_br ? (double)(n_br - btfn_ok) / (double)n_br : 0.0;

  // 理想 IPC: 每条指令 1 周期, 分支预测错误和跳转冲刷各加 flush 个周期
  double pen_ant  = ((double)n_br * miss_ant  * flush_branch + (double)n_jump * flush_jump) / (double)(n_inst ? n_inst : 1);
  double pen_at   = ((double)n_br * miss_at   * flush_branch + (double)n_jump * flush_jump) / (double)(n_inst ? n_inst : 1);
  double pen_btfn = ((double)n_br * miss_btfn * flush_branch + (double)n_jump * flush_jump) / (double)(n_inst ? n_inst : 1);

  if (!quiet) {
    printf("动态指令数      = %llu\n", (unsigned long long)n_inst);
    printf("分支指令        = %llu (%.2f%%, 平均每 %.1f 条指令一条分支)\n",
           (unsigned long long)n_br, 100.0 * br_rate, n_br ? (double)n_inst / (double)n_br : 0.0);
    printf("  其中跳转      = %llu\n", (unsigned long long)n_taken);
    printf("无条件跳转      = %llu\n", (unsigned long long)n_jump);
    printf("\n静态预测策略        准确率      预测错误率   理想 IPC\n");
    printf("  总是预测不跳转   %8.2f%%  %8.2f%%     %.3f\n",
           100.0 * (1 - miss_ant), 100.0 * miss_ant, 1.0 / (1.0 + pen_ant));
    if (extra) {
      printf("  总是预测跳转     %8.2f%%  %8.2f%%     %.3f\n",
             100.0 * (1 - miss_at), 100.0 * miss_at, 1.0 / (1.0 + pen_at));
      printf("  BTFN             %8.2f%%  %8.2f%%     %.3f\n",
             100.0 * (1 - miss_btfn), 100.0 * miss_btfn, 1.0 / (1.0 + pen_btfn));
    }
  }
  printf("RESULT inst=%llu branch=%llu taken=%llu jump=%llu "
         "miss_ant=%.6f miss_at=%.6f miss_btfn=%.6f ipc_ant=%.4f ipc_at=%.4f ipc_btfn=%.4f\n",
         (unsigned long long)n_inst, (unsigned long long)n_br, (unsigned long long)n_taken,
         (unsigned long long)n_jump, miss_ant, miss_at, miss_btfn,
         1.0 / (1.0 + pen_ant), 1.0 / (1.0 + pen_at), 1.0 / (1.0 + pen_btfn));
  return 0;
}
