# HGT 交叉 hold 设计

本文是设计文档，**还没有实现**。它讨论怎样支持 OCT 的交叉 hold：hold 一个配对的迭代变量，同时 hold **另一个**配对的残差方程。文中给出两个方案并做比较：

- **方案一**：在交互式稳态求解器（交互式 FMU + Python `FMUProblem`）中实现；
- **方案二**：在现在的编译期改写框架中实现。

相关文档：

- [HGT_hold.md](HGT_hold.md)：按配对、编译期改写的 hold 方案（实现已撤销，保留为设计记录；现在 hold 只解析，给警告 8009 后忽略）
- [HGT_steady_state_runtime.md](HGT_steady_state_runtime.md)：交互式 FMU 和 Python 稳态接口的设计，方案一以它为基础
- [HGT_matching_and_tearing.md](HGT_matching_and_tearing.md)：`hgtMatching` 和撕裂，方案二要改这里

## 目录

1. [什么是交叉 hold](#1-什么是交叉-hold)
2. [现在的实现的问题](#2-现在的实现的问题)
3. [方案一：交互式稳态求解器](#3-方案一交互式稳态求解器)
4. [方案二：编译期改写](#4-方案二编译期改写)
5. [两个方案的比较](#5-两个方案的比较)
6. [建议](#6-建议)
7. [附录：OCT 的 Python 脚本](#7-附录oct-的-python-脚本)

---

## 1. 什么是交叉 hold

OCT 中 hold 可以分别写在迭代变量和残差方程上（R10）。被 hold 的迭代变量不再是未知量，被 hold 的残差不再是方程。只要被 hold 的变量和残差个数相等，方程组仍然平衡，**它们不必属于同一个配对**。

### 1.1 OCT 的官方例子

OCT 用户手册 "Specification of Hand Guided Tearing" 一章的例子 `twoEqSteadyStateParaHold`（模型在 `ExampleModels.mo` 中，运行脚本是 `parametric_hold_IV.py`）。手册的原话是："parameters for parametric holding is specified for the iteration variables and residuals as follows"：

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

这是一个两方程的稳态问题（一阶反应的转化率 x 和温度 T）。注意每个配对的残差和迭代变量绑定的是**不同**的参数：

| 配对 | 残差 | 残差的 hold | 迭代变量 | 变量的 hold |
|---|---|---|---|---|
| 1 | `LongEq` | `testHold1` | x | `testHold2` |
| 2 | `LongEq2` | `testHold2` | T | `testHold1` |

按参数看：

| 参数 | 被 hold 的变量 | 被 hold 的残差 |
|---|---|---|
| `testHold1` | T（配对 2 的变量） | `LongEq`（配对 1 的残差） |
| `testHold2` | x（配对 1 的变量） | `LongEq2`（配对 2 的残差） |

每个参数都 hold 一个配对的**变量**和**另一个**配对的**残差**：这就是交叉 hold。模型中没有写死任何 true/false，运行时设置两个参数就切换工况：

| 运行时设为 true | 被 hold 的变量 | 被 hold 的残差 | 未知量 → 方程 | 含义 |
|---|---|---|---|---|
| （无） | ∅ | ∅ | x、T → `LongEq`、`LongEq2` | 两个方程联立求 x 和 T |
| `testHold1` | {T} | {`LongEq`} | x → `LongEq2` | 给定温度 T，由 `LongEq2` 求 x |
| `testHold2` | {x} | {`LongEq2`} | T → `LongEq` | 给定转化率 x，由 `LongEq` 求 T |
| 两个都设 | {x, T} | {`LongEq`、`LongEq2`} | 不用解 | x、T 都给定 |

数值（按方程算出，没有在 OCT 上运行）：

| 工况 | 给定 | 解 |
|---|---|---|
| 都不 hold，从 start（x = 1，T = 400）出发 | | x = 0.96387，T = 346.164（唯一的稳态） |
| `testHold1`，T 设为 330 | T = 330 | x = 11·30/543 = 0.60773 |
| `testHold2`，x 设为 0.8 | x = 0.8 | T = 328.988 |
| `testHold2`，x 保持 start 1 | x = 1 | **无解**：x = 1 时 `LongEq` = 120 − 0，和 T 无关 |

最后一行说明**保持值是"当前值"还是"start"有实际影响**：OCT 中被 hold 的 x 保持当前值（用户设的值，或上一次的解 0.96387），能解；如果像现在的 OMC 一样保持 start 1，`LongEq` 就恒等于 120，解不出 T。

### 1.2 一个配对两边的四种组合

在 OCT 中，同一个配对的迭代变量和残差的 hold 是**独立**的，官方例子中每个配对都是"一边 `testHold1`、一边 `testHold2`"。设 `testHold1` = true、`testHold2` = false 时：

| 配对 | 变量的 hold | 残差的 hold | 含义 |
|---|---|---|---|
| 1 | x：**false** | `LongEq`：**true** | `LongEq` 去掉；x 仍是未知量，只能由别的方程（`LongEq2`）决定 |
| 2 | T：**true** | `LongEq2`：**false** | T 固定；`LongEq2` 仍要成立，只能靠别的变量（x）满足 |

两个配对互相补上，方程数平衡。四种组合在 OCT 中的含义：

| 变量的 hold | 残差的 hold | 这个配对 | 方程数 |
|---|---|---|---|
| false | false | 正常求解 | 不变 |
| true | true | 整对去掉：变量固定，残差不要（[HGT_hold.md](HGT_hold.md) 中已撤销的按配对实现支持的就是这种） | 不变 |
| true | false | 变量固定，但残差还在：要由**别的配对**释放出来的变量满足 | 少一个未知量，必须有别处 hold 一条残差 |
| false | true | 残差去掉，但变量还在：要由**别的配对**的残差决定 | 少一条方程，必须有别处 hold 一个变量 |

后两种必须成对出现（可以分布在不同配对、不同块中），整个模型被 hold 的变量和残差个数相等，而且剩下的方程能解出剩下的未知量（结构非奇异），否则求解时报错。因为这些参数在运行时才确定，个数检查和结构检查也只能在**运行时**做：这正是方案一（§3.4 第 2、3 步）的做法；方案二只能在编译期逐个参数检查（§4.4）。

## 2. 现在的实现的问题

现在的 OMC **不支持 hold**：前端解析并存储 `hold`，只要有一个 hold 不是字面量 `false`，就给警告 8009（"The hold attribute of hand guided tearing is not supported yet and is ignored."），然后按"都不 hold"求解。

| 写法 | 例子 | 现在的结果 |
|---|---|---|
| 不写 hold，或只写字面量 `false` | | 正常求解，没有警告 |
| 写了参数或 `true` | §1.1 官方例子 `twoEqSteadyStateParaHold` | 警告 8009，hold 被忽略，按"都不 hold"求解（x = 0.96387，T = 346.164），不管 `testHold1`、`testHold2` 设成什么 |

所以现在不会静默算错（总有警告），但 hold 完全不起作用。

曾经有过一版按**配对**的实现（[HGT_hold.md](HGT_hold.md)，已撤销）：一个配对的 hold 取残差上的，没写就取迭代变量上的，两边都写时必须是同一个表达式。它对官方例子报错（两边的表达式不同），而且只写一边时会把交叉 hold 静默当成整对 hold。撤销的原因之一就是它和 OCT 的交叉 hold 语义不一致。下面两个方案都按 OCT 的语义来设计。

## 3. 方案一：交互式稳态求解器

### 3.1 思路

在交互式 FMU 中，所有 HGT 迭代变量都是 FMU 的**输入**，所有残差都是**输出**，FMU 只负责"给定迭代变量，算出残差"（见 [HGT_steady_state_runtime.md](HGT_steady_state_runtime.md)）。外层求解器每次求解时根据当前的 hold 状态决定：

- 未知量 U = 没有被 hold 的迭代变量；
- 方程 E = 没有被 hold 的残差。

交叉 hold 只是从全体迭代变量和残差中各挑一部分，不需要合并块，也不需要改写方程。

### 3.2 FMU 要提供的信息

**(1) hold 分别按变量和残差导出**，不按配对合并：

```xml
<HandGuidedTearing version="1">
  <IterationVariable name="x" hold="testHold2"/>
  <IterationVariable name="T" hold="testHold1"/>
  <Residual name="$res.LongEq"  residualName="LongEq"  hold="testHold1"/>
  <Residual name="$res.LongEq2" residualName="LongEq2" hold="testHold2"/>
  <Pair residual="$res.LongEq"  iterationVariable="x"/>
  <Pair residual="$res.LongEq2" iterationVariable="T"/>
</HandGuidedTearing>
```

- `Pair` 只作参考（日志、初值），求解时不依赖它。
- 交互模式下 hold 由外层求解器处理，编译器不再对 hold 给警告 8009。

**(2) 残差对迭代变量的依赖关系**：FMI 2.0 的 `<ModelStructure><Outputs>` 本来就记录每个输出依赖哪些输入。残差是输出、迭代变量是输入，所以这就是全局雅可比矩阵的稀疏结构，用于结构检查和按块分解。OMC 已经会为普通 FMU 生成 ModelStructure，需要确认它在"HGT 块只求值"的路径下也正确。

### 3.3 求解器的状态

```python
class FMUProblem:
    vars:          list[IterationVar]  # 名字、valueReference、nominal、min、max、hold 参数（可选）
    residuals:     list[Residual]      # 名字、valueReference、nominal、hold 参数（可选）
    api_held_vars: set                 # holdIterationVariables / releaseIterationVariables
    api_held_res:  set                 # holdResiduals / releaseResiduals
    dep:           稀疏 0/1 矩阵        # residuals × vars，来自 ModelStructure
```

### 3.4 每次 solve() 的步骤

```
1. 定出被 hold 的集合（parametric hold 每次重读参数）
     H_v = api_held_vars ∪ {v | v 的 hold 参数当前为 true}
     H_r = api_held_res  ∪ {r | r 的 hold 参数当前为 true}
     U = vars − H_v,  E = residuals − H_r

2. 个数检查
     |U| ≠ |E| → 报错，列出两边，例如"释放了 3 个迭代变量，但只有 2 条残差"

3. 结构检查：在 dep[E, U] 上做二部图最大匹配
     不是完全匹配 → 报错，指出不依赖任何释放变量的残差、
                    不出现在任何释放残差中的变量

4. 被 hold 的变量保持当前值：它们是 FMU 输入，不去动它

5. 只在 U 和 E 上做 Newton
     x = U 的当前值，投影到 [min, max]
     F = E 的残差 × 缩放
     J = dep[E, U] 位置上的偏导（方向导数，或对 U 的列差分）
     解 J·dx = −F，线搜索，投影，直到收敛

6. 解留在 FMU 中，下一次 solve() 从这里出发（"保持当前值"）
```

**按块分解（可选，提速用）**：有了 `dep[E, U]`，每次求解前可以对子问题做 Tarjan 分块，先解前面的小块再解后面的。交叉 hold 改变了因果关系，分块结果也随之改变，但这是在**运行时**按当前 hold 状态重新算的。

### 3.5 官方例子

FMU 接口：输入 {x, T}，输出 {`LongEq`, `LongEq2`}。依赖：两条残差都依赖 {x, T}。

| 工况 | H_v | H_r | U | E | 结构检查 | 结果 |
|---|---|---|---|---|---|---|
| 都不 hold | ∅ | ∅ | {x, T} | {LongEq, LongEq2} | 完全匹配 | x = 0.96387，T = 346.164 |
| `testHold1` | {T} | {LongEq} | {x} | {LongEq2} | LongEq2–x | T 保持当前值，x 由 `LongEq2` 求出 |
| `testHold2` | {x} | {LongEq2} | {T} | {LongEq} | LongEq–T | x 保持当前值，T 由 `LongEq` 求出 |
| 用 API 只 hold x | {x} | ∅ | {T} | {LongEq, LongEq2} | 个数 1 ≠ 2 | 报错，提示再 hold 一条残差 |

```python
p = FMUProblem("twoEqSteadyStateParaHold.fmu")
Solver(p).solve()                                    # x = 0.96387, T = 346.164
p.set("testHold1", True); p.set("T", 330.0)
Solver(p).solve()                                    # T 给定 330，x = 0.60773
# 不用参数，直接用 API：
p.holdIterationVariables(["x"]); p.holdResiduals(["LongEq2"])
```

### 3.6 工作量

交叉 hold 是交互式 FMU 第一版（约 5–6 周）之上的增量：

| 内容 | 工作量 |
|---|---|
| 编译器：hold 按变量、残差分别导出；交互模式下不给警告 8009 | 0.5 天 |
| 确认 ModelStructure 的依赖关系在"只求值"路径下正确，必要时补上 | 1–2 天 |
| 求解器：hold 集合、个数检查、二部图结构检查、取子雅可比矩阵 | 2 天 |
| 诊断信息（`printInfo('held')`、列出不匹配的项） | 0.5 天 |
| 测试：两种工况、个数不等、结构奇异、跨块 | 1 天 |
| **合计** | **5–6 天** |
| 可选：运行时按块分解 | 约 1 周 |

## 4. 方案二：编译期改写

### 4.1 思路

沿用 [HGT_hold.md](HGT_hold.md)（已撤销）的做法：把 hold 编译进残差表达式，用参数在运行时切换。区别是不再按配对，而是**按 hold 表达式分组**。

关键观察：同一个 hold 表达式 h 下，设被 hold 的变量集合为 V_h，被 hold 的残差集合为 R_h。只要 |V_h| = |R_h|，把 R_h 中的每条残差换成某个 `v − v.start`（v ∈ V_h），**哪条残差配哪个变量都不影响解**：换上去的方程集合总是 {v − v.start : v ∈ V_h}，不同的对应只是雅可比矩阵的行排列不同。所以用户不需要指定对应关系。

官方例子按参数分组：

| 组 | V_h | R_h | 个数 |
|---|---|---|---|
| `testHold1` | {T} | {`LongEq`} | 1 = 1 ✓ |
| `testHold2` | {x} | {`LongEq2`} | 1 = 1 ✓ |

改写后：

```
LongEq:   0 = if testHold1 then T - T.start
                           else 120*x - 75*(0.12*exp(12581*(T - 298)/(298*T)))*(1 - x)
LongEq2:  0 = if testHold2 then x - x.start
                           else -x*(873 - T) + 11.0*(T - 300)
```

- 每条残差都换成了**另一个配对**的变量的固定方程：`LongEq` 的位置固定 T，`LongEq2` 的位置固定 x。
- 两个配对本来就在同一个块中（两条方程都含 x 和 T），不需要额外合并。
- `testHold1` = true 时 T 固定、x 由 `LongEq2` 求出，正是期望的语义。

但方案二的保持值是 **start**：`testHold2` = true 时 x 固定在 start 1，`LongEq` 恒等于 120，**解不出**（§1.1 最后一行）。要用这个工况，只能改模型，把 start 换成参数（例如 `Real x(start = x0)`），再用 `-override=testHold2=true,x0=0.8` 运行。OCT 保持的是当前值，不需要改模型。

### 4.2 步骤

| 步骤 | 位置 | 内容 |
|---|---|---|
| 1. 分组、检查个数 | 前端 `NFHandGuidedTearing.finish` | 把"hold 不支持"的警告 8009 去掉；按 hold 表达式（`Expression.isEqual`）分组得到 V_h、R_h；个数不等时报新错误，例如"hold = testHold1 固定了 2 个迭代变量，但只去掉了 1 条残差"。同一配对两边都写同一个 h 的情况自然落在同一组，行为和现在一样 |
| 2. 定对应关系 | 后端 `HandGuidedTearing.lower` | 同一配对的变量优先配给自己的残差，其余按名字顺序配对 |
| 3. 改写 | 后端 `lower`（现在只有 `scaleResidual`，可以恢复已撤销的 `rewriteResidual` 再扩展） | R_h 中第 k 条残差改写成 `if h then V_h[k] − V_h[k].start else 原残差`（原残差照旧除以 nominal） |
| 4. 合并块 | 后端 `hgtMatching` | 交叉 hold 一般跨块：例如被 hold 的残差和被 hold 的变量本来分属先后两个块时，hold 后求解顺序会变。所以同一组涉及的所有配对要强制放进同一个块，复用已有的 `addRing`（相当于对这一组局部打开 `--hgtMergeBLTBlocks`） |
| 5. 结构检查 | 后端，撕裂之后 | 对每个 h，把 R_h 那几行换成 V_h 的单位行，检查撕裂后的系统在结构上非奇异（迭代变量 × 残差的依赖关系有完全匹配）。官方例子中，`testHold1` 组要求 `LongEq2` 依赖 x，`testHold2` 组要求 `LongEq` 依赖 T，都满足 |
| 6. 测试和文档 | | 官方例子的各工况（保持值写成参数）、个数不等、结构奇异、同一配对两边 hold（回归）、C 和 Rust 运行时 |

### 4.3 工作量

| 内容 | 工作量 |
|---|---|
| 前端：分组、个数检查、新错误号 | 0.5 天 |
| 后端：对应关系、改写 | 0.5 天 |
| `hgtMatching` 中按组合并块 | 1 天 |
| 结构检查 | 1–1.5 天 |
| 测试、文档 | 1 天 |
| **合计** | **3–5 天** |

### 4.4 限制

- **块变大**：同一组的配对永远合在一个块里，不 hold 时也是，非线性系统变大，可能变慢、更难收敛。
- **组合检查不完整**：多个 hold 参数同时为 true 的组合，编译期只能逐个参数检查（参数很少时可以枚举全部组合），其余组合到运行时才发现奇异。
- **和 OCT 仍有差距**：要事先在注解中绑定参数，没有 API hold；保持值是 start（官方例子的 `testHold2` 工况因此解不出，要改模型）；只能在两次运行之间切换。

## 5. 两个方案的比较

### 5.1 功能

| | 方案一（交互式求解器） | 方案二（编译期改写） | OCT |
|---|---|---|---|
| 交叉 hold | 支持 | 支持 | 支持 |
| hold 的来源 | 参数，或者 API 临时 hold | 只能是事先绑定的参数 | 参数和 API |
| 不改模型就 hold 任意迭代变量 | 能 | 不能 | 能 |
| 保持值 | 当前值（用户设的或上次的解） | start（可以写成参数） | 当前值 |
| 切换 | 同一会话中随时切换，从上次的解出发 | 两次运行之间用 `-override` | 同一会话中随时 |
| 跨块 | 运行时按 hold 状态重新分块 | 编译期把相关配对永久合进一个块 | 运行时 |
| 结构检查 | 每次求解时按实际的 hold 组合 | 编译期逐个参数 | 求解时 |
| 普通仿真、普通 FMU 中可用 | 不能，只在交互式 FMU 中 | 能 | 推断不能 |

### 5.2 实现与维护

| | 方案一 | 方案二 |
|---|---|---|
| 前提 | 先有交互式 FMU（第一版约 5–6 周） | 现有框架就能做 |
| 交叉 hold 本身的工作量 | 5–6 天 | 3–5 天 |
| 改动位置 | 编译器少量（导出信息）+ Python 求解器 | 前端、`lower`、`hgtMatching`、新的结构检查 |
| 运行时改动 | C 和 Rust 运行时都不用改；求解器在 Python 中 | 不用改；开关在生成的代码中 |
| 性能影响 | 不 hold 时没有影响 | 不 hold 时块也变大 |
| 和现在的关系（hold 不支持） | 只在交互模式下支持 hold；普通仿真中 hold 仍被忽略 | 普通仿真和普通 FMU 中都支持 hold；可以复用 [HGT_hold.md](HGT_hold.md) 中已撤销实现的改写代码 |
| 风险 | 交互式 FMU 本身的风险（只求值的代码生成、FMI 调用开销） | 合并块带来的收敛问题；结构检查只覆盖部分组合 |

### 5.3 优缺点小结

**方案一**

- 优点：语义和 OCT 一致；不影响不 hold 时的性能；hold 组合在运行时检查，诊断信息准确；同时解决 API hold、保持当前值、交互式切换。
- 缺点：依赖交互式 FMU，总工作量大；只能在 Python 中用，普通仿真用不了。

**方案二**

- 优点：现有框架内几天就能做完；普通仿真和普通 FMU 中都能用；不依赖 Python。
- 缺点：块永久变大；结构检查不完整；仍然没有 API hold、保持当前值和交互式切换。

## 6. 建议

1. **马上做**：§2 的临时措施，只写一边的 hold 给警告或报错，避免 OCT 模型静默算错。约半小时。
2. **短期**（有用到交叉 hold 的模型要在普通仿真中跑时）：方案二，3–5 天。
3. **长期**（要 OCT 那种交互式稳态工作流时）：方案一，随交互式 FMU 一起做。

两个方案可以并存：方案二服务于普通仿真和普通 FMU，方案一服务于交互式 FMU。交互模式下编译器跳过方案二的改写，把 hold 信息原样导出给外层求解器。

## 7. 附录：OCT 的 Python 脚本

手册中运行官方例子的脚本 `parametric_hold_IV.py` 开头如下（原文，只摘到能看到的部分）：

```python
import os
from pymodelica import compile_fmu
from pyfmi import load_fmu
from oct.steadystate.nlesol import FMUProblem

compiler_opts = {"interactive_fmu": True,
                 "expose_scalar_equation_blocks_in_interactive_fmu": True,
                 ...}
```

注意它打开了 `expose_scalar_equation_blocks_in_interactive_fmu`：连解不出来的单个标量方程也暴露给外部求解器。

下面的后续部分是**按文档推测**写的，演示 §1.1 的各工况和"保持当前值"。只核对过这些名字：`FMUProblem`、`Solver`（在 `oct.steadystate.nlesol` 中）、`holdIterationVariables` / `releaseIterationVariables`（按下标）、`printInfo`；函数的参数细节、初始化之后改参数要不要重新初始化，没有核对，以手册中 `parametric_hold_IV.py` 的实际内容为准。

```python
from oct.steadystate.nlesol import Solver

fmu = compile_fmu("twoEqSteadyStateParaHold", "ExampleModels.mo",   # 未核对：模型的全名
                  compiler_options=compiler_opts)
model = load_fmu(fmu)
problem = FMUProblem(model)        # 未核对：构造参数
solver = Solver(problem)
problem.printInfo("all")

# 1. 都不 hold：两个方程联立
solver.solve()
print(model.get(["x", "T"]))                  # x = 0.96387, T = 346.164

# 2. testHold1：T 固定，去掉 LongEq，由 LongEq2 求 x
model.set("testHold1", True)                  # 未核对：初始化之后改参数是否需要 reset
model.set("T", 330.0)                         # T 保持这个值，不是 start 400
solver.solve()
problem.printInfo("parametricHold")
print(model.get(["x", "T"]))                  # x = 0.60773, T = 330

# 3. testHold2：x 固定，去掉 LongEq2，由 LongEq 求 T
model.set("testHold1", False)
model.set("testHold2", True)
model.set("x", 0.8)
solver.solve()
print(model.get(["x", "T"]))                  # x = 0.8, T = 328.988

# 4. 不用参数，直接用 API hold x（下标从 printInfo("all") 查）
model.set("testHold2", False)
problem.holdIterationVariables([0])           # 假设 x 是第 0 个迭代变量
#   只 hold 变量还不够，还要去掉一条残差，方程数才平衡
problem.releaseIterationVariables([0])
```

| 步骤 | 设为 true 的参数 | 给定 | x | T |
|---|---|---|---|---|
| 1 | （无） | | 0.96387 | 346.164 |
| 2 | `testHold1` | T = 330 | 0.60773 | 330 |
| 3 | `testHold2` | x = 0.8 | 0.8 | 328.988 |

同一个模型在现在的 OMC 中（注解换成 `__OpenModelica_HGT`）：hold 被忽略，给警告 8009（§2），三步都按"都不 hold"求解，得到同一个解。方案二实现后，第 1、2 步可以算（第 2 步要把 T 的 start 写成参数才能给 330），第 3 步要把 x 的 start 写成参数，否则保持在 1 解不出；方案一实现后，结果应和上表一致。
