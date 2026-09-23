# NPC 的主频评估 (yosys-sta)

B1 总线讲义要求用 yosys-sta 评估 NPC 的主频。本目录提供把 NPC 的
SystemVerilog 转成可综合 Verilog 的脚本，配合 [yosys-sta](https://github.com/OSCPU/yosys-sta)
即可得到主频与面积。

## 依赖

```bash
# 1) yosys (>= 0.48), 这里用 oss-cad-suite 的预编译包
#    https://github.com/YosysHQ/oss-cad-suite-build/releases
export PATH=/path/to/oss-cad-suite/bin:$PATH

# 2) sv2v: 把 SystemVerilog 的 interface 展开成普通 Verilog (yosys 不直接支持 interface)
#    https://github.com/zachjs/sv2v/releases

# 3) yosys-sta: git clone https://github.com/OSCPU/yosys-sta && cd yosys-sta && make init
```

## 步骤

```bash
NPC=~/ysyx-workbench/npc
SV2V=/path/to/sv2v
YOSYS_STA=/path/to/yosys-sta

# 1) 把带 interface 的 RTL 展开成一个扁平 module
mkdir -p /tmp/svwork && cd /tmp/svwork
cp $NPC/vsrc/*.sv $NPC/vsrc/*.svh .
$SV2V --write=adjacent -I. axi4lite_if.sv alu.sv regfile.sv axi_mem.sv \
      axi_uart.sv axi_clint.sv axi_arbiter.sv axi_xbar.sv npc_core.sv top.sv

# 2) 去掉不可综合的 DPI-C / $write (讲义: DPI 实现的存储器不在评估范围内)
python3 $NPC/tools/sta/prepare_sta.py top.v top_sta.v

# 3) 综合 + 时序分析 (top 是顶层模块名, DESIGN 必须与之一致)
cd $YOSYS_STA
make syn DESIGN=top RTL_FILES="/tmp/svwork/top_sta.v /tmp/svwork/alu.v /tmp/svwork/regfile.v" CLK_FREQ_MHZ=500
make sta DESIGN=top CLK_FREQ_MHZ=500

# 4) 查看结果
head -8 result/top-500MHz/top.rpt        # 每个端点的 Path Delay / Slack / Freq(MHz)
grep -E "Chip area|sequential" result/top-500MHz/synth_stat.txt
```

## 本机实测结果 (icsprout55 H7L, 2026-09-17)

```text
| Endpoint              | Delay Type | Path Delay | Slack  | Freq(MHz) |
| gpr_dbg[189]_reg_p:D  | max        | 2.081f     | -0.127 | 470.112   |   <- 关键路径

Chip area for module '\top': 19062.96   (sequential 占 37.71%)
```

也就是：**Fmax ≈ 470 MHz @ nangate45/icsprout55 H7L 工艺**，关键路径是
写回数据进入寄存器堆的那一段 (`gpr_dbg[...]:D`，寄存器堆端口被 sv2v 按
debug 端口命名)。作为对比，讲义中参考的 AXI4-Lite 多周期 NPC 在 nangate45
下约 297.7 MHz。

> 说明：`--no-debug` 选项会把只给仿真环境用的调试输出 (pc/inst/gpr_dbg/
> mem_*/dbg_*) 的驱动去掉，用于评估"真实芯片"里的主频；本机两种情况下
> 关键路径相同，都是写回→寄存器堆这段。
