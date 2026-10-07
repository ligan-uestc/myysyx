/* ysyxSoC 的链接脚本 (B2 讲义)
 *
 * 存储器布局:
 *   MROM  0x2000_0000 ~ 0x2000_0fff  4KiB, 只读, NPC 复位后从这里取指
 *   SRAM  0x0f00_0000 ~ 0x0f00_1fff  8KiB, 可读写
 *
 * TRM 的四个要素在本平台上的落地:
 *   * 程序入口  -> .text 链接到 MROM, 与 NPC 复位后的 PC (0x2000_0000) 一致;
 *   * 堆区      -> 分配在 SRAM, 见 _heap_start;
 *   * 栈        -> 分配在 SRAM 的末尾, 由 _stack_pointer 指定栈顶初值;
 *   * 输出/退出 -> putch() 写 UART16550, halt() 用 ebreak。
 *
 * .data/.bss 的"运行时地址"在 SRAM, 但 .data 的"加载地址"仍在 MROM 中
 * (MROM 里的程序镜像由仿真环境提供, 无法在运行时修改)。因此 TRM 的入口
 * (start.S) 需要实现一个简单的 bootloader: 把 .data 从 MROM 拷贝到 SRAM,
 * 并把 .bss 清零, 之后程序才能读写全局变量 (讲义"支持全局变量的写入操作")。
 */
ENTRY(_start)
PHDRS { text PT_LOAD; data PT_LOAD; }

MEMORY {
  mrom (rx)  : ORIGIN = 0x20000000, LENGTH = 4K
  sram (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
}

SECTIONS {
  . = ORIGIN(mrom);

  .text : {
    *(entry)
    *(.text*)
  } > mrom : text
  etext = .;
  _etext = .;

  .rodata : {
    *(.rodata*)
  } > mrom

  .data : {
    _data_start = .;
    *(.data*)
    *(.sdata*)
    _data_end = .;
  } > sram AT> mrom : data
  _data_lma = LOADADDR(.data);
  edata = .;
  _data = .;

  .bss : {
    _bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(.scommon)
    *(COMMON)
  } > sram
  _bss_end = .;

  /* ---- SRAM: 堆与栈 ----
   * 堆区从 .bss 之后开始, 向上增长; 栈顶在 SRAM 末尾, 向下增长。
   * mem-test 用 [heap_start, stack_top) 作为可写内存的测试范围。
   */
  _sram_base = ORIGIN(sram);
  _sram_end  = ORIGIN(sram) + LENGTH(sram);

  _stack_pointer = _sram_end;   /* 栈顶初值 (栈向低地址增长) */
  _stack_top     = _sram_end;

  end  = _sram_end;
  _end = _sram_end;

  _heap_start = ALIGN(4);
}
