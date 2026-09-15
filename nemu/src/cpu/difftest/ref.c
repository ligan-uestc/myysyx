/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <isa.h>
#include <cpu/cpu.h>
#include <difftest-def.h>
#include <memory/paddr.h>

/* NEMU can be compiled as a shared library (TARGET_SHARE) and loaded by a DUT
 * (e.g. the NPC) through dlopen(), so that the DUT can compare its behaviour
 * with NEMU instruction by instruction (Differential Testing).
 *
 * The register layout exchanged with the DUT is:
 *
 *   word_t gpr[RISCV_GPR_NUM];   // all architectural GPRs (without x0 special case)
 *   word_t pc;
 *
 * i.e. GPRs first, then pc, which is the same convention used by NEMU's own
 * difftest framework (see DIFFTEST_REG_SIZE in difftest-def.h). */

__EXPORT void difftest_memcpy(paddr_t addr, void *buf, size_t n, bool direction) {
  if (direction == DIFFTEST_TO_REF) {
    memcpy(guest_to_host(addr), buf, n);
  } else {
    memcpy(buf, guest_to_host(addr), n);
  }
}

__EXPORT void difftest_regcpy(void *dut, bool direction) {
  word_t *regs = (word_t *)dut;
  int n = ARRLEN(cpu.gpr);
  if (direction == DIFFTEST_TO_REF) {
    for (int i = 0; i < n; i ++) { cpu.gpr[i] = regs[i]; }
    cpu.pc = regs[n];
  } else {
    for (int i = 0; i < n; i ++) { regs[i] = cpu.gpr[i]; }
    regs[n] = cpu.pc;
  }
}

__EXPORT void difftest_exec(uint64_t n) {
  cpu_exec(n);
}

__EXPORT void difftest_raise_intr(word_t NO) {
  cpu.pc = isa_raise_intr(NO, cpu.pc);
}

__EXPORT void difftest_init(int port) {
  void init_mem();
  init_mem();
  /* Perform ISA dependent initialization. */
  init_isa();
}
