#ifndef ARCH_H__
#define ARCH_H__

#ifdef __riscv_e
#define NR_REGS 16
#else
#define NR_REGS 32
#endif

struct Context {
  // 成员顺序必须与 $ISA/nemu/trap.S 压栈的顺序一致:
  //   gpr[0..NR_REGS-1] -> mcause -> mstatus -> mepc
  // trap.S 中 OFFSET_CAUSE/STATUS/EPC = (NR_REGS + 0/1/2) * XLEN。
  // 地址空间信息 pdir 目前虽然用不到 (PA4 的 VME 才会用),
  // 仍然要放在正确的位置 (所有寄存器与 CSR 之后)。
  uintptr_t gpr[NR_REGS], mcause, mstatus, mepc;
  void *pdir;
};

#ifdef __riscv_e
#define GPR1 gpr[15] // a5
#else
#define GPR1 gpr[17] // a7
#endif

#define GPR2 gpr[0]
#define GPR3 gpr[0]
#define GPR4 gpr[0]
#define GPRx gpr[0]

#endif
