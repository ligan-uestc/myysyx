# NPC: RV32E 处理器（C2/D4/B1/B2）

> **B5 更新**：NPC 增加了一个**五级流水线**实现，并且可以在两套实现之间切换。
> * `vsrc/npc_pipe_core.sv`：IF/ID/EX/MEM/WB 五级流水线
>   * 数据冒险：转发（EX/MEM、MEM/WB → ID）+ 生产者还在 EX 时的停顿；
>   * 控制冒险：预测不跳转，EX 段检查并冲刷；
>   * 异常：ecall/mret 在 EX 处理（mepc 精确），并冲刷流水线；
>   * `fence.i`：冲刷流水线 + 冲刷 icache；
> * `make`/`make soc` 默认用流水线核心，`make CORE=multi` 切回多周期实现；
> * 新增 `tools/branchsim/`（分支预测准确率评估），`cachesim -M` 支持 mtrace（dcache 评估）；
> * 新增 `tests/{trap.c, fence-smc.c}`（异常处理、fence.i 反例）。
> * 性能（crc32，ysyxSoC）：多周期 56795 周期 / IPC 0.386 → 流水线 46466 周期 / IPC 0.471。
>
> 详见 `lecture/B5_流水线处理器_完成过程.md`。

> **B4 更新**：加入性能计数器与简易 icache。
> * `vsrc/icache.sv`：可配置的直接映射 icache（块大小/块数可调；只有存储器
>   类型的地址走 cache，SRAM 与设备旁路）；命中当拍返回，不额外增加取指周期；
> * `fence.i`：按讲义方案 (3) 冲刷整个 icache；
> * 性能计数器（`PERF=1`）：IPC、IFU/LSU/EXU 事件、指令类别、icache 命中/缺失、
>   AMAT 相关数据，`make perf` 直接打印成表（见 `tools/perf_report.py`）；
> * `tools/cachesim/`：cache 模拟器，可对 icache 做**性能测试的 DiffTest**
>   （命中/缺失次数与 RTL 完全一致），并支持并行设计空间探索（`dse.py`）；
> * `tests/{smc.c,loader.c}`：复现"自修改代码"与"加载器"导致的缓存一致性问题。
>
> 详见 `lecture/B4_性能优化和简易缓存_完成过程.md`。

> **B2 更新**：NPC 已经接入 ysyxSoC。
> * 访存接口从 AXI4-Lite 扩展为**完整 AXI4**（`vsrc/axi4_if.sv`，带
>   `id/len/size/burst/last`；`arsize/awsize` 由访存指令的宽度决定）；
> * 新增符合 `spec/cpu-interface.md` 的顶层 `vsrc/ysyx_22040000.sv`
>   （不再包含习题用的 AXI4-Lite SRAM/UART，但保留 CLINT）；
> * 新增 SoC 仿真环境 `csrc/soc_main.cpp` 与构建目标 `make soc` / `make soc-run`，
>   verilator 的顶层模块是 ysyxSoC 的 `ysyxSoCFull`；
> * 新增 DPI-C 退休回调 `npc_retire()`，用于在 SoC 仿真里做 trace 与 DiffTest；
> * 复位期间不驱动 AXI 请求（SoC 会刻意延迟 CPU 复位 10 个周期）；
> * 新增裸机小程序 `tests/char-test.c`（输出 `A`）与 `--autoflush` 选项。
>
> 详见 `lecture/B2_SoC计算机系统_完成过程.md`。

用 RTL（SystemVerilog + Verilator）实现的模块化**多周期**处理器，支持完整的
RV32E 指令集，通过 **AXI4-Lite 总线**访问存储器与设备，并配有
sdb / trace / DiffTest 三套调试基础设施。

## ISA

- PC 初值为 `0x80000000`（npc 运行时环境约定）；
- GPR = 16 个（RV32E），`x0` 恒为 0；
- 指令：`lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu
  sb sh sw addi slti sltiu xori ori andi slli srli srai add sub sll slt
  sltu xor srl sra or and`，以及 `fence`(空操作)、`ebreak`(AM 的 nemu_trap，
  携带 `$a0` 退出码)、`ecall`(自陷异常) 和 `mret`(异常返回)；
- CSR：`csrrw/csrrs/csrrc/csrrwi/csrrsi/csrrci`；已实例化
  `mstatus/mtvec/mepc/mcause`、`mcycle/mcycleh`(64 位周期计数器)、
  `mvendorid`("ysyx" = 0x79737978) 与 `marchid`(学号 22040000)；
- 不含 M 扩展：乘除法由 AM 的 `riscv/npc/libgcc/*` 软件例程实现。

## 目录结构

```text
vsrc/top.sv        顶层：NPC + 仲裁器 + Xbar + 从设备 + 调试端口
vsrc/npc_core.sv   核心：多周期 FSM，IFU/LSU 为 AXI4-Lite master
vsrc/alu.sv        组合逻辑 ALU
vsrc/regfile.sv    16 x 32 通用寄存器组（x0 硬连线为 0，复位清零）
vsrc/alu_ops.svh   ALU 操作码定义
vsrc/axi4lite_if.sv  AXI4-Lite interface（5 个通道的握手信号）
vsrc/axi_arbiter.sv  AXI4-Lite 仲裁器（IFU/LSU -> 1 个 slave）
vsrc/axi_xbar.sv     AXI4-Lite 地址译码（存储器 / CLINT / UART）
vsrc/axi_mem.sv      AXI4-Lite 存储器从设备（DPI 支撑 + LFSR 随机延迟）
vsrc/axi_uart.sv     AXI4-Lite UART 从设备（写 -> $write）
vsrc/axi_clint.sv    AXI4-Lite CLINT（mtime / mtimecmp）
csrc/main.cpp      仿真环境：参数解析、时钟驱动、批处理
csrc/memory.cpp    物理内存模型 + DPI-C(pmem_read/pmem_write/ebreak)
csrc/sdb.cpp       简易调试器：si / info r / x N ADDR / c / q
csrc/trace.cpp     itrace(capstone) / mtrace / ftrace(ELF 符号)
csrc/difftest.cpp  与 NEMU 共享库逐条对比（Differential Testing）
tools/build-ref.sh 生成 DiffTest 的 REF（riscv32-nemu-interpreter-so）
tools/sta/         yosys-sta 主频评估脚本与说明
```

存储器（128 MiB，从 0x80000000 开始）用 C++ 实现，RTL 通过 DPI-C 使用：

- `pmem_read(addr)`：返回 `addr & ~3` 处对齐的 4 字节；
- `pmem_write(addr, data, wmask)`：按字节写掩码写回 4 字节。

另外，写地址 `0xa00003f8` 会经过 Xbar 送到 UART 从设备，写入的字节由
`$write` 输出到终端，AM 的 `putch()` 就是往这里写；CLINT 提供只读的
`mtime`（每周期 +1）和可写的 `mtimecmp`。

## 使用

```bash
make                           # 编译出 build/top
make run IMG=xxx.bin ARGS=-b   # 批处理运行镜像
make RAND_DELAY=1              # 打开存储器的 LFSR 随机延迟（总线压力测试）
npc/build/top [OPTION] IMAGE   # 不加 -b 时进入 sdb
```

常用选项：`-b` 批处理（不进入 sdb）、`-e ELF`（ftrace 需要）、
`-l FILE`（trace 日志）、`-t` 打开 itrace+mtrace+ftrace、
`-d REF_SO` 打开 DiffTest、`-n N` 限制最大指令数。

通过 AM 一键运行（不需要手动传镜像）：

```bash
export AM_HOME=/home/ligan/ysyx-workbench/abstract-machine
export NPC_HOME=/home/ligan/ysyx-workbench/npc
cd /home/ligan/ysyx-workbench/am-kernels/tests/cpu-tests
make ARCH=riscv32e-npc ALL=dummy run                       # RV32E
make ARCH=riscv32e-npc ALL=recursion run NPC_EXTRA_FLAGS="-t -l /tmp/npc.log"
make ARCH=riscv32e-npc run NPC_EXTRA_FLAGS="-d /path/to/riscv32-nemu-interpreter-so"
make ARCH=minirv-npc ALL=dummy run                         # D4 流程仍然可用
```

DiffTest 的 REF 用 `npc/tools/build-ref.sh` 生成（会临时切换 NEMU 的编译
目标，结束后自动恢复）。
