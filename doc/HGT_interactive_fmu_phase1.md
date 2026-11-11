# HGT 稳态求解器方案：第一阶段实施文档

本文是稳态求解器方案（[HGT_steady_state_runtime.md](HGT_steady_state_runtime.md)）**第一阶段**的实施文档：做什么、不做什么、编译器和 Python 两边各改哪里、怎么验收。**还没有实现。**

相关文档：

- [HGT_steady_state_runtime.md](HGT_steady_state_runtime.md)：总体设计
- [HGT_cross_hold.md](HGT_cross_hold.md)：交叉 hold 和 OCT 官方例子
- [HGT_hold_runtime.md](HGT_hold_runtime.md)：在现有仿真运行时中做 hold 的另一个方案
- [HGT_matching_and_tearing.md](HGT_matching_and_tearing.md)：后端的匹配与撕裂

## 目录

1. [第一阶段的范围](#1-第一阶段的范围)
2. [做法：在后端把模型变换成"残差计算器"](#2-做法在后端把模型变换成残差计算器)
3. [编译器的改动](#3-编译器的改动)
4. [FMU 的接口](#4-fmu-的接口)
5. [Python 包 omsteady](#5-python-包-omsteady)
6. [官方例子走一遍](#6-官方例子走一遍)
7. [测试与验收](#7-测试与验收)
8. [里程碑与工作量](#8-里程碑与工作量)
9. [风险与待确认的问题](#9-风险与待确认的问题)
10. [第一阶段之后](#10-第一阶段之后)

---

## 1. 第一阶段的范围

**目标**：OCT 官方例子 `twoEqSteadyStateParaHold` 和 `HGT.mo` 中的稳态模型，能用 omc 编译成交互式 FMU，在 Python 中求解，并且支持 hold（包括交叉 hold、跨块的 hold）。

| | 第一阶段做 | 以后再做 |
|---|---|---|
| 编译选项 | `--interactiveFMU` | 暴露标量块的选项（OCT 的 `expose_scalar_equation_blocks_in_interactive_fmu`） |
| 模型 | 没有状态、没有事件的稳态模型 | 带状态（`der(x) = 0` 作残差）、带事件 |
| 暴露的项 | 用户写的 HGT 配对 | 自动撕裂出来的迭代变量和残差 |
| FMI | 2.0 Model Exchange | FMI 3、Co-Simulation |
| 运行时 | C 运行时 | Rust 运行时（`C+Rust` 目标下报错） |
| 雅可比矩阵 | 差分；FMU 已有的方向导数能用就用（§9） | 专门优化 |
| 求解 | 全部未知量联立的阻尼 Newton | 运行时分块、KINSOL 后端、1×1 用 Brent |
| hold | 参数（parametric hold）和 API；变量、残差分开；个数检查和结构检查 | |
| 缩放与界 | 残差 nominal（none / automatic / manual / hybrid）；每步投影到 [min, max] | |

普通仿真和普通 FMU 完全不受影响：不加 `--interactiveFMU` 时生成的代码必须和现在逐字节相同。

## 2. 做法：在后端把模型变换成"残差计算器"

总体设计 §7.4 设想的是改代码生成：HGT 块照常撕裂，生成时把 `solve_nonlinear_system` 换成"只求值"。第一阶段改用一个更简单的做法：**在后端匹配之前，把模型本身变换掉**，之后的整条流水线都不用改。

对每个 HGT 配对（残差方程 e：`lhs = rhs`，迭代变量 x）：

| 变换 | 结果 |
|---|---|
| x 从未知量变成**顶层输入** | 它的值由外面给，不再需要方程来解它 |
| 新增一个**顶层输出**变量 `$res.e` | |
| e 改写成 `$res.e = lhs − rhs` | 这条方程现在用来算 `$res.e`，不再约束 x |

每个配对去掉一个未知量（x），加上一个未知量（`$res.e`），方程数不变，系统仍然平衡。变换后的模型是一个普通的 Modelica 模型：给定输入（迭代变量），算出输出（残差）。例如官方例子变换后相当于：

```modelica
model twoEqSteadyStateParaHold_interactive
  input Real x(start = 1);
  input Real T(start = 400);
  output Real '$res.LongEq';
  output Real '$res.LongEq2';
  parameter Boolean testHold1 = false;
  parameter Boolean testHold2 = false;
equation
  '$res.LongEq'  = 0 - (120*x - 75*(0.12*exp(12581*(T - 298)/(298*T)))*(1 - x));
  '$res.LongEq2' = 0 - (-x*(873 - T) + 11.0*(T - 300));
end twoEqSteadyStateParaHold_interactive;
```

这样做的好处：

- **匹配、撕裂、SimCode、代码生成、FMU 导出都不用改。** 原来的 HGT 代数环在变换后自然消失：用户的迭代变量撕开之后，块内其余方程本来就能依次显式算出。
- **输出对输入的依赖关系自动得到。** 现有的 `SimCodeUtil.createFMIModelStructure` 从符号雅可比矩阵算出 `<ModelStructure><Outputs>` 的 `dependencies`，残差是输出、迭代变量是输入，所以"每条残差依赖哪些迭代变量"（包括跨块的间接依赖）直接出现在 `modelDescription.xml` 中，不用另外计算。
- **方向导数自动可用。** FMU 已经为"输出对输入"生成 FMIDER 雅可比矩阵，`fmi2GetDirectionalDerivative` 给出的就是残差对迭代变量的导数。
- **初始化系统和仿真系统自然一致**：变换在创建初始化系统之前做，两边用的是同一个变换后的模型。没有状态时，FMU 初始化之后的每次求值都只是把方程算一遍。
- **用户给的迭代变量不够时也能工作**：剩下的代数环留在 FMU 内部，由 FMU 自己的求解器解（和 OCT"只暴露部分块"的行为类似）。所以第一阶段**不需要**强制 `--hgtOnly`。
- hold、nominal、界都不进入方程，只作为元数据导出（§4）。

OCT 文档对 `interactive_fmu` 的描述是"DAE 系统被转换成交互式 FMU，残差方程和迭代变量变成顶层的输出和输入"，和这个做法一致。

## 3. 编译器的改动

路径相对 `OMCompiler/Compiler/`。

### 3.1 选项（`Util/Flags.mo`、`Util/FlagsUtil.mo`）

- 新增 config flag `interactiveFMU`（Bool，默认 false），描述中注明对应 OCT 的 `interactive_fmu`。flag 的编号必须连续（`checkConfigFlags`）。
- 检查（放在 `HandGuidedTearing.lower` 的开头）：
  - 没有打开 `--handGuidedTearing`：报错；
  - `--simCodeTarget=C+Rust`：报错，说明 Rust 运行时还不支持；
  - 不是 FMU 导出（普通 `simulate`/`buildModel`）：警告，模型会被变换成残差计算器，直接仿真没有意义。

### 3.2 前端（`NFFrontEnd/NFHandGuidedTearing.mo`）

- 交互模式下不给"hold 不支持"的警告 8009；其余不变。变量上和残差上的 hold 已经分别存储并传到 `DAE.HAND_GUIDED_TEARING`。

### 3.3 后端：变换（`BackEnd/HandGuidedTearing.mo`）

在 `lower` 中（`BackendDAECreate.lower` 调用，此时还没有匹配，也没有初始化系统），交互模式下走新函数 `lowerInteractive`，代替现在的"保护迭代变量、缩放残差"：

| 步骤 | 内容 | 用到的已有函数 |
|---|---|---|
| 1 | 找到规范，建立"方程名 → 配对"和"变量名 → 配对"两张表 | `findSpec`、`equationName` |
| 2 | 每个迭代变量：方向改成 `DAE.INPUT()`；有 HGT 的 start 就写进 start 属性；nominal、min、max **不写进**变量属性（min/max 会生成范围检查），只留在规范里 | `BackendVariable.setVarDirection`、`setVarStartValue` |
| 3 | 每条残差方程 e：新建变量 `$res.<方程名>`（Real，`DAE.OUTPUT()`，不可替换），把方程改写成 `$res.e = lhs − rhs`（**不除以 nominal**） | `BackendVariable.setVarUnreplaceable`、`Expression.expSub` |
| 4 | 初始方程上的配对同样处理（没有状态时一般没有） | |
| 5 | 模型有状态时报错：第一阶段不支持 | `BackendVariable.isStateVar` |
| 6 | 把规范标记成"已变换"（`HGTSpec` 加一个 Boolean 字段，或者交互模式下令 `shared.handGuidedTearing` 的残差列表为空而把元数据存到新字段），让后面的 `hgtMatching`、`Tearing.handGuidedTearing`、`componentItems` 对这些配对什么都不做 | |

之后的流程不变：输入变量进入已知变量集合，匹配和排序照常进行，HGT 的环自然消失。

需要注意：

- **标签**：改写后的方程保留源信息即可；`checkPresence`（8011/8012）在交互模式下不运行，因为迭代变量已经不是未知量。
- **优化模块中的保护**：迭代变量是输入、`$res.e` 是输出且不可替换，现有的别名消除不会删掉它们；HGT 原有的"带标签的方程不删除"的保护继续有效。
- **数组和 for**：前端已经把它们展开成标量配对，这里逐个处理；`$res` 的名字用展开后的方程名（例如 `$res.seg[2]`）。
- **不加选项时零影响**：`lowerInteractive` 只在 `--interactiveFMU` 下调用。

### 3.4 元数据进入 SimCode（`SimCode/SimCode.mo`、`SimCodeUtil.mo`）

`SimCode.SIMCODE` 新增一个字段（构造处只有两处），内容是配对表：

```
record HGT_INTERACTIVE_PAIR
  DAE.ComponentRef residual           "$res.e";
  String residualName                 "e";
  DAE.ComponentRef iterationVariable;
  Option<DAE.Exp> residualNominal, residualHold;
  Option<DAE.Exp> varNominal, varMin, varMax, varHold;
end HGT_INTERACTIVE_PAIR;
```

第一阶段对这些表达式的限制：常数，或者**单个参数的引用**（hold 可以再加一层 `not`）。更复杂的参数表达式在编译期给警告并忽略该属性；以后可以为它们生成辅助的输出变量。

### 3.5 FMU 模板（`Template/CodegenFMU.tpl`）

只改一处：`VendorAnnotations` 模板（现在生成空标签），交互模式下输出配对表（§4.2）。迭代变量的 `causality="input"`、残差的 `causality="output"`、`ModelStructure` 的依赖关系都由现有模板和 `createFMIModelStructure` 生成，不用改。

### 3.6 调试输出

`-d=hgtDump` 在交互模式下打印变换结果：

```
Hand guided tearing (interactive):
  input x, output $res.LongEq = 0.0 - (120.0 * x - ...)
  input T, output $res.LongEq2 = ...
```

## 4. FMU 的接口

### 4.1 变量

| 内容 | modelDescription.xml |
|---|---|
| 迭代变量 | `causality="input"`，`start` 是初值 |
| 残差 | `causality="output"`，名字 `$res.<方程名>` |
| hold 参数、其他参数 | 不变 |
| 残差对迭代变量的依赖 | `<ModelStructure><Outputs><Unknown index=… dependencies=…>` |

### 4.2 配对表（VendorAnnotations）

```xml
<VendorAnnotations>
  <Tool name="OpenModelica">
    <HandGuidedTearing version="1">
      <Pair residual="$res.LongEq" residualName="LongEq" residualHold="testHold1"
            iterationVariable="x" variableHold="testHold2"/>
      <Pair residual="$res.LongEq2" residualName="LongEq2" residualHold="testHold2"
            iterationVariable="T" variableHold="testHold1"/>
    </HandGuidedTearing>
  </Tool>
</VendorAnnotations>
```

属性：`residualNominal`、`variableNominal`、`min`、`max` 的值是数字或参数名；`residualHold`、`variableHold` 是参数名（前面可以带 `!` 表示取反）或 `true`。求解器用 `fmi2GetReal`/`fmi2GetBoolean` 读参数的当前值。

### 4.3 调用顺序

```
fmi2Instantiate → fmi2SetupExperiment → fmi2EnterInitializationMode
  → fmi2Set*(参数、迭代变量的初值) → fmi2ExitInitializationMode
循环：fmi2SetReal(迭代变量) → fmi2GetReal(残差)          每次求值
      fmi2GetDirectionalDerivative(残差, 迭代变量)        可选
改参数：fmi2Reset → 重新走一遍初始化（omsteady 内部处理，保留迭代变量的当前值）
```

每次 `fmi2GetReal` 时，FMU 的 `updateIfNeeded` 重新执行 `functionODE` 和 `functionAlgebraics`，也就是把变换后的方程算一遍。

## 5. Python 包 omsteady

位置：仓库的 `OMSteady/`（纯 Python，依赖 FMPy 和 numpy）。

| 模块 | 内容 |
|---|---|
| `problem.py` | `FMUProblem`：加载 FMU，解析配对表和 ModelStructure；`set`/`get`；`holdIterationVariables`/`releaseIterationVariables`、`holdResiduals`/`releaseResiduals`（按名字或下标）；`printInfo('all' / 'held' / 'parametricHold')`；`residuals(u)`、`jacobian(u)` |
| `structure.py` | 个数检查；在"释放的残差 × 释放的变量"上做二部图最大匹配；出错时给出没有匹配上的残差和变量 |
| `solver.py` | `Solver(problem, **options).solve()`：阻尼 Newton、线搜索、残差缩放、界投影；返回 `Solution(success, iterations, residual_norm, message)` |
| `__init__.py` | 导出 `FMUProblem`、`Solver` |

每次 `solve()`（细节见 [HGT_cross_hold.md](HGT_cross_hold.md) §3.4）：

1. 读 hold 参数的当前值，和 API 设的 hold 取并集，得到未知量 U 和方程 E；
2. 个数检查，结构检查；
3. 被 hold 的变量保持当前值（它们是 FMU 输入，不去动）；
4. 在 U、E 上做 Newton：雅可比矩阵用方向导数（可用时）或对 U 的列差分；残差按 `residual_scaling` 缩放；每步把 U 投影到 [min, max]；
5. 解留在 FMU 中，下一次从这里出发。

Solver 选项（第一阶段）：`tol`（1e-8）、`max_iter`（100）、`residual_scaling`（`"hybrid"`）、`jacobian`（`"auto"` / `"fd"`）、`line_search`（True）、`log_level`（0）。

## 6. 官方例子走一遍

```python
from omsteady import FMUProblem, Solver
# omc: setCommandLineOptions("--handGuidedTearing --interactiveFMU");
#      buildModelFMU(twoEqSteadyStateParaHold, version="2.0", fmuType="me");
p = FMUProblem("twoEqSteadyStateParaHold.fmu")
p.printInfo("all")

Solver(p).solve()                      # 都不 hold
print(p.get(["x", "T"]))               # x = 0.96387, T = 346.164

p.set("testHold1", True)               # T 固定，去掉 LongEq
p.set("T", 330.0)
Solver(p).solve()
print(p.get(["x", "T"]))               # x = 0.60773, T = 330

p.set("testHold1", False); p.set("testHold2", True)   # x 固定，去掉 LongEq2
p.set("x", 0.8)
Solver(p).solve()
print(p.get(["x", "T"]))               # x = 0.8, T = 328.988

p.set("testHold2", False)
p.holdIterationVariables(["x"])        # 只 hold 变量：个数不平衡
Solver(p).solve()                      # 报错：1 个未知量，2 条残差
```

数值按方程算出（[HGT_cross_hold.md](HGT_cross_hold.md) §1.1）。跨块的例子（`TwoBlocks`：`e1` 只含 p，`e2` 含 p 和 m）也要通过：hold m、去掉 `e1` 时由 `e2` 反算 p；反过来 hold p、去掉 `e2` 时结构检查报错。

## 7. 测试与验收

| 层次 | 测试 | 位置 |
|---|---|---|
| 编译器 | `-d=hgtDump` 的变换结果；`modelDescription.xml` 中的输入、输出、依赖关系、配对表 | `testsuite/simulation/modelica/tearing/HGTInteractive1.mos`（基准输出） |
| 编译器 | 报错：有状态；没开 `--handGuidedTearing`；`C+Rust` 目标 | `HGTInteractiveError1.mos` |
| 回归 | 不加 `--interactiveFMU` 时，现有的全部 HGT 测试不变 | 现有测试 |
| FMU 求值 | 迭代变量设为已知解时残差为 0；设成别的值时残差和手算一致 | `OMSteady/tests/test_fmu.py`（pytest） |
| 求解 | `HGT.mo` 中的稳态模型（`Loop`、`Chain`、`Bound`、`Multi`、`CrossSCC` 等）：交互式求解的结果和普通仿真一致 | `OMSteady/tests/test_solve.py` |
| hold | 官方例子的各工况；`TwoBlocks` 的跨块 hold；个数不平衡；结构奇异；API hold 和 parametric hold 合并；保持当前值（连续两次 `solve()`） | `OMSteady/tests/test_hold.py` |
| 缩放和界 | `Bound`：界防止 `log` 的参数为负；残差 nominal 在 `manual`、`hybrid` 下起作用 | `OMSteady/tests/test_scaling.py` |

Python 测试通过一个 `.mos` 包装接进 testsuite（环境中没有 FMPy 时跳过）。

**验收标准**：上表全部通过；官方例子 §6 的脚本得到表中的数值；不加选项时生成的代码不变。

## 8. 里程碑与工作量

| 里程碑 | 内容 | 工作量 |
|---|---|---|
| M1 编译器 | 选项和检查；`lowerInteractive`；后续模块跳过已变换的配对；`hgtDump` | 3–4 天 |
| M2 元数据 | SimCode 字段；`VendorAnnotations` 模板；确认 ModelStructure 的依赖关系和方向导数正确 | 2–3 天 |
| M3 FMU 求值验证 | 用 FMPy 手工验证官方例子和几个 `HGT.mo` 模型的残差 | 1 天 |
| M4 omsteady | `FMUProblem`、结构检查、`Solver`（Newton、缩放、界）、hold API、`printInfo` | 6–8 天 |
| M5 测试和文档 | §7 的测试；用户文档；本系列设计文档的更新 | 3 天 |
| **合计** | | **约 3–4 周** |

比总体设计估计的 5–6 周少，是因为用了 §2 的变换做法：代码生成、FMU 包装、依赖表、方向导数都复用现有实现。M1–M3 做完时就有一个可以用任何 FMI 工具检查的交互式 FMU，可以作为中间交付。

## 9. 风险与待确认的问题

| 问题 | 说明与对策 |
|---|---|
| 变换后的输入会不会被前面的模块特殊处理 | 迭代变量在前端是普通变量，到后端才改成输入；要确认 `BackendDAECreate` 之后没有模块依赖"输入一定是顶层声明的 input"。M1 中验证 |
| `createFMIModelStructure` 对新建的输出是否生效 | 它从符号雅可比矩阵得到依赖关系，要确认后端新建的输出变量和输入变量被计入。不行的话在 M2 中补上 |
| 方向导数的正确性 | FMIDER 是否覆盖"输出对输入"，以及对新变量是否正确；不可用时求解器退回差分，不阻塞第一阶段 |
| 改参数要 `fmi2Reset` | OMC 的 FMU 中普通参数在初始化之后不能改；`omsteady` 在 `set` 参数后重新初始化并恢复迭代变量的值。每次切换工况多一次初始化，可以接受 |
| 迭代变量的 min/max 不再进入模型 | 界只由外层求解器保证；FMU 内部的方程在迭代变量取界外的值时可能触发断言（例如 `log` 的参数为负），所以求解器必须先投影再求值 |
| 伪根约束 | 原来撕裂时为反解非线性函数生成的解检查，在变换后内部方程仍按同样的方式求解，约束仍然生成；断言失败时 FMU 求值报错，求解器要把它当作"这一步不可接受"并缩短步长 |
| 参数表达式形式的属性 | 第一阶段只支持常数和单个参数；其余给警告 |
| OCT 的实际行为 | `FMUProblem` 的构造参数、hold 残差的 API 名字、不平衡时的报错，最好用 OCT 的 `parametric_hold_IV.py` 对照确认，再定 `omsteady` 的 API 细节 |

## 10. 第一阶段之后

| 内容 | 说明 |
|---|---|
| 带状态的模型 | 状态变成输入，`der(x)` 变成输出残差 |
| 暴露自动撕裂的块 | FMU 内部剩下的代数环也变换成输入和输出 |
| 运行时分块 | 用依赖表对当前的未知量和方程做 Tarjan，按块依次求解，提高收敛的稳健性 |
| KINSOL 后端、Brent | `Solver(method=…)` |
| Rust 运行时 | 变换在后端完成，生成的 C 代码是普通模型，理论上 Rust 运行时的 FMU 可以直接用，需要验证 |
