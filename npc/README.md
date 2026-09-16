# NPC: RV32E 单周期处理器（C2/D4）

用 RTL（SystemVerilog + Verilator）实现的模块化单周期处理器，支持完整的
RV32E 指令集，并配有 sdb / trace / DiffTest 三套调试基础设施。

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
vsrc/top.sv        顶层（clk/rst + 调试端口）
vsrc/npc_core.sv   核心：IFU/IDU/EXU/LSU/WBU + DPI-C 访存/停机
vsrc/alu.sv        组合逻辑 ALU
vsrc/regfile.sv    16 x 32 通用寄存器组（x0 硬连线为 0，复位清零）
vsrc/alu_ops.svh   ALU 操作码定义
csrc/main.cpp      仿真环境：参数解析、时钟驱动、批处理
csrc/memory.cpp    物理内存模型 + DPI-C(pmem_read/pmem_write/ebreak)
csrc/sdb.cpp       简易调试器：si / info r / x N ADDR / c / q
csrc/trace.cpp     itrace(capstone) / mtrace / ftrace(ELF 符号)
csrc/difftest.cpp  与 NEMU 共享库逐条对比（Differential Testing）
tools/build-ref.sh 生成 DiffTest 的 REF（riscv32-nemu-interpreter-so）
```

存储器（128 MiB，从 0x80000000 开始）用 C++ 实现，RTL 通过 DPI-C 使用：

- `pmem_read(addr)`：返回 `addr & ~3` 处对齐的 4 字节；
- `pmem_write(addr, data, wmask)`：按字节写掩码写回 4 字节。

另外，写地址 `0xa00003f8` 被当作简化串口（与 NEMU 的串口地址一致），
写入的字节直接输出到终端，AM 的 `putch()` 就是往这里写。

## 使用

```bash
make                           # 编译出 build/top
make run IMG=xxx.bin ARGS=-b   # 批处理运行镜像
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
