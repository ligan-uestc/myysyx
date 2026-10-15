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

#ifdef CONFIG_ETRACE
static const char *etrace_cause_name(word_t NO) {
  if (NO & 0x80000000u) {          // interrupt: mcause[31] = 1
    switch (NO & 0x7fffffffu) {
      case 7:  return "machine timer interrupt";
      case 11: return "machine external interrupt";
      default: return "interrupt";
    }
  }
  switch (NO) {
    case 0:  return "instruction address misaligned";
    case 2:  return "illegal instruction";
    case 3:  return "breakpoint";
    case 11: return "environment call from M-mode";
    case 12: return "instruction page fault";
    case 13: return "load page fault";
    case 15: return "store page fault";
    default: return "exception";
  }
}

/* etrace: record exceptions raised by the processor.
 * Unlike itrace/mtrace this is NOT limited by the TRACE_START/TRACE_END
 * window: exceptions may happen long after the trace window ends, and etrace
 * is also useful when the program is already broken. */
static void etrace_log(word_t NO, vaddr_t epc, vaddr_t handler) {
#ifndef CONFIG_TARGET_AM
  extern FILE *log_fp;
  if (log_fp == NULL) return;
  fprintf(log_fp, "etrace: %s (mcause = 0x%x) at pc = " FMT_WORD ", jump to mtvec = " FMT_WORD "\n",
      etrace_cause_name(NO), (unsigned)NO, epc, handler);
  fflush(log_fp);
#endif
}
#endif

word_t isa_raise_intr(word_t NO, vaddr_t epc) {
  /* Save the exception cause and the PC of the offending instruction. */
  cpu.mcause = NO;
  cpu.mepc   = epc;

  /* mstatus: MPIE <- MIE, MIE <- 0.
   * (Privilege modes are not implemented yet; keeping mstatus consistent
   * makes mret correct once interrupts are enabled in PA4.) */
  word_t mpie = (cpu.mstatus & MSTATUS_MIE) ? MSTATUS_MPIE : 0;
  cpu.mstatus = (cpu.mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE)) | mpie;

#ifdef CONFIG_ETRACE
  etrace_log(NO, epc, cpu.mtvec);
#endif

  /* Jump to the exception entry address programmed by cte_init(). */
  return cpu.mtvec;
}

word_t isa_query_intr() {
  return INTR_EMPTY;
}
