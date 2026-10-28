# HGT 后端：hgtMatching 与 handGuidedTearing 导读

本文讲解旧后端中手动引导撕裂（HGT）的两段核心代码：它们各做什么、怎么配合，以及读代码时从哪里入手。

- `HandGuidedTearing.hgtMatching`：`OMCompiler/Compiler/BackEnd/HandGuidedTearing.mo`
- `Tearing.handGuidedTearing`：`OMCompiler/Compiler/BackEnd/Tearing.mo`

前端、SimCode 和运行时的部分见 [HGT_developer_guide.md](HGT_developer_guide.md)，本文是它 §4.3–§4.5 的展开。

## 目录

1. [先搞清楚两件事：匹配和撕裂](#1-先搞清楚两件事匹配和撕裂)
2. [两者的分工](#2-两者的分工)
3. [在流水线中的位置](#3-在流水线中的位置)
4. [三种下标](#4-三种下标)
5. [hgtMatching](#5-hgtmatching)
6. [Tearing.handGuidedTearing](#6-tearinghandguidedtearing)
7. [没有嵌套 level](#7-没有嵌套-level)
8. [一个完整例子](#8-一个完整例子)
9. [读代码的顺序](#9-读代码的顺序)
10. [调试方法](#10-调试方法)
11. [容易踩的坑](#11-容易踩的坑)

---

## 1. 先搞清楚两件事：匹配和撕裂

后端把方程组变成可执行代码，要经过两步。

**匹配 + 排序（BLT）**

- **匹配**：给每条方程指定一个它负责求解的变量，两边一一对应。结果存在 `ass1`（变量 → 方程）和 `ass2`（方程 → 变量）两个数组里。
- **排序**：有了匹配，就有"方程 A 要用到方程 B 算出的变量"这种依赖关系，形成一张有向图。Tarjan 算法求这张图的强连通分量（SCC），每个 SCC 就是一个块（`StrongComponent`）：
  - 只有一条方程的块按顺序直接求解；
  - 多条方程互相依赖的块（`EQUATIONSYSTEM`）是一个代数环，必须联立求解。

**撕裂（tearing）**

对一个代数环块：
1. 选几个**迭代变量**（tearing variables），假设它们已知；
2. 其余方程按因果顺序依次求出剩下的变量（内部方程，inner equations）；
3. 最后剩下几条方程无法直接用来求值，作为**残差**，检验假设是否正确。

非线性求解器只需要迭代这几个迭代变量，未知量的个数从块的大小降到迭代变量的个数。撕裂的结果是 `TORNSYSTEM(TEARINGSET(tearingvars, residualequations, innerEquations, ...))`。

普通流程里，这两步都是自动的：匹配算法决定块，`--tearingMethod` 指定的启发式算法选迭代变量。HGT 让用户自己指定"用哪条方程当残差、迭代哪个变量"，所以两步都要改。

## 2. 两者的分工

| | hgtMatching | Tearing.handGuidedTearing |
|---|---|---|
| 回答的问题 | 用户指定的项落在哪个块里？哪些方程必须放进同一个块？ | 块内部：迭代哪些变量、哪些方程作残差、其余方程按什么顺序求解？ |
| 操作对象 | 整个 EqSystem 的匹配（`ass1`/`ass2`）和 BLT 块 | 一个块（`EQUATIONSYSTEM`） |
| 输出 | 改写后的匹配和强连通分量 | `TORNSYSTEM` |
| 相当于普通流程里的 | 匹配 + `strongComponentsScalar` | `tearingSystem` 里的某个撕裂方法 |

**最关键的一点**：在 hgtMatching 里，"残差方程 e 配迭代变量 x"只是一个**占位**。e 实际上并不去解 x，这个配对只是让 x 和 e 落进同一个块。

举例来说，e3: `h(x, z) = 0` 被强制匹配给 x 之后：
- 用到 x 的方程都依赖 e3；
- e3 本身又依赖 z；
- 于是形成环，Tarjan 把它们放进一个块。

Tearing 拿到这个块时，再把这个配对解释成"x 是迭代变量，e3 是残差"。

两边通过两样东西对上号：
- 方程上的标签 `__OpenModelica_HGTEquation`，由 `equationName` 读出；
- `shared.handGuidedTearing` 中的规范（`HGT_SPEC`）。

## 3. 在流水线中的位置

`hgtMatching` 注册在 `BackendDAEUtil.mo` 的初始化优化模块（`allInitOptimizationModules`）和后优化模块（`allPostOptimizationModules`）里，都排在 `tearingSystem` 之前：

```
... → reduceDynamicOptimization → hgtMatching → tearingSystem → simplifyLoops → ...
```

开了 `--handGuidedTearing` 时，`getPostOptModules` 和 `getInitOptModules` 会自动启用这个模块。

所以这两个函数各运行两次：
- 一次在**初始化系统**（initialization DAE）上；
- 一次在**仿真系统**（simulation DAE）上。

两次之间的区别：
- **初始化系统**：初始方程已经并入 `orderedEqs`，写在 initial equation 上的 HGT 项在这里生效。
- **仿真系统**：在后优化之前，`Initialization.removeInitializationStuff` 已经清空了 `shared.initialEqs`。所以 hgtMatching 先用 `simulationSpec` 去掉只属于初始化系统的项（见 §5.1）。

在这之前，`HandGuidedTearing.lower` 和优化模块里的几处保护已经保证：迭代变量不会被当成别名消掉，残差方程不会被删除，带 nominal 的残差已经缩放。见开发指南 §4.1、§4.2。

## 4. 三种下标

读这两段代码时，最容易搞混的是下标。一共有三种：

| 下标 | 含义 | 出现在 |
|---|---|---|
| **全局方程/变量下标** | 在 `syst.orderedEqs` 和 `syst.orderedVars` 中的位置 | `matchSystem` 的 `pairs`；块中的 `comp.eqns`/`comp.vars` |
| **标量行**（row） | 数组方程展开后的标量方程；一条方程可以对应多行 | `matchSystem` 中的邻接矩阵、`ass2`、`hgt_rows`；转换靠 `map_eqn_row`（方程 → 行列表）和 `map_row_eqn`（行 → 方程） |
| **块内局部下标** | 在块的方程列表和变量列表中的位置（从 1 开始） | `componentItems` 的输出，`Tearing.handGuidedTearing` 的全部参数和数组 |

`eqnRow(e, map_eqn_row)` 取方程 e 的第一行。HGT 的残差方程都是标量方程，所以这样取没问题。

Tearing 里调试输出中的 `(local)` 都是块内局部下标。要对回具体方程，可以看 `-d=tearingdump` 打印的块内方程列表。

## 5. hgtMatching

### 5.1 入口 `hgtMatching`

```modelica
if not isActive(inDAE.shared) then return; end if;   // 没开开关或模型里没有规范
SOME(spec) := inDAE.shared.handGuidedTearing;

if BackendDAEUtil.isSimulationDAE(inDAE.shared) then
  spec := simulationSpec(spec);                       // 去掉只属于初始化的项
  outDAE.shared := setSharedHandGuidedTearing(...);   // 写回，Tearing 读的就是它
  checkPresence(outDAE, spec);                        // 完整性检查
end if;

outDAE := mapEqSystem(outDAE, function matchSystem(spec = spec));
```

- **`simulationSpec`** 从规范中去掉只属于初始化系统的配对，也就是残差方程在 `initialResiduals` 中的配对。
- **`checkPresence`** 只对仿真系统做：
  - 每个残差标签在所有 `orderedEqs` 中必须正好出现 1 次，否则报 8011；
  - 每个迭代变量必须在某个系统的 `orderedVars` 中，否则报 8012；
  - 有状态变量时给警告 8017。

### 5.2 `matchSystem`：每个独立系统一次

`mapEqSystem` 对每个 EqSystem 调用一次 `matchSystem`。函数按注释分成下面几段。

#### ① 定位 HGT 项

```
indexTags(syst.orderedEqs, eqn_index)     // 标签名 → 全局方程下标
for res in spec.residuals:        // 前端只接受显式配对，每个残差都有迭代变量
  方程和变量都在本系统 → pairs += (v, e)
  只有一边在本系统     → 报 8013
```

- 本系统没有配对，直接返回，这个系统保持原样。

#### ② 两套标量邻接矩阵

- **`SOLVABLE`**（`m_s`）：只记录方程能解出的变量，用来做匹配和增广。
- **`NORMAL`**（`m_n`/`mt_n`）：记录全部依赖，用来求强连通分量和检查依赖关系。

为什么要两套：残差方程不需要能解出它的变量，因为强制配对不检查可解性；但排序必须看到全部依赖。

#### ③ 改写匹配

1. **从原有匹配出发**：复制 `syst.matching` 的 `ass2`。
2. **拿掉并锁定**：`markVar`、`markRow` 把所有 HGT 变量和残差行从匹配中拿掉，并在 `hgt_vars`、`hgt_rows` 中标记为锁定。被拿掉的普通方程或变量就成了未匹配状态。
3. **强制配对**：`assign(v, eqnRow(e))`，让残差方程"解"它配对的变量。
4. **修复**：对每个未匹配、未锁定的行调用 `augment` 找增广路径（Kuhn 算法），只走 `m_s` 里可解的边，不经过锁定的行和变量。因此修复时不会拆开 HGT 配对，也不会让普通方程去解 HGT 变量。
5. **兜底**：仍未匹配的行和变量（`free_rows`、`free_vars`）按顺序一对一配上，记作 `auto_rows`。
   - 这些配对同样是占位。Tearing 中它们会变成自动选出的残差和迭代变量，也就是 OCT 说的 "the automatic algorithm will kick in"。
   - 剩余的行数和变量数不等时，说明系统不是方阵，报内部错误。
   - 开了 `--hgtOnly` 时不做兜底：只要有剩余项就报 8018，列出匹配不上的方程和变量。

#### ④ 强制合并（addRing）

有 `auto_rows`，或者开了 `--hgtMergeBLTBlocks` 时，把所有 HGT 残差行和自动行收集到 `merge_rows`。`addRing` 在这些行之间加一圈**人为的依赖**：第 i 行依赖第 i+1 行所匹配的变量，最后一行依赖第一行。

效果：
- 这些行在依赖图里成环，Tarjan 一定把它们放进同一个 SCC；
- 夹在它们之间路径上的所有块，也一起被合并进来。

加的依赖只存在于传给 Tarjan 的矩阵副本 `m_ring`/`mt_ring` 中，不影响方程本身。

#### ⑤ 重新求强连通分量

```modelica
syst := setAdjacencyAndMatching(syst, m_ring, mt_ring, MATCHING(ass1, ass2, {}));
(syst, comps) := BackendDAETransform.strongComponentsScalar(syst, shared, map_eqn_row, map_row_eqn);
```

#### ⑥ 事后检查

- **`checkDependence`**：每个配对 `(v, row)` 所在的块中，必须有方程用到 v（在 `m_n` 中）。否则残差和迭代变量无关，撕裂后的系统是奇异的，报 8016。
- **`checkResidualCounts`**（R9）：`--hgtAllowMultipleResiduals=false` 时，每个块最多只能有一个用户残差，否则报 8021；默认 true，不检查。
- **`-d=hgtDump`**：`dumpComponents` 打印每个含 HGT 项的块。

## 6. Tearing.handGuidedTearing

### 6.1 入口：`Tearing.tearingSystem` → `traverseComponent`

```modelica
(is_hgt, hgt_vars, hgt_eqns) := HandGuidedTearing.componentItems(inComp, isyst, ishared);
if is_hgt then
  oComp := handGuidedTearing(inComp, isyst, ishared, hgt_vars, hgt_eqns);
  outRunMatching := true;
  return;
end if;
```

- `componentItems` 在块中找出 HGT 迭代变量和残差方程，返回**块内局部下标**。
- 只要块里有 HGT 项，就一定走 `handGuidedTearing`，不受 `--tearingMethod`、`--noTearingForComponent` 和"撕裂是否划算"的判断影响。
- 1×1 的 `SINGLEEQUATION` 块也会被撕裂成 1×1 的 `TORNSYSTEM`，残差方程不会被直接解出。

### 6.2 主流程

整体结构参照 `userDefinedTearing`，分三段。

#### ① 建子系统

- 用块内的方程和变量建一个小的 EqSystem（`subsyst`），以及它的标量邻接矩阵 `m`/`mt`，删掉负数条目。
- 用 `getAdjacencyMatrixEnhancedScalar(subsyst, ishared, true)` 建增强邻接矩阵 `me`，记录每个变量在每条方程里能否解出、怎么解。

最后一个参数 `true` 的意思是：**不管全局的 `--tearingStrictness` 是什么，都按 casual 判断可解性**。原因是迭代变量已经由用户选定，其余方程应该尽量都能解出来。否则像 `m = k*sqrt(pa - pb)` 这样的方程解不出 pa，用户的选择就会被自动补的迭代变量推翻。

#### ② 因果化循环

```
user_rows := 用户残差的行
tvars := userTVars
while not finished:
  ass1/ass2 清零
  标记 tvars 为已知，标记 user_rows 为已占用
  m1/mt1 := 删掉 tvars 和 user_rows 后的邻接矩阵副本

  反复取一条只剩一个未知量、且能解出的方程（getNextSolvableEqn），
  分配给这个未知量（makeAssignment），记入 order，直到卡住

  unassigned := 还没被求出的变量
  为空      → finished
  否则      → 选一个补作迭代变量（selectAdditionalTearingVar），重来
```

`selectAdditionalTearingVar` 选在未分配方程中出现次数最多的连续变量，离散变量不会被选。开了 `--hgtOnly` 时不补变量，直接报 8018，列出解不出的方程和变量。

每补一个迭代变量就**从头**再因果化一遍。补的变量通常很少，而且从头做逻辑最简单，不容易出错。

#### ③ 生成结果

- `auto_rows`：最后仍未分配的行，成为自动残差。
- 检查数量：`user_rows` 加 `auto_rows` 的个数必须等于 `tvars` 的个数，否则报 8020。
- `hgtInnerEquations` 按 `order` 生成内部方程：
  - 某条方程如果**只有反解非线性函数才能求出**（strict 模式下不可解，casual 模式下可解），例如 `m = k*sqrt(dp)` 被解成 `dp = (m/k)^2`，就生成 `INNEREQUATIONCONSTRAINTS`。它带一个约束 `abs(lhs - rhs) <= 1e-8*(abs(lhs) + abs(rhs) + 1)`，模板把它生成为 assert。运行时如果求解器收敛到负 m 这样的伪根，就会被拒绝。
- 输出 `TORNSYSTEM(TEARINGSET(tvars, residuals, inner_equations, EMPTY_JACOBIAN()), NONE(), linear, mixed)`。

## 7. 没有嵌套 level

OCT 的 level ≥ 2 是嵌套撕裂：外层每迭代一次，内层块就完整地解一遍。这里**不支持**，注解里的 `level` 只能是 1（前端报 8001），所以：
- 规范、DAE 和后端都没有 level 的概念，所有配对在同一层撕裂；
- `handGuidedTearing` 不递归，也没有内层块；内部方程只有 `INNEREQUATION` 和 `INNEREQUATIONCONSTRAINTS` 两种；
- R9 只有一条规则：`--hgtAllowMultipleResiduals=false` 时每个块最多一个用户残差。

需要"先解内层、再解外层"时，目前只能把内外层的配对都写在 level 1，由一个非线性系统一起解。

## 8. 一个完整例子

模型可以直接运行，开 `-d=hgtDump,tearingdump`。

### 8.1 单个配对

```modelica
model Loop
  Real x(start = 1), y, z;
equation
  y = exp(x);                // e1
  z = y ^ 2 + x;             // e2
  z - 10 = 0 annotation(__OpenModelica_HGT(name = e3, ResidualEquation(iterationVariable = x)));
end Loop;
```

**hgtMatching**
1. 自动匹配下 e3 解 z、e2 解 y、e1 解 x，三个都是单方程块，根本不是代数环。
2. 拿掉 x 和 e3 并锁定，强制 e3 ↔ x。
3. 增广修复：e1 解 y，e2 解 z。
4. 新的依赖关系：e1 用到 x，x 由 e3 负责，e3 用到 z，z 由 e2 负责，e2 用到 y，y 由 e1 负责。这是一个环，三条方程进同一个块。

**handGuidedTearing**
1. x 已知，e3 是残差；
2. 因果化：e1 算出 y，e2 算出 z，全部算完，不需要补变量。
3. 结果：迭代变量 {x}，残差 {e3}，内部方程 [e1 → y, e2 → z]。

输出：

```
Hand guided tearing matching (simulation system):
  block of 3 equations: residual equations {e3}, iteration variables {x}
Tearing type: hand guided
User iteration variables (local): 1
User residual equations (local): 3
Iteration variables (local): 1
Residual equations (local): 3
Automatically added: 0
```

解为 x = 1.0934，此时 y = e^x = 2.984，z = y² + x = 10。

## 9. 读代码的顺序

1. **`HandGuidedTearing.lower`**：先弄清规范 `HGT_SPEC` 里有什么（residuals、initialResiduals；每个 residual 都带着它的迭代变量），以及 `equationName` 怎么从方程上读出标签。
2. **`hgtMatching`**：十几行，看清楚仿真系统和初始化系统的区别。
3. **`matchSystem`**：按 §5.2 的六段读。脑子里只放 `ass1`/`ass2` 两个数组，这个函数从头到尾就是在改它们。辅助函数可以先当黑盒：
   - `augment`：Kuhn 增广路径；
   - `addRing`：加环。
4. **`componentItems`**：看 Tearing 怎么认出块里的 HGT 项，注意从这里开始全是局部下标。
5. **`Tearing.traverseComponent`** 中 `is_hgt` 那几行：HGT 块的分流点。
6. **`Tearing.handGuidedTearing`**：按 §6.2 的三段读。因果化部分复用了普通撕裂的工具函数，可以对照 `userDefinedTearing` 看：
   - `traverseCollectiveEqnsforAssignable`
   - `getNextSolvableEqn`
   - `makeAssignment`
   - `markTVarsOrResiduals`
   - `deleteEntriesFromAdjacencyMatrix`
7. **`hgtInnerEquations`**：内部方程和伪根约束。

一个快速入门的办法：先看 `userDefinedTearing`（`--tearingMethod=userDefined` 用的就是它），它是 handGuidedTearing 的原型，结构一样但简单得多。

## 10. 调试方法

| 标志 | 输出 |
|---|---|
| `-d=hgtDump` | 前端读到的 HGT 项；每个系统 matchSystem 之后含 HGT 项的块 |
| `-d=tearingdump` | handGuidedTearing 中的 `debugFlag` 输出：用户项、补的迭代变量、自动残差数（局部下标） |
| `-d=tearingdumpV` | 更详细的撕裂过程 |
| `-d=dumpdaelow`、`-d=optdaedump` | 各阶段的方程和变量，用来把下标对回具体方程 |
| `-d=bltdump` | 匹配和 BLT 块 |

示例：

```bash
cd testsuite/simulation/modelica/tearing
# 把某个 .mos 里的 setCommandLineOptions 改成
#   "--handGuidedTearing -d=hgtDump,tearingdump"
omc HGTPair1.mos
```

推荐按这个顺序看测试例子：

| 测试 | 看点 |
|---|---|
| `HGTPair1` | 单个配对，跨 SCC 合并 |
| `HGTPair2` | 1×1 块 |
| `HGTSystem1` | 系统级配对，跨两个组件 |
| `HGTPlant1`、`HGTAlgebra1` | 自动补全（`auto_rows`、`selectAdditionalTearingVar`） |
| `HGTOnly1` | `--hgtOnly`：不自动补全，解不出就报 8018 |
| `HGTSolve1` | casual 可解性与伪根约束 |
| `HGTInit1` | 只在初始化系统生效的配对 |

## 11. 容易踩的坑

- **配对是占位，不是求解关系**。在 matchSystem 里 e 匹配 x，不代表 e 能解出 x，所以强制配对时不检查可解性。真正的含义由 Tearing 决定。
- **两套邻接矩阵**。匹配用 SOLVABLE，排序和依赖检查用 NORMAL。用错的话，要么增广时走了不可解的边，要么 Tarjan 漏掉依赖，块被拆开。
- **局部下标和全局下标**。`componentItems` 之后全是局部下标。
- **方程和行**。matchSystem 的数组是按标量行的；检查和打印时要用 `map_row_eqn` 换回方程。
- **初始化和仿真各跑一次**。只在仿真系统里出现的错误，先想想是不是被优化删掉了，或者是不是初始方程（§5.1）。
- **可解性是 casual**。handGuidedTearing 按 casual 判断可解性，生成内部方程时再用 strict 判断是否需要伪根约束。修改可解性相关的代码时，两处都要考虑。
- **修改了 `BackendDAE.HGT_SPEC` 或 `SHARED`**，所有构造它们的地方都要同步。`HGT_SPEC` 只在 `findSpec` 里构造。
- **R9 分成两处检查**。块的最外层由 `checkResidualCounts` 检查，内层由 `hgtCheckResidualCount` 检查。改其中一处时，另一处也要看。
