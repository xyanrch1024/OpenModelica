# HGT 交叉 hold 设计

本文是设计文档，**还没有实现**。它讨论怎样支持 OCT 的交叉 hold：hold 一个配对的迭代变量，同时 hold **另一个**配对的残差方程。文中给出两个方案并做比较：

- **方案一**：在交互式稳态求解器（交互式 FMU + Python `FMUProblem`）中实现；
- **方案二**：在现在的编译期改写框架中实现。

相关文档：

- [HGT_hold.md](HGT_hold.md)：现在的 hold 实现（按配对、编译期改写）
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

典型用法是设计工况和校核工况之间的切换。下面是一个阀门的例子：

```modelica
model Valve
  parameter Boolean design = false;
  parameter Real k = 1, dp = 4, u_set = 0.5;
  Real m(start = 2), u(start = 0.5);
equation
  m = u * k * sqrt(dp) annotation(__OpenModelica_HGT(name = valve,
    ResidualEquation(iterationVariable(hold = design) = m)));
  u = u_set annotation(__OpenModelica_HGT(name = set,
    ResidualEquation(iterationVariable = u, hold = design)));
end Valve;
```

| 工况 | 已知 | 求解 | 用到的方程 |
|---|---|---|---|
| 校核（`design = false`） | 开度 `u = u_set` | 流量 m | `valve`、`set` |
| 设计（`design = true`） | 流量 m（保持在给定值） | 开度 u | 只用 `valve`；`set` 被去掉 |

设计工况下被 hold 的是配对 1 的**变量** m 和配对 2 的**残差** `set`：这就是交叉 hold。

### 1.1 一个配对的两边可以一个为 true、一个为 false

在 OCT 中，同一个配对的迭代变量和残差的 hold 是**独立**的。最灵活的写法是：每个迭代变量、每条残差各绑定一个 Boolean 参数，默认都是 false，**运行时**再决定 hold 哪些：

```modelica
model ValveRuntimeHold
  parameter Boolean hold_m = false     "hold 迭代变量 m";
  parameter Boolean hold_valve = false "hold 残差 valve";
  parameter Boolean hold_u = false     "hold 迭代变量 u";
  parameter Boolean hold_set = false   "hold 残差 set";
  parameter Real k = 1, p_in = 5, p_out = 1, u_set = 1;
  Real dp;
  Real m(start = 1), u(start = 0.5);
equation
  dp = p_in - p_out;
  m = k * u * sqrt(dp) annotation(__Modelon(name = valve,
    ResidualEquation(hold = hold_valve, iterationVariable(hold = hold_m) = m)));
  u = u_set annotation(__Modelon(name = set,
    ResidualEquation(hold = hold_set, iterationVariable(hold = hold_u) = u)));
end ValveRuntimeHold;
```

模型中没有写死任何 true/false，同一个编译好的 FMU 可以在运行时切换成不同的工况：

| 运行时设为 true 的参数 | 被 hold 的变量 | 被 hold 的残差 | 未知量 → 方程 | 工况 |
|---|---|---|---|---|
| （无） | ∅ | ∅ | m → `valve`，u → `set` | 校核：给定开度 u_set，求流量 |
| `hold_m`、`hold_set` | {m} | {set} | u → `valve` | 设计：给定流量 m，反算开度（**交叉 hold**） |
| `hold_u`、`hold_set` | {u} | {set} | m → `valve` | 给定开度 u（当前值，不用 u_set），求流量（整对 hold 配对 2） |
| `hold_m`、`hold_valve` | {m} | {valve} | u → `set` | m 给定，u = u_set（整对 hold 配对 1） |
| `hold_u`、`hold_valve` | {u} | {valve} | m → `set`？ | **结构奇异**：`set` 不含 m，解不出 m，求解前报错 |
| 只有 `hold_m` | {m} | ∅ | 1 个未知量，2 条方程 | **个数不平衡**，求解前报错 |

第二行就是"一个配对的两边一个为 true、一个为 false"：

| 配对 | 变量的 hold | 残差的 hold | 含义 |
|---|---|---|---|
| 1 | `hold_m` = **true** | `hold_valve` = **false** | m 固定；`valve` 仍要成立，只能靠别的变量（u）满足 |
| 2 | `hold_u` = **false** | `hold_set` = **true** | `set` 去掉；u 仍是未知量，只能由别的方程（`valve`）决定 |

两个配对互相补上：被 hold 的变量 {m} 和残差 {set} 各一个，方程数平衡。

四种组合在 OCT 中的含义：

| 变量的 hold | 残差的 hold | 这个配对 | 方程数 |
|---|---|---|---|
| false | false | 正常求解 | 不变 |
| true | true | 整对去掉：变量固定，残差不要（[HGT_hold.md](HGT_hold.md) 现在支持的就是这种） | 不变 |
| true | false | 变量固定，但残差还在：要由**别的配对**释放出来的变量满足 | 少一个未知量，必须有别处 hold 一条残差 |
| false | true | 残差去掉，但变量还在：要由**别的配对**的残差决定 | 少一条方程，必须有别处 hold 一个变量 |

后两种必须成对出现（可以分布在不同配对、不同块中），整个模型被 hold 的变量和残差个数相等，而且剩下的方程能解出剩下的未知量（结构非奇异），否则求解时报错。因为这些参数在运行时才确定，个数检查和结构检查也只能在**运行时**做：这正是方案一（§3.4 第 2、3 步）的做法；方案二只能在编译期逐个参数检查（§4.4）。

## 2. 现在的实现的问题

现在按**配对** hold（[HGT_hold.md](HGT_hold.md) §4）：一个配对的 hold 取残差上的，没写就取迭代变量上的，然后整对 hold。所以上例中：

| | 期望（OCT 语义） | 现在 OMC 的结果 |
|---|---|---|
| m | 保持在 2 | 保持在 2 |
| u | 由 `valve` 算出 | 也保持在 start 0.5 |
| `valve` | 保留，用来解 u | 被去掉 |
| `set` | 被去掉 | 被去掉 |

两个配对都被整对 hold 了，没有报错，也没有警告。从 OCT 迁移来的、用了交叉 hold 的模型会**静默算错**。

§1.1 那种每一边绑定各自参数的写法（`ValveRuntimeHold`），现在会报错 8009（同一配对的残差和迭代变量的 hold 表达式不同），所以不会算错，但也不能用。两种写法在现在的实现中的结果：

| 写法 | 例子 | 现在的结果 |
|---|---|---|
| 两边都写，表达式相同 | `hold = h`、`iterationVariable(hold = h)` | 整对 hold，和 OCT 一致 |
| 两边都写，表达式不同 | §1.1 `ValveRuntimeHold` | 报错 8009 |
| 只写一边 | §1 `Valve` | 当成整对 hold，和 OCT **不一致**，没有提示 |

**临时措施**（和下面两个方案无关，应该先做，约半小时）：一个配对只有一边写了 hold（不是字面量 `false`）时给警告，说明"只写一边的 hold 目前按整对处理，和 OCT 不同"；或者直接报错，要求两边都写。

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
  <IterationVariable name="m" hold="design" nominal="1" min="0"/>
  <IterationVariable name="u" nominal="1"/>
  <Residual name="$res.valve" residualName="valve" nominal="1"/>
  <Residual name="$res.set"   residualName="set"   hold="design"/>
  <Pair residual="$res.valve" iterationVariable="m"/>
  <Pair residual="$res.set"   iterationVariable="u"/>
</HandGuidedTearing>
```

- `Pair` 只作参考（日志、初值），求解时不依赖它。
- 交互模式下编译器不做 `if hold` 改写，也不检查"两边 hold 必须相同"（8009）。

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

### 3.5 阀门例子

FMU 接口：输入 {m, u}，输出 {valve, set}。依赖：valve 依赖 {m, u}，set 依赖 {u}。

| 工况 | H_v | H_r | U | E | 结构检查 | 结果 |
|---|---|---|---|---|---|---|
| 校核 | ∅ | ∅ | {m, u} | {valve, set} | valve–m、set–u | u = u_set，m 由 valve 算出 |
| 设计 | {m} | {set} | {u} | {valve} | valve–u | m 保持当前值，u 由 valve 反算 |
| 用 API 只 hold m | {m} | ∅ | {u} | {valve, set} | 个数 1 ≠ 2 | 报错，提示再 hold 一条残差 |

```python
p = FMUProblem("Valve.fmu")
p.set("design", False); Solver(p).solve()       # 校核：给定开度，算流量
p.set("m", 2.0); p.set("design", True)
Solver(p).solve()                               # 设计：给定流量 2.0，反算开度
# 不用参数，直接用 API：
p.holdIterationVariables(["m"]); p.holdResiduals(["set"])
```

### 3.6 工作量

交叉 hold 是交互式 FMU 第一版（约 5–6 周）之上的增量：

| 内容 | 工作量 |
|---|---|
| 编译器：hold 按变量、残差分别导出；交互模式下不改写、不检查 8009 | 0.5 天 |
| 确认 ModelStructure 的依赖关系在"只求值"路径下正确，必要时补上 | 1–2 天 |
| 求解器：hold 集合、个数检查、二部图结构检查、取子雅可比矩阵 | 2 天 |
| 诊断信息（`printInfo('held')`、列出不匹配的项） | 0.5 天 |
| 测试：两种工况、个数不等、结构奇异、跨块 | 1 天 |
| **合计** | **5–6 天** |
| 可选：运行时按块分解 | 约 1 周 |

## 4. 方案二：编译期改写

### 4.1 思路

沿用现在的做法：把 hold 编译进残差表达式，用参数在运行时切换。区别是不再按配对，而是**按 hold 表达式分组**。

关键观察：同一个 hold 表达式 h 下，设被 hold 的变量集合为 V_h，被 hold 的残差集合为 R_h。只要 |V_h| = |R_h|，把 R_h 中的每条残差换成某个 `v − v.start`（v ∈ V_h），**哪条残差配哪个变量都不影响解**：换上去的方程集合总是 {v − v.start : v ∈ V_h}，不同的对应只是雅可比矩阵的行排列不同。所以用户不需要指定对应关系。

阀门例子改写后：

```
0 = m - u * k * sqrt(dp)                          // valve：不 hold，保留
0 = if design then m - m.start else u - u_set     // set：换成固定 m 的方程
```

`design = true` 时 m 固定，u 由 `valve` 解出，正是期望的语义。

### 4.2 步骤

| 步骤 | 位置 | 内容 |
|---|---|---|
| 1. 分组、检查个数 | 前端 `NFHandGuidedTearing.finish` | 去掉按配对的规则（`checkHold` 和 8009）；按 hold 表达式（`Expression.isEqual`）分组得到 V_h、R_h；个数不等时报新错误，例如"hold = design 固定了 2 个迭代变量，但只去掉了 1 条残差"。同一配对两边都写同一个 h 的情况自然落在同一组，行为和现在一样 |
| 2. 定对应关系 | 后端 `HandGuidedTearing.lower` | 同一配对的变量优先配给自己的残差，其余按名字顺序配对 |
| 3. 改写 | 后端 `rewriteResidual` | R_h 中第 k 条残差改写成 `if h then V_h[k] − V_h[k].start else 原残差`（原残差照旧除以 nominal） |
| 4. 合并块 | 后端 `hgtMatching` | 交叉 hold 一般跨块：上例中 `set` 本来自成一块，hold 后 u 要由 `valve` 决定，求解顺序变了。所以同一组涉及的所有配对要强制放进同一个块，复用已有的 `addRing`（相当于对这一组局部打开 `--hgtMergeBLTBlocks`） |
| 5. 结构检查 | 后端，撕裂之后 | 对每个 h，把 R_h 那几行换成 V_h 的单位行，检查撕裂后的系统在结构上非奇异（迭代变量 × 残差的依赖关系有完全匹配）。上例要求 `valve` 依赖 u，否则 hold 后解不出 u，编译期报错 |
| 6. 测试和文档 | | 阀门例子两种工况、个数不等、结构奇异、同一配对两边 hold（回归）、C 和 Rust 运行时 |

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
- **和 OCT 仍有差距**：要事先在注解中绑定参数，没有 API hold；保持值是 start；只能在两次运行之间切换。

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
| 和现在的 hold 的关系 | 交互模式下取代编译期改写；普通仿真仍用现在的实现 | 扩展现在的实现 |
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

下面的脚本在 OCT 中运行 §1.1 的 `ValveRuntimeHold`：模型中不写任何 true/false，所有 hold 都在运行时通过参数设置。它同时演示 OCT 的 hold 是"保持当前值"：被 hold 的变量保持上一次的解或用户设的值，不是 start。

只核对过这些名字：编译选项 `interactive_fmu`；`oct.steadystate.nlesol` 的 `FMUProblem`、`Solver`；`holdIterationVariables` / `releaseIterationVariables`（按下标）；`printInfo`。函数的参数细节、初始化之后改参数要不要重新初始化，没有核对，要对照所用的 OCT 版本调整。

```python
from pymodelica import compile_fmu
from pyfmi import load_fmu
from oct.steadystate.nlesol import FMUProblem, Solver

fmu = compile_fmu("ValveRuntimeHold", "ValveRuntimeHold.mo",
                  compiler_options={"interactive_fmu": True,
                                    "hand_guided_tearing": True})
model = load_fmu(fmu)
problem = FMUProblem(model)        # 未核对：构造参数
solver = Solver(problem)
problem.printInfo("all")

def set_hold(**holds):
    """运行时设置 hold 参数，没给的一律设成 False。"""
    for name in ["hold_m", "hold_valve", "hold_u", "hold_set"]:
        model.set(name, holds.get(name, False))   # 未核对：初始化之后改参数是否需要 reset

# 1. 校核：都不 hold，给定开度 u_set = 1，求流量
set_hold()
solver.solve()
print("校核:", model.get(["m", "u"]))           # m = 2.0, u = 1.0

# 2. 设计（交叉 hold）：hold 变量 m 和残差 set
#    m 保持上一次的解 2.0（不是 start 1.0），u 由 valve 反算
set_hold(hold_m=True, hold_set=True)
model.set("p_in", 9)                            # dp = 8
solver.solve()
problem.printInfo("parametricHold")
print("设计:", model.get(["m", "u"]))           # m = 2.0, u = 2/sqrt(8) = 0.7071

# 3. 设计：把 m 设成给定值再求解
model.set("m", 3.0)
solver.solve()
print("设计, m=3:", model.get(["m", "u"]))      # m = 3.0, u = 3/sqrt(8) = 1.0607

# 4. 给定开度：hold 变量 u 和残差 set，u 保持当前值 1.0607，求流量
set_hold(hold_u=True, hold_set=True)
model.set("p_in", 5)                            # dp = 4
solver.solve()
print("给定开度:", model.get(["m", "u"]))       # m = 1.0607*2 = 2.1213, u = 1.0607

# 5. 错误的组合：只 hold m，方程数不平衡，求解前报错
set_hold(hold_m=True)
try:
    solver.solve()
except Exception as e:
    print("不平衡:", e)

# 6. 不用参数，直接用 API hold m（下标从 printInfo("all") 查）
set_hold()
idx_m = 0                                       # 假设 m 是第 0 个迭代变量
problem.holdIterationVariables([idx_m])
#   只 hold 变量还不够，还要去掉一条残差方程数才平衡；
#   残差的 API 名字没有核对，也可以继续用残差上的参数 hold_set。
problem.releaseIterationVariables([idx_m])
```

| 步骤 | 设为 true 的 hold 参数 | p_in | m | u | 说明 |
|---|---|---|---|---|---|
| 1 校核 | （无） | 5 | 2.0 | 1.0 | 都求解 |
| 2 设计 | `hold_m`、`hold_set` | 9 | 2.0 | 0.7071 | m 保持第 1 步的解 |
| 3 设计 | `hold_m`、`hold_set` | 9 | 3.0 | 1.0607 | m 是用户设的值 |
| 4 给定开度 | `hold_u`、`hold_set` | 5 | 2.1213 | 1.0607 | u 保持第 3 步的解 |
| 5 | `hold_m` | | | | 不平衡，报错 |

同样的模型在现在的 OMC 中：注解换成 `__OpenModelica_HGT` 后报错 8009（§2）；即使改成只写一边，也会被当成整对 hold，而且保持值是 start（第 2 步得到 m = 1.0），也没有运行时的个数和结构检查。方案一实现之后，结果应和上表一致。
