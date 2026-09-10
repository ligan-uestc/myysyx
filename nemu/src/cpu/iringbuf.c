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

#include <cpu/cpu.h>
#include <cpu/iringbuf.h>
#include <stdarg.h>

#ifdef CONFIG_IRINGBUF

#define IRINGBUF_SIZE 16

/* Each entry stores exactly the itrace-style line of one instruction,
 * e.g. "0x80000000: 97 02 00 00  auipc t0, 0x80000000".  */
static char iringbuf[IRINGBUF_SIZE][128];
static int head = 0;  /* next slot to write */
static int nr_inst = 0;

void iringbuf_record(vaddr_t pc, const char *inst) {
  (void)pc; /* the PC is already part of the disassembly text in inst */
  snprintf(iringbuf[head], sizeof(iringbuf[head]), "%s", inst);
  head = (head + 1) % IRINGBUF_SIZE;
  if (nr_inst < IRINGBUF_SIZE) nr_inst ++;
}

/* Write to both the terminal and the NEMU log file.
 * Unlike log_write() we do NOT respect the TRACE_START/TRACE_END window:
 * a crash dump should always be visible.  */
static void iringbuf_printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  fflush(stdout);

#ifndef CONFIG_TARGET_AM
  extern FILE *log_fp;
  if (log_fp != NULL) {
    va_start(ap, fmt);
    vfprintf(log_fp, fmt, ap);
    va_end(ap);
    fflush(log_fp);
  }
#endif
}

void iringbuf_dump() {
  if (nr_inst == 0) return;

  int oldest = (head - nr_inst + IRINGBUF_SIZE) % IRINGBUF_SIZE;
  iringbuf_printf("=============== iringbuf: last %d instruction(s) ===============\n", nr_inst);
  for (int i = 0; i < nr_inst; i ++) {
    int idx = (oldest + i) % IRINGBUF_SIZE;
    /* "-->" marks the most recently executed instruction kept in the buffer */
    iringbuf_printf("%s%s\n", (i == nr_inst - 1) ? "-->" : "   ", iringbuf[idx]);
  }
}

#endif
