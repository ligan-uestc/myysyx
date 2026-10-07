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

# ---------------------------------------------------------------------------
# B4: icache 参数与性能计数器开关
#   make ICACHE_BLOCK=16 ICACHE_BLOCKS=64          # 换一组 cache 参数
#   make PERF=1                                    # 打开性能计数器
# ---------------------------------------------------------------------------
PERF          ?= 0
ICACHE_BLOCK  ?= 4
ICACHE_BLOCKS ?= 16
ICACHE_SRAM   ?= 0
NPC_CFG_DEFS   = +define+NPC_ICACHE_BLOCK=$(ICACHE_BLOCK) \
                 +define+NPC_ICACHE_BLOCKS=$(ICACHE_BLOCKS) \
                 +define+NPC_ICACHE_SRAM=$(ICACHE_SRAM)
PERF_DEFS      = $(if $(filter 1,$(PERF)),+define+NPC_PERF,)
VERILATOR_CFLAGS += $(NPC_CFG_DEFS) $(PERF_DEFS)

default: $(BIN)

$(shell mkdir -p $(BUILD_DIR))

# 把 verilator 选项写进一个标记文件: 选项变化时 (例如切换 PERF=1 或改 icache
# 参数) 触发重新编译, 否则 make 会认为目标是最新的。
# 注意: 这两条 $(shell ...) 必须放在所有选项变量都定义完之后 (见下面 SOC 段)。
STANDALONE_FLAGS_FILE = $(BUILD_DIR)/.top_flags
SOC_FLAGS_FILE        = $(BUILD_DIR)/.soc_flags

$(BIN): $(VSRCS) $(CSRCS) $(STANDALONE_FLAGS_FILE)
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
            $(abspath ./vsrc/icache.sv) \
            $(abspath ./vsrc/regfile.sv) \
            $(abspath ./vsrc/npc_core.sv) \
            $(abspath ./vsrc/axi_arbiter.sv) \
            $(abspath ./vsrc/axi_clint.sv) \
            $(abspath ./vsrc/ysyx_22040000.sv)
SOC_PERIP = $(shell find $(SOC_HOME)/perip -name '*.v')
SOC_VERILATOR_FLAGS = --build -cc -O3 --x-assign fast --x-initial fast --noassert \
	-Wno-fatal --timescale "1ns/1ns" --no-timing --autoflush \
	$(NPC_CFG_DEFS) $(PERF_DEFS)

$(shell mkdir -p $(BUILD_DIR); printf '%s\n' '$(VERILATOR_CFLAGS)' > $(STANDALONE_FLAGS_FILE).new; cmp -s $(STANDALONE_FLAGS_FILE).new $(STANDALONE_FLAGS_FILE) || mv -f $(STANDALONE_FLAGS_FILE).new $(STANDALONE_FLAGS_FILE))
$(shell mkdir -p $(BUILD_DIR); printf '%s\n' '$(SOC_VERILATOR_FLAGS)' > $(SOC_FLAGS_FILE).new; cmp -s $(SOC_FLAGS_FILE).new $(SOC_FLAGS_FILE) || mv -f $(SOC_FLAGS_FILE).new $(SOC_FLAGS_FILE))

soc: $(SOC_BIN)

# ysyxSoC 生成的 Verilog 里 CPU 是一个名为 ysyx_00000000 的黑盒, 这里生成一份
# 把黑盒名替换成 ysyx_22040000 的副本 (不改动 ysyxSoC 仓库本身)。
SOC_TOP_V = $(BUILD_DIR)/ysyxSoCFull.npc.v
SOC_CPU_NAME ?= ysyx_22040000

$(SOC_TOP_V): $(SOC_HOME)/build/ysyxSoCFull.v
	@mkdir -p $(BUILD_DIR)
	sed 's/ysyx_00000000/$(SOC_CPU_NAME)/g' $< > $@

SOC_CSRCS = ./csrc/soc_main.cpp ./csrc/difftest.cpp

$(SOC_BIN): $(SOC_SRCS) $(SOC_PERIP) $(SOC_TOP_V) $(SOC_CSRCS) $(SOC_FLAGS_FILE)
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

# ---------------------------------------------------------------------------
# B4: 性能评估 —— 打开性能计数器, 运行指定镜像, 打印性能数据
#
#   make perf PERF_IMG=<image.bin>
#   make perf PERF_IMG=... ICACHE_BLOCK=16 ICACHE_BLOCKS=64
#
# 输出的各项性能数据可用于讲义要求的"记录性能数据"表格, 也可用于
# 结合 Amdahl's law 寻找性能瓶颈。
# ---------------------------------------------------------------------------
PERF_IMG ?= $(abspath ./tests/bench.bin)

perf:
	@rm -f $(SOC_BIN)
	@$(MAKE) --no-print-directory soc PERF=1
	@$(SOC_BIN) --mrom $(PERF_IMG) > /tmp/npc-perf.out 2>&1 || true
	@grep -h '^PERF' /tmp/npc-perf.out | tail -1 | python3 tools/perf_report.py

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
