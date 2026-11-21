# HGT hold 的运行时方案（在现有仿真运行时中实现）

本文是设计文档，**还没有实现**。它重新设计 hold：编译器只做准备，**hold 的选择、个数检查和结构检查都在运行时完成**，而且就在现有的 C 仿真运行时中做，不依赖交互式 FMU 和 Python。Rust 运行时（`--simCodeTarget=C+Rust`）暂时不做，见 §11。

相关文档：

- [HGT_cross_hold.md](HGT_cross_hold.md)：交叉 hold 和 OCT 官方例子 `twoEqSteadyStateParaHold`；本文是那里方案一、方案二之外的第三个方案
- [HGT_hold.md](HGT_hold.md)：已撤销的按配对、编译期改写方案
- [HGT_steady_state_runtime.md](HGT_steady_state_runtime.md)：交互式 FMU + Python 的方案
- [SimulationRuntime_walkthrough.md](SimulationRuntime_walkthrough.md)：本文要改的运行时代码的走读

## 目录

1. [目标](#1-目标)
2. [核心想法](#2-核心想法)
3. [语义](#3-语义)
4. [编译器要做的准备](#4-编译器要做的准备)
5. [运行时的流程](#5-运行时的流程)
6. [结构检查](#6-结构检查)
7. [残差和雅可比矩阵的替换](#7-残差和雅可比矩阵的替换)
8. [保持值](#8-保持值)
9. [官方例子走一遍](#9-官方例子走一遍)
10. [诊断信息](#10-诊断信息)
11. [Rust 运行时](#11-rust-运行时)
12. [和其他方案的比较](#12-和其他方案的比较)
13. [分阶段计划与工作量](#13-分阶段计划与工作量)
14. [风险与待确认的问题](#14-风险与待确认的问题)

---

## 1. 目标

- 支持 OCT 的 hold 语义：迭代变量和残差的 hold **分别**生效，可以交叉（[HGT_cross_hold.md](HGT_cross_hold.md) §1），OCT 官方例子 `twoEqSteadyStateParaHold` 能直接运行。
- hold 由参数决定，**运行时**通过 `-override` 切换，不用重新编译。
- 个数检查和结构检查在**运行时**按实际的 hold 组合做，不在编译期枚举组合。
- 不改各个非线性求解器（hybrid、KINSOL、Newton、homotopy、mixed），只在非线性系统的入口和生成的残差、雅可比函数上加钩子。
- 普通仿真和普通 FMU 中都能用。

不做：同一次运行中途切换 hold（参数在一次运行中不变）；交互式 hold/release（那是交互式 FMU 的方案）。

## 2. 核心想法

设一个 HGT 非线性系统有 n 个迭代变量 x 和 n 条残差 r(x)。运行时根据 hold 参数的当前值得到：

- H_v：被 hold 的迭代变量，H_r：被 hold 的残差，要求 |H_v| = |H_r| = k；
- 未知量 U = x − H_v，方程 E = r − H_r。

真正要解的是 n − k 维的问题 E(U) = 0，H_v 固定在保持值。但改变系统的维数要动每个求解器的内存分配。所以这里用一个**等价的 n 维问题**代替：

```
把 H_r 中第 i 条残差的位置，换成 H_v 中第 i 个变量的固定方程：
    r_{H_r[i]}(x)  →  ( x_{H_v[i]} − held_{H_v[i]} ) / nominal(x_{H_v[i]})
其余残差不变
```

替换后的系统维数仍是 n，所有求解器原样使用。它的解就是"H_v 取保持值、E(U) = 0"的解：

- k 条替换方程把 H_v 固定在保持值；
- 剩下的 n − k 条就是 E，未知量就是 U。

**H_r 和 H_v 之间怎么一一对应都可以**：换上去的方程集合总是 {x_v − held_v : v ∈ H_v}，不同的对应只是雅可比矩阵的行排列不同。所以运行时按下标顺序配对就行，用户不需要指定。

这和已撤销的编译期方案（[HGT_hold.md](HGT_hold.md)）的区别：替换在**运行时**按实际的 hold 组合决定，所以变量和残差可以分开 hold，交叉 hold 也能处理；保持值是求解开始时的值，不是写死的 start。

## 3. 语义

| 规则 | 说明 |
|---|---|
| hold 的位置 | 和 OCT 相同：残差上 `ResidualEquation(hold = …)`，变量上 `iterationVariable(hold = …)`，系统级配对的两边 |
| hold 的值 | Boolean 参数表达式；不是结构参数，可以 `-override` |
| 两边独立 | 一个配对的变量和残差可以绑定不同的参数，也可以只写一边。**不再有**"两边必须相同"的检查 |
| 平衡 | 每个系统中，被 hold 的变量个数 = 被 hold 的残差个数，否则运行时报错 |
| 结构 | 释放的残差能解出释放的变量（二部图完全匹配），否则运行时报错 |
| 保持值 | 这个系统第一次在 hold 状态下求解时，迭代变量的当前值（§8） |
| 适用范围 | 初始化系统和仿真系统都生效 |
| 只能 hold HGT 的项 | 用户写在注解里的迭代变量和残差；撕裂时自动补的迭代变量和残差不能 hold |

## 4. 编译器要做的准备

### 4.1 前端

- 删掉"hold 不支持"的警告 8009。
- `parseHold` 不变：hold 仍是 Boolean 参数表达式，变量上和残差上的 hold 分别存储，不合并、不比较。
- 可选的静态检查：如果模型中只有变量带 hold、没有残差带 hold（或反过来），任何一个 hold 为 true 都不平衡，给警告。

### 4.2 后端：把可能被 hold 的项放进同一个非线性系统

运行时能做的只是在**一个**非线性系统内部替换方程，不能改变块之间的求解顺序。交叉 hold 的变量和残差如果在不同的块中，hold 之后求解顺序会变（[HGT_cross_hold.md](HGT_cross_hold.md) §4.2 第 4 步），所以要在编译期保证它们在同一个块中：

| 位置 | 改动 |
|---|---|
| `hgtMatching` | 所有带 hold（不是字面量 `false`）的配对放进同一个强连通分量，复用已有的 `addRing`。没有 hold 的配对不受影响 |
| `Tearing.handGuidedTearing` | 带 hold 的块：强制生成**非线性**撕裂系统（`TORNSYSTEM` 的 `linear` 置为 false），也不允许 1×1 块被显式解掉；否则运行时没有可以挂钩子的非线性系统 |
| `lower` | 不改写残差（只保留已有的 nominal 缩放） |

一般 hold 只用在少数几个配对上，所以合并的代价有限；但不 hold 时这个块也会变大，见 §14。

### 4.3 SimCode 与代码生成

对每个带 hold 的非线性系统，生成一组静态数据（`initializeStaticDataNLS<N>` 中设置）。为了让 `NONLINEAR_SYSTEM_DATA` 的布局变化最小（Rust 运行时要镜像这个结构，见 §11），这些数据放进一个单独的结构 `HGT_HOLD_DATA`，`NONLINEAR_SYSTEM_DATA` 末尾只加一个指针 `hgtHold`，没有 hold 的系统为 `NULL`：

| `HGT_HOLD_DATA` 的字段 | 内容 |
|---|---|
| `hgtNHoldVars`、`hgtHoldVarIdx[]` | 可能被 hold 的迭代变量在本系统迭代向量中的下标 |
| `hgtNHoldRes`、`hgtHoldResIdx[]` | 可能被 hold 的残差在本系统残差向量中的下标 |
| `hgtHoldVarNames[]`、`hgtHoldResNames[]` | 名字（变量名、HGT 方程名），用于诊断 |
| `hgtHoldFlags` | 生成的函数：按 hold 表达式的当前值填两个 Boolean 数组 |
| `hgtStructRowPtr[]`、`hgtStructCols[]` | 原始的结构：每条残差依赖哪些迭代变量（CSR），用于 §6 的结构检查 |

生成的 hold 标志函数：

```c
void hgtHoldFlagsNLS4(DATA *data, threadData_t *threadData,
                      modelica_boolean *varHeld, modelica_boolean *resHeld)
{
  varHeld[0] = data->simulationInfo->booleanParameter[1] /* testHold2 */;   /* x */
  varHeld[1] = data->simulationInfo->booleanParameter[0] /* testHold1 */;   /* T */
  resHeld[0] = data->simulationInfo->booleanParameter[0] /* testHold1 */;   /* LongEq */
  resHeld[1] = data->simulationInfo->booleanParameter[1] /* testHold2 */;   /* LongEq2 */
}
```

生成的残差函数和雅可比列函数末尾各加一句钩子调用（§7）：

```c
void residualFunc4(RESIDUAL_USERDATA* userData, const double* xloc, double* res, const int* iflag)
{
  ...                                   /* 原来的内部方程和残差 */
  hgtApplyHoldResidual(data, &data->simulationInfo->nonlinearSystemData[0], xloc, res);
}
```

**稀疏模式要补上可能的替换位置**：对每条可能被 hold 的残差 r 和每个可能被 hold 的变量 v，在非线性系统的稀疏模式中加入 (r, v)，然后再着色。这样不管运行时怎么配对，替换后的雅可比矩阵都在稀疏模式之内，着色也仍然有效（§7.2）。带 hold 的系统必须生成稀疏模式（1×1 系统现在可能没有，见 `nonlinearSystem.c:513`）。

## 5. 运行时的流程

在 `solve_nonlinear_system`（`nonlinearSystem.c`）中，取初值之后、调用 `solveNLS` 之前：

```
if 本系统有 hgtHoldFlags:
    hgtHoldFlags(data, threadData, varHeld, resHeld)
    if 标志和上次不同（或第一次）:
        H_v = {v | varHeld[v]},  H_r = {r | resHeld[r]}
        个数检查：|H_v| ≠ |H_r| → 报错（§10），求解失败
        结构检查（§6）：不通过 → 报错，求解失败
        配对：H_r 的第 i 个 ↔ H_v 的第 i 个，记入 hgtHoldMap
        记录保持值：held[v] = 当前迭代值 nlsx[v]（§8）
        hgtHoldActive = (k > 0)
        日志（-lv=LOG_NLS）：列出 hold 的变量、残差和保持值
    被 hold 的变量的初值直接设为保持值（nlsx[v] = held[v]），省一步迭代
solveNLS(...)                    ← 各求解器不变，残差和雅可比已被钩子替换
```

- hold 参数在一次运行中不变，所以标志只在第一次求解时真正处理；之后每次求解只做一次比较。
- 初始化系统和仿真系统各有自己的非线性系统，各自处理。
- 求解之后照常做 HGT 的界检查（`checkHGTBounds`）。被 hold 的变量的保持值如果在 [min, max] 之外，激活时给警告。

## 6. 结构检查

在第一次激活时，用编译器导出的原始结构 `hgtStructRowPtr/hgtStructCols`（残差 × 迭代变量，已经包含内部方程带来的间接依赖，就是撕裂后雅可比矩阵的稀疏结构）做二部图最大匹配：

```
行：E = 释放的残差（不在 H_r 中）
列：U = 释放的迭代变量（不在 H_v 中）
边：(r, x) 当且仅当 r 依赖 x（原始结构）
用增广路径求最大匹配（规模就是一个非线性系统，几个到几十个）
匹配数 < |E| → 结构奇异
```

结构奇异时，用匹配结果给出有用的诊断：

- 没有匹配上的残差：它依赖的释放变量都已经被别的残差占用，或者它只依赖被 hold 的变量；
- 没有匹配上的变量：剩下的残差都不含它。

例如官方例子中如果 hold x 而释放的残差只有 `LongEq2` 且它不含 T，就会报"`LongEq2` 不依赖任何释放的迭代变量（T）"。官方例子两条方程都含 x 和 T，所有组合都结构非奇异。

结构检查只保证**结构上**可解；数值上的奇异（例如官方例子中 x 保持在 1 时 `LongEq` 对 T 的导数为 0）要到求解时才发现，见 §9。

## 7. 残差和雅可比矩阵的替换

### 7.1 残差

运行时函数 `hgtApplyHoldResidual(data, sys, x, res)`（`nonlinearSystem.c` 中新增）：

```c
if (!sys->hgtHoldActive) return;
for (i = 0; i < sys->hgtHoldK; i++) {
  r = sys->hgtHoldMapRes[i];  v = sys->hgtHoldMapVar[i];
  res[r] = (x[v] - sys->hgtHeldValue[v]) / sys->nominal[v];
}
```

所有求解器、差分雅可比矩阵、homotopy 都通过 `residualFunc` 求残差，所以都自动用上替换后的方程。

### 7.2 雅可比矩阵

符号雅可比矩阵由生成的列函数按种子向量 s 计算 J·s。替换后，被 hold 的残差 r 那一行只有 (r, v) 一个元素，值为 1/nominal(v)，所以：

```c
/* hgtApplyHoldJacobian(data, sys, seed, result)，在生成的 NLSJac 列函数末尾调用 */
result[r] = seed[v] / sys->nominal[v];      /* 对每个 (r, v) ∈ hgtHoldMap */
```

着色时多个列共用一个种子，这样仍然正确：§4.3 已经把所有可能的 (r, v) 加进了稀疏模式，同一种颜色中最多只有一列在第 r 行的模式里；如果 v 不在这种颜色中，`seed[v] = 0`，第 r 行在这种颜色中的结果为 0，解压后被 hold 的行上其他列都是 0，正是替换后的雅可比矩阵。

没有符号雅可比矩阵时，求解器对 `residualFunc` 做差分，自动正确。

### 7.3 缩放

替换方程除以 nominal(v)，和迭代变量的缩放一致；KINSOL 等的自动残差缩放照常工作。

## 8. 保持值

保持值是这个系统**第一次在 hold 状态下求解时**迭代变量的当前值，之后在这次运行中不变。在现有运行时中，"当前值"的来源有三种：

| 来源 | 用法 | 对应 OCT |
|---|---|---|
| start 值 | 默认：初始化时迭代变量的初值就是 start | |
| `-override=x=0.8` | 运行时改迭代变量的 start（需要确认对 HGT 迭代变量可用，见 §14） | `model.set("x", 0.8)` |
| `-iif=上次的结果.mat -iit=时刻` | 从上一次运行的结果文件读初值 | 保持上一次的解 |

仿真系统在初始化之后第一次求解时激活，保持值就是初始化的结果，所以两个系统一致。

这比已撤销的方案好：那里保持值固定为 start，官方例子的 `testHold2` 工况（x 保持在 start 1）解不出；这里可以 `-override=x=0.8`，或者用 `-iif` 接上一次的解。

## 9. 官方例子走一遍

[HGT_cross_hold.md](HGT_cross_hold.md) §1.1 的 `twoEqSteadyStateParaHold`，注解换成 `__OpenModelica_HGT`。两条方程本来就在同一个块中（都含 x 和 T），系统大小 2，迭代变量 (x, T)，残差 (`LongEq`, `LongEq2`)。

| 运行命令 | H_v | H_r | 替换 | 结果（按方程算出） |
|---|---|---|---|---|
| `./twoEq` | ∅ | ∅ | 无 | x = 0.96387，T = 346.164 |
| `./twoEq -override=testHold1=true` | {T} | {LongEq} | `LongEq` → `T − 400` | x = 2.3256，T = 400 |
| `./twoEq -override=testHold1=true,T=330` | {T} | {LongEq} | `LongEq` → `T − 330` | x = 0.60773，T = 330 |
| `./twoEq -override=testHold2=true` | {x} | {LongEq2} | `LongEq2` → `x − 1` | **数值奇异**：x = 1 时 `LongEq` 对 T 的导数为 0，求解失败 |
| `./twoEq -override=testHold2=true,x=0.8` | {x} | {LongEq2} | `LongEq2` → `x − 0.8` | x = 0.8，T = 328.988 |
| 第 1 次运行后：`./twoEq -override=testHold2=true -iif=twoEq_res.mat -iit=0` | {x} | {LongEq2} | `LongEq2` → `x − 0.96387` | x = 0.96387，T = 346.164（保持上一次的解） |

第四行说明：结构检查通过（`LongEq` 含 T），但数值上奇异。运行时的日志会列出 hold 的项和保持值（x = 1），提示用户换一个保持值。

## 10. 诊断信息

运行时的新消息：

| 情况 | 消息 |
|---|---|
| 个数不平衡 | `Hand guided tearing system %d: %d iteration variables are held ({x, T}), but %d residual equations are held ({LongEq}).` |
| 结构奇异 | `Hand guided tearing system %d: with the held items the residual equations {…} cannot determine the iteration variables {…}.` |
| 保持值越界 | `Hand guided tearing system %d: the held value %g of %s is outside [%g, %g].`（警告） |
| 激活（`-lv=LOG_NLS`） | `Hand guided tearing system %d holds {x = 0.8} and drops {LongEq2}.` |

个数不平衡和结构奇异都在第一次求解前报出，作为初始化失败处理（和普通的非线性系统求解失败一样结束运行），不会算出错误的结果。

编译期的消息：

| 情况 | 消息 |
|---|---|
| 只有变量带 hold、没有残差带 hold（或反过来） | 警告：任何 hold 为 true 时都不平衡 |

## 11. Rust 运行时

**暂时不做**。第一版只在 C 运行时中实现，但有两件事必须现在就处理，否则会影响 Rust 运行时的所有模型：

| 事项 | 原因 | 做法 |
|---|---|---|
| 结构布局 | Rust 运行时的 `abi.rs` 按 C 的布局镜像 `NONLINEAR_SYSTEM_DATA`，生成的 C 代码按 C 的 `sizeof` 访问系统数组。C 中加了字段而 Rust 没加，**所有**带非线性系统的模型都会访问错位 | `abi.rs` 的镜像同步加上 `hgtHold` 指针（只加一个字段，Rust 运行时总把它当作 `NULL`） |
| 带 hold 的模型 | Rust 运行时不处理 hold，带 hold 的模型如果照常编译，hold 会被静默忽略 | `--simCodeTarget=C+Rust` 且模型中有不是字面量 `false` 的 hold 时，编译期报错（或警告后忽略 hold，和以前的 8009 一样），明确说明 Rust 运行时还不支持 hold |

如果钩子采用"在生成的残差函数末尾调用"的方式（§4.3），生成代码中会出现对 `hgtApplyHoldResidual` 的调用，Rust 运行时没有这个符号会链接失败；上面第二项在编译期就挡住了带 hold 的模型，所以不会走到这一步。如果钩子采用"运行时替换函数指针"的方式，生成代码不变，也就没有这个问题。

以后要支持时：`nls.rs` 实现 §5 的激活、个数检查和结构检查，导出 `hgtApplyHoldResidual`、`hgtApplyHoldJacobian`（或实现指针替换），诊断文字和 C 相同，测试两边比对。估计 2–3 天。

## 12. 和其他方案的比较

| | 已撤销的按配对改写（[HGT_hold.md](HGT_hold.md)） | 编译期按表达式分组（[HGT_cross_hold.md](HGT_cross_hold.md) 方案二） | **本文：运行时替换** | 交互式 FMU（[HGT_cross_hold.md](HGT_cross_hold.md) 方案一） |
|---|---|---|---|---|
| 交叉 hold | 不支持 | 支持 | 支持 | 支持 |
| 官方例子 | 报错 | 能运行（保持 start） | 能运行 | 能运行 |
| 两边绑定不同参数、靠组合平衡 | 不支持 | 要求每个参数各自平衡 | 支持（按实际组合检查） | 支持 |
| 个数、结构检查 | 无需 | 编译期逐个参数 | **运行时按实际组合** | 求解时按实际组合 |
| 保持值 | start | start | 求解开始时的值（start、`-override`、`-iif`） | 当前值 |
| 切换 | `-override` | `-override` | `-override` | 同一会话中随时 |
| API hold（不用参数） | 不能 | 不能 | 可以加运行时选项（阶段 2） | 能 |
| 跨块 | 不涉及 | 编译期合并 | 编译期合并带 hold 的配对 | 运行时重新分块 |
| 普通仿真、普通 FMU | 能 | 能 | 能 | 不能 |
| 运行时改动 | 无 | 无 | C 运行时加一部分（Rust 运行时以后再做） | 新的 Python 包 |
| 工作量 | （已撤销） | 3–5 天 | 约 2–2.5 周 | 交互式 FMU 5–6 周 + 5–6 天 |

本文的方案在现有运行时中做到了和 OCT 最接近的语义（交叉 hold、按实际组合检查、保持值可以给定），代价是要改 C 运行时（Rust 运行时以后再做），以及带 hold 的配对在编译期被合并成一个块。

## 13. 分阶段计划与工作量

| 阶段 | 内容 | 工作量 |
|---|---|---|
| **1. 编译器** | 前端去掉 8009 警告；`hgtMatching` 合并带 hold 的配对；强制非线性系统；SimCode 字段、hold 标志函数、钩子调用；稀疏模式补上 (r, v) 并保证生成；导出原始结构和名字 | 4–5 天 |
| **2. C 运行时** | `NONLINEAR_SYSTEM_DATA` 新字段；激活、个数检查、二部图结构检查；`hgtApplyHoldResidual`、`hgtApplyHoldJacobian`；保持值；诊断 | 3–4 天 |
| **3. Rust 运行时的兼容** | `abi.rs` 镜像加 `hgtHold` 指针；`C+Rust` 目标遇到 hold 时编译期报错 | 0.5 天 |
| **4. 测试和文档** | 官方例子各工况（含 `-override` 保持值、`-iif` 接上次的解、数值奇异）；个数不平衡；结构奇异；同一配对两边同一参数（回归）；不带 hold 的模型在 Rust 运行时上回归 | 1–2 天 |
| **合计** | | **约 2 周** |
| 以后：Rust 运行时支持 hold | §11 | 2–3 天 |
| 可选：运行时选项 | `-hgtHoldVars=x,T`、`-hgtHoldResiduals=LongEq`：不用参数、按名字 hold（相当于 OCT 的 `holdIterationVariables`），只要编译器把所有 HGT 项都按"可能被 hold"处理 | 2–3 天 |

## 14. 风险与待确认的问题

| 问题 | 说明与对策 |
|---|---|
| 合并块的代价 | 带 hold 的配对永远在一个块中，不 hold 时块也变大，可能变慢、更难收敛。只合并带 hold 的配对，影响范围有限；需要用实际模型评估 |
| `-override` 迭代变量的 start | 之前的试验中，`iterationVariable(start = …)` 写成常数时，`-override=x=…` 提示"不能覆盖"。要确认原因，必要时让 HGT 的 start 保持可覆盖 |
| 数值奇异 | 结构检查只能发现结构问题；保持值让雅可比矩阵奇异时（官方例子 x = 1）只能在求解时失败。日志中给出保持值，帮助定位 |
| 强制非线性系统 | 原本线性或可以显式解出的块被强制成非线性系统，多一点开销；只影响带 hold 的块 |
| 稀疏模式与着色 | 补上 (r, v) 后要重新着色；1×1 系统现在可能没有稀疏模式，要保证带 hold 的系统总是生成 |
| 动态模型 | hold 参数在一次运行中不变，保持值在第一次求解时确定；对动态模型（HGT 本来就只保证稳态）不额外处理 |
| OCT 行为细节 | 被 hold 的变量和残差个数不平衡时 OCT 的具体报错、保持值的确切来源，最好用 `parametric_hold_IV.py` 在 OCT 上对照确认 |
