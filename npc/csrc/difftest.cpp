// Differential testing: the DUT is the NPC, the REF is a NEMU shared library
// (built with npc/tools/build-ref.sh as riscv32-nemu-interpreter-so).
//
// The register layout exchanged with the REF is "GPRs then PC", the same
// convention as NEMU's own difftest framework.
#include "npc_sim.hpp"

#include <dlfcn.h>

#define DIFFTEST_TO_DUT false
#define DIFFTEST_TO_REF true

static void (*ref_difftest_memcpy)(uint32_t, void *, size_t, bool) = nullptr;
static void (*ref_difftest_regcpy)(void *, bool) = nullptr;
static void (*ref_difftest_exec)(uint64_t) = nullptr;
static void (*ref_difftest_init)(int) = nullptr;

static bool     s_on = false;
static uint32_t s_ref_regs[N_GPR + 1];
static uint64_t s_nr_dut_inst = 0;

bool difftest_init(const char *ref_so) {
  void *handle = dlopen(ref_so, RTLD_LAZY);
  if (handle == nullptr) {
    fprintf(stderr, "difftest: cannot load REF '%s': %s\n", ref_so, dlerror());
    return false;
  }
#define LOAD(var, sym) \
  do { \
    var = reinterpret_cast<decltype(var)>(dlsym(handle, sym)); \
    if (var == nullptr) { fprintf(stderr, "difftest: no %s in REF\n", sym); return false; } \
  } while (0)
  LOAD(ref_difftest_memcpy, "difftest_memcpy");
  LOAD(ref_difftest_regcpy, "difftest_regcpy");
  LOAD(ref_difftest_exec,   "difftest_exec");
  LOAD(ref_difftest_init,   "difftest_init");
#undef LOAD

  ref_difftest_init(0);
  s_on = true;
  return true;
}

void difftest_sync_mem(uint32_t addr, const void *buf, size_t n) {
  if (s_on) { ref_difftest_memcpy(addr, const_cast<void *>(buf), n, DIFFTEST_TO_REF); }
}

void difftest_sync_regs(const uint32_t *gpr, uint32_t pc) {
  if (!s_on) { return; }
  for (int i = 0; i < N_GPR; i ++) { s_ref_regs[i] = gpr[i]; }
  s_ref_regs[N_GPR] = pc;
  ref_difftest_regcpy(s_ref_regs, DIFFTEST_TO_REF);
}

bool difftest_check(const uint32_t *dut_gpr, uint32_t dut_pc) {
  if (!s_on) { return true; }

  ref_difftest_exec(1);
  ref_difftest_regcpy(s_ref_regs, DIFFTEST_TO_DUT);
  s_nr_dut_inst ++;

  static const char *reg_names[N_GPR] = {
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5"
  };

  bool ok = true;
  for (int i = 0; i < N_GPR; i ++) {
    if (dut_gpr[i] != s_ref_regs[i]) {
      printf("difftest: %s mismatch after %llu instruction(s): "
             "NPC = 0x%08x, NEMU = 0x%08x\n",
             reg_names[i], (unsigned long long)s_nr_dut_inst,
             dut_gpr[i], s_ref_regs[i]);
      ok = false;
    }
  }
  if (dut_pc != s_ref_regs[N_GPR]) {
    printf("difftest: pc mismatch after %llu instruction(s): "
           "NPC = 0x%08x, NEMU = 0x%08x\n",
           (unsigned long long)s_nr_dut_inst, dut_pc, s_ref_regs[N_GPR]);
    ok = false;
  }
  if (!ok) {
    printf("difftest: DUT and REF are different, simulation stopped\n");
  }
  return ok;
}
