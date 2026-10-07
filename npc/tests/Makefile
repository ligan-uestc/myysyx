# B2 讲义里的裸机小程序 (直接从 MROM 运行, 不经过 AM)
CROSS   = riscv64-linux-gnu-
CFLAGS  = -march=rv32e_zicsr -mabi=ilp32e -nostdlib -ffreestanding -O2 \
          -fno-builtin -Wl,-Ttext=0x20000000
OBJCOPY = $(CROSS)objcopy

SOC = ../build/soc

all: char-test.bin char-test-nonl.bin char-test-spin.bin

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

clean:
	rm -f *.elf *.bin

.PHONY: all run run-nonl run-spin clean
