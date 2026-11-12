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
| 暴露的项 | 用户写的 HGT 配对；剩下的代数环默认由 FMU 内部求解，加 `--hgtOnly` 时编译期报错（§3.7） | 自动撕裂出来的迭代变量和残差 |
| FMI | 2.0 Model Exchange | FMI 3、Co-Simulation |
| 运行时 | C 运行时 | Rust 运行时（`C+Rust` 目标下报错） |
| 雅可比矩阵 | 差分；FMU 已有的方向导数能用就用（§9） | 专门优化 |
| 求解 | 全部未知量联立的阻尼 Newton | 运行时分块、KINSOL 后端、1×1 用 Brent |
| hold | 参数（parametric hold）和 API；变量、残差分开；个数检查和结构检查 | |
| 缩放与界 | 残差 nominal（none / automatic / manual / hybrid）；每步投影到 [min, max] | |

普通仿真和普通 FMU 完全不受影响：不加 `--interactiveFMU` 时生成的代码必须和现在逐字节相同。

## 2. 做法：在后端把模型变换成"残差计算器"

总体设计 §7.4 设想的是改代码生成：HGT 块照常撕裂，生成时把 `solve_nonlinear_system` 换成"只求值"。第一阶段改用一个更简单的做法：**在后端匹配之前，把模型本身变换掉**，之后的整条流水线都不用改。

对第 N 个 HGT 配对（残差方程 e：`lhs = rhs`，迭代变量 x），按 OCT 交互式 FMU 的命名约定（§4.1）：

| 变换 | 结果 |
|---|---|
| x 本身变成**顶层输入**，并以别名 `iter_N` 导出（同一个值引用） | 迭代变量的值由外面给，不再需要方程来解它 |
| 新增**顶层输出** `res_N` | |
| e 改写成 `res_N = lhs − rhs` | 这条方程现在用来算 `res_N`，不再约束 x |
| 新增 Boolean 参数 `iter_N_hold`、`res_N_hold` | hold 标志，由注解中的 hold 绑定 |

每个配对去掉一个未知量（x 成了输入），加上一个未知量（`res_N`），方程数不变，系统仍然平衡。变换后的模型是一个普通的 Modelica 模型：给定输入（迭代变量），算出输出（残差）。例如官方例子变换后相当于：

```modelica
model twoEqSteadyStateParaHold_interactive
  input Real x(start = 1);        // 以别名 iter_0 导出
  input Real T(start = 400);      // 以别名 iter_1 导出
  output Real res_0 "LongEq";
  output Real res_1 "LongEq2";
  parameter Boolean testHold1 = false;
  parameter Boolean testHold2 = false;
  parameter Boolean iter_0_hold = testHold2;
  parameter Boolean iter_1_hold = testHold1;
  parameter Boolean res_0_hold = testHold1;
  parameter Boolean res_1_hold = testHold2;
equation
  res_0 = 0 - (120*x - 75*(0.12*exp(12581*(T - 298)/(298*T)))*(1 - x));
  res_1 = 0 - (-x*(873 - T) + 11.0*(T - 300));
end twoEqSteadyStateParaHold_interactive;
```

这样做的好处：

- **匹配、撕裂、SimCode、代码生成、FMU 导出都不用改。** 原来的 HGT 代数环在变换后自然消失：用户的迭代变量撕开之后，块内其余方程本来就能依次显式算出。
- **输出对输入的依赖关系自动得到。** 现有的 `SimCodeUtil.createFMIModelStructure` 从符号雅可比矩阵算出 `<ModelStructure><Outputs>` 的 `dependencies`，残差是输出、迭代变量是输入，所以"每条残差依赖哪些迭代变量"（包括跨块的间接依赖）直接出现在 `modelDescription.xml` 中，不用另外计算。
- **方向导数自动可用。** FMU 已经为"输出对输入"生成 FMIDER 雅可比矩阵，`fmi2GetDirectionalDerivative` 给出的就是残差对迭代变量的导数。
- **初始化系统和仿真系统自然一致**：变换在创建初始化系统之前做，两边用的是同一个变换后的模型。没有状态时，FMU 初始化之后的每次求值都只是把方程算一遍。
- **用户给的迭代变量不够时**：默认剩下的代数环留在 FMU 内部，由 FMU 自己的求解器解（和 OCT"只暴露部分块"的行为类似）；加了 `--hgtOnly` 时不自动撕裂、不补迭代变量，FMU 内部只要还有代数环就编译期报错（§3.7）。
- hold、nominal、界都不进入方程：hold 是参数，nominal、min、max 是 `iter_N`、`res_N` 的属性（§4）。

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

- 交互模式下不给"hold 不支持"的警告 8009。变量上和残差上的 hold 已经分别存储并传到 `DAE.HAND_GUIDED_TEARING`。
- `enabled = false` 的配对**保持现状**：前端求值 `enabled` 后直接丢掉，交互模式下也不导出。OCT 的交互式 FMU 中这样的配对仍然导出成 `iter_N`/`res_N`（§4.1），这一点第一阶段不跟随。
- 为每条残差方程保存源码文本（方程加注解），用作 `res_N` 的 `description`。

### 3.3 后端：变换（`BackEnd/HandGuidedTearing.mo`）

在 `lower` 中（`BackendDAECreate.lower` 调用，此时还没有匹配，也没有初始化系统），交互模式下走新函数 `lowerInteractive`，代替现在的"保护迭代变量、缩放残差"：

| 步骤 | 内容 | 用到的已有函数 |
|---|---|---|
| 1 | 找到规范，建立"方程名 → 配对"和"变量名 → 配对"两张表（`enabled = false` 的配对已被前端丢掉，不在规范中） | `findSpec`、`equationName` |
| 2 | 按配对编号 N = 0, 1, …（顺序同前端：按残差名排序），命名规则见 §4.1 | |
| 3 | 第 N 个配对的迭代变量 x：方向改成 `DAE.INPUT()`，不可替换；HGT 的 start、nominal 写进 x 的属性；再登记一个别名变量 `iter_N`，和 x 共用值引用（放进别名变量集合，FMU 导出时生成同一个 `valueReference` 的别名） | `BackendVariable.setVarDirection`、`setVarStartValue`、`setVarNominalValue` |
| 3' | 第 N 个配对的残差方程 e：新建输出 `res_N`（Real，`DAE.OUTPUT()`，不可替换；nominal 取残差的 nominal，没写时为 0，和 OCT 一致），把方程改写成 `res_N = lhs − rhs`（**不除以 nominal**）；`description` 是方程的源码文本加注解（§4.1） | `BackendVariable.setVarUnreplaceable`、`Expression.expSub` |
| 3'' | 新建两个 Boolean 参数 `iter_N_hold`、`res_N_hold`：hold 是字面量或没写（取 false）时是普通参数；hold 是参数表达式时，绑定为这个表达式（§4.2） | |
| 4 | 初始方程上的配对同样处理（没有状态时一般没有） | |
| 5 | 模型有状态时报错：第一阶段不支持 | `BackendVariable.isStateVar` |
| 6 | 把规范标记成"已变换"（`HGTSpec` 加一个 Boolean 字段，或者交互模式下令 `shared.handGuidedTearing` 的残差列表为空而把元数据存到新字段），让后面的 `hgtMatching`、`Tearing.handGuidedTearing`、`componentItems` 对这些配对什么都不做 | |

之后的流程不变：输入变量进入已知变量集合，匹配和排序照常进行，HGT 的环自然消失。

需要注意：

- **标签**：改写后的方程保留源信息即可；`checkPresence`（8011/8012）在交互模式下不运行，因为迭代变量已经不是未知量。
- **优化模块中的保护**：`iter_N` 是输入、`res_N` 是输出且都不可替换，现有的别名消除不会删掉它们；HGT 原有的"带标签的方程不删除"的保护继续有效。
- **数组和 for**：前端已经把它们展开成标量配对，这里逐个处理，每个元素一个编号 N；描述里写展开后的名字（例如 `seg[2]`）。
- **x 和 `iter_N`**：x 是输入本身，`iter_N` 只是别名，两者是同一个值。`ModelStructure` 中的依赖关系引用的是 x 的编号，不是 `iter_N` 的（OCT 的 FMU 中也是这样，§4.1）。
- **min/max 不能生成范围检查**：HGT 的 min/max 只用于导出到 x 的属性，供外层求解器投影；要确认运行时不会对它们生成越界断言（§9），否则外层迭代中间值越界会让求值失败。
- **不加选项时零影响**：`lowerInteractive` 只在 `--interactiveFMU` 下调用。

### 3.4 SimCode（`SimCode/SimCode.mo`、`SimCodeUtil.mo`）

按 OCT 的方式，所有信息都在模型变量上（名字、属性、参数），**不需要**新的 SimCode 字段，也不需要私有的配对表：

- `iter_N`、`res_N` 是普通的输入、输出变量，nominal、min、max 是它们的标准属性；
- `iter_N_hold`、`res_N_hold` 是普通的参数，绑定的表达式由现有的 `updateBoundParameters` 计算，**任意参数表达式都可以**，不再有"只能是常数或单个参数"的限制；
- `iter_N` 是 x 的别名，`description` 是 x 的名字；`res_N` 的 `description` 是方程的源码文本加注解（§4.1），供诊断和 `printInfo` 使用。

要确认的只有一点：现有的 FMI 导出会把带非字面量绑定的参数导出成 `causality="calculatedParameter"`，把字面量参数导出成 `causality="parameter" variability="fixed" initial="exact"`（§4.2），和 OCT 的 FMU 一致。不一致的话在模板中对这些变量单独处理。

### 3.5 FMU 模板（`Template/CodegenFMU*.tpl`）

原则上不用改：输入、输出、参数、属性、`ModelStructure` 的依赖关系都由现有模板和 `createFMIModelStructure` 生成。`VendorAnnotations` 保持为空。

### 3.6 调试输出

`-d=hgtDump` 在交互模式下打印变换结果：

```
Hand guided tearing (interactive):
  0: iter_0 (x, hold = testHold2), res_0 (LongEq, hold = testHold1) = 0.0 - (120.0 * x - ...)
  1: iter_1 (T, hold = testHold1), res_1 (LongEq2, hold = testHold2) = ...
```

### 3.7 `--hgtOnly`：FMU 内部不允许留下代数环

变换之后，用户的配对已经是输入和输出。模型里如果还有代数环（用户没写配对的环，或者撕开用户的配对后仍然解不出的方程），默认由 FMU 内部的求解器解（§2）。加 `--hgtOnly` 时不这样做：

- 不自动撕裂，不自动补迭代变量和残差；
- FMU 内部不能有任何非线性系统、线性系统或混合系统；
- 只要还有，就编译期报错，列出这些系统的方程和变量，提示用户给它们写 HGT 配对。

这样外层求解器看到的就是模型中全部的代数未知量，求解完全由它控制，没有藏在 FMU 里的迭代。

**检查的位置**：SimCode 生成之后（`SimCodeUtil`），检查仿真系统和初始化系统的方程列表中有没有 `SES_NONLINEAR`、`SES_LINEAR`、`SES_MIXED`。放在 SimCode 而不是 BLT 上检查，是因为它反映实际生成的代码：单条方程解不出显式形式时（例如由 `z + sin(z) = y` 求 z），后端会生成 1×1 的非线性系统，这样也能查出来。

**新错误**（下一个空号 8023）：

```
HGT_INTERACTIVE_LOOP: With --interactiveFMU and --hgtOnly the FMU may not solve algebraic
loops, but the equations {%s} form a %s system for the variables {%s}. Give them hand guided
tearing pairs or compile without --hgtOnly.
```

**例子**：`HGT.mo` 中的 `OnlyStuck`

```modelica
Real x(start = 1), y, z(start = 1);
equation
  y = exp(x);
  z + sin(z) = y;
  z * x = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
```

变换后 x 由输入 `iter_0` 给出，`res_0 = z*x − 2` 是输出，`y = exp(x)` 显式可解，但 `z + sin(z) = y` 解不出 z，后端生成一个 1×1 的非线性系统：

| 选项 | 结果 |
|---|---|
| 不加 `--hgtOnly` | 可以编译，FMU 每次求值时内部迭代求 z |
| 加 `--hgtOnly` | 报错：方程 `{z + sin(z) = y}` 是关于 `{z}` 的非线性系统。用户要再写一个配对，例如 `z + sin(z) = y` 配 z，之后外层求解器同时迭代 x 和 z |

线性系统也一并报错，因为 `--hgtOnly` 的含义就是"只用用户给的项"。如果以后觉得太严，可以放宽成只对非线性系统报错。

## 4. FMU 的接口

按 OCT 交互式 FMU 的方式：不用私有的 XML 配对表，而是用**专门的模型变量加命名约定**。这些都是标准的 FMI 变量，任何 FMI 工具都能读写。

### 4.1 变量和命名约定

以下约定对照了一个真实的 OCT 交互式 FMU（`TetraSystem.Systems.BaseModels.SteadyState.HP_Cycle`，FMI 2.0，`variableNamingConvention="structured"`）。第 N 个配对（N 从 0 开始，**迭代变量和残差用同一个 N**）：

| 变量 | OCT 中看到的 | 本设计 |
|---|---|---|
| `iter_N` | **参数**：start 由表达式算出的是 `causality="calculatedParameter" variability="fixed" initial="calculated"`（`iter_0`，值引用 3124），start 是字面量的是 `causality="parameter"`（`iter_10`，`start="0.0"`）；`description` 是迭代变量名；属性只有 `relativeQuantity` | **不同**：原来的迭代变量 x 是 FMI 输入，`iter_N` 是 x 的别名（同一个值引用）；start、nominal、min、max 在 x 上（理由见 §4.2'） |
| `res_N` | 新的变量，值引用连续（7720 + N）；`causality="output" variability="continuous" initial="calculated"`；`nominal="0"` | 同左；给了残差 nominal 时写这个值，没给时写 0 |
| `res_N` 的 `description` | 方程的源码文本加注解，残差形式写成 `a - b = 0`，例如 `EXV_Opening.value - EXV_Opening.setPoint = 0 annotation(__Modelon(ResidualEquation(iterationVariable(hold = EXV_Opening.fixed or (EXV_Opening.isOff or false)) = EXV_Opening.scaledValue,hold = true,enabled = false)))` | 同左 |
| `iter_N_hold`、`res_N_hold` | Boolean，见 §4.2 | 同左 |
| 依赖关系 | 残差对迭代变量的依赖**没有导出**：`res_0`（第 10371 个变量）在 `<Outputs>` 中依赖 `"8"`（`fixed`），在 `<InitialUnknowns>` 中依赖 `"4 5 8 9"`，都没有 `iter_0`（第 1670 个变量）。按 FMI 2.0，`<Outputs>` 只列输入和状态，`<InitialUnknowns>` 只列初始化的自变量，计算参数形式的迭代变量都不能出现，依赖被追溯到了 start 所依赖的独立参数上 | 迭代变量是输入，所以 `<Outputs>` 直接给出残差对迭代变量的依赖（引用 x 的编号）；求解器通过值引用把 `iter_N` 对应到 x |

官方例子 `twoEqSteadyStateParaHold`（本设计的编号按残差名排序：`LongEq` 是 0，`LongEq2` 是 1）：

| 变量 | 内容 |
|---|---|
| x（别名 `iter_0`） | 输入，start 1 |
| T（别名 `iter_1`） | 输入，start 400 |
| `res_0` | `LongEq` 的残差，`description` 是 `0 = 120*x - … annotation(…)` |
| `res_1` | `LongEq2` 的残差 |
| `iter_0_hold` | 计算参数，= `testHold2` |
| `iter_1_hold` | 计算参数，= `testHold1` |
| `res_0_hold` | 计算参数，= `testHold1` |
| `res_1_hold` | 计算参数，= `testHold2` |

### 4.2 hold 变量的两种形式

| 注解中的 hold | 生成的参数 | `modelDescription.xml` | 怎么改 |
|---|---|---|---|
| 没写，或字面量 `true`/`false` | `parameter Boolean res_0_hold = true;` | `causality="parameter" variability="fixed" initial="exact"`，`<Boolean start="true"/>` | 初始化之前直接 `fmi2SetBoolean` |
| 参数表达式，例如 `hold = testHold1`，或者 OCT 库中的 `hold = EXV_Opening.fixed or (EXV_Opening.isOff or false)` | `parameter Boolean iter_0_hold = …;` | `causality="calculatedParameter"`，`<Boolean />` 没有 start | 改表达式中的参数；值由 FMU 计算，要在初始化之后读，不能看 XML |

两点好处：

- **没写 hold 的项也有 hold 变量**（取 false，可以直接设），所以用户不改模型、直接 `fmi2SetBoolean(iter_0_hold, true)` 就能 hold 任何迭代变量。这就是 OCT `holdIterationVariables` 那种"不绑定参数的 hold"，不需要专门的 API。
- **复杂的 hold 表达式**（`not design`、`h1 and h2` 等）由 FMU 自己算出，外层求解器只读结果。

外层求解器只靠命名约定：对每个 N 读 `iter_N_hold`、`res_N_hold` 的当前值，得到被 hold 的变量和残差。

### 4.2' 和 OCT 的兼容性

| 项目 | 状态 |
|---|---|
| 命名 `iter_N`、`res_N`、`iter_N_hold`、`res_N_hold` | 已确认 |
| 迭代变量和残差共用同一个 N | 已确认（`iter_0` 是 `EXV_Opening.scaledValue`，`res_0` 的注解中迭代变量正是它） |
| `res_N` 是连续输出，`initial="calculated"` | 已确认 |
| `res_N` 的 `description` 是方程文本加注解 | 已确认 |
| 没给残差 nominal 时 `nominal="0"` | 已确认；给了 nominal 时的写法还没看到 |
| 字面量 hold 是固定参数，参数表达式的 hold 是计算参数 | 已确认，hold 表达式可以是 `or` 等组合 |
| `enabled = false` 的配对 | OCT 中仍然导出（已确认）；**本设计不导出**，保持现在的行为：前端直接丢掉。以后如果需要，再确认它在 OCT 交互式 FMU 中的确切含义 |
| `iter_N` 的因果属性 | **已确认，和本设计不同**：OCT 中是参数或计算参数（初始化时由 start 决定，`variability="fixed"`），本设计中是输入（x 本身是输入，`iter_N` 是别名） |
| 残差对迭代变量的依赖 | **已确认 OCT 没有导出**（`<Outputs>`、`<InitialUnknowns>` 中都没有 `iter_N`）；本设计在 `<Outputs>` 中导出 |
| 编号的顺序 | 未确认；本设计按残差名排序 |
| 没写 hold 时是否也生成 hold 变量 | 未确认；本设计生成，取 false |

**为什么迭代变量不照搬 OCT 做成参数**：

| | 照搬 OCT（参数） | 本设计（输入） |
|---|---|---|
| 依赖结构 | `modelDescription.xml` 中没有，只能在运行时数值探测，导数恰好为 0 的点会漏掉依赖 | `<Outputs>` 中直接给出，是结构上的依赖，结构检查和运行时分块可靠 |
| 设置迭代变量 | 固定参数只能在初始化模式中修改，求解器要一直停在初始化模式；计算参数按 FMI 2.0 不允许由外部设置 | 标准操作：初始化之后设输入、读输出 |
| 其他 FMI 工具 | 大多不允许修改计算参数，无法驱动 | 任何工具都能驱动 |

所以 OMC 生成的 FMU 只在命名和描述上和 OCT 一致，`iter_N` 的因果属性不同，OCT 的 `FMUProblem` 不能直接用它；`omsteady` 也不能直接解 OCT 生成的 FMU。以后需要时，给 `omsteady` 加一个"OCT 模式"（§10）。

### 4.2'' 在当前运行时上做全局求解时

不生成 FMU、在 C 运行时里直接做全局稳态求解时（不需要交互的方案），用同样的变量：运行时按编号读 `iter_N_hold`、`res_N_hold` 的值，用户用 `-override=iter_0_hold=true` 就能 hold 任意迭代变量。两种方式的模型变换完全相同。

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
| `problem.py` | `FMUProblem`：加载 FMU，按命名约定找出 `iter_N`、`res_N`、`iter_N_hold`、`res_N_hold`（§4.1），读 ModelStructure；`iter_N` 通过值引用对应到基础变量（输入）和它在 `ModelStructure` 中的编号；`set`/`get` 接受原来的变量名，也接受 `iter_N`；`set`/`get`；`holdIterationVariables`/`releaseIterationVariables`、`holdResiduals`/`releaseResiduals`（按名字或下标）；`printInfo('all' / 'held' / 'parametricHold')`；`residuals(u)`、`jacobian(u)` |
| `structure.py` | 个数检查；在"释放的残差 × 释放的变量"上做二部图最大匹配；出错时给出没有匹配上的残差和变量 |
| `solver.py` | `Solver(problem, **options).solve()`：阻尼 Newton、线搜索、残差缩放、界投影；返回 `Solution(success, iterations, residual_norm, message)` |
| `__init__.py` | 导出 `FMUProblem`、`Solver` |

每次 `solve()`（细节见 [HGT_cross_hold.md](HGT_cross_hold.md) §3.4）：

1. 读 `iter_N_hold`、`res_N_hold` 的当前值（计算参数要在初始化之后读），和 API 设的 hold 取并集，得到未知量 U 和方程 E；
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
p.set("T", 330.0)                      # T 就是输入，别名 iter_1
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
| 编译器 | `--hgtOnly`：`OnlyStuck` 报 8023；`OnlySolvable`、官方例子通过；不加 `--hgtOnly` 时 `OnlyStuck` 能编译，FMU 内部解 z | `HGTInteractiveOnly1.mos` |
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
| M1 编译器 | 选项和检查；`lowerInteractive`；后续模块跳过已变换的配对；`--hgtOnly` 下的代数环检查（§3.7）；`hgtDump` | 4–5 天 |
| M2 元数据 | 确认 hold 参数导出成 parameter/calculatedParameter；确认 ModelStructure 的依赖关系和方向导数正确；对照 OCT FMU 的命名 | 1–2 天 |
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
| 别名导出 | 要确认 OMC 的 FMU 导出会把 `iter_N` 生成为和 x 同一个值引用的别名，而且 x 的 `causality="input"`。不行的话退回到"新建输入 `iter_N`，x = iter_N"的做法 |
| `enabled = false` 的配对 | 本设计不导出，和 OCT 不同：从 OCT 迁移来、依赖这类配对在交互式 FMU 中出现的模型，要把 `enabled` 改成 true。以后如果要跟随 OCT，再确认它的确切语义 |
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
| `omsteady` 的 OCT 模式 | 求解 OCT 生成的交互式 FMU：进入初始化模式后不退出，按值引用设 `iter_N`（参数），读 `res_N`；依赖结构在运行时用差分探测（在 start 附近取几个点，减少导数恰好为 0 造成的遗漏），并警告结构检查不完全可靠 |
