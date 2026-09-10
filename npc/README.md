# NPC: minirv 处理器（D4）

用 RTL（SystemVerilog + Verilator）实现一个模块化的 minirv 处理器。

## minirv ISA

- PC 初值为 `0x80000000`（minirv-npc 运行时环境约定；单独仿真时程序也从这里开始）；
- GPR 数量与 RV32E 一致（16 个，`x0` 恒为 0）；
- 只支持 8 条指令：`add, addi, lui, lw, lbu, sw, sb, jalr`；
- 其余编码细节与 RV32I 相同；
- 额外支持 `ebreak`（AM 的 nemu_trap），用于通知仿真环境结束并携带 `$a0` 退出码。

## 目录结构

```text
vsrc/top.sv       顶层（clk/rst）
vsrc/npc_core.sv  核心：IFU/IDU/EXU/LSU/WBU + DPI-C 访存/停机
vsrc/regfile.sv   16 x 32 通用寄存器组（x0 硬连线为 0）
csrc/main.cpp     仿真环境：加载镜像、内存模型、时钟驱动、HIT GOOD/BAD TRAP
```

存储器（128 MiB，从 0x80000000 开始）用 C++ 实现：

- `pmem_read(addr)`：返回 `addr & ~3` 处对齐的 4 字节；
- `pmem_write(addr, data, wmask)`：按字节写掩码写回 4 字节；
- RTL 通过 DPI-C 调用它们；取指和访存共用这套“总线”接口。

## 使用

```bash
make                 # 编译出 build/top
make run IMG=xxx.bin # 运行镜像
make clean
```

通过 AM 一键运行（见 D4 讲义）：

```bash
export AM_HOME=/home/ligan/ysyx-workbench/abstract-machine
export NPC_HOME=/home/ligan/ysyx-workbench/npc
cd /home/ligan/ysyx-workbench/am-kernels/tests/cpu-tests
make ARCH=minirv-npc ALL=dummy run
```
