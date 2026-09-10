TOPNAME = top
VERILATOR = verilator
VERILATOR_CFLAGS += --build -cc -O3 \
	--x-assign fast --x-initial fast --noassert -Wno-fatal

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

VSRCS = $(shell find $(abspath ./vsrc) -name "*.sv" -o -name "*.v")
CSRCS = $(shell find $(abspath ./csrc) -name "*.cpp" -o -name "*.cc" -o -name "*.c")

default: $(BIN)

$(shell mkdir -p $(BUILD_DIR))

$(BIN): $(VSRCS) $(CSRCS)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) \
		$(VSRCS) $(CSRCS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

all: default

# IMG is passed by the AM run target (abstract-machine/scripts/platform/npc.mk)
run: $(BIN)
	@$(BIN) $(IMG)

sim:
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@$(BIN) $(IMG)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default all run sim clean

-include ../Makefile
