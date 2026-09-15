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
  return NULL;
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
