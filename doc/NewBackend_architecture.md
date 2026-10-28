# 新后端（NBackEnd）架构导读，以及 HGT 移植草案

本文介绍 OpenModelica 实验性的新后端：它的数据结构、处理流程，以及和旧后端（`BackEnd/`）的区别。最后一章是把手动引导撕裂（HGT）移植到新后端的设计草案。

- 代码：`OMCompiler/Compiler/NBackEnd/`、`OMCompiler/Compiler/NSimCode/`
- 开关：`--newBackend`（`Flags.NEW_BACKEND`，标为 experimental / WIP），会同时启用新前端
- 旧后端的 HGT 实现见 [HGT_developer_guide.md](HGT_developer_guide.md) 和 [HGT_matching_and_tearing.md](HGT_matching_and_tearing.md)

## 目录

1. [一句话概括](#1-一句话概括)
2. [整体数据流](#2-整体数据流)
3. [核心数据结构](#3-核心数据结构)
4. [模块流水线](#4-模块流水线)
5. [数组是怎么保留下来的](#5-数组是怎么保留下来的)
6. [NSimCode：回到旧的代码生成](#6-nsimcode回到旧的代码生成)
7. [与旧后端的对比](#7-与旧后端的对比)
8. [读代码的顺序与调试标志](#8-读代码的顺序与调试标志)
9. [HGT 移植设计草案](#9-hgt-移植设计草案)

---

## 1. 一句话概括

旧后端先把模型**全部标量化**，再在标量方程上做匹配、排序和撕裂。新后端**尽量保留数组方程和 for 方程**，按"方程切片 ↔ 变量切片"做匹配、排序和求解，生成的代码里也保留循环。

动机：对离散化的管道、网格、电池模组这类大规模数组模型，标量化让方程数、编译时间和生成的 C 代码都随数组规模线性膨胀。新后端的目标是"N 个相同的方程只处理一次"。

代价：这是一次重写，不是在旧后端上修补。数据结构、表达式类型和模块全部是新的。目前只有代码生成和运行时是复用旧的。

## 2. 整体数据流

```
新前端 NFInst
  │  FlatModel（不经过旧的 DAE.Element）
  ▼
NBackendDAE.lower            Classes/NBackendDAE.mo
  │  BackendDAE.MAIN
  ▼
NBackendDAE.main             Pre → Main → Post 三段模块
  │  BackendDAE.MAIN（带 Partition 和 StrongComponent）
  ▼
NSimCode.SimCode.create      NSimCode/NSimCode.mo
  │  NSimCode.SimCode
  ▼
NSimCode.SimCode.convert     转成旧的 SimCode.SimCode
  │
  ▼
CodegenC.tpl 等旧模板 → C 运行时
```

入口在 `SimCodeMain.translateModelCallBackendNB`。打开 `--newBackend` 时，`SimCodeMain` 会走这条路径，而不是 `translateModelCallBackend` 那条旧路径。

旧后端的数据流是 `FlatModel → DAE.DAElist → BackendDAECreate.lower → BackendDAE`，中间多一层旧的 DAE 表示，表达式也都换成了 `DAE.Exp`。新后端跳过这一层，直接使用新前端的类型：`NFExpression`、`NFComponentRef`、`NFType`、`NFFunction`。

新后端开启时，前端也会少做一些事。例如 `NFInst` 会额外做 `combineBinaries`，把连续的二元运算合并成多元运算；`NFFlatten` 对 for 方程和数组的展开也更少。

## 3. 核心数据结构

### 3.1 `BackendDAE.MAIN`（`Classes/NBackendDAE.mo`）

```modelica
record MAIN
  list<Partition> ode          "微分代数方程的分区";
  list<Partition> algebraic    "只含代数方程的分区";
  list<Partition> ode_event    "事件迭代用";
  list<Partition> alg_event;
  list<Partition> clocked      "时钟分区";
  list<Partition> init         "初始化";
  Option<list<Partition>> init_0  "同伦 lambda = 0 时的初始化";
  Option<list<Partition>> dae  "DAE 模式";
  list<StrongComponent> parameters  "参数绑定的求解顺序";
  VarData varData;  EqData eqData;
  Events.EventInfo eventInfo;  Partitioning.ClockedInfo clockedInfo;
  UnorderedMap<Path, Function> funcMap;
end MAIN;
```

和旧后端对比：旧后端是一个 `BackendDAE(eqs: list<EqSystem>, shared: Shared)`，初始化系统要另外建一个完整的 `BackendDAE`。新后端把所有系统分类放在**同一个**结构里，初始化分区和仿真分区共享同一份 `varData` 和 `eqData`。

`BackendDAE` 还有其他变体：`JACOBIAN`（雅可比矩阵本身也是一个小的 BackendDAE）、`HESSIAN`。

### 3.2 变量与方程

- **变量**（`Classes/NBVariable.mo`）用 `Pointer<Variable>` 共享，所有地方引用的是同一个对象。`VarData.VAR_DATA_SIM` 按类别保存多个 `VariablePointers`：`unknowns`、`knowns`、`initials`、`states`、`derivatives`、`algebraics`、`discretes`、`previous`、`aliasVars`……
- **方程**（`Classes/NBEquation.mo`）同样用 `Pointer<Equation>`，种类有：
  - `SCALAR_EQUATION`、`ARRAY_EQUATION`、`RECORD_EQUATION`
  - `ALGORITHM`、`IF_EQUATION`、`WHEN_EQUATION`
  - **`FOR_EQUATION(size, iter, body, source, attr)`**：保留 for 循环，`iter` 记录迭代器和范围
  - `AUX_EQUATION`、`DUMMY_EQUATION`

  每条方程都带 `DAE.ElementSource source`（和旧后端一样，注释和注解都在这里）以及 `EquationAttributes attr`：`residualVar`、`exclusively_initial`、`kind`……
- 方程会被改写成残差形式，并用一个残差变量 `$RES_SIM_n` 来命名（`attr.residualVar`）。dump 中看到的 `($RES_SIM_2)` 就是方程的名字。

旧后端的变量和方程放在 `BackendDAE.Variables` / `EquationArray`，按**标量下标**访问；一条数组方程在邻接矩阵里展开成很多行。

### 3.3 `Partition`（`Classes/NBPartition.mo`）

```modelica
record PARTITION
  Integer index;
  Association association              "连续 / 时钟";
  VariablePointers unknowns;
  Option<VariablePointers> daeUnknowns;
  EquationPointers equations;
  Option<Adjacency.Matrix> adjacencyMatrix;
  Option<Matching> matching;
  Option<array<StrongComponent>> strongComponents;
end PARTITION;
```

它相当于旧后端的 `EqSystem`。分区的类型 `Kind` 是 `ODE, ALG, ODE_EVT, ALG_EVT, INI, INI_0, DAE, JAC, CLK`。各个模块按 `kind` 决定处理 `MAIN` 中的哪些分区。

### 3.4 `StrongComponent`（`Classes/NBStrongComponent.mo`）

新后端支持数组，很大程度上就体现在强连通分量的种类上：

| 记录 | 含义 |
|---|---|
| `SINGLE_COMPONENT(var, eqn, status)` | 一条方程（可以是数组方程）解一个变量（可以是多维的） |
| `MULTI_COMPONENT(vars, eqn, status)` | 一条方程同时解多个变量：算法、when、if |
| `SLICED_COMPONENT(var_cref, var, eqn, status)` | 方程的**一个切片**解变量的一个切片，切片用 0 起始下标 |
| `RESIZABLE_COMPONENT(..., order, status)` | 尺寸可变的 for 方程，带求值顺序（independent / forward / backward） |
| `GENERIC_COMPONENT` | 需要切片、但恢复不出 for 循环的情况 |
| `ENTWINED_COMPONENT` | 多个 for 方程必须交错求值、但不构成代数环 |
| `ALGEBRAIC_LOOP(idx, strict, casual, linear, mixed, homotopy, status, ...)` | 代数环，内含撕裂集 |
| `ALIAS` | 和已有的分量结构相同，直接复用它的结果 |

旧后端对应的只有 `SINGLEEQUATION`、`SINGLEARRAY`、`SINGLEALGORITHM`、`SINGLEWHENEQUATION`、`EQUATIONSYSTEM`、`TORNSYSTEM` 等，基本都是标量粒度。

### 3.5 撕裂集 `Tearing.TEARING_SET`（`Modules/3_Post/NBTearing.mo`）

```modelica
record TEARING_SET
  list<Slice<VariablePointer>> iteration_vars;
  list<Slice<EquationPointer>> residual_eqns;
  array<StrongComponent> innerEquations   "已匹配的内部方程，本身也是强连通分量";
  Option<Jacobian> jac;
end TEARING_SET;
```

`ALGEBRAIC_LOOP` 里有两套撕裂集：`strict`，以及可选的 `casual`，对应两种可解性判断。旧后端的 `TEARINGSET` 也有 strict 和 casual 两个，但内部方程是 `INNEREQUATION(eqn, vars)` 这样的下标列表；新后端的内部方程直接就是 `StrongComponent`，所以天然可以带切片，结构上也可以嵌套。

### 3.6 工具（`Util/`）

| 文件 | 作用 |
|---|---|
| `NBSlice.mo` | `Slice<T>`：一个对象（方程或变量）加上被选中的下标列表；还有切片之间依赖关系的计算 |
| `NBAdjacency.mo` | 邻接矩阵。`FULL` 保存全部信息，`FINAL` 是按某种可解性（strict / casual）生成的最终矩阵，`SPARSITY` 给雅可比矩阵用。依赖关系通过 `Mapping` 按数组记录，不把数组展开成标量行 |
| `NBASSC.mo` | 解析可解性检查（Analytical to Structural Singularity Conversion），把结构上看起来可解、实际奇异的情况提前转换过来 |
| `NBResizable.mo` | 可变尺寸数组（`--resizableArrays`） |
| `NBDifferentiate.mo` | 符号微分，新写的一套，旧后端用的是 `Differentiate.mo` |
| `NBReplacements.mo` | 替换表，用于别名消除和内联 |
| `NBBackendUtil.mo` | 杂项 |

## 4. 模块流水线

`NBackendDAE.main` 把模块分成三段，用 `applyModules` 依次执行。每个模块都是一个 `Module.wrapper`（`Modules/NBModule.mo`，接口是 `BackendDAE → BackendDAE`），执行时自动计时；开 `-d=dumpBackendClocks` 可以看到每个模块的耗时。

**模块顺序写死在代码里**，不像旧后端那样可以用 `--preOptModules+=` 增删。

### 4.1 Pre（`Modules/2_Pre/`）：分区之前，作用在整个模型上

| 顺序 | 模块 | 作用 |
|---|---|---|
| 1 | `Bindings` | 把变量的 binding 变成方程 |
| 2 | `FunctionAlias` | 相同的函数调用只算一次，结果放进辅助变量 |
| 3 | `Inline`（early） | 内联函数 |
| 4 | `simplify` | 化简 |
| 5 | `Alias` | 别名消除，相当于旧后端的 `removeSimpleEquations` |
| 6 | `simplify` | 再化简一次 |
| 7 | `removeStream` | 处理 stream 连接器 |
| 8 | `DetectStates` | 识别状态变量，`der(x)` 换成 `$DER.x` |
| 9 | `Events` | 收集时间事件和状态事件 |

### 4.2 Main（`Modules/1_Main/`）

| 顺序 | 模块 | 作用 |
|---|---|---|
| 1 | `Partitioning.main` | 按连通性拆成独立的分区 |
| 2 | `Causalize.main` | 匹配（`NBMatching`）、排序（`NBSorting`，Tarjan）和指标约简（`NBResolveSingularities`），作用在 ODE 和时钟分区上 |
| 3 | `Inline`（after index reduction） | 指标约简之后再做一次内联 |
| 4 | `Initialization.main` | 从仿真系统派生出初始化分区 `init`，有 homotopy 时还派生 `init_0`；然后对它们做 Causalize |
| （5） | `DAEMode.main` | 只在 DAE 模式下运行 |

`Causalize` 的实现由 `--matchingAlgorithm` 选择，目前是 `PFPlusExt` 或 `pseudo`，两者都走 `causalizePseudoArray`：在数组层面做匹配，必要时退回到标量。

### 4.3 Post（`Modules/3_Post/`）

| 顺序 | 模块 | 作用 |
|---|---|---|
| 1 | `Evaluation.removeDummies` | 去掉占位方程 |
| 2 | `Tearing.main` | 撕裂所有 `ALGEBRAIC_LOOP`，方法由 `--tearingMethod` 选择：`minimalTearing`、`cellier`、`omcTearing`（目前等同于 minimal）、`guruTearing` |
| 3 | `Partitioning.categorize` | 把分区按 ode、alg、event 等重新分类 |
| 4 | `Solve.main` | 符号求解每个分量；解不出的分量由 `Tearing.implicit` 升级为代数环 |
| 5 | `Jacobian.main` | 生成雅可比矩阵 |
| 6 | `Initialization.minimizeHomotopySystem` | 缩小同伦系统 |

旧后端的对应顺序是：preOpt 模块 → 匹配排序 → 初始化系统（单独一套 DAE，再跑 initOpt 模块） → postOpt 模块。其中 `tearingSystem` 只是 postOpt 里的一个模块，而且在 `solveSimpleEquations` 等模块之前运行。新后端先撕裂，再求解。

## 5. 数组是怎么保留下来的

以下面的模型为例：

```modelica
for i in 2:N loop
  x[i] = f(x[i-1]);
end for;
```

1. **lower**：生成一条 `FOR_EQUATION`，而不是 N−1 条标量方程。
2. **邻接矩阵**：记录"方程第 k 次迭代依赖 `x` 的下标 k 和 k−1"这样的映射，不展开成标量行。
3. **匹配和排序**：如果能证明这条 for 方程整体按下标顺序解出 `x[2:N]`，就生成一个 `SLICED_COMPONENT` 或 `RESIZABLE_COMPONENT`，求值顺序是 forward。
4. **代码生成**：生成一个 for 循环。默认情况下 `--simCodeScalarize=true`，生成代码时仍然会标量化；设成 false 才保留循环。

如果数组层面处理不了，会逐级退回：
- 依赖关系太复杂时，在数组层面匹配失败，退到标量匹配；
- 恢复不出 for 循环的，变成 `GENERIC_COMPONENT`；
- 几个 for 方程交错求值的，变成 `ENTWINED_COMPONENT`，它带有标量化的备选方案 `entwined_tpl_lst`。

这一套机制，以及 §3.4 里各种分量和 `Slice`，是新后端最主要的复杂度来源，也是它和旧后端本质上的区别。

## 6. NSimCode：回到旧的代码生成

- `NSimCode.SimCode.create` 从 `MAIN` 生成新的 SimCode 结构：`NSimVar`、`NSimStrongComponent`、`NSimJacobian`、`NSimPartition`……
- `NSimCode.SimCode.convert` 把它转换成旧的 `SimCode.SimCode`。之后就和旧后端完全一样：同一套 `CodegenC.tpl`，同一套 C 运行时（以及可选的 Rust 运行时）。
- `NSimStrongComponent.fromStrongComponent` 处理代数环时，对 `strict.innerEquations` 中的每个分量**递归**调用自己。所以内部方程本身也可以是一个复杂的分量。

这样设计，是因为模板和运行时是最大、最稳定的部分。先只重写中间的符号处理，风险最小。代价是 `convert` 这一层必须能把新的结构表达成旧的记录。例如 `SLICED_COMPONENT` 如果不标量化，就需要旧 SimCode 里本来就有对应的循环结构。

## 7. 与旧后端的对比

| 方面 | 旧后端（`BackEnd/`） | 新后端（`NBackEnd/`） |
|---|---|---|
| 输入 | `DAE.DAElist` | `FlatModel` |
| 表达式 | `DAE.Exp`、`DAE.ComponentRef` | `NFExpression`、`NFComponentRef` |
| 数组 | 基本全部标量化 | 保留数组方程和 for 方程，按切片匹配、排序和求解 |
| 顶层结构 | `BackendDAE(eqs, shared)` + 单独的初始化 DAE | 一个 `MAIN`，分区按类别存放 |
| 变量和方程 | 数组加哈希，按标量下标访问 | `Pointer` 共享，按类别分组 |
| 邻接矩阵 | `array<list<Integer>>`，标量行 | `Adjacency.Matrix`，按数组记录映射 |
| 强连通分量 | 标量粒度，种类少 | 支持切片、可变尺寸、交织等多种 |
| 模块 | 很多，命令行可增删 | 较少，顺序固定 |
| 初始化 | `Initialization.solveInitialSystem` 另建 DAE | Main 阶段的一个模块，共享数据 |
| 先撕裂还是先求解 | 先做 `solveSimpleEquations` 等，`tearingSystem` 在后 | 先 Tearing，后 Solve |
| 撕裂方法 | omcTearing、cellier、userDefined、**HGT** | minimalTearing、cellier、guruTearing |
| SimCode | 直接生成 `SimCode.SimCode` | `NSimCode` → `convert` |
| 模板与运行时 | `CodegenC.tpl` + C/Rust 运行时 | 同一套 |
| 代码量 | 约 14 万行 | 约 5.3 万行（含 NSimCode） |
| 成熟度 | 默认使用 | 实验性 |

## 8. 读代码的顺序与调试标志

**阅读顺序**

1. `SimCodeMain.translateModelCallBackendNB`：二十几行，整条路径一目了然。
2. `Classes/NBackendDAE.mo`：先看 `MAIN`、`lower` 和 `main`（模块列表）。
3. `Classes/NBVariable.mo`、`NBEquation.mo`：只看记录定义和 `toString`，其余函数用到时再查。
4. `Classes/NBPartition.mo`、`NBStrongComponent.mo`：重点是 §3.4 那张表。
5. `Util/NBSlice.mo`、`NBAdjacency.mo`：数组处理的核心。比较难读，可以先用 `-d=dumpSlice` 看几个例子的输出。
6. `Modules/1_Main/NBCausalize.mo` → `NBMatching.mo` → `NBSorting.mo`。
7. `Modules/3_Post/NBTearing.mo`：`main` → `tearingTraverser` → `getModule` → `minimal` 和 `guru`。`guru` 和我们的 HGT 最像。
8. `NSimCode/NSimCode.mo`、`NSimStrongComponent.mo`：`create` 和 `convert`。

**调试标志**（加在 `-d=` 后面）

| 标志 | 输出 |
|---|---|
| `optdaedump` | lower 之后和每个模块之后的 BackendDAE |
| `dumpBackendClocks` | 每个模块的耗时 |
| `bltdump` | 强连通分量 |
| `tearingdump` | 撕裂的结果（见 §9.1 的例子） |
| `dumpSlice` | 切片运算 |
| `dumpSolve` | 符号求解 |
| `dumpBackendInline`、`dumprepl`、`debugAlias` | 内联、替换、别名消除 |
| `initialization` | 初始化分区的平衡过程 |
| `dumpASSC` | 解析可解性检查 |
| `failtrace` | 模块失败时打印是哪个模块 |

例子：

```bash
omc --newBackend -d=optdaedump,tearingdump,dumpBackendClocks model.mos
```

## 9. HGT 移植设计草案

### 9.1 现状

前端收集 HGT 注解的部分（`NFHandGuidedTearing`）两个后端共用，`-d=hgtDump` 也能打印出前端读到的配对。但是新后端**完全不读取** `FlatModel.handGuidedTearing`，撕裂仍然按 `--tearingMethod` 自动进行。

用 [HGT_matching_and_tearing.md](HGT_matching_and_tearing.md) §8.2 的 `Nested` 模型实测（`--newBackend --handGuidedTearing -d=hgtDump,tearingdump`）：

```
Hand guided tearing:
  pair: residual equation e2 (level 2), iteration variable y (level 2)
  pair: residual equation e3 (level 1), iteration variable x (level 1)
...
BLOCK: Algebraic Loop (Linear = false, Mixed = false, Homotopy = false, size = 3)
### Iteration Variables:
    [ALGB] (1) Real x (start = 1.0)
### Residual Equations:
    [SCAL] (1) $RES_SIM_2 = x - (y ^ 3.0 + y); ($RES_SIM_2)
### Inner Equations:
    ... z 由 z * x = 6 解出 ...
    ... y 由 z = y + x 解出 ...
```

迭代变量 x 恰好是对的，但残差选的是 e2，内部方程用 e3 去解 z。用户的配对 e3↔x、e2↔y 以及嵌套结构都没有被采用。这个例子碰巧也能解出 x=2、y=1，但在真正需要 HGT 的模型上（例如开发指南里提到的 `HGTGrid` 的 sqrt 形式），这样就解不出来了。

### 9.2 旧后端的各部分在新后端里对应什么

| 旧后端 HGT 部分 | 作用 | 新后端中的位置 | 难度 |
|---|---|---|---|
| `HandGuidedTearing.lower` | 读取规范，迭代变量设为不可替换，应用 start/nominal，缩放残差 | `NBackendDAE.lower`：把规范放进 `MAIN` 的新字段；变量属性写进 `NBVariable` 的 `BackendInfo` 和 `VariableAttributes` | 低 |
| 方程标签 `__OpenModelica_HGTEquation` | 在后端识别 HGT 方程 | 方程的 `source` 仍是 `DAE.ElementSource`，`equationName` 的做法可以直接沿用 | 低 |
| 优化模块中的保护 | 不让别名消除删掉迭代变量和残差方程 | `NBAlias`、`NBFunctionAlias`、`simplify`、`Inline` 要跳过 HGT 项 | 中 |
| `hgtMatching` | 强制配对、合并成一个块 | `NBCausalize`：匹配前锁定配对，排序时保证它们进同一个强连通分量 | **高**（数组匹配） |
| `Tearing.handGuidedTearing` | 按用户指定撕裂，卡住时自动补迭代变量 | `NBTearing` 中新增 `hgt` 方法，参照 `guru` | 中 |
| 嵌套 level | 内层块 `INNERCOMPONENT` | `TEARING_SET.innerEquations` 中放入一个内层 `ALGEBRAIC_LOOP` | 中到高（需要验证 NSimCode 和运行时） |
| 伪根约束 `INNEREQUATIONCONSTRAINTS` | 反解非线性函数时检查原方程 | `NBSolve` 或 NSimCode 中生成 assert | 中 |
| `hgtAttributes`、迭代变量界、`hgtBounds` | 运行时的投影和解检查 | `NSimCode.convert` 时填进旧 SimCode 的 `hgtAttributes`，之后完全复用 | 低 |
| 初始化和仿真的区别（`initialResiduals`） | 初始方程上的配对只用于初始化 | 方程上已有 `attr.exclusively_initial`，直接用 | 低 |

### 9.3 建议的实现步骤

**阶段 1：只支持标量项，不支持嵌套**

1. `BackendDAE.MAIN` 增加 `Option<HGTSpec> handGuidedTearing`，在 `lower` 中从 `FlatModel` 读取。
2. 迭代变量：在变量属性中标记不可删除，应用 start 和 nominal；残差按 nominal 缩放。这一步可以参照旧后端 `HandGuidedTearing.lower`，改用新前端的表达式类型。
3. 在 `NBAlias` 等 Pre 模块中保护 HGT 项：被标记的变量不当作别名消除，带标签的方程不删除。
4. 新增撕裂方法 `hgt`，接入 `NBTearing.getModule`，并且**只要强连通分量里有 HGT 项就强制使用它**，不受 `--tearingMethod` 影响。实现上参照 `guru`：
   - `iteration_vars` = 用户的迭代变量；`residual_eqns` = 用户的残差方程；
   - 其余方程按 casual 可解性做因果化，卡住时自动补迭代变量（逻辑和旧后端 §6.2 ③ 相同）；
   - 最后剩下的方程作为自动残差。
5. 只做到这一步时，**用户的项分散在不同的强连通分量里**的情况还处理不了：旧后端靠 `hgtMatching` 强制合并，这一阶段可以先报错。
6. `NSimCode.convert` 时生成 `hgtAttributes`，复用已有的运行时实现。

只做阶段 1，就能覆盖用户的项本来就在同一个代数环里的情况，这在 HGT 的实际用法里是大多数。

**阶段 2：强制合并（新后端版的 hgtMatching）**

- 在 `NBCausalize` 中，匹配之前把配对写进初始匹配并锁定，类似旧后端的 `markVar`、`markRow` 和 `assign`。
- 排序（`NBSorting`）时，在 HGT 行之间加人为依赖，相当于 `addRing`，保证它们进同一个分量。
- 难点：新后端的匹配是数组层面的。如果某个 HGT 项是一条 for 方程的切片，就要把那条 for 方程拆成切片，或者对含 HGT 项的分区**退回标量匹配**。建议先退回标量：HGT 模型通常不大，而且用户写的配对本来就是标量的（注意前端目前也不支持在 for 方程上写 HGT 注解）。

**阶段 3：嵌套 level**

- 在 `TEARING_SET.innerEquations` 中放入一个内层 `ALGEBRAIC_LOOP`，用自己的撕裂集表示内层块。
- 需要验证：
  - `NSimStrongComponent.fromStrongComponent` 递归时，是否能为内层代数环生成嵌套的非线性系统；
  - 旧 SimCode 是否能表达这种嵌套。旧后端的 HGT 已经用嵌套 NLS 实现过，见开发指南 §5.2，所以 SimCode 和运行时一侧是现成的，主要是 `convert` 的映射。
- 求解顺序（内层块的输入已知后整体求解），参照旧后端的 `order := (-k) :: order` 逻辑。

**阶段 4：数组上的 HGT（可选）**

- 前端已经支持 for 方程和数组方程上的注解，但做法依赖展开：for 方程由 `unrollForLoop` 展开、数组方程由 `NFScalarize` 拆开，每个元素成为一个带标签的标量配对。新后端保留 for 方程和数组方程，所以这条路径用不上。
- 在新后端要用 `Slice` 表达"这条 for 方程（或数组方程）的第 i 个切片和 `m[i]` 配对"，在数组层面强制匹配；前端也要改成把整条方程的配对规则（下标对应关系）传下去，而不是展开后的元素。
- 这是新后端独有的能力，旧后端无法做到，但工作量最大。

### 9.4 工作量与风险

| 阶段 | 估计（熟悉新后端的人） | 主要风险 |
|---|---|---|
| 1 | 1–2 周 | Pre 模块里的保护是否完整：新后端的别名消除比旧后端激进 |
| 2 | 1–2 周 | 数组匹配和锁定配对能否共存；退回标量匹配的范围 |
| 3 | 1 周以上 | NSimCode 对嵌套代数环的支持，雅可比矩阵的生成 |
| 4 | 数周 | 前端语法、切片匹配、测试覆盖 |

**测试**：旧后端的 14 个 HGT 仿真测试和 16 个前端测试可以直接加上 `--newBackend` 再跑一遍，作为回归测试。结果应该和旧后端一致，对比方法和 C/Rust 运行时那次一样，用 `diffSimulationResults`。

**风险点**：新后端本身仍在快速变化。上游最近还改了 `ScopeRef`，就影响到了我们的前端代码。建议等阶段 1 的接口确定后，尽早向上游提交，减少之后合并时的冲突。
