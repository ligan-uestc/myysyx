TOPNAME = top
VERILATOR = verilator
VERILATOR_CFLAGS += --build -cc -O3 \
	--x-assign fast --x-initial fast --noassert -Wno-fatal

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

VSRCS = $(shell find $(abspath ./vsrc) -name "*.sv" -o -name "*.v")
# SoC 仿真环境 (soc_main.cpp) 只在 `make soc` 里编译, 不进入独立仿真流程
CSRCS = $(shell find $(abspath ./csrc) -name "*.cpp" -o -name "*.cc" -o -name "*.c" | grep -v soc_main.cpp)

# itrace/ftrace disassembly: reuse the capstone library shipped with NEMU
CAPSTONE_HOME = $(abspath $(NPC_HOME)/../nemu/tools/capstone/repo)
CAPSTONE_CFLAGS = -I$(abspath ./vsrc) -I$(CAPSTONE_HOME)/include
CAPSTONE_LDFLAGS = -L$(CAPSTONE_HOME) -l:libcapstone.so.5 -Wl,-rpath,$(CAPSTONE_HOME)

IMG ?=
ARGS ?=
# 存储器随机延迟 (LFSR) 开关: make RAND_DELAY=1 打开, 用于总线压力测试
RAND_DELAY ?= 0
VERILATOR_CFLAGS += -GRAND_DELAY=$(RAND_DELAY)

default: $(BIN)

$(shell mkdir -p $(BUILD_DIR))

$(BIN): $(VSRCS) $(CSRCS)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		+incdir+$(abspath ./vsrc) \
		-CFLAGS "$(CAPSTONE_CFLAGS)" \
		-LDFLAGS "$(CAPSTONE_LDFLAGS)" \
		--top-module $(TOPNAME) \
		$(VSRCS) $(CSRCS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

all: default

# ---------------------------------------------------------------------------
# B2: 把 NPC 接入 ysyxSoC
#
# verilator 的顶层模块变成 ysyxSoC 生成的 ysyxSoCFull, 我们的处理器
# (ysyx_22040000) 只是它内部的一个子模块, 因此这里单独一套文件列表/选项:
#   * ysyxSoC/perip 下所有 .v 都要加入 (UART16550/SPI/GPIO/VGA 等 IP);
#   * uart16550 与 spi 的 rtl 目录要加入 include 搜索路径;
#   * 加上 --timescale "1ns/1ns" 与 --no-timing (ysyxSoC 的 RTL 里有时序指令)。
# ---------------------------------------------------------------------------
SOC_HOME  = $(abspath $(NPC_HOME)/../ysyxSoC)
SOC_TOP   = ysyxSoCFull
SOC_OBJ   = $(BUILD_DIR)/soc_obj
SOC_BIN   = $(BUILD_DIR)/soc
SOC_SRCS  = $(abspath ./vsrc/axi4_if.sv) \
            $(abspath ./vsrc/alu.sv) \
            $(abspath ./vsrc/regfile.sv) \
            $(abspath ./vsrc/npc_core.sv) \
            $(abspath ./vsrc/axi_arbiter.sv) \
            $(abspath ./vsrc/axi_clint.sv) \
            $(abspath ./vsrc/ysyx_22040000.sv)
SOC_PERIP = $(shell find $(SOC_HOME)/perip -name '*.v')
SOC_VERILATOR_FLAGS = --build -cc -O3 --x-assign fast --x-initial fast --noassert \
	-Wno-fatal --timescale "1ns/1ns" --no-timing --autoflush

soc: $(SOC_BIN)

# ysyxSoC 生成的 Verilog 里 CPU 是一个名为 ysyx_00000000 的黑盒, 这里生成一份
# 把黑盒名替换成 ysyx_22040000 的副本 (不改动 ysyxSoC 仓库本身)。
SOC_TOP_V = $(BUILD_DIR)/ysyxSoCFull.npc.v
SOC_CPU_NAME ?= ysyx_22040000

$(SOC_TOP_V): $(SOC_HOME)/build/ysyxSoCFull.v
	@mkdir -p $(BUILD_DIR)
	sed 's/ysyx_00000000/$(SOC_CPU_NAME)/g' $< > $@

SOC_CSRCS = ./csrc/soc_main.cpp ./csrc/difftest.cpp

$(SOC_BIN): $(SOC_SRCS) $(SOC_PERIP) $(SOC_TOP_V) $(SOC_CSRCS)
	@rm -rf $(SOC_OBJ)
	$(VERILATOR) $(SOC_VERILATOR_FLAGS) \
		+incdir+$(abspath ./vsrc) \
		+incdir+$(SOC_HOME)/perip/uart16550/rtl \
		+incdir+$(SOC_HOME)/perip/spi/rtl \
		--top-module $(SOC_TOP) \
		$(SOC_SRCS) $(SOC_TOP_V) $(SOC_PERIP) \
		$(SOC_CSRCS) \
		--Mdir $(SOC_OBJ) --exe -o $(abspath $(SOC_BIN))

soc-run: $(SOC_BIN)
	@$(SOC_BIN) $(SOC_ARGS)

# AM (`make ARCH=riscv32e-npc run`) passes IMG/ARGS through
# abstract-machine/scripts/platform/npc.mk
run: $(BIN)
	@$(BIN) $(ARGS) $(IMG)

sim:
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@$(BIN) $(ARGS) $(IMG)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default all run sim soc soc-run clean

-include ../Makefile
