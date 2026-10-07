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

#include <memory/host.h>
#include <memory/paddr.h>
#include <device/mmio.h>
#include <isa.h>

#if   defined(CONFIG_PMEM_MALLOC)
static uint8_t *pmem = NULL;
#else // CONFIG_PMEM_GARRAY
static uint8_t pmem[CONFIG_MSIZE] PG_ALIGN = {};
#endif

/* ---------------------------------------------------------------------------
 * B2: ysyxSoC 的 MROM 与 SRAM
 *
 * NPC 接入 ysyxSoC 之后, 程序放在 MROM (0x2000_0000, 4KiB) 中执行, 数据放在
 * SRAM (0x0f00_0000, 8KiB) 中。为了让 DiffTest 能继续工作, NEMU 里也要有这两块
 * 内存: 仿真环境在初始化时把 MROM 的内容同步给 NEMU (用的是框架已有的
 * difftest_memcpy API, 它内部调用 guest_to_host), 之后 NPC 执行的每一条指令
 * 都会与 NEMU 逐条对比。
 *
 * 这里没有引入新的 DiffTest API, 只是让 guest_to_host()/paddr_read()/
 * paddr_write() 认识这两块新的地址空间。
 * ------------------------------------------------------------------------- */
#define YSYX_MROM_BASE 0x20000000u
#define YSYX_MROM_SIZE 0x1000u
#define YSYX_SRAM_BASE 0x0f000000u
#define YSYX_SRAM_SIZE 0x2000u
/* UART16550 (0x1000_0000): 只读的状态寄存器返回"发送保持寄存器空"。
 * 这样 AM 的 putch() 里的轮询循环在 NEMU 与 NPC 上会走到同样的分支。 */
#define YSYX_UART_BASE 0x10000000u
#define YSYX_UART_SIZE 0x8u

static uint8_t ysyx_mrom[YSYX_MROM_SIZE] PG_ALIGN = {};
static uint8_t ysyx_sram[YSYX_SRAM_SIZE] PG_ALIGN = {};

static inline bool in_ysyx_mrom(paddr_t addr) {
  return addr >= YSYX_MROM_BASE && addr < YSYX_MROM_BASE + YSYX_MROM_SIZE;
}
static inline bool in_ysyx_sram(paddr_t addr) {
  return addr >= YSYX_SRAM_BASE && addr < YSYX_SRAM_BASE + YSYX_SRAM_SIZE;
}
static inline bool in_ysyx_uart(paddr_t addr) {
  return addr >= YSYX_UART_BASE && addr < YSYX_UART_BASE + YSYX_UART_SIZE;
}

static uint8_t* ysyx_guest_to_host(paddr_t paddr) {
  if (in_ysyx_mrom(paddr)) return ysyx_mrom + (paddr - YSYX_MROM_BASE);
  if (in_ysyx_sram(paddr)) return ysyx_sram + (paddr - YSYX_SRAM_BASE);
  return NULL;
}

static word_t ysyx_uart_read(paddr_t addr) {
  /* UART_REG_LS = 5: bit5 (THRE, 发送保持寄存器空) 恒为 1 */
  if (addr - YSYX_UART_BASE == 5) return 0x20;
  return 0;
}

uint8_t* guest_to_host(paddr_t paddr) {
  uint8_t *p = ysyx_guest_to_host(paddr);
  return (p != NULL) ? p : (pmem + paddr - CONFIG_MBASE);
}
paddr_t host_to_guest(uint8_t *haddr) { return haddr - pmem + CONFIG_MBASE; }

static word_t pmem_read(paddr_t addr, int len) {
  word_t ret = host_read(guest_to_host(addr), len);
  return ret;
}

static void pmem_write(paddr_t addr, int len, word_t data) {
  host_write(guest_to_host(addr), len, data);
}

static void out_of_bound(paddr_t addr) {
  panic("address = " FMT_PADDR " is out of bound of pmem [" FMT_PADDR ", " FMT_PADDR "] at pc = " FMT_WORD,
      addr, PMEM_LEFT, PMEM_RIGHT, cpu.pc);
}

#ifdef CONFIG_MTRACE
static void mtrace_log(paddr_t addr, int len, word_t data, bool is_write) {
#ifdef CONFIG_MTRACE_COND
  if (!MTRACE_COND) return;
#endif
  log_write("mtrace: " FMT_PADDR " %s len=%d data=" FMT_WORD " pc=" FMT_WORD "\n",
      addr, is_write ? "write" : "read ", len, data, cpu.pc);
}
#endif

void init_mem() {
#if   defined(CONFIG_PMEM_MALLOC)
  pmem = malloc(CONFIG_MSIZE);
  assert(pmem);
#endif
  IFDEF(CONFIG_MEM_RANDOM, memset(pmem, rand(), CONFIG_MSIZE));
  Log("physical memory area [" FMT_PADDR ", " FMT_PADDR "]", PMEM_LEFT, PMEM_RIGHT);
}

word_t paddr_read(paddr_t addr, int len) {
  if (likely(in_pmem(addr))) {
    word_t data = pmem_read(addr, len);
    IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, false));
    return data;
  }
  if (in_ysyx_mrom(addr) || in_ysyx_sram(addr)) {
    word_t data = host_read(ysyx_guest_to_host(addr), len);
    IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, false));
    return data;
  }
  if (in_ysyx_uart(addr)) {
    word_t data = ysyx_uart_read(addr);
    IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, false));
    return data;
  }
#ifdef CONFIG_DEVICE
  {
    word_t data = mmio_read(addr, len);
    IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, false));
    return data;
  }
#endif
  out_of_bound(addr);
  return 0;
}

void paddr_write(paddr_t addr, int len, word_t data) {
  if (likely(in_pmem(addr))) {
    pmem_write(addr, len, data);
    IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, true));
    return;
  }
  if (in_ysyx_mrom(addr) || in_ysyx_sram(addr)) {
    host_write(ysyx_guest_to_host(addr), len, data);
    IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, true));
    return;
  }
  if (in_ysyx_uart(addr)) {   /* 写 UART 只影响输出, 不影响体系结构状态 */
    IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, true));
    return;
  }
#ifdef CONFIG_DEVICE
  mmio_write(addr, len, data);
  IFDEF(CONFIG_MTRACE, mtrace_log(addr, len, data, true));
  return;
#endif
  out_of_bound(addr);
}
