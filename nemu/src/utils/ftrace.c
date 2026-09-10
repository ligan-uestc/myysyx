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
#include <cpu/ftrace.h>

#ifdef CONFIG_FTRACE

#include <elf.h>
#include <stdlib.h>

#define MAX_FUNC_SYMBOLS 1024
#define MAX_FUNC_NAME    128

/* A function symbol collected from the ELF symbol table. */
typedef struct {
  char name[MAX_FUNC_NAME];
  vaddr_t addr;
  uint32_t size;
} FuncSymbol;

static FuncSymbol funcs[MAX_FUNC_SYMBOLS];
static int nr_func = 0;
static int ftrace_depth = 0;
static bool ftrace_ready = false;

/* Translate an address in the code section to a function name.
 * Returns "???" when no symbol covers the address. */
static const char *find_func_name(vaddr_t addr) {
  for (int i = 0; i < nr_func; i ++) {
    if (funcs[i].size != 0 &&
        addr >= funcs[i].addr && addr < funcs[i].addr + funcs[i].size) {
      return funcs[i].name;
    }
  }
  return "???";
}

/* Parse the ELF file by hand (man 5 elf): locate .symtab, then use the
 * string table pointed by its sh_link to obtain every FUNC symbol. */
static void parse_elf_symbols(const char *path) {
  FILE *fp = fopen(path, "rb");
  Assert(fp, "ftrace: can not open ELF file '%s'", path);

  Elf32_Ehdr ehdr;
  int ret = fread(&ehdr, sizeof(ehdr), 1, fp);
  Assert(ret == 1, "ftrace: failed to read the ELF header of '%s'", path);
  Assert(memcmp(ehdr.e_ident, ELFMAG, SELFMAG) == 0, "ftrace: '%s' is not an ELF file", path);
  Assert(ehdr.e_ident[EI_CLASS] == ELFCLASS32, "ftrace: only 32-bit ELF is supported");
  Assert(ehdr.e_ident[EI_DATA] == ELFDATA2LSB, "ftrace: only little-endian ELF is supported");

  /* Read all section headers. */
  Elf32_Shdr *shdrs = malloc(ehdr.e_shentsize * ehdr.e_shnum);
  Assert(shdrs != NULL, "ftrace: malloc failed for section headers");
  fseek(fp, ehdr.e_shoff, SEEK_SET);
  ret = fread(shdrs, ehdr.e_shentsize, ehdr.e_shnum, fp);
  Assert(ret == ehdr.e_shnum, "ftrace: failed to read section headers of '%s'", path);

  /* Find the symbol table (.symtab, SHT_SYMTAB). */
  int sym_idx = -1;
  for (int i = 0; i < ehdr.e_shnum; i ++) {
    if (shdrs[i].sh_type == SHT_SYMTAB) { sym_idx = i; break; }
  }
  Assert(sym_idx != -1, "ftrace: no symbol table (.symtab) in '%s'", path);

  Elf32_Shdr *symtab = &shdrs[sym_idx];
  Elf32_Shdr *strtab = &shdrs[symtab->sh_link];

  /* Read the whole symbol table and its string table. */
  int sym_cnt = symtab->sh_size / symtab->sh_entsize;
  Elf32_Sym *syms = malloc(symtab->sh_size);
  char *strs = malloc(strtab->sh_size);
  Assert(syms != NULL && strs != NULL, "ftrace: malloc failed for symbols/strings");

  fseek(fp, symtab->sh_offset, SEEK_SET);
  ret = fread(syms, symtab->sh_size, 1, fp);
  Assert(ret == 1, "ftrace: failed to read symbols of '%s'", path);

  fseek(fp, strtab->sh_offset, SEEK_SET);
  ret = fread(strs, strtab->sh_size, 1, fp);
  Assert(ret == 1, "ftrace: failed to read the string table of '%s'", path);

  fclose(fp);

  for (int i = 0; i < sym_cnt; i ++) {
    if (ELF32_ST_TYPE(syms[i].st_info) != STT_FUNC) continue;
    if (syms[i].st_name == 0 || syms[i].st_value == 0) continue;
    if (nr_func >= MAX_FUNC_SYMBOLS) {
      Log("ftrace: too many function symbols (limit = %d), ignore the rest",
          MAX_FUNC_SYMBOLS);
      break;
    }

    FuncSymbol *f = &funcs[nr_func ++];
    snprintf(f->name, sizeof(f->name), "%s", strs + syms[i].st_name);
    f->addr = syms[i].st_value;
    f->size = syms[i].st_size;
  }

  free(syms);
  free(strs);
  free(shdrs);

  Log("ftrace: %d function symbol(s) collected from %s", nr_func, path);
}

void init_ftrace(const char *elf_file) {
  if (elf_file == NULL) {
    Log("ftrace is enabled, but no ELF file is provided (use -e/--elf)");
    return;
  }
  parse_elf_symbols(elf_file);
  ftrace_ready = true;
  log_write("========== ftrace start ==========\n");
}

void trace_call(vaddr_t pc, vaddr_t target) {
  if (!ftrace_ready) return;
  log_write(FMT_WORD ": %*scall [%s@0x%08x]\n",
      (word_t)pc, ftrace_depth * 2, "", find_func_name(target), (uint32_t)target);
  ftrace_depth ++;
}

void trace_ret(vaddr_t pc) {
  if (!ftrace_ready) return;
  if (ftrace_depth > 0) ftrace_depth --;
  /* The instruction itself lies inside the function that is returning. */
  log_write(FMT_WORD ": %*sret  [%s]\n",
      (word_t)pc, ftrace_depth * 2, "", find_func_name(pc));
}

#endif
