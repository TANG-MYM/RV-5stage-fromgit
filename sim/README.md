# VCS + Verdi 仿真 / 功能验证流程

本目录提供基于 **Synopsys VCS**（编译/仿真）与 **Verdi**（波形 & 源码调试）的
验证环境，针对 HiRiscy（**RV32I**）5 级流水线 SoC。

## 目录内容

| 文件 | 作用 |
|------|------|
| `filelist.f`   | RTL + testbench 源文件清单（含 `+incdir`），供 VCS `-f` 使用 |
| `Makefile`     | VCS 编译、运行、Verdi 调试、清理等目标 |
| `setup_env.sh` | VCS_HOME / VERDI_HOME / license 环境变量模板（需自行填写路径） |

## 使用步骤

```bash
cd sim

# 1) 配置工具环境（先编辑 setup_env.sh 里的路径和 license）
source ./setup_env.sh

# 2) 编译（默认开启 FSDB 波形 + KDB 源码调试）
make comp

# 3) 运行仿真（自动把 ../tb/firmware.hex 拷到当前目录）
make run

# 4) 用 Verdi 打开波形做功能验证
make verdi

# 5) 清理所有生成物
make clean
```

## 说明

- **波形**：编译时通过 `+define+FSDB` 打开 testbench 内的 `$fsdbDump*`，
  仿真后生成 `hiriscy_soc.fsdb`。`make verdi` 会同时加载 `simv.daidir`(KDB)，
  支持源码级调试。
- **VCD（可选）**：testbench 仍保留 VCD 通路，运行时加 plusarg 即可：
  `make run RUN_ARGS="+VCD"`，生成 `hiriscy_soc.vcd`。
- **固件**：SoC 通过 `$readmemh("firmware.hex", ...)` 加载程序，Makefile 会自动
  把 `../tb/firmware.hex` 拷贝到运行目录。
- **FSDB PLI**：当 `VERDI_HOME` 已设置时，Makefile 会自动链接
  `$VERDI_HOME/share/PLI/VCS/$PLATFORM/{novas.tab,pli.a}`。如平台目录不是
  `LINUX64`，在 `setup_env.sh` 里修改 `PLATFORM`。
- 顶层模块为 `tb_hiriscy_soc`；仿真结束会打印 `PASSED / FAILED` 统计。
