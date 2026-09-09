# NPC: sCPU（数列求和处理器）

把 sCPU 作为 NPC 的设计目标：用 RTL 实现一个只支持 sISA 的简单处理器，
运行 1+2+...+10 的求和程序，并通过 NVBoard 的七段数码管显示计算结果。

## sISA 指令集

PC 为 4 位（初值 0），GPR 为 4 个 8 位寄存器。

```
add    rd, rs1, rs2  | 00 | rd | rs1 | rs2 |  R[rd] = R[rs1] + R[rs2]
li     rd, imm       | 10 | rd |   imm    |  R[rd] = imm（高位补 0）
bner0  addr, rs2     | 11 | addr  | rs2   |  if (R[0] != R[rs2]) PC = addr
out    rs            | 01 | rs |  0000    |  将 R[rs] 以十六进制输出到数码管
```

`out rs` 是讲义 F5 必做题要求添加的指令，这里选用未被占用的操作码 `01`，
`rs` 位于 `[5:4]`。

## 求和程序

ROM 中内嵌的程序（`vsrc/scpu.v`）：

```
li r1, 0       # sum = 0
li r2, 1       # i = 1
li r3, 1       # step = 1
li r0, 11      # 循环直到 i == 11
add r1, r1, r2 # sum += i
add r2, r2, r3 # i += 1
bner0 4, r2    # if (R[0] != i) goto 4
out r1         # 显示结果
bner0 8, r1    # 停机：原地循环
```

计算完成后 R[1] = 55 = 0x37，数码管按十六进制显示为 `37`
（NVBoard N4 板上 `seg7` 在最左侧，作为高 4 位，`seg6` 作为低 4 位，
从左到右读作 37）。

## 使用

先设置环境变量 `NVBOARD_HOME` 指向 NVBoard 项目路径，然后在 `npc/` 下：

```bash
make           # 编译 NVBoard 目标
make run       # 打开 NVBoard 窗口运行
make sim       # 运行 RTL 仿真（对比软件模型，验证结果）
make clean     # 清理
```
