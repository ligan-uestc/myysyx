# ysyxSoC 平台 (B2 讲义)
#
# 与 npc 平台的区别: 程序链接到 MROM (0x2000_0000), 栈/堆在 SRAM
# (0x0f00_0000), 并直接在 ysyxSoC 的 verilator 仿真环境 (npc/build/soc) 中运行。

AM_SRCS := riscv/ysyxsoc/start.S \
           riscv/ysyxsoc/trm.c \
           riscv/ysyxsoc/ioe.c \
           riscv/ysyxsoc/timer.c \
           riscv/ysyxsoc/input.c \
           riscv/ysyxsoc/cte.c \
           riscv/ysyxsoc/trap.S \
           platform/dummy/vme.c \
           platform/dummy/mpe.c

CFLAGS    += -fdata-sections -ffunction-sections
LDSCRIPTS += $(AM_HOME)/scripts/linker-ysyxsoc.ld
LDFLAGS   += --gc-sections -e _start

MAINARGS_MAX_LEN = 72
MAINARGS_PLACEHOLDER = the_insert-arg_rule_in_Makefile_will_insert_mainargs_here
CFLAGS += -DMAINARGS_MAX_LEN=$(MAINARGS_MAX_LEN) -DMAINARGS_PLACEHOLDER=$(MAINARGS_PLACEHOLDER)

# 在 ysyxSoC 的仿真环境中运行: 把镜像作为 MROM 的内容
SOCFLAGS += $(addprefix --mrom ,$(abspath $(IMAGE).bin))
# B4: 程序的内存布局优化 —— 在代码前填充 TEXT_PAD 个空白字节
ifdef TEXT_PAD
ASFLAGS += -DTEXT_PAD=$(TEXT_PAD)
endif
# 可选: 加上 DIFF_REF=<NEMU 共享库路径> 即可打开 DiffTest
ifdef DIFF_REF
SOCFLAGS += -d $(DIFF_REF)
endif

insert-arg: image
	@python3 $(AM_HOME)/tools/insert-arg.py $(IMAGE).bin $(MAINARGS_MAX_LEN) $(MAINARGS_PLACEHOLDER) "$(mainargs)"

image: image-dep
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@# 只保留 MROM 中的内容 (.text/.rodata/.data 的 LMA); .bss 不需要出现在镜像里,
	@# 它由 start.S 里的 bootloader 在运行时清零。
	@$(OBJCOPY) -S -R .bss -R .sbss -R .scommon -R COMMON -O binary $(IMAGE).elf $(IMAGE).bin

run: insert-arg
	$(MAKE) -C $(NPC_HOME) soc-run SOC_ARGS="$(SOCFLAGS)"

.PHONY: insert-arg
