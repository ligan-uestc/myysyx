#include <am.h>
#include <riscv/riscv.h>
#include <klib.h>

static Context* (*user_handler)(Event, Context*) = NULL;

Context* __am_irq_handle(Context *c) {
  if (user_handler) {
    Event ev = {0};
    switch (c->mcause) {
      case 11: // Environment call from M-mode (见 RISC-V 手册的异常号表)
        // RISC-V 把"异常返回地址要不要 +4"交给软件决定: ecall 属于自陷类
        // 异常, 返回后应当跳过 ecall 指令本身, 因此这里把 mepc 加 4。
        // (故障类异常, 例如缺页, 返回时应当重新执行同一条指令, 则不加 4)
        c->mepc += 4;
        ev.event = ((intptr_t)c->GPR1 == -1) ? EVENT_YIELD : EVENT_ERROR;
        break;
      default: ev.event = EVENT_ERROR; break;
    }

    c = user_handler(ev, c);
    assert(c != NULL);
  }

  return c;
}

extern void __am_asm_trap(void);

bool cte_init(Context*(*handler)(Event, Context*)) {
  // initialize exception entry
  asm volatile("csrw mtvec, %0" : : "r"(__am_asm_trap));

  // register event handler
  user_handler = handler;

  return true;
}

Context *kcontext(Area kstack, void (*entry)(void *), void *arg) {
  /* 在 kstack 的栈顶构造一个"即将从 entry(arg) 开始执行"的上下文。
   *
   * trap.S 的恢复路径是:
   *   mv sp, a0            # sp = 要被恢复的上下文
   *   csrw mstatus/mepc    # 写回 CSR
   *   MAP(REGS, POP)       # 恢复通用寄存器
   *   addi sp, sp, CONTEXT_SIZE
   *   mret                 # PC <- mepc
   * 所以把上下文放在 "栈顶(16 字节对齐) - CONTEXT_SIZE" 处,
   * 新的内核线程第一次被恢复时 sp 正好指向栈顶, 且在栈的范围之内。
   */
  const int context_size = (NR_REGS + 3) * sizeof(uintptr_t);  // 与 trap.S 的 CONTEXT_SIZE 一致
  uintptr_t sp_top = (uintptr_t)kstack.end & ~(uintptr_t)0xf;
  Context *c = (Context *)(sp_top - context_size);

  memset(c, 0, context_size);       // 只清 gpr[] + mcause/mstatus/mepc (不动 pdir)
  c->mepc    = (uintptr_t)entry;
  c->mstatus = 0x1800;              // riscv32: MPP = 3 (M-mode), 供 DiffTest 使用
  c->gpr[10] = (uintptr_t)arg;      // a0: 按 RISC-V 调用约定传递第一个参数

  return c;
}

void yield() {
#ifdef __riscv_e
  asm volatile("li a5, -1; ecall");
#else
  asm volatile("li a7, -1; ecall");
#endif
}

bool ienabled() {
  return false;
}

void iset(bool enable) {
}
