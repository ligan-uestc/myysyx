// Trace support of the NPC simulation environment:
//   itrace - every executed instruction (PC + encoding + disassembly)
//   mtrace - load/store addresses and data of the current instruction
//   ftrace - function call/return, resolved with the ELF symbol table
//
// The instruction is obtained from the DUT (the RTL fetches it through the
// DPI-C memory), the disassembly is done with capstone (the same library used
// by NEMU), and the memory access information comes from the RTL debug ports.
#include "npc_sim.hpp"

#include <capstone/capstone.h>
#include <elf.h>

#include <cstdarg>
#include <cstring>
#include <vector>

// ------------------------------ log helpers --------------------------------
static FILE *s_log = nullptr;

static void trace_log(const char *fmt, ...) {
  if (s_log == nullptr) { return; }
  va_list ap;
  va_start(ap, fmt);
  vfprintf(s_log, fmt, ap);
  va_end(ap);
  fflush(s_log);
}

// ------------------------------ itrace -------------------------------------
static bool s_itrace = false;
static bool s_mtrace = false;
static bool s_ftrace = false;

static csh  s_cs    = 0;
static bool s_cs_ok = false;

static void init_capstone() {
  if (cs_open(CS_ARCH_RISCV, CS_MODE_RISCV32, &s_cs) == CS_ERR_OK) {
    cs_option(s_cs, CS_OPT_DETAIL, CS_OPT_OFF);
    s_cs_ok = true;
  }
}

std::string trace_disasm(uint32_t pc, uint32_t inst) {
  if (!s_cs_ok) { return ""; }
  uint8_t code[4] = {
    (uint8_t)(inst & 0xff), (uint8_t)((inst >> 8) & 0xff),
    (uint8_t)((inst >> 16) & 0xff), (uint8_t)((inst >> 24) & 0xff),
  };
  cs_insn *insn = nullptr;
  size_t n = cs_disasm(s_cs, code, sizeof(code), pc, 1, &insn);
  if (n == 0) { return "???"; }
  std::string text = insn[0].mnemonic;
  if (insn[0].op_str[0] != '\0') {
    text += " ";
    text += insn[0].op_str;
  }
  cs_free(insn, n);
  return text;
}

// ------------------------------ ftrace -------------------------------------
#define MAX_FUNC_SYMBOLS 1024
#define MAX_FUNC_NAME    128

struct FuncSymbol {
  char     name[MAX_FUNC_NAME];
  uint32_t addr;
  uint32_t size;
};

static FuncSymbol s_funcs[MAX_FUNC_SYMBOLS];
static int        s_nr_func = 0;
static int        s_ftrace_depth = 0;

static const char *find_func_name(uint32_t addr) {
  for (int i = 0; i < s_nr_func; i ++) {
    if (s_funcs[i].size != 0 &&
        addr >= s_funcs[i].addr && addr < s_funcs[i].addr + s_funcs[i].size) {
      return s_funcs[i].name;
    }
  }
  return "???";
}

// Parse .symtab/.strtab of the ELF image by hand (man 5 elf).
static void parse_elf_symbols(const char *path) {
  FILE *fp = fopen(path, "rb");
  if (fp == nullptr) {
    fprintf(stderr, "warning: cannot open ELF file '%s' for ftrace\n", path);
    return;
  }

  Elf32_Ehdr ehdr;
  if (fread(&ehdr, sizeof(ehdr), 1, fp) != 1 ||
      memcmp(ehdr.e_ident, ELFMAG, SELFMAG) != 0 ||
      ehdr.e_ident[EI_CLASS] != ELFCLASS32 ||
      ehdr.e_ident[EI_DATA] != ELFDATA2LSB) {
    fprintf(stderr, "warning: '%s' is not a 32-bit little-endian ELF\n", path);
    fclose(fp);
    return;
  }

  std::vector<Elf32_Shdr> shdrs(ehdr.e_shnum);
  fseek(fp, ehdr.e_shoff, SEEK_SET);
  if (fread(shdrs.data(), ehdr.e_shentsize, ehdr.e_shnum, fp) != ehdr.e_shnum) {
    fprintf(stderr, "warning: cannot read section headers of '%s'\n", path);
    fclose(fp);
    return;
  }

  int sym_idx = -1;
  for (int i = 0; i < ehdr.e_shnum; i ++) {
    if (shdrs[i].sh_type == SHT_SYMTAB) { sym_idx = i; break; }
  }
  if (sym_idx < 0) {
    fprintf(stderr, "warning: no symbol table in '%s'\n", path);
    fclose(fp);
    return;
  }

  Elf32_Shdr &symtab = shdrs[sym_idx];
  Elf32_Shdr &strtab = shdrs[symtab.sh_link];
  int sym_cnt = symtab.sh_size / symtab.sh_entsize;

  std::vector<Elf32_Sym> syms(sym_cnt);
  std::vector<char> strs(strtab.sh_size);
  fseek(fp, symtab.sh_offset, SEEK_SET);
  if (fread(syms.data(), symtab.sh_size, 1, fp) != 1) { fclose(fp); return; }
  fseek(fp, strtab.sh_offset, SEEK_SET);
  if (fread(strs.data(), strtab.sh_size, 1, fp) != 1) { fclose(fp); return; }
  fclose(fp);

  for (int i = 0; i < sym_cnt; i ++) {
    if (ELF32_ST_TYPE(syms[i].st_info) != STT_FUNC) { continue; }
    if (syms[i].st_name == 0 || syms[i].st_value == 0) { continue; }
    if (s_nr_func >= MAX_FUNC_SYMBOLS) { break; }
    FuncSymbol *f = &s_funcs[s_nr_func ++];
    snprintf(f->name, sizeof(f->name), "%s", &strs[syms[i].st_name]);
    f->addr = syms[i].st_value;
    f->size = syms[i].st_size;
  }
  trace_log("ftrace: %d function symbol(s) from %s\n", s_nr_func, path);
}

// Detect the RV32 call/return instructions (same rules as NEMU's ftrace):
//   call: jal/jalr with rd == ra(x1)      ret: jalr x0, 0(ra)
static bool check_call_ret(uint32_t inst, bool *is_call, uint32_t *target,
                           uint32_t next_pc) {
  uint32_t opcode = inst & 0x7fu;
  uint32_t rd     = (inst >> 7) & 0x1fu;
  uint32_t rs1    = (inst >> 15) & 0x1fu;
  uint32_t imm    = inst >> 20;

  if (opcode == 0x6f && rd == 1) {          // jal ra, offset
    *is_call = true;
    *target  = next_pc;
    return true;
  }
  if (opcode == 0x67) {                     // jalr
    if (rd == 1) {                          // jalr ra, rs1, imm
      *is_call = true;
      *target  = next_pc;
      return true;
    }
    if (rd == 0 && rs1 == 1 && imm == 0) {  // ret
      *is_call = false;
      return true;
    }
  }
  return false;
}

// ------------------------------ public API ---------------------------------
void trace_init(FILE *log_fp, bool itrace, bool mtrace, bool ftrace,
                const char *elf_file) {
  s_log    = log_fp;
  s_itrace = itrace;
  s_mtrace = mtrace;
  s_ftrace = ftrace;
  init_capstone();
  if (s_ftrace && elf_file != nullptr) {
    parse_elf_symbols(elf_file);
  }
}

void trace_observe(uint32_t pc, uint32_t inst, uint32_t next_pc,
                   bool mem_valid, bool mem_we, uint32_t mem_addr,
                   uint32_t mem_data, uint32_t mem_size) {
  if (s_itrace) {
    std::string text = trace_disasm(pc, inst);
    trace_log("0x%08x: %08x  %s\n", pc, inst, text.c_str());
  }

  if (s_mtrace && mem_valid) {
    int bytes = 1 << mem_size;
    trace_log("mtrace: 0x%08x %s len=%d data=0x%08x pc=0x%08x\n",
        mem_addr, mem_we ? "write" : "read ", bytes, mem_data, pc);
  }

  if (s_ftrace) {
    bool is_call = false;
    uint32_t target = 0;
    if (check_call_ret(inst, &is_call, &target, next_pc)) {
      if (is_call) {
        trace_log("0x%08x: %*scall [%s@0x%08x]\n", pc, s_ftrace_depth * 2, "",
            find_func_name(target), target);
        s_ftrace_depth ++;
      }
      else {
        if (s_ftrace_depth > 0) { s_ftrace_depth --; }
        trace_log("0x%08x: %*sret  [%s]\n", pc, s_ftrace_depth * 2, "",
            find_func_name(pc));
      }
    }
  }
}
