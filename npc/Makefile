TOPNAME = top
VERILATOR = verilator
VERILATOR_CFLAGS += --build -cc -O3 \
	--x-assign fast --x-initial fast --noassert -Wno-fatal

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

VSRCS = $(shell find $(abspath ./vsrc) -name "*.sv" -o -name "*.v")
CSRCS = $(shell find $(abspath ./csrc) -name "*.cpp" -o -name "*.cc" -o -name "*.c")

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

# AM (`make ARCH=riscv32e-npc run`) passes IMG/ARGS through
# abstract-machine/scripts/platform/npc.mk
run: $(BIN)
	@$(BIN) $(ARGS) $(IMG)

sim:
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@$(BIN) $(ARGS) $(IMG)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default all run sim clean

-include ../Makefile
