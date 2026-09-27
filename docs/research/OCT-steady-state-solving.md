# OCT 稳态求解调研（基于官方文档）

> 调研对象：Modelon **OPTIMICA Compiler Toolkit (OCT)**  
> 主要依据：[OCT Help Center](https://help.modelon.com/latest/reference/oct/)、[UsersGuide.pdf](https://help.modelon.com/latest/reference/assets/UsersGuide.pdf)、[Steady-State Settings](https://help.modelon.com/latest/articles/how_to_steady_state_settings/)、[Lecture 3.4](https://help.modelon.com/latest/training/Lectures/Lecture_3.4.pdf)

---

## 1. 结论摘要

OCT 的稳态求解**不是**把动态仿真跑到导数近似为零，而是：

1. 将稳态模型编译为 **Interactive FMU**（迭代变量 → 输入，残差方程 → 输出）；
2. 由基于 **SUNDIALS KINSOL** 的非线性方程求解器求解 \(f(x, sw)=0\)；
3. 通过 **Physics-Based Solving (PbS)** / **Hand Guided Tearing (HGT)** 由用户/库作者指定迭代变量与残差，提升大规模非线性收敛性。

与 OpenModelica 的 `-steadyState`（动态仿真过程中检测 \(\max|\dot x_i|/nominal\)）是不同问题形态。

---

## 2. OCT 是什么

OCT 是 Modelon Impact 的计算引擎（编译器 + 求解器），在动态仿真之外提供：

- 大规模稳态非线性求解；
- Physics Based Solving（用户指定残差与迭代变量）；
- Optimica 扩展上的动态优化；
- Python / MATLAB 脚本 API（`pymodelica` / `pyfmi` / `oct.steadystate`）。

官方定位（Help Center）：

> A non-linear solver for solving large-scale systems of equations arising, e.g., in steady-state applications. Efficient and robust steady-state problem formulation is enabled by Physics Based Solving, which enables user specified selection of residuals and iteration variables.

---

## 3. 动态 vs 稳态：问题形态

| | Dynamic | Steady-State |
|---|---|---|
| 方程形态 | \(\dot x = f(x,u,t)\)，初值问题 | \(f(x,sw)=0\)，代数非线性方程组 |
| 稳健手段 | 缩小步长 | 好的初值 + 好的撕裂结构 + 缩放/步长限制 |
| 求解器 | CVODE / Radau5 / Euler 等 | KINSOL（SUNDIALS） |
| 典型用途 | 工况瞬态、驾驶循环 | 设计点、标定、流量平衡、热力循环工况点 |

官方术语（[Terminologies](https://help.modelon.com/latest/terminology/terminology/)）：

- **Steady-state**：时间无关仿真；可为纯代数模型，也可对动态模型施加 \(\dot x = 0\)。
- **Iteration Variables (IV)**：无法前向求值时被猜测并迭代的未知量。
- **Residual equations**：在当前 IV 猜测下不恒成立的方程，用于构造牛顿修正。

Tearing 流程（Lecture 3.4）：

1. 编译期：选 IV + 残差（DV），形成 torn blocks；
2. 运行期：猜 IV → 求其余变量 → 评估残差 → 迭代至容差内。

---

## 4. 稳态求解流水线

```
Modelica 稳态模型
    │  编译选项: interactive_fmu=true, hand_guided_tearing=true, ...
    ▼
Interactive FMU
    │  iter_* (inputs)  ←→  物理迭代变量
    │  res_*  (outputs) ←→  残差方程
    ▼
oct.steadystate.nlesol.FMUProblem
    ▼
oct.steadystate.nlesol.Solver  (KINSOL-based)
    ▼
解 + XML 日志 / LogViewer / diagnostics
```

### 4.1 Interactive FMU

启用 `interactive_fmu` 后，DAE 中的迭代变量变为顶层 **input**，残差变为顶层 **output**，供外部非线性求解器驱动。

官方示例（UsersGuide §9.2.2.1）：

```modelica
model twoEqSteadyState
  Real x(start = 1);
  Real T(start = 400);
equation
  0 = 120*x - 75*(0.12*exp(12581*(T - 298)/(298*T)))*(1 - x);
  0 = -x*(873 - T) + 11.0*(T - 300);
end twoEqSteadyState;
```

编译后近似变为：

- `input Real x`, `input Real T`
- `parameter Real iter_0 "T"`, `parameter Real iter_1 "x"`
- `output Real res_0`, `output Real res_1`

命名约定：`iter_<n>` / `res_<n>`（description 指向真实变量名）。

### 4.2 数学形式（UsersGuide Ch.9）

\[
f(x, sw) = 0, \quad g(x, sw)\ \text{为间断指示函数}
\]

- \(x\)：迭代变量；\(sw\)：开关状态；
- 残差在间断两侧要求至少 \(C^1\)；
- 求解器通过回调在间断两侧切换连续表示；
- 精度由求解器选项与变量 `nominal` 共同控制。

### 4.3 Python / MATLAB 接口

| 角色 | Python | MATLAB |
|---|---|---|
| 包 | `oct.steadystate.nlesol` | `oct.nlesol` |
| 问题 | `FMUProblem(fmu)` | `FMUProblem(fmu)` |
| 求解 | `Solver(problem).solve(...)` | `Solver(problem).solve` |
| 诊断 | `LogViewer`, `generate_nle_solver_report` | `LogViewer` |

典型流程：`compile_fmu`（`interactive_fmu`）→ `load_fmu` → `FMUProblem` → `Solver.solve`。

另有 **ContinuationSolver**（Ch.10）：对边界条件做延拓，仍要求 Interactive FMU 命名约定。

---

## 5. Physics-Based Solving / Hand Guided Tearing

### 5.1 概念

- **自动撕裂**：编译器选 IV / 残差；
- **HGT / PbS**：库作者用 `__Modelon` 注解指定，优先于自动撕裂；
- Impact GUI 中组件参数 `usePbS=true` 触发库内嵌注解（可随 Boolean 参数切换，无需重编译）。

### 5.2 注解语法（UsersGuide Ch.14）

**配对撕裂（方程级）：**

```modelica
0 = ... annotation(__Modelon(ResidualEquation(iterationVariable = c)));
```

**非配对：**

```modelica
Real x annotation(__Modelon(IterationVariable));
0 = ... annotation(__Modelon(ResidualEquation, name = dx));
```

**系统级配对**（残差与 IV 不在同一名字空间）：在 class annotation 中用 `tearingPairs(...)`。

关键属性：`enabled`, `level`（嵌套 HGT）, `nominal`, `min`/`max`/`start`, `hold`（参数化 hold）。

### 5.3 实践要点（HeatPump / Orifice 教程）

- 开启 `variability_propagation`，把能降为参数/常量的量提前降下来；
- 全系统一致的 `start` / `nominal`；
- 闭环系统需“接地”压力等（如固定高压侧）；
- 源/汇用 `isSource` 标识，供 PbS 从拓扑推断求解结构；
- 设计模式切换（如 orifice `sizing`）可通过 Boolean 改变 IV/残差集合。

---

## 6. 关键编译 / 求解选项

### 6.1 编译选项（Steady-State）

| 选项 | 默认 | 含义 |
|---|---|---|
| `interactive_fmu` | True | 生成 Interactive FMU |
| `hand_guided_tearing` | True | 启用 HGT |
| `automatic_tearing` | True | 自动撕裂补全 |
| `equation_sorting` | True | BLT 分块 |
| `variability_propagation` | False* | 全局变异性分析（教程常开） |
| `merge_blt_blocks` | True | 合并 HGT 相关 BLT 块 |
| `expose_scalar_equation_blocks_in_interactive_fmu` | True | 暴露未解标量方程 |
| `index_reduction` | False | 高指标降指标 |
| `local_iteration_in_tearing` | annotation | 局部迭代：`off` / `annotation` / `all` |
| `generate_html_diagnostics` | False | 输出 BLT HTML |

\* Impact 文档表中为 False；热泵教程要求稳态实验显式打开。

### 6.2 求解选项（节选，UsersGuide Table 9.1）

| 选项 | 典型默认 | 含义 |
|---|---|---|
| `tolerance` | 1e-6 | 相对容差 |
| `max_iter` | 100 | 最大迭代 |
| `max_iter_no_jacobian` | 10 | 无 Jacobian 更新的最大迭代 |
| `step_limit_factor` | 0.2 | 牛顿步长相对 nominal/min/max 限制 |
| `jacobian_calculation_mode` | 0~9 | 差分 / 压缩等 Jacobian 模式 |
| `jacobian_update_mode` | 2 | 全量 / Broyden / 复用 |
| `residual_equation_scaling` | 1 | 残差缩放策略 |
| `iteration_variable_scaling` | 2 | IV 缩放（nominal-based） |
| `enforce_bounds` | true | 强制 IV 边界 |
| `solver_exit_criterion` | 3 | 步长+残差 / hybrid |
| `regularization_tolerance` | 1e-10 | 奇异 Jacobian 正则化阈值 |

Impact UI 中部分默认值与 UsersGuide 表略有差异（如 UI 文档中 `tolerance=1e-5`, `jacobian_calculation_mode=9`），以实际产品版本为准。

---

## 7. 诊断与调试

1. **求解器控制台轨迹**：`res_norm`, `max_res`, `lambda`（阻尼）、Jacobian 更新标记等；
2. **HTML diagnostics**：`blt.html`, `initBlt.html`, `bltTable.html`（Interactive FMU 下 init 与 DAE 的 BLT 一致；`res_i` 对应残差）；
3. **LogViewer**：读取迭代变量、残差、Jacobian、错误/警告；
4. **`generate_nle_solver_report`**：收敛摘要、非零残差、nominal/min/max 等。

---

## 8. 与 OpenModelica 的对照（本仓库语境）

| 维度 | OCT 稳态 | OpenModelica |
|---|---|---|
| 目标 | 直接解代数稳态 \(f(x)=0\) | 初始化 / 动态仿真；`-steadyState` 为**检测**稳态并提前结束仿真 |
| 核心算法 | KINSOL + Interactive FMU | DASSL/IDA/CVODE 等积分；初始化可用 homotopy |
| 用户引导撕裂 | `__Modelon` HGT / PbS（一等公民） | 主要为自动 tearing；无同等厂商 PbS 注解体系 |
| 交付物 | Interactive FMU + 外部 NLE 求解 | 普通 FMU / 可执行仿真 |
| 适用场景 | 工业级设计点、库级稳态工作流 | 开源动态仿真与初始化 |

OM 中达到“稳态解”的常见做法仍是：

- `initial equation` 中写 `der(x)=0`（稳态初始化）；
- 或长时间动态仿真 + `-steadyState` / `-steadyStateTol`（见 `simulation_options.c` / UsersGuide simulation flags）。

这与 OCT 的“专用稳态 NLE + Interactive FMU”路径不同。

---

## 9. 官方资料索引

| 文档 | URL |
|---|---|
| OCT 总览 | https://help.modelon.com/latest/reference/oct/ |
| UsersGuide.pdf（Ch.9/10/11/14） | https://help.modelon.com/latest/reference/assets/UsersGuide.pdf |
| Steady-State Settings | https://help.modelon.com/latest/articles/how_to_steady_state_settings/ |
| Execution Settings | https://help.modelon.com/latest/articles/how_to_execution_settings/ |
| 术语（Steady-state / IV） | https://help.modelon.com/latest/terminology/terminology/ |
| Lecture 3.4（编译与稳态求解） | https://help.modelon.com/latest/training/Lectures/Lecture_3.4.pdf |
| Orifice PbS 教程 | https://help.modelon.com/latest/tutorials/orifice_sizing/problemsetup/ |
| HeatPump 稳态教程 | https://help.modelon.com/latest/tutorials/heatpump/base/ |
| HGT 论文背景（Lund） | https://lup.lub.lu.se/luur/download?fileOId=9078543&func=downloadFile&recordOId=9078542 |

---

## 10. 可落地建议

若目标是**复现 / 对齐 OCT 稳态能力**（例如在 OpenModelica 侧做对照实验）：

1. 把稳态问题显式建成代数系统（或对动态模型加 \(\dot x=0\)），而不是依赖长时间积分；
2. 关注撕裂结构：IV / 残差选择、`nominal`、边界与初值；
3. 若评估 PbS，需理解其依赖厂商注解与库内嵌指令，OM 无法直接消费 `__Modelon`；
4. 调试优先看残差范数、Jacobian 条件数与 BLT，而不是积分步长。
