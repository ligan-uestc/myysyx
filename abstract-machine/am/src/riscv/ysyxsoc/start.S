.section entry, "ax"
.globl _start
.type _start, @function

_start:
  mv s0, zero
  /* ---- bootloader: 把 .data 从 MROM (LMA) 拷贝到 SRAM (VMA) ---- */
  la   a0, _data_start      /* 目标地址 (SRAM) */
  la   a1, _data_lma        /* 源地址   (MROM)  */
  la   a2, _data_end
1:
  bgeu a0, a2, 2f
  lw   t0, 0(a1)
  sw   t0, 0(a0)
  addi a0, a0, 4
  addi a1, a1, 4
  j    1b
2:
  /* ---- 清零 .bss ---- */
  la   a0, _bss_start
  la   a2, _bss_end
3:
  bgeu a0, a2, 4f
  sw   zero, 0(a0)
  addi a0, a0, 4
  j    3b
4:
  /* ---- fence.i: 让接下来取到的指令与刚刚写入的内存保持一致 ----
   * bootloader 本质上就是一个"加载器": 它用 store 把 .data 搬运到 SRAM,
   * 之后程序还可能跳进这些内存去执行 (或在同一个位置加载新程序)。
   * RISC-V 手册规定 store 对取指可见之前必须执行 fence.i, 否则 icache 里
   * 可能还留着旧指令 (见 B4 讲义的"缓存一致性")。
   */
  fence.i
  la sp, _stack_pointer
  call _trm_init

  /* B4 "优化程序的内存布局": 在程序代码前填充若干空白字节。
   * 填充放在 entry 段里 (即 _start 之后), 这样 _start 仍然落在复位 PC 上,
   * 而主代码 (.text*) 的地址会整体后移, icache 的 index 映射随之改变。
   * 用 make ARCH=riscv32e-ysyxsoc TEXT_PAD=0x40 ... 打开 (0 表示不填充)。
   */
  /* 通过 CFLAGS 的 -DTEXT_PAD=... 传入 (start.S 会先经过 C 预处理器) */
#ifdef TEXT_PAD
  .skip TEXT_PAD, 0
#endif

.size _start, . - _start
