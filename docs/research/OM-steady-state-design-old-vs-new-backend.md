# OpenModelica 对齐 OCT 稳态求解：设计方案（旧后端 / 新后端）

> 前置调研：[`OCT-steady-state-solving.md`](./OCT-steady-state-solving.md)  
> 目标：在 OpenModelica 中提供与 OCT 同形态的稳态能力——**直接解 \(f(x)=0\)**，而非依赖长时间动态仿真 + `-steadyState` 检测。

---

## 0. 目标能力（对齐 OCT）

| 能力 | OCT | OM 现状 | 本设计目标 |
|---|---|---|---|
| 稳态问题形态 | 代数 NLE \(f(x,sw)=0\) | 初始化代数系统 / 动态积分 | 一等公民稳态分析模式 |
| 交付物 | Interactive FMU + 外部 KINSOL | 可执行 / 标准 FMU，内部 NLS | 内建求解 **+** Interactive FMU |
| 引导撕裂 | `__Modelon` PbS/HGT | `__OpenModelica_tearingSelect` + CLI | 扩展为 IV+残差配对注解 |
| 求解器 | KINSOL | 已有 `kinsol`/`newton`/`homotopy` | 复用，补缩放/步长限制策略 |
| API | `oct.steadystate.nlesol` | 无 | Python/`simulate`/`solveSteadyState` |

**建议产品形态（两条路径并存）：**

- **Path A — Built-in Steady Solve**：编译期把动态 DAE 改写成稳态代数系统（加 \(\dot x=0\)），用现有 NLS（优先 KINSOL）一次解出工况点。对接 OMEdit / `simulate(..., method="steadyState")`。
- **Path B — Interactive FMU**：撕裂后把迭代变量升为 FMI input、残差升为 FMI output，供外部求解器（Python/KINSOL）驱动，对齐 OCT 工作流。

MVP 优先 Path A；Path B 作为可互操作的第二阶段。

---

## 1. 总体架构

```
                    FlatModel (NF)
                         │
            ┌────────────┴────────────┐
            │  --steadyStateMode      │
            ▼                         ▼
     Path A: STEADY DAE          Path B: Interactive FMU
   (der(x)=0 代数化)              (IV→input, res→output)
            │                         │
     Matching/Tearing            Matching/Tearing
            │                         │
     SimCode + residualFunc      SimCode 不嵌 NLS
            │                         │
     Runtime KINSOL 一次解       FMI set/get + 外部 Solver
            │                         │
     结果 .mat / OMEdit           Python API / Continuation
```

### 1.1 模式如何进入稳态（对齐 OCT：显式选择，不自动猜测）

OCT 不靠“扫到没有 `der()`”判断稳态，而是 **Impact Analysis=Steady-State / 脚本 `interactive_fmu`** 显式选模式。OM 应对齐同一原则：

```text
OMEdit: Simulation → Analysis type = Steady-State
  或 mos:  setCommandLineOptions("--steadyStateMode=builtin");
           solveSteadyState(MyModel);
  或 OMPython 同等调用
        │
        ▼
Flags.STEADY_STATE_MODE ≠ off
        │
        ├─ builtin      → Path A（内建 NLE，解完退出）
        └─ interactiveFmu → Path B（导出 Interactive FMU）
        │
后端读 flag 分流（旧: Initialization/SteadyState 旁路；新: Kind.STEADY）
        │
运行时 / 外部 Solver 解 f(x)=0
```

**不要做的事：**

- 不要仅因模型无 `der()` 就自动走稳态（纯代数模型仍可能是 DAE-mode/初始化路径）。
- 不要复用/混淆现有仿真 flag `-steadyState`（那是**动态仿真中检测**导数变小并提前停）。
- 不要依赖注解（`tearingSelect` / 未来 ResidualEquation）决定是否稳态——注解只影响撕裂质量。

**建议命名对照：**

| OCT / Impact | OpenModelica 建议 |
|---|---|
| Analysis = Steady-State | OMEdit Analysis = Steady-State；内部设 `--steadyStateMode` |
| `interactive_fmu=true` | `--steadyStateMode=interactiveFmu` |
| 内建稳态实验（Impact 一键） | `--steadyStateMode=builtin` + `solveSteadyState` |
| `-steadyState`（无此 OCT 语义） | OM 保留原义：**detect**，与 **solve** 分开 |

### 1.2 新增编译/仿真入口（共享）

| 入口 | 建议 |
|---|---|
| 编译 flag | `--steadyStateMode=off\|builtin\|interactiveFmu`（默认 `off`） |
| 仿真 flag | Path A：`-steadySolve`（或由 builtin 模式自动带上）；NLS 默认 `-nls=kinsol`；收敛用 `-nleTol`（勿复用 `-steadyStateTol` 语义） |
| Scripting | 首选独立 API：`solveSteadyState(model, ...)`；内部设置 mode 并编译运行 |
| OMPython | `omc.sendExpression('solveSteadyState(MyModel)')` 或 `ModelicaSystem.solveSteadyState()` |
| OMEdit | Analysis 类型增加 **Steady-State**（对标 Impact），选中后写 `--steadyStateMode=builtin` |

### 1.3 注解策略（共享，前端）

现有：

```modelica
Real p annotation(__OpenModelica_tearingSelect = TearingSelect.prefer);
```

扩展（兼容 OCT 思路，命名走 OM 前缀；`__Modelon(...)` 别名已解析）：

```modelica
// 配对：残差方程 ↔ 迭代变量
0 = massBalance(...) annotation(
  __OpenModelica_ResidualEquation(iterationVariable = m_flow, nominal = 1e-3));

// 非配对：仅标记 IV / 残差，由编译器完成配对
Real T annotation(__OpenModelica_IterationVariable(nominal = 300));
0 = energyBalance(...) annotation(__OpenModelica_ResidualEquation);

// OCT 别名（前端已接受）
0 = f(x) annotation(__Modelon(ResidualEquation(iterationVariable = x)));
Real y annotation(__Modelon(IterationVariable(hold = true)));
```

**前端实现状态（已落地）：**

| 落点 | 内容 |
|---|---|
| `NFBackendExtension.HgtIterationVariable` / `HgtResidualEquation` | 解析 `enabled/level/nominal/min/max/start/hold/name/iterationVariable`；裸注解 `ResidualEquation` / `IterationVariable`（NOMOD）也识别 |
| `Annotations.iterationVariable` | 变量级 IV，经 `Annotations.create` 写入 `BackendInfo` |
| `NBEquation.EquationAttributes.residualHgt` | 方程级残差，经 `NBackendDAE.lowerEquationAttributes` + `ElementSource` 写入 |
| `BVariable.getHgtIterationVariable` / `hasHgtIterationVariable` | 后端读取入口 |
| `Obfuscate.mo` | 白名单保留 `__OpenModelica_*` / `__Modelon` |

下一阶段：`NBTearing` / 旧 `Tearing.mo` 消费配对；class 级 `tearingPairs` 尚未实现。详见 [`OM-hgt-annotation-frontend.md`](./OM-hgt-annotation-frontend.md)。

解析落点：`NFBackendExtension`（已有 `tearingSelect`）→ 写入变量 `Annotations` / 方程 `residualHgt`，供旧 `Tearing.mo` 与新 `NBTearing.mo` 消费。  
旧后端可用现有 `--setTearingVars` / `--setResidualEqns` 作为过渡；新后端优先注解 + `guruTearing`。

### 1.4 稳态问题构造规则（共享语义）

对动态模型进入稳态模式时：

1. **状态导数约束**：对每个连续状态 \(x\)，加入 \( \dot x = 0 \)（或把 DAE 残差中的 \(\dot x\) 替换为 0）。
2. **自由度**：状态一般 `fixed=false`；用边界条件 / 设计参数闭合系统（对标 OCT 的 pressure grounding、`isSource` 等——OM 侧用模型参数表达，不强制引入厂商拓扑注解）。
3. **离散 / when**：稳态下 `when` 取初始分支或要求模型显式稳态形态；不支持的构造报清晰错误。
4. **事件开关**：保留 discontinuity indicator（对标 OCT 的 \(g(x,sw)\)），运行时允许开关迭代。
5. **Homotopy**：保留 `homotopy()`，优先走全局/局部 homotopy（OM 已有 init homotopy 基础设施）。

---

## 2. 旧后端（BackEnd）方案

### 2.1 现状挂载点

| 阶段 | 文件 | 作用 |
|---|---|---|
| 流水线 | `BackendDAEUtil.getSolvedSystem` | pre-opt → causalize → **init** → post-opt |
| 初始化 | `Initialization.solveInitialSystem` | 建 init DAE；`der→$DER`，`pre→$PRE` |
| 撕裂 | `Tearing.mo` | omc/cellier/minimal/total + user-defined |
| SimCode | `SimCodeUtil.createNonlinearResidualEquations` | 生成 residual 方程块 |
| 代码生成 | `Template/CodegenC.tpl` `generateNonLinearResidualFunction` | `xloc→res` 回调 |
| FMU | `CodegenFMU2.tpl` / `CodegenFMU3.tpl` | FMI I/O；FMI3+`--daeMode` 已有局部残差暴露 |
| 运行时 | `nonlinearSystem.c`, `kinsolSolver.c`, `initialization.c` | NLS + homotopy |

### 2.2 Path A（Built-in）：旧后端设计

**思路**：稳态 = “特殊的、以 \(\dot x=0\) 闭合的初始化系统”，解完即结束，不进入时间积分。

#### 编译期

1. 新增 flag `--steadyStateMode=builtin`。
2. 在 `Initialization.solveInitialSystem` **之前或之内**插入模块 `SteadyState.mo`（建议新文件，避免继续膨胀 `Initialization.mo`）：
   - 收集全部连续状态；
   - 强制 `fixed=false`（或忽略 `fixed=true` 并告警）；
   - 为每个状态追加 `$DER.x = 0`（复用 `collectInitialEqns` 的 der 替换惯例）；
   - 若模型已有 `initial equation der(x)=0`，去重；
   - 调用现有 `balanceInitialSystem` / under-/over-determined 处理。
3. Init post-opt 照常：`Tearing` + `SymbolicJacobian`。
4. SimCode：只生成 **initial / steady** 方程系统；标记 `simCode.modelInfo.steadyStateOnly = true`。
5. Codegen：生成 `functionSteadyStateEquations`（可直接复用 `functionInitialEquations` 路径），`main` / `simulate` 在求解后写结果并 `exit`，跳过 `perform_simulation` 循环。

#### 运行时

1. 入口：`simulation_runtime.cpp` 检测 `-steadySolve` 或模型元数据 → 调用 `symbolic_initialization` / 专用 `solve_steady_state()`。
2. NLS 默认 `-nls=kinsol`，打开稀疏路径（`-nlssMinSize` 调低）。
3. 收敛判据：残差范数 / 步长（对齐 OCT `solver_exit_criterion`）；**不要**用 \(\max|\dot x|/nominal\)（那是动态检测）。
4. 日志：复用 `LOG_NLS` / `LOG_INIT`；可选导出 iteration / residual 轨迹。

#### 旧后端 Path A 改动清单

| 组件 | 改动 |
|---|---|
| `Flags.mo` | `STEADY_STATE_MODE` |
| `Initialization.mo` 或新 `SteadyState.mo` | 注入 \(\dot x=0\)、平衡系统 |
| `BackendDAEUtil.mo` | 在 getSolvedSystem 中分支 |
| `SimCodeUtil.mo` / `SimCodeTV.mo` | `steadyStateOnly` 元数据 |
| `CodegenC.tpl` | 稳态入口；可跳过积分器链接 |
| `simulation_runtime.cpp` | `-steadySolve` |
| `testsuite/simulation/.../steadySolve_*.mos` | 回归 |

**优点**：改动面可控，最大化复用 init + KINSOL。  
**风险**：大规模单块 NLE 的撕裂质量；离散/`when` 语义需严格定义。

### 2.3 Path B（Interactive FMU）：旧后端设计

**思路**：撕裂完成后，不把 NLS 链进 FMU，而是把 IV/残差提升为 FMI 变量。

#### 编译期

1. `--steadyStateMode=interactiveFmu` 隐含 `+target=fmu`（或要求用户显式 FMU 导出）。
2. 先走 Path A 的稳态 DAE 构造（同一套 \(\dot x=0\)），再 tearing。
3. 在 `SimCodeUtil` 中新增 `promoteTornSystemToFmiIO`：
   - 扫描所有 `TORNSYSTEM` / `SES_NONLINEAR`；
   - tearing vars → FMI **input**，命名 `iter_<i>`，`description` = 原变量名；
   - residual eqs → FMI **output** `res_<i>`；
   - 其余边界参数保持 input；内部 torn eqs 仍为 FMU 内前向赋值。
4. **关闭** FMU 内对该块的 `solve_nonlinear_system` 调用；改为 `setReal(iter) → evaluate inners → getReal(res)`。
5. `modelDescription.xml`：可增 vendor annotation `OpenModelica:interactiveSteadyState=true`。

与现有 FMI3 DAE mode（`--daeMode`，局部 residual）的区别：

| | FMI3 DAE residuals | Interactive Steady FMU |
|---|---|---|
| 目的 | 外部积分器 / FMI-LS-DAE | 外部 NLE 求解器 |
| I/O | 局部变量 / LS 清单 | top-level input/output |
| 未知量 | \(x,\dot x,y\) | 撕裂迭代变量 |
| 时间 | 有时间推进 | 无时间（或 t 固定） |

可复用 `fmi3DaeResiduals` 的残差抽取经验，但 **因果性改写与命名约定需新做**。

#### 运行时 / API

- 最小 Python：`pyfmi` load FMU + 自写牛顿/KINSOL；或后续提供 `ompython.steadystate`。
- 诊断：编译期 `-d=tearingdump` + HTML BLT（若启用 diagnostics）。

#### 旧后端 Path B 改动清单

| 组件 | 改动 |
|---|---|
| `SimCodeUtil.mo` | IV/res 提升、抑制内嵌 NLS |
| `CodegenFMU2/3.tpl` | I/O 因果性、跳过 NLS 调度 |
| `XmlFiles` / modelDescription | vendor 注解 |
| 文档 + 示例 | 对齐 OCT `twoEqSteadyState` |

**优点**：与 OCT/外部工具链互操作。  
**风险**：多块 torn system 的暴露策略（合并成一个大 NLE vs 分层求解）；嵌套撕裂。

### 2.4 旧后端撕裂增强（A/B 共用）

1. 消费新注解 `__OpenModelica_ResidualEquation` / `IterationVariable`（在 `Tearing.mo` user-defined 路径扩展，不仅依赖 index CLI）。
2. 稳态模式下默认 `--tearingMethod=cellier` 或保留 omc，但对“整系统大块”提高 `maxSizeNonlinearTearing`。
3. 文档化：稳态库作者应给压力/流量/焓等提供 `nominal` + tearingSelect。

---

## 3. 新后端（NBackEnd）方案

### 3.1 现状挂载点

| 阶段 | 文件 | 作用 |
|---|---|---|
| 主流程 | `NBackendDAE.main` | pre → Partitioning/Causalize/**Initialization** → post(Tearing/Solve/Jacobian) |
| 分区种类 | `NBPartition.Kind` | 已有 `ODE` / `INI` / `DAE` |
| 初始化 | `NBInitialization.main` | clone sim eqs → start eqs → INI Partitioning/Causalize/**Tearing** |
| 平衡 | `NBResolveSingularities.balanceInitialization` | underdetermined 补 start |
| 撕裂 | `NBTearing.mo` | 含 `guruTearing`（纯注解驱动） |
| 强分量 | `NBStrongComponent.ALGEBRAIC_LOOP` | `iteration_vars` + `residual_eqns` |
| SimCode | `NSimCode` / `NSimStrongComponent` | 转为 `NONLINEAR` |
| DAE mode | `NBDAEMode` | `--daeMode` 旁路 |

新后端天然更适合引入新的 **partition kind**，而不是把稳态硬塞进 init。

### 3.2 Path A（Built-in）：新后端设计（推荐主路径）

**核心提案：新增 `NBPartition.Kind.STEADY`（或 `SS`）。**

#### 流水线改造（`NBackendDAE.main`）

```
preOpt (Bindings → … → DetectStates → Events)   // 不变
    │
    ├─ ODE Partitioning / Causalize              // 仍可跑，用于状态识别
    │
    └─ [若 steadyStateMode=builtin]
           SteadyState.main  ──► 生成 steady partitions (Kind.STEADY)
           （替代或旁路常规 Initialization.main 的“仿真用途”）
    │
postOpt: Tearing(kind=STEADY) → Categorize → Solve → Jacobian
```

更干净的做法（推荐）：

1. 增加模块 `NBSteadyState.mo`：
   - 输入：已 detect 的 states + 方程；
   - 动作：复制连续方程集；将所有 `der(x)` 替换为 `0`（或添加显式 `der(x)=0` 并让 matching 处理）；
   - 状态变为代数未知量；`$DER.*` 不再作为自由变量；
   - 输出：`bdae.steady = SOME(list<Partition>)`（在 `MAIN` record 增字段，类似 `dae` / `init`）。
2. `MAIN` record 扩展：

```modelica
Option<list<Partition>> steady  "Partitions for steady-state solve";
```

3. 对 `steady` partitions 走与 INI 类似的后处理：`Tearing.main(kind=STEADY)`、`Solve`、`Jacobian`。
4. `NSimCode`：优先排放 steady 系统；`steadyStateOnly` 时不生成积分 loop。

与 init 的差异（重要）：

| | INI | STEADY |
|---|---|---|
| 目的 | 为时间积分准备一致初值 | 直接求工况点 |
| `fixed=true` 状态 | 常固定为 start | 默认不固定，靠 \(\dot x=0\) + 边界闭合 |
| 离散 `pre` | 需要 | 有限支持 / 要求模型稳态化 |
| Homotopy λ=0 系统 | `init_0` | 可镜像 `steady_0` |

#### 平衡与奇异

- 复用 `NBResolveSingularities.balanceInitialization` 的思路，但 **不要**盲目补 `x=start`（那会破坏稳态自由度）。
- 欠定：报错并指出缺少的边界（压力接地、流量指定等）。
- 过定：least-squares 或明确 residual 冲突报告（OCT 文献里流体稳态过定用过 LS；OM 可二期再做）。

#### 运行时

与旧后端 Path A 共享 C runtime 入口；新后端只负责产出正确的 SimCode 结构。

#### 新后端 Path A 改动清单

| 组件 | 改动 |
|---|---|
| `NBPartition.Kind` | 增 `STEADY` |
| `NBackendDAE.MAIN` | 增 `steady` 字段 |
| 新 `NBSteadyState.mo` | \(\dot x=0\) 变换、partition 构建 |
| `NBackendDAE.main` | 分支调用 |
| `NBTearing` / `NBSolve` / `NBJacobian` | 接受 `kind=STEADY`（大多可直接复用 INI 路径） |
| `NSimCode` | 排放 steady 块、元数据 |
| `guruTearing` | 稳态默认启用注解优先 |

**优点**：分区模型清晰，不污染 init 语义；与 `--daeMode` 并列的一等模式。  
**这是中长期主推路径。**

### 3.3 Path B（Interactive FMU）：新后端设计

1. 在 Path A 得到 torn `ALGEBRAIC_LOOP` 之后，于 `NSimStrongComponent` 转换点分支：
   - 正常：生成内嵌 NLS；
   - interactive：生成 `FMI_IO_EXPOSURE{inputs=iteration_vars, outputs=residual_eqns, inners=...}`。
2. 数组/可缩放方程（NB 强项）：保持 slice 一致的 `iter_*`/`res_*` 展开规则，写入 modelDescription。
3. FMU codegen 与旧后端 **共用模板层**（`CodegenFMU*.tpl`），避免两套 FMI 约定。
4. 嵌套撕裂（nested HGT）：NB 的 inner `StrongComponent` 树可映射为“先解内层块、再暴露外层残差”——对齐 OCT Nested HGT。

### 3.4 新后端注解 / guruTearing

稳态模式建议默认：

```
--tearingMethod=guruTearing   // 若模型提供了足够注解
否则回退 cellier/omc 启发式
```

`NBTearing.guru` 已强制 prefer/always 为 IV；扩展 residual 注解后：

1. 先应用用户配对（HGT）；
2. 再自动撕裂补全；
3. `hold` 参数（对标 OCT parametric hold）可作为二期：Boolean 参数屏蔽某些 IV/残差对。

---

## 4. 共享运行时与 API 设计

### 4.1 C Runtime

| 项 | 建议 |
|---|---|
| 入口 | `solve_steady_state(data, threadData)` |
| 求解 | 复用 `solve_nonlinear_system`；默认 KINSOL+KLU |
| 选项映射 | 对齐 OCT：`step_limit_factor`、`residual_equation_scaling`、`max_iter_no_jacobian` → 扩展现有 newton/kinsol options |
| 结果 | 写入 `result_*.mat` 单点（或 startTime 处） |
| 与 `-steadyState` | **保持原义**（动态检测）；新功能用 `-steadySolve` / `--steadyStateMode`，避免语义混淆 |

### 4.2 Scripting / Python

```python
# 示意
from OMPython import OMCSessionZMQ
omc = OMCSessionZMQ()
omc.sendExpression('setCommandLineOptions(\"--steadyStateMode=builtin\")')
omc.sendExpression('solveSteadyState(MyModel)')

# Path B
omc.sendExpression('buildModelFMU(MyModel, ...)');  # interactive FMU
# 外部: pyfmi + 自选 NLE / 未来 ompython.steadystate.Solver
```

### 4.3 诊断

- 编译：`-d=bltdump,tearingdump,initialization`
- 稳态专用：`-d=steadyStateDump`（打印 IV 列表、残差方程、自由度数）
- 运行：`LOG_NLS`, `LOG_NLS_V`；HTML BLT（可后续移植 OCT 风格 diagnostics）

---

## 5. 旧后端 vs 新后端：方案对照

| 维度 | 旧后端 | 新后端 |
|---|---|---|
| 稳态挂载 | 扩展 `Initialization` / 旁路仿真 loop | 新 `Kind.STEADY` + `NBSteadyState` |
| 语义清晰度 | 易与 init 混淆 | 一等分区，清晰 |
| 撕裂引导 | `Tearing.mo` + CLI indexes；注解需接线 | `guruTearing` 已就绪，扩展成本低 |
| 数组/大规模 | 一般 | 更强（slice、resizable） |
| Interactive FMU | SimCodeUtil + FMU tpl | NSimStrongComponent → 共用 FMU tpl |
| 实现优先级 | **短期 MVP（Path A）** | **中期主路径（Path A+B）** |
| 维护策略 | MVP 验证语义后，功能冻结/迁移 | 长期唯一增强面 |

**推荐节奏：**

1. **Phase 0**：统一语义文档 + flag 名 + 注解草案（前后端共享）。  
2. **Phase 1（旧后端 Path A MVP）**：小模型 `der(x)=0` 整系统 KINSOL 求解；OMShell API。  
3. **Phase 2（新后端 Path A）**：`Kind.STEADY` 完整流水线；迁移测试。  
4. **Phase 3**：注解配对（HGT-lite）+ `guruTearing` 默认策略。  
5. **Phase 4（Path B）**：Interactive FMU + Python solver 包。  
6. **Phase 5**：Continuation、过定 LS、更细的 OCT 选项对齐。

---

## 6. 关键设计决策（需提前钉死）

1. **`fixed=true` 状态在稳态下是否报错还是忽略？**  
   建议：默认忽略并 warning；`--steadyStateStrictFixed=true` 时报错。
2. **纯代数模型（无状态）？**  
   支持：直接撕开代数环求解；`-steadyState` 动态检测本来就不适用。
3. **闭环流体缺压力参考？**  
   编译期自由度检查失败，给出可操作提示（指定某 `p` 或泵特性）。
4. **是否兼容 OCT `__Modelon` 注解？**  
   一期不解析；二期可做可选翻译层 → `__OpenModelica_*`，避免厂商锁定。
5. **与现有 `-steadyState` 命名？**  
   严格区分：`detect` vs `solve`。

---

## 7. 最小验证用例

| 用例 | 期望 |
|---|---|
| `der(x)=-x+1` 稳态 | \(x=1\)，builtin 一次求出 |
| 两方程非线性（OCT `twoEqSteadyState` 类） | 与手工 NLE 解一致 |
| MSL 简单电路稳态 | 与长时间仿真终点一致 |
| 带 `tearingSelect` / 新残差注解 | IV 选择符合注解 |
| Interactive FMU 往返 | 外部牛顿收敛到同解 |
| 欠定闭环 | 清晰错误而非错误收敛 |

---

## 8. 结论

- OCT 稳态的本质是 **代数 NLE +（可选）Interactive FMU + 引导撕裂**；OM 已有 KINSOL、撕裂、init homotopy、FMI3 残差雏形，缺的是 **稳态问题构造** 与 **IV/残差对外暴露**。
- **旧后端**：以“特殊初始化 + 跳过积分”最快做出 Path A MVP。  
- **新后端**：以 `Kind.STEADY` 做成一等分析模式，并承接 Path B 与注解增强，作为长期方案。  
- 两条后端共享：**语义规则、flag、注解、C runtime、FMU 约定、测试集**；避免两套用户可见行为。
