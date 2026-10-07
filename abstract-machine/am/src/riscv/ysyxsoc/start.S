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
  la sp, _stack_pointer
  call _trm_init

.size _start, . - _start
