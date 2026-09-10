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

#ifndef __CPU_FTRACE_H__
#define __CPU_FTRACE_H__

#include <common.h>

/* Parse the symbol table of an ELF file so that function addresses can be
 * translated into names later. elf_file == NULL disables ftrace silently. */
void init_ftrace(const char *elf_file);

/* Instruction-side hooks (RV32I jal/jalr) */
void trace_call(vaddr_t pc, vaddr_t target);
void trace_ret(vaddr_t pc);

#endif
