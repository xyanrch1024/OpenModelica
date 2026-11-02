# HGT 稳态运行时设计（交互式 FMU + Python 稳态接口）

本文是设计文档，**还没有实现**。目标是在 OMC 中提供类似 OCT `oct.steadystate` 的稳态求解接口：用 omc 把带手动引导撕裂（HGT）注解的模型编译成**交互式 FMU**，在 Python 中用 `FMUProblem` 和 `Solver` 求解稳态，并在同一个会话里随时 hold / release 迭代变量和残差。

相关文档：

- [HGT_developer_guide.md](HGT_developer_guide.md)：HGT 的整体实现
- [HGT_hold.md](HGT_hold.md)：现在的 hold 实现（编译期改写残差）
- [HGT_matching_and_tearing.md](HGT_matching_and_tearing.md)：后端的匹配与撕裂
- [HGT_design.md](HGT_design.md)：OCT 规范要点（R1–R11）

## 目录

1. [目标与范围](#1-目标与范围)
2. [OCT 的做法](#2-oct-的做法)
3. [现状](#3-现状)
4. [总体结构](#4-总体结构)
5. [求解器放在哪里](#5-求解器放在哪里)
6. [稳态问题的表示](#6-稳态问题的表示)
7. [编译器：交互模式](#7-编译器交互模式)
8. [交互式 FMU 的接口](#8-交互式-fmu-的接口)
9. [Python 包 omsteady](#9-python-包-omsteady)
10. [求解算法](#10-求解算法)
11. [和现在的实现相比](#11-和现在的实现相比)
12. [分阶段计划与工作量](#12-分阶段计划与工作量)
13. [测试](#13-测试)
14. [风险](#14-风险)
15. [待定的问题](#15-待定的问题)

---

## 1. 目标与范围

**目标**

- 编译选项 `--interactiveFMU`，生成标准 FMI 2.0 Model Exchange 的 FMU。FMU 只负责"给定迭代变量，算出残差"，不在内部求解 HGT 块。
- Python 包 `omsteady`，API 尽量和 OCT 同名：`FMUProblem`、`Solver`、`holdIterationVariables`、`releaseIterationVariables`、`printInfo` 等。
- hold 和 OCT 对齐：迭代变量和残差可以**分开** hold，可以跨块；被 hold 的变量保持**当前值**；注解里的 hold 参数（parametric hold）和 API 设的 hold 同时生效。
- 残差 nominal 真正参与缩放，迭代变量的 min/max 在每一步迭代中都生效。

**不做**

- 动态仿真：交互式 FMU 只用于稳态。普通仿真和普通 FMU 继续用现在的实现。
- 新后端：先只做旧后端。
- 第一版不支持带状态的模型（§12 第二阶段）。

## 2. OCT 的做法

已查到的部分（Modelon 帮助中心和 OCT 用户手册）：

- 编译时打开 `interactive_fmu=true`，生成交互式 FMU。在交互式 FMU 中，**初始化系统和 DAE 系统是同一个系统**。
- Python 中用 `oct.steadystate.nlesol` 的 `FMUProblem` 包装 FMU，交给 `Solver` 求解；`Solver` 基于 KINSOL。
- `FMUProblem` 提供 `holdIterationVariables`、`releaseIterationVariables`；`printInfo` 有 `'held'`、`'all'`、`'parametricHold'` 等选项。MATLAB 例子在建 `FMUProblem` 时传入变量名 `'x'` 和残差名 `'res_0'`。
- 注解中的 `hold` 绑定 Boolean 参数（R10），在 `FMUProblem` 中生效。

推断的部分（手册没有明说）：

- HGT 的迭代变量和残差暴露在 FMU 接口上，FMU 内部不求解这些块，由外层 `Solver` 驱动 Newton 迭代。
- 被 hold 的迭代变量保持当前值。

## 3. 现状

| 部分 | 现在 |
|---|---|
| 运行时 | 仿真运行时：初始化后时间积分；HGT 块在每一步由通用非线性求解器（homotopy、hybrid、KINSOL）各自求解 |
| hold | 编译期把残差改写成 `if hold then x - $START.x else ...`；按配对；保持 start 值；两次运行之间用 `-override` 切换（见 [HGT_hold.md](HGT_hold.md)） |
| 残差 nominal | 除进方程；默认被求解器按雅可比矩阵的自动缩放抵消 |
| min/max | 起点投影加解检查（`hgtBounds`），迭代中间不保证在界内 |
| FMU 中的求解器 | 只带 hybrid、homotopy 和 CVODE（`RuntimeSources.mo`），**没有 KINSOL** |
| 方向导数 | FMU 已经能导出"输出对输入、状态"的方向导数（FMIDER 雅可比矩阵） |

## 4. 总体结构

```
┌──────────────────────── Python：omsteady ────────────────────────┐
│ FMUProblem：读配对表；hold / release；set / get；parametric hold │
│ Solver：全局阻尼 Newton；残差缩放；界投影；1×1 用 Brent；日志    │
└──────────────────────────────────────────────────────────────────┘
          │ fmi2SetReal（迭代变量）        ▲ fmi2GetReal（残差）
          ▼                                │ fmi2GetDirectionalDerivative（第二阶段）
┌────────────── 交互式 FMU（omc --interactiveFMU 生成）─────────────┐
│ 输入：HGT 迭代变量                                                │
│ 计算：按 BLT 顺序执行；HGT 块只算内部方程和残差，不求解；          │
│       非 HGT 的代数环照常在内部求解                                │
│ 输出：HGT 残差                                                    │
│ 元数据：modelDescription.xml 的 VendorAnnotations 中的配对表       │
└──────────────────────────────────────────────────────────────────┘
```

两条路径并存：

- **普通仿真和普通 FMU**：完全不变，继续用现在的实现。
- **交互式 FMU**：新的编译模式。前端、`hgtMatching`、`Tearing.handGuidedTearing` 两边共用，差别只在 `HandGuidedTearing.lower` 要不要改写残差，以及代码生成走哪条路径。

## 5. 求解器放在哪里

| | S1：Python 求解器（推荐） | S2：C 求解器打包进 FMU | S3：独立的 C 库 `libOMSteady` |
|---|---|---|---|
| FMU | 标准 FMI | 多导出非标准函数（`oss_solve`、`oss_hold` 等） | 标准 FMI |
| 求解器代码 | Python + numpy | C，可以复用 `kinsolSolver.c`，但要把 KINSOL 打包进 FMU | C，单独发布 |
| 速度 | 每次求残差一次 FMI 调用；中小模型足够，大模型靠方向导数 | 最快 | 快 |
| 开发与调试 | 最快，求解策略容易调整 | 慢；C 和 Rust 运行时各要一份 | 中等；Python 包要带本地库 |
| 能否脱离 Python | 不能 | 能 | 能（C、OMSimulator、MATLAB） |
| 和 OCT 的对应 | 一致：OCT 的 `Solver` 也在 Python 包中 | 不一致 | 介于两者之间 |

**建议**：第一版用 S1。以后性能不够，或者要在 Python 以外使用时，把 `Solver` 下沉成 S3，Python API 保持不变。

## 6. 稳态问题的表示

### 6.1 未知量和方程

- 设所有 HGT 块的迭代变量为 `v[1..n]`，残差为 `r[1..m]`（包括自动补的项，见 §7.3）。正常情况下 `n = m`。
- 未被 hold 的迭代变量是未知量 `u`，未被 hold 的残差是方程 `F(u) = 0`。
- **全局求解**：所有块合成一个问题，一次 Newton。雅可比矩阵是块三角的（BLT 顺序），第一版不利用这一点，第二阶段可以按块分解提速。

### 6.2 hold 的语义

| 规则 | 说明 |
|---|---|
| 变量和残差分开 hold | `holdIterationVariables`、`holdResiduals` 各自独立，可以跨块 |
| 平衡检查 | 每次 `solve()` 前检查：未被 hold 的迭代变量个数 = 未被 hold 的残差个数，否则报错并列出两边 |
| 保持当前值 | 被 hold 的变量取 FMU 中的当前值：用户 `set` 的值，或上一次的解 |
| parametric hold | 每次 `solve()` 前读出注解中 hold 参数的当前值；为 true 的配对，它的迭代变量和残差都算 hold |
| 合并 | 实际 hold 集合 = API 设的 hold ∪ parametric hold |
| 结构奇异 | 平衡但结构奇异（例如 hold 掉的变量正好是某条释放残差唯一依赖的变量）时，Newton 的雅可比矩阵奇异；第一版报错，给出秩亏的行列 |

和现在 [HGT_hold.md](HGT_hold.md) 的区别：那里是按配对、保持 start、两次运行之间切换；这里是 OCT 的完整语义。

### 6.3 状态

第一版只支持没有状态的模型，交互模式下遇到状态报错。第二阶段：状态变成迭代变量，`der(x) = 0` 变成残差（§12）。

## 7. 编译器：交互模式

### 7.1 选项

- `--interactiveFMU`（config flag）：必须和 `--handGuidedTearing` 一起用，只影响 `buildModelFMU`。
- 第一版要求 `--hgtOnly`，见 §7.3。

### 7.2 后端

| 位置 | 改动 |
|---|---|
| `HandGuidedTearing.lower` | 交互模式下**不改写残差**：不做 hold 的 `if` 改写，也不除以 nominal。nominal 和 hold 作为元数据导出 |
| 初始化 | 初始化系统和仿真系统合并成一个（和 OCT 一样）；没有状态时，两者本来就几乎相同 |
| `hgtMatching`、`Tearing.handGuidedTearing` | 不变 |

### 7.3 自动补的迭代变量

`Tearing.handGuidedTearing` 在用户的项不够时会自动补迭代变量和残差。交互模式下有两种做法：

- 第一版：要求 `--hgtOnly`，不会有自动补的项，接口上只有用户写的配对，名字稳定。
- 以后：把自动补的项也暴露出来，名字自动生成（例如 `$hgtAuto.<变量名>`、`$hgtAutoRes<n>`），在配对表中标记为自动。

### 7.4 SimCode 与代码生成

- 现在每个 HGT 块生成为一个非线性系统，它的残差函数（`residualFunc`）已经包含"由迭代变量算内部方程、再算残差"。
- 交互模式下，模板对 HGT 块生成"只求值"的调用，代替调用非线性求解器：

  ```c
  /* 交互模式下的 HGT 块 */
  copy_inputs_to_iteration_vars(data, sysIndex);  /* 迭代变量取 FMU 输入的值 */
  residualFunc(data, x, res);                     /* 算内部方程和残差 */
  copy_residuals_to_outputs(data, res);           /* 残差写到 FMU 输出 */
  ```

- 非 HGT 的代数环、普通方程照常执行。
- 新增 SimCode 字段：交互模式标志；每个 HGT 块的迭代变量和残差在 FMU 变量表中的位置。

### 7.5 方向导数（第二阶段）

迭代变量是输入、残差是输出，正好可以用已有的 FMIDER 雅可比矩阵（输出对输入的偏导）提供 `fmi2GetDirectionalDerivative`。需要确认 FMIDER 在"HGT 块只求值"的路径下仍然正确。

## 8. 交互式 FMU 的接口

### 8.1 变量

| 内容 | modelDescription.xml |
|---|---|
| HGT 迭代变量 | `causality="input"`、`variability="continuous"` 的 Real；名字就是变量名 |
| HGT 残差 | 新增的 `causality="output"` Real；名字是方程名加前缀，例如 `$res.e2`、`$res.valve.law` |
| hold 参数 | 原有的参数，不变 |
| 其余变量 | 不变 |

### 8.2 配对表（VendorAnnotations）

```xml
<VendorAnnotations>
  <Tool name="OpenModelica">
    <HandGuidedTearing version="1">
      <Pair residual="$res.e2" residualName="e2" nominal="2.0"
            iterationVariable="x" start="1.5" min="0.0" max="10.0" variableNominal="1.0"
            hold="h" block="1"/>
      ...
    </HandGuidedTearing>
  </Tool>
</VendorAnnotations>
```

- 属性值是参数表达式时，导出的是**值引用**或表达式字符串，第一版只支持常数和单个参数名（求解器用 `fmi2GetReal` 读参数的当前值）。
- `block` 是 BLT 块编号，供第二阶段按块分解使用。

### 8.3 调用顺序

```
fmi2Instantiate → fmi2SetupExperiment → fmi2EnterInitializationMode
  → fmi2SetReal(参数) → fmi2ExitInitializationMode
loop:
  fmi2SetReal(迭代变量) → fmi2GetReal(残差)   # 每次求值
```

`fmi2ExitInitializationMode` 在交互模式下只做一次求值，不求解 HGT 块。之后改参数需要 FMI 2.0 的 tunable 参数，或者重新进入初始化模式；第一版在 Python 侧封装成 `p.set()`，内部按需要 reset。

## 9. Python 包 omsteady

### 9.1 依赖

- FMPy（加载 FMU、FMI 调用），numpy；scipy 可选（Brent、稀疏线性求解）。
- 不依赖 OMPython：FMU 可以在别处编译好。

### 9.2 API

```python
from omsteady import FMUProblem, Solver

p = FMUProblem("Plant.fmu")
p.printInfo("all")                      # 所有配对、当前值、hold 状态
p.set("load", 0.8)                      # 参数
p.holdIterationVariables(["m_flow"])    # 设计工况：流量给定
p.set("m_flow", 2.0)
p.holdResiduals(["valve.law"])
sol = Solver(p, residual_scaling="hybrid").solve()
print(sol.success, sol.iterations, sol.residual_norm)
print(p.get(["p_in", "valve.opening"]))

p.releaseIterationVariables(["m_flow"])
p.releaseResiduals(["valve.law"])
sol = Solver(p).solve()                 # 校核工况，从上一次的解出发
p.printInfo("held")
p.printInfo("parametricHold")
```

| 类 / 方法 | 作用 |
|---|---|
| `FMUProblem(path)` | 加载 FMU，读配对表，实例化并初始化 |
| `set(name, value)` / `get(names)` | 设值、读值；迭代变量的 `set` 就是设初值或保持值 |
| `holdIterationVariables(names)` / `releaseIterationVariables(names)` | 按名字 hold / 释放迭代变量；也接受下标，和 OCT 一样 |
| `holdResiduals(names)` / `releaseResiduals(names)` | 按名字 hold / 释放残差 |
| `printInfo(what)` | `'all'`、`'held'`、`'parametricHold'` |
| `residuals(u)`、`jacobian(u)` | 给求解器用：求残差；求雅可比矩阵（差分或方向导数） |
| `Solver(problem, **options)` | 选项见 §10.4 |
| `Solver.solve()` | 返回 `Solution`：`success`、`iterations`、`residual_norm`、`message`，失败时有诊断信息 |

### 9.3 发布

- 第一版放在仓库的 `OMSteady/`（或 `OMPython` 旁边），用 `pip install -e` 安装。
- 以后发布到 PyPI。

## 10. 求解算法

### 10.1 主循环（阻尼 Newton）

```
u := 未被 hold 的迭代变量的当前值，投影到 [min, max]
for k in 1..maxIter:
    F := 缩放后的残差 S_r · F(u)
    if ‖F‖ ≤ tol: 成功
    J := 雅可比矩阵（差分或方向导数），按 S_r 和 S_x 缩放
    du := 解 J · du = -F（奇异时最小二乘，并报告）
    线搜索：λ = 1, 1/2, ...，u_new = proj(u + λ·du)，直到 ‖F(u_new)‖ 足够下降
    u := u_new
失败：报告最大残差、它的方程名、最后的步长
```

### 10.2 缩放

| 选项 `residual_scaling` | 残差缩放 `S_r` |
|---|---|
| `"none"` | 1 |
| `"automatic"` | 按雅可比矩阵每行的最大值（和 OMC 的 KINSOL 一样），每次更新雅可比矩阵时重算 |
| `"manual"` | 1 / 残差 nominal（配对表中的 `nominal`，没写就是 1） |
| `"hybrid"`（默认） | 写了 nominal 的用 nominal，其余自动 |

迭代变量缩放 `S_x` 用迭代变量的 nominal。这样，现在实现中"残差 nominal 被自动缩放抵消"的问题在这里不存在。

### 10.3 界

- 每一步都把 `u` 投影到 `[min, max]`；线搜索中撞到界时，先截断步长再投影。
- 只有一个未知量时可以选 Brent 法（有界、保证收敛），对应 OCT 1×1 块的做法。

### 10.4 Solver 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `tol` | 1e-8 | 缩放后残差的范数 |
| `max_iter` | 100 | |
| `residual_scaling` | `"hybrid"` | §10.2 |
| `jacobian` | `"auto"` | 有方向导数就用，否则差分 |
| `line_search` | True | |
| `brent_1d` | True | 只有一个未知量时用 Brent |
| `log_level` | 0 | 每步打印范数、步长、最大残差 |

## 11. 和现在的实现相比

| | 现在（仿真运行时） | 稳态运行时 |
|---|---|---|
| hold | 按配对；保持 start；两次运行之间用 `-override` | 变量和残差可以分开、跨块；保持当前值；同一会话里随时 hold / release |
| 求解 | 每个块各自求解，要走时间积分 | 一次全局 Newton，没有积分器 |
| 残差 nominal | 除进方程，基本被自动缩放抵消 | 求解器真正使用，支持 auto / manual / hybrid |
| min/max | 起点投影加解检查 | 每一步都投影，1×1 可以用 Brent |
| 交互 | 每次都是完整的运行 | 保留状态，多次求解，参数扫描、设计和校核 |
| 互操作 | omc 自己运行 | 标准 FMU，Python 中使用 |
| 速度 | C，快 | 每次求残差一次 FMI 调用；大模型需要方向导数 |
| 维护 | 已经完成 | 新增编译模式、Python 包、测试；两条路径都要维护 |
| 动态仿真 | 支持 | 不管 |

## 12. 分阶段计划与工作量

| 阶段 | 内容 | 工作量 |
|---|---|---|
| **1. 第一版** | | **5–6 周** |
| 1a 编译器 | `--interactiveFMU`；`lower` 跳过改写；只求值的代码生成；初始化合并；要求 `--hgtOnly`、无状态 | 2 周 |
| 1b FMU 包装 | 迭代变量输入、残差输出；VendorAnnotations 配对表 | 1 周 |
| 1c Python 包 | `FMUProblem`、`Solver`（差分雅可比、缩放、界、线搜索）、hold API、日志 | 1.5–2 周 |
| 1d 测试和文档 | Python 测试接进 testsuite；用户文档和例子 | 0.5–1 周 |
| **2. 完整版** | | **再加 4–7 周** |
| 2a 方向导数 | FMIDER 接 `fmi2GetDirectionalDerivative` | 1–2 周 |
| 2b 带状态的模型 | 状态变成迭代变量，`der(x) = 0` 变成残差 | 1–2 周 |
| 2c 自动补的项 | 去掉 `--hgtOnly` 的要求，暴露自动补的迭代变量和残差 | 0.5 周 |
| 2d 求解器增强 | Brent、按块分解、诊断信息 | 1 周 |
| 2e Rust 运行时 | Rust 运行时版本的交互式 FMU | 1–2 周 |

## 13. 测试

| 测试 | 内容 |
|---|---|
| 编译器 | `buildModelFMU(..., --interactiveFMU)` 的 modelDescription：输入、输出、配对表（.mos 基准输出） |
| FMU 求值 | 用 FMPy 设迭代变量为已知解，读出的残差应为 0；设成别的值，残差和手算一致 |
| 求解 | `HGT.mo` 中现有的稳态模型（`Loop`、`Chain`、`Bound`、`Multi`、`Hold` 等）：交互式求解结果和现在的仿真结果一致 |
| hold | 分开 hold 变量和残差；跨块 hold；不平衡时报错；parametric hold；保持当前值（两次 `solve()` 之间） |
| 缩放和界 | `Bound` 模型：界防止 `log` 的参数为负；残差 nominal 改一个数量级时 `hybrid` 模式下收敛行为的变化 |
| 回归 | 不加 `--interactiveFMU` 时，现有 HGT 测试全部不变 |

## 14. 风险

| 风险 | 对策 |
|---|---|
| 只求值的代码生成：HGT 块之外的部分（代数环、事件、离散变量）在 FMI 求值顺序下是否正确 | 第一版限定为无状态、无事件的稳态模型，遇到不支持的结构在编译期报错 |
| FMI 调用开销：大模型差分雅可比太慢 | 方向导数（2a）可以提前到第一版 |
| 结构奇异的 hold 组合 | 求解前做结构秩检查，报出无法求解的变量和残差 |
| 参数表达式形式的属性（例如 `max = 20 - p`） | 第一版只导出常数和单个参数名；更复杂的表达式在编译期报警告 |
| OCT 行为是推断的 | 用 OCT 做对照实验，确认 hold 和普通仿真的关系后再定细节 |

## 15. 待定的问题

| 问题 | 建议 |
|---|---|
| 求解器放在哪里：S1 / S2 / S3 | S1（Python） |
| FMI 版本 | FMI 2.0 Model Exchange；FMI 3 以后再说 |
| 第一版是否支持带状态的模型 | 不支持，放到 2b |
| 自动补的迭代变量 | 第一版要求 `--hgtOnly` |
| 交互式 FMU 是否同时支持 Rust 运行时 | 第一版只做 C 运行时 |
| Python 包的位置和名字 | 仓库中的 `OMSteady/`，包名 `omsteady` |

参考：

- [Optimica Compiler Toolkit - Help Center](https://help.modelon.com/latest/reference/oct/)
- [OPTIMICA Compiler Toolkit User's Guide (Version 1.44)](https://help.modelon.com/latest/reference/assets/UsersGuide.pdf)
