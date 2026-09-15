// Simple debugger of the NPC (C2 lecture: 为NPC搭建sdb).
//
// Commands:
//   si [N]         single step N instructions (default 1)
//   info r         print the RV32E general purpose registers and pc
//   x N ADDR       examine N 4-byte words of the physical memory
//   c              continue until the program stops
//   q              quit
//   help           print this message
#include "npc_sim.hpp"

#include <cstdlib>
#include <cstring>

static const char *reg_names[N_GPR] = {
  "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
  "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5"
};

static void info_regs() {
  for (int i = 0; i < N_GPR; i ++) {
    printf("%-5s= 0x%08x%s", reg_names[i], sim_gpr(i), (i % 4 == 3) ? "\n" : "  ");
  }
  printf("pc   = 0x%08x  inst = 0x%08x  (executed %llu)\n",
      sim_pc(), sim_inst(), (unsigned long long)sim_inst_count());
}

static void scan_mem(int n, uint32_t addr) {
  for (int i = 0; i < n; i ++) {
    uint32_t a = addr + i * 4;
    printf("0x%08x: 0x%08x\n", a, npc_pmem_read(a, 4));
  }
}

static void help() {
  printf("si [N]      - step N instructions (default 1)\n");
  printf("info r      - print registers\n");
  printf("x N ADDR    - examine N 4-byte words of the memory\n");
  printf("c           - continue until the program stops\n");
  printf("q           - quit\n");
}

void sdb_mainloop() {
  char line[256];
  printf("Welcome to the NPC debugger. Type 'help' for commands.\n");
  while (true) {
    printf("(npc) ");
    fflush(stdout);
    if (fgets(line, sizeof(line), stdin) == nullptr) { break; }

    if (strncmp(line, "si", 2) == 0) {
      int n = 1;
      sscanf(line + 2, "%d", &n);
      if (n <= 0) { n = 1; }
      sim_run(n);
      if (npc_stopped()) { sim_report_result(); break; }
    }
    else if (strncmp(line, "info", 4) == 0) {
      if (strstr(line, "r") != nullptr) { info_regs(); }
      else { printf("usage: info r\n"); }
    }
    else if (line[0] == 'x') {
      int n = 0;
      unsigned addr = 0;
      if (sscanf(line + 1, "%d %x", &n, &addr) == 2 && n > 0) { scan_mem(n, addr); }
      else { printf("usage: x N ADDR\n"); }
    }
    else if (line[0] == 'c') {
      sim_run(-1);
      sim_report_result();
      if (npc_stopped()) { break; }
    }
    else if (line[0] == 'q') {
      break;
    }
    else if (strncmp(line, "help", 4) == 0 || line[0] == '\n') {
      help();
    }
    else {
      printf("unknown command '%s'\n", line);
    }
  }
}
