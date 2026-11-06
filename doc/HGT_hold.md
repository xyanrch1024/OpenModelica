# HGT 的 hold 实现说明

本文讲解手动引导撕裂（HGT）注解中 `hold` 属性的含义和实现：语法、前端检查、后端怎样改写残差方程、生成的代码，以及和 OCT 的差别。

- 前端：`OMCompiler/Compiler/NFFrontEnd/NFHandGuidedTearing.mo`（`parseHold`、`checkHold`）
- 后端：`OMCompiler/Compiler/BackEnd/HandGuidedTearing.mo`（`lower`、`pairHold`、`rewriteResidual`、`holdResidual`）
- 错误信息：`OMCompiler/Compiler/Util/Error.mo`（8009 `HGT_HOLD_MISMATCH`）
- 测试：`testsuite/simulation/modelica/tearing/HGTHold1.mos`、`testsuite/flattening/modelica/scodeinst/HGTError13.mo`
- 整体说明见 [HGT_developer_guide.md](HGT_developer_guide.md)（§4.8 是本文的摘要）

## 目录

1. [一句话概括](#1-一句话概括)
2. [OCT 中的 hold](#2-oct-中的-hold)
3. [语法](#3-语法)
4. [语义：按配对 hold](#4-语义按配对-hold)
5. [前端：解析与检查](#5-前端解析与检查)
6. [后端：改写残差方程](#6-后端改写残差方程)
7. [生成的代码](#7-生成的代码)
8. [和其他功能的关系](#8-和其他功能的关系)
9. [一个完整例子](#9-一个完整例子)
10. [测试](#10-测试)
11. [和 OCT 的差别、限制](#11-和-oct-的差别限制)
12. [以后可以扩展的方向](#12-以后可以扩展的方向)

---

## 1. 一句话概括

一个配对被 hold 时，它的迭代变量 x 保持在 start 值，它的残差方程不再要求成立。实现上，后端把残差方程 `lhs = rhs` 改写成

```
0 = if hold then x - $START.x else (lhs - rhs) / nominal
```

方程和变量都还在，系统结构不变，所以匹配、撕裂、SimCode 和运行时都不用改。hold 是普通参数，用 `-override` 就能在运行时切换，不用重新编译。

## 2. OCT 中的 hold

OCT 手册（设计文档 [HGT_design.md](HGT_design.md) 的 R10，出自手册第 107、125 页）：

- `hold` 绑定一个 Boolean 参数，默认 false；可以写在残差方程上，也可以写在迭代变量上。
- 为 true 时，在**交互式 FMU 的稳态求解器**（Python 的 `FMUProblem`）中，被 hold 的迭代变量不参与求解（保持当前值），被 hold 的残差也不参与求解。
- 典型用法是"设计工况 / 校核工况"切换：设计工况下某个量是给定的，那条方程不要；校核工况下由那条方程求出这个量。

OCT 手册 "Specification of Hand Guided Tearing" 一章的官方例子 `twoEqSteadyStateParaHold`（运行脚本 `parametric_hold_IV.py`）：

```modelica
model twoEqSteadyStateParaHold
  Real x (start = 1);
  Real T (start = 400);
  parameter Boolean testHold1 = false;
  parameter Boolean testHold2 = false;
equation
  0 = 120*x - 75*(0.12*exp(12581*(T - 298)/(298*T)))*(1 - x)
    annotation(__Modelon(ResidualEquation(hold = testHold1,
      iterationVariable(hold = testHold2)=x), name = LongEq));
  0 = -x*(873 - T) + 11.0*(T - 300)
    annotation(__Modelon(ResidualEquation(hold = testHold2,
      iterationVariable(hold = testHold1)=T), name = LongEq2));
end twoEqSteadyStateParaHold;
```

每个配对的残差和迭代变量绑定的是**不同**的参数：`testHold1` hold 变量 T 和**另一个**配对的残差 `LongEq`，`testHold2` hold 变量 x 和残差 `LongEq2`。这是**交叉 hold**，现在的实现不支持：两边的 hold 表达式不同，报错 8009。怎样支持见 [HGT_cross_hold.md](HGT_cross_hold.md)。本文的实现只覆盖"一个配对两边同时 hold"的情况，§9 的例子就是这种。

OMC 没有交互式 FMU，所以这里把 hold 做成编译出来的模型中的**运行时开关**：效果相当于 OCT 在 `FMUProblem` 里 hold 之后再求解一次。差别见 §11。

## 3. 语法

`hold` 可以出现在三个位置，和 OCT 相同：

```modelica
// 残差方程上
x * y = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x, hold = h)));

// 迭代变量上
x * y = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(hold = h) = x)));

// 系统级配对的两边
annotation(__OpenModelica_HGT(tearingPairs(
  Pair(residualEquation(hold = h) = b.res, iterationVariable(start = 2, hold = h) = c.q))));
```

规则：

- 值必须是**标量 Boolean 参数表达式**：字面量 `true`/`false`、参数 `h`、参数表达式 `not isSteadyState`、`h1 and h2` 都可以；离散变量、连续变量不行（8001）。OCT 也要求是参数。
- hold 不是结构参数：前端不求值，保留成表达式，所以可以用 `-override` 改。
- 数组配对（数组方程或切片）上的 hold 只能是标量，作用于所有元素。
- 只写一边 `hold = false` 等同于不写。

## 4. 语义：按配对 hold

OCT 可以分别 hold 迭代变量和残差，由交互式 FMU 的求解器负责平衡方程数。这里没有那一层，所以**按配对 hold**：

| 残差上的 hold | 迭代变量上的 hold | 配对的 hold |
|---|---|---|
| 没写 | 没写 | 不 hold |
| `h` | 没写 | `h` |
| 没写 | `h` | `h` |
| `h` | `h` | `h` |
| `h1` | `h2`（和 `h1` 不同） | 错误 8009 |
| `false` | `true` | 错误 8009 |
| `true` | `false` | 错误 8009 |
| `false` | 没写 | 不 hold |

配对被 hold 时，迭代变量少一个未知量，残差少一条方程，方程数一定平衡。

**保持值**是迭代变量的 start：

- HGT 里写的 `iterationVariable(start = ...)` 优先（`lowerVariable` 已经把它写进变量的 start 属性）；
- 没写就用变量声明的 start。

普通变量的 start 不能用 `-override` 改。要在运行时改保持值，就把 start 写成参数：

```modelica
parameter Real x0 = 1.5;
... iterationVariable(start = x0, hold = h) = x ...
```

然后 `-override=h=true,x0=2.5`。

## 5. 前端：解析与检查

### 5.1 `parseHold`

`parseHold(mod, scope, flattenFn, info)` 读出 `hold` 字段：

1. `Inst.instExp` 实例化表达式，`Typing.typeExp` 求出类型和可变性；
2. 不是标量 Boolean，或者可变性高于 `NON_STRUCTURAL_PARAMETER`，报 8001（"expected a Boolean parameter expression"）；
3. 用 `flattenFn` 补上组件前缀，返回 `SOME(exp)`；没写返回 `NONE()`。

调用它的地方：

| 调用方 | 位置 | 存到哪里 |
|---|---|---|
| `parseResidualEquation` | 方程上的 `ResidualEquation(..., hold = ...)` | `RESIDUAL_EQUATION.hold` |
| `parsePair` | `Pair(residualEquation(hold = ...) = ...)` | `RESIDUAL_EQUATION.hold` |
| `parseIterationVariableAttributes` | `iterationVariable(hold = ...) = x` | `ITERATION_VARIABLE.hold` |

数组配对展开成标量配对时（`makeResiduals`），每个元素拿到同一个 hold 表达式。

### 5.2 `checkHold`

`finish` 在 `checkOnlyPairs` 之后对每个残差调用 `checkHold`（`List.fold`），**所有配对都检查完再失败**，这样一次能看到所有冲突：

```modelica
if isSome(residual.hold) and isSome(var.hold) then
  if not Expression.isEqual(rh, vh) then
    Error.addSourceMessage(Error.HGT_HOLD_MISMATCH, {...}, residual.info);
    ok := false;
  end if;
end if;
```

要点：

- 只要两边**都写了**就比较，字面量 `false` 也算。早先的版本只在两边都不是字面量 `false` 时才比较，结果 `false` 对 `true` 会被静默忽略或静默启用，后来修正了。
- 比较的是表达式（`Expression.isEqual`），不是值：`hold = h1` 和 `hold = h2` 即使两个参数的值相同也报错，因为参数可以被 `-override` 分别改掉。
- 这时 `checkOnlyPairs` 已经保证每个残差都有迭代变量，所以 `SOME(var) := residual.iterationVariable` 不会失败。

错误信息（8009）：

```
A hand guided tearing pair is held as a whole, but the residual equation $hgt1 has
hold = h1 and its iteration variable x has hold = h2.
```

### 5.3 进入 DAE

前端不合并两边的 hold，两边原样转成 `DAE.HGT_RESIDUAL.hold` 和 `DAE.HGT_ITERATION_VARIABLE.hold`（`Expression.toDAE`）。`-d=hgtDump` 也按原样打印，例如：

```
pair: residual equation e2 (nominal = 2.0, hold = h), iteration variable x (start = 1.5)
```

## 6. 后端：改写残差方程

### 6.1 `pairHold`

后端用 `pairHold(residual)` 求出配对的 hold：

```modelica
hold := match (residual.hold, residual.iterationVariable.hold)
  case (SOME(DAE.BCONST(false)), _) then NONE();
  case (SOME(_), _) then residual.hold;
  case (_, SOME(DAE.BCONST(false))) then NONE();
  else residual.iterationVariable.hold;
end match;
```

前端已经保证两边都写时相同，所以这里取残差上的就行；字面量 `false` 变成 `NONE()`（不 hold）。

### 6.2 `lower` 和 `rewriteResidual`

`HandGuidedTearing.lower`（由 `BackendDAECreate.lower` 调用）：

1. 把带 nominal 或 hold 的残差放进 `residual_map`（方程名 → `DAE.HGTResidual`）；
2. 对仿真方程 `eqns` 和初始方程 `initialEqns` 都调用 `rewriteResidual`。

`rewriteResidual` 先用方程源注释里的 `__OpenModelica_HGTEquation` 标签找到方程名（`equationName`），查表，然后：

```
res := lhs - rhs
if nominal:  res := res / nominal
match pairHold:
  NONE()         → res
  SOME(true)     → x - $START.x
  SOME(h)        → if h then x - $START.x else res
方程改成 0 = res
```

- `holdResidual(x)` 生成 `x - $START.x`。`$START.x` 是 `ComponentReference.crefPrefixStart(x)`，和后端在其他地方（例如 `expandAlgorithmStmts`）表示 start 值的方式一样。
- `hold = true` 字面量不生成 `if`，直接写成 `x - $START.x`。
- 只处理标量方程 `BackendDAE.EQUATION`。数组方程已经被 `-d=nfScalarize` 拆开；其他种类的方程（`ALGORITHM`、`COMPLEX_EQUATION` 等）上的 hold 给警告 8007 后忽略。

### 6.3 为什么这样改写

| 考虑 | 说明 |
|---|---|
| 结构不变 | 方程和变量都在，邻接关系里仍有 x，`hgtMatching` 的强制配对、`Tearing.handGuidedTearing` 的撕裂都不受影响：x 仍是迭代变量，这条方程仍是残差 |
| 运行时切换 | hold 是普通参数，`if` 在运行时求值；改 hold 不用重新编译 |
| 不用改 SimCode 和运行时 | 开关全在生成的残差表达式里，C 和 Rust 运行时都不用改 |
| 雅可比矩阵不奇异 | hold 分支对 x 的导数是 1（§7），不会因为删掉一条方程而出现零行 |
| 方程数平衡 | 按配对 hold，少一个未知量就少一条方程 |

另一种做法是在前端把 hold 当结构参数求值，hold 为 true 时直接删掉残差方程、把 x 变成参数。它更简单，但每次切换都要重新编译，和 OCT 运行时切换的用法不一样，所以没有采用。

## 7. 生成的代码

以 §9 的 `HGT.Hold` 为例，非线性系统的残差函数（`Hold_02nls.c`，注释删掉了）：

```c
res[0] = (data->simulationInfo->booleanParameter[0] /* h */)
       ? data->localData[0]->realVars[0] /* x */
         - ((modelica_real *)(data->modelData->realVarsData[0].attribute.start.data))[0]  /* $START.x */
       : 0.5 * (x * y) - 1.0;                                                             /* (x*y - 2)/2，已化简 */
```

`$START.x` 读的是变量 x 的 start 属性，初始化时由 start 表达式（这里是参数 `x0`）算出，所以 `-override=x0=...` 会改变保持值。

非线性系统的符号雅可比矩阵（`Hold_12jac.c`，简化后）：

```c
resultVars[0] = (h) ? seedVars[0]                         /* d(x - $START.x)/dx = 1 */
                    : 0.5 * (seedVars[0] * (y - x));      /* 原残差的导数 */
```

`$START.x` 对 x 求导为 0（它不是被求导的变量），所以 hold 分支的导数是 1。`if` 表达式的导数也是 `if`，两个分支分别求导，`Differentiate` 不需要任何改动。

## 8. 和其他功能的关系

| 功能 | 关系 |
|---|---|
| 残差 nominal | 只作用于不 hold 的分支：`(lhs - rhs) / nominal`。hold 分支 `x - $START.x` 不缩放，求解器的自动缩放会处理它 |
| 迭代变量的 start、nominal | start 就是保持值；nominal 照常写进变量属性 |
| 迭代变量的 min/max（`hgtBounds`） | 不用改：保持值在界内时解检查照常通过；保持值本身越界时，解检查会报警告并判为失败 |
| 初始化系统 | 初始方程上的残差也改写，hold 在初始化和仿真中都生效 |
| 1×1 配对 | 改写后方程里有 `if`，要么 `ExpressionSolve` 按分支解出，要么变成 1×1 非线性系统；测试 `HoldSingle` 两种结果都对 |
| 数组配对 | 每个元素一个标量配对，共用同一个 hold 表达式；测试 `HoldArray` |
| for 循环 | 展开后每次迭代一个标量配对，同上 |
| `--hgtOnly` | 不受影响，结构没变 |
| `hgtMatching`、`--hgtMergeBLTBlocks` | 不受影响 |
| `--hgtAllowMultipleResiduals=false` | 被 hold 的残差仍算一个用户残差 |
| C 和 Rust 运行时 | 都不用改；两边测试结果相同 |

## 9. 一个完整例子

`testsuite/simulation/modelica/tearing/HGT.mo` 中的 `Hold`：

```modelica
model Hold "a held pair: h keeps x at x0 instead of solving x * y = 2"
  parameter Boolean h = false;
  parameter Real x0 = 1.5;
  Real x(start = 1), y(start = 1);
equation
  x + y = 3;
  x * y = 2 annotation(__OpenModelica_HGT(name = e2,
    ResidualEquation(iterationVariable(start = x0, hold = h) = x, nominal = 2, hold = h)));
end Hold;
```

改写后的残差方程：

```
0 = if h then x - $START.x else (x * y - 2) / 2
```

运行结果（`--handGuidedTearing`，`stopTime = 0`）：

| simflags | x | y | 说明 |
|---|---|---|---|
| （无） | 1.0 | 2.0 | 不 hold：x + y = 3、x·y = 2 的一个根（从 start 1.5 出发） |
| `-override=h=true` | 1.5 | 1.5 | x 保持在 x0 = 1.5，y 由 x + y = 3 算出 |
| `-override=h=true,x0=2.5` | 2.5 | 0.5 | 改了保持值 |

三次运行用的是同一个可执行文件，没有重新编译。

## 10. 测试

| 测试 | 内容 |
|---|---|
| `simulation/modelica/tearing/HGTHold1.mos` | `HGT.Hold`：不 hold、`-override=h=true`、改保持值 `x0`；`HGT.HoldSingle`：1×1 配对；`HGT.HoldArray`：数组配对的每个元素 |
| `flattening/modelica/scodeinst/HGTError13.mo` | 8009：两个不同的参数 `h1`/`h2`、`false` 对 `true`、`true` 对 `false`，三条错误一起报出 |
| `flattening/modelica/scodeinst/HGTSystemPair1.mo` | 系统级配对两边都写 `hold = subSystem2Hold`，不报错 |
| `simulation/modelica/tearing/HGTIf1.mos` | `HGT.SteadyStateSwitch` 两边都写 `hold = false`，等同于不 hold |

C 和 Rust 两个 omc 都跑过全部 HGT 测试。

## 11. 和 OCT 的差别、限制

| | OCT | OMC |
|---|---|---|
| hold 的值 | Boolean 参数 | Boolean 参数表达式（相同） |
| 在哪里生效 | 交互式 FMU 的稳态求解器（`FMUProblem`） | 编译出来的模型中处处生效：初始化和仿真 |
| 粒度 | 迭代变量和残差可以分开 hold，`FMUProblem` 也能按名字 hold/release | 按配对；两边都写时必须相同 |
| 保持值 | 变量的当前值（用户设的值或上一次的解） | 变量的 start 值；要改就把 start 写成参数 |
| 切换 | 交互式 FMU 中改参数后重新求解 | 两次运行之间用 `-override` |
| 官方例子 `twoEqSteadyStateParaHold`（§2） | 支持 | 报错 8009（交叉 hold，见 [HGT_cross_hold.md](HGT_cross_hold.md)） |

说明：

- **保持值**：hold 是参数，一次运行里不会切换，运行开始时变量的"当前值"就是 start，所以在 OMC 的用法下两者结果相同。但 OCT 的用户通常先 `set` 一个值再 hold，这在 OMC 中只能把 start 写成参数再 `-override`。这个差别有实际影响：官方例子中如果 x 保持在 start 1，`LongEq` 恒等于 120，解不出 T（见 [HGT_cross_hold.md](HGT_cross_hold.md) §1.1）。
- **按配对**：这是有意的限制。分开 hold 时，被 hold 的变量和残差个数必须相等，还要决定被 hold 的残差由哪个变量的固定方程顶替；没有交互式 FMU 那一层，这样做只会让结构变得难以预测。
- **非标量方程**：hold 只支持标量方程，其他种类给警告 8007 后忽略。
- OCT 那边"普通仿真时 hold 是否生效"手册没有明说，上表是根据"在 `FMUProblem` 中被保持"推断的。

## 12. 以后可以扩展的方向

| 方向 | 做法 | 难点 |
|---|---|---|
| 离散变量作 hold | `parseHold` 的可变性检查放宽到离散；改写不用变 | hold 变量依赖本块变量时会变成混合系统，需要后端检查 hold 只依赖块外已算出的量 |
| 保持当前值 | 用 `pre(x)` 代替 `$START.x` | 只有支持运行中切换 hold 时才有意义 |
| 交互式 FMU | FMU 只算残差，外层求解器管 hold，变量和残差可以分开 hold、保持当前值 | 见交互式 FMU 设计讨论：编译器、FMU 包装、外层求解器都要做，约 1.5–2 个月 |
| 新后端 | 在 `NBackendDAE.lower` 中做同样的改写 | 新后端还没有接入 HGT（见 [NewBackend_architecture.md](NewBackend_architecture.md) §9） |
