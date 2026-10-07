# B2 讲义里的裸机小程序 (直接从 MROM 运行, 不经过 AM)
CROSS   = riscv64-linux-gnu-
# -fno-pic / -mcmodel=medany: la 必须生成 auipc+addi 的 PC 相对序列,
# 这样 smc.c 里被拷贝到 SRAM 的代码才能正确寻址 (不能使用 GOT)。
CFLAGS  = -march=rv32e_zicsr_zifencei -mabi=ilp32e -nostdlib -ffreestanding -O2 \
          -fno-pic -mcmodel=medany -fno-builtin -Wl,-Ttext=0x20000000
OBJCOPY = $(CROSS)objcopy

SOC = ../build/soc

all: char-test.bin char-test-nonl.bin char-test-spin.bin smc.bin smc-fence.bin \
     loader.bin loader-fence.bin

# 输出 'A' 与换行
char-test.bin: char-test.c
	$(CROSS)gcc $(CFLAGS) -DWITH_NEWLINE=1 $< -o char-test.elf
	$(OBJCOPY) -O binary --only-section=.text char-test.elf $@

# 只输出 'A', 不输出换行 (讲义 "去掉换行也能输出")
char-test-nonl.bin: char-test.c
	$(CROSS)gcc $(CFLAGS) -DWITH_NEWLINE=0 $< -o char-test-nonl.elf
	$(OBJCOPY) -O binary --only-section=.text char-test-nonl.elf $@

run: char-test.bin
	$(SOC) char-test.bin

run-nonl: char-test-nonl.bin
	$(SOC) char-test-nonl.bin

# 输出 'A' 后死循环: 用来观察不加 --autoflush 时输出会被缓冲吞掉
char-test-spin.bin: char-test.c
	$(CROSS)gcc $(CFLAGS) -DWITH_NEWLINE=0 -DWITH_SPIN=1 $< -o char-test-spin.elf
	$(OBJCOPY) -O binary --only-section=.text char-test-spin.elf $@

run-spin: char-test-spin.bin
	-$(SOC) char-test-spin.bin

# 自修改代码: 不带 fence.i (复现一致性问题) / 带 fence.i (正确)
# 注意: 这两个程序需要在 SRAM 里执行并改写自己, 因此要用
#       make soc ICACHE_SRAM=1 构建仿真环境。
smc.bin: smc.c
	$(CROSS)gcc $(CFLAGS) $< -o smc.elf
	$(OBJCOPY) -O binary --only-section=.text smc.elf $@

smc-fence.bin: smc.c
	$(CROSS)gcc $(CFLAGS) -DWITH_FENCEI=1 $< -o smc-fence.elf
	$(OBJCOPY) -O binary --only-section=.text smc-fence.elf $@

run-smc: smc.bin
	-$(SOC) --mrom smc.bin

run-smc-fence: smc-fence.bin
	$(SOC) --mrom smc-fence.bin

# 加载器导致的一致性: 不带 fence.i (会取到旧指令) / 带 fence.i (正确)
loader.bin: loader.c
	$(CROSS)gcc $(CFLAGS) $< -o loader.elf
	$(OBJCOPY) -O binary --only-section=.text loader.elf $@

loader-fence.bin: loader.c
	$(CROSS)gcc $(CFLAGS) -DWITH_FENCEI=1 $< -o loader-fence.elf
	$(OBJCOPY) -O binary --only-section=.text loader-fence.elf $@

run-loader: loader.bin
	-$(SOC) --mrom loader.bin

run-loader-fence: loader-fence.bin
	$(SOC) --mrom loader-fence.bin

clean:
	rm -f *.elf *.bin

.PHONY: all run run-nonl run-spin run-smc run-smc-fence run-loader run-loader-fence clean
