# 手动引导撕裂（HGT）开发者说明

本文按**当前代码**说明 OpenModelica 中手动引导撕裂（Hand Guided Tearing，HGT）的实现，供维护和扩展这部分代码的开发人员阅读。设计动机、与 OCT 规范的对照和分期计划见 [HGT_design.md](HGT_design.md)；两者不一致时以本文和代码为准（差异见 §9）。

文中路径相对于 `OMCompiler/Compiler/`，另有说明的除外。行号只作定位参考，以函数名为准。

## 目录

1. [概览](#1-概览)
2. [注解与选项](#2-注解与选项)
3. [前端（NF）](#3-前端nf)
4. [后端（旧后端）](#4-后端旧后端)
5. [SimCode 与模板](#5-simcode-与模板)
6. [运行时](#6-运行时)
7. [诊断信息一览](#7-诊断信息一览)
8. [测试](#8-测试)
9. [与设计文档的差异、限制和待办](#9-与设计文档的差异限制和待办)
10. [常见改动的入口](#10-常见改动的入口)

---

## 1. 概览

HGT 让用户在模型里指定代数环的**迭代变量**和**残差方程**，编译器先按用户的指定撕裂，再自动补全其余部分。注解语法与 OCT 的 `__Modelon(...)` 一一对应，OMC 的容器注解是 `__OpenModelica_HGT(...)`。与 OCT 一样，只保证稳态模型（无状态变量）。

数据从前端一路传到运行时：

```
Modelica 源码 annotation(__OpenModelica_HGT(...))
   │  AbsynToSCode：保留空修饰（ResidualEquation）、合并多个 tearingPairs
   ▼
NF 展平（NFFlatten + NFHandGuidedTearing）
   │  收集注解、加前缀、给方程打标签 __OpenModelica_HGTEquation="名字"、校验
   │  FlatModel.handGuidedTearing : Option<Spec>
   ▼
NFConvertDAE ──► DAE.HAND_GUIDED_TEARING 元素
   ▼
旧后端 BackendDAECreate ──► HandGuidedTearing.lower
   │  Shared.handGuidedTearing : Option<HGTSpec>；迭代变量不可替换，应用 start/nominal，残差缩放
   ▼
各优化模块：识别带标签的方程，不删除、不改写
   ▼
hgtMatching（post-opt 和 init-opt，在 tearingSystem 之前）
   │  强制配对 → 修复匹配 → 绑定未配对项 → 合并环 → 重算 SCC → 校验
   ▼
Tearing.handGuidedTearing（tearingSystem 内）
   │  固定用户项 → 贪心因果化 → 自动补撕裂变量 → 嵌套层（INNERCOMPONENT）
   │  反函数求解的方程加解检查约束
   ▼
SimCodeUtil：hgtAttributes（min/max）、嵌套 NLS、解检查 assert
   ▼
CodegenC.tpl：sysData->hgtBounds = 1、min/max 写进 NLS 数组
   ▼
运行时（C，以及 C+Rust）：起点投影、Newton 迭代投影、解的越界检查
```

只有 `--handGuidedTearing` 打开时 HGT 才生效。不打开时前端仍会识别注解，但只给一条通知（8008），不产生规范，后续流程完全不变。

**新后端（`--newBackend`）不支持 HGT。** `NSimCode` 只把新增的 `hgtAttributes` 字段设为 `{}` 以通过编译，新后端的撕裂（`NBTearing.mo`）没有 HGT 处理。

## 2. 注解与选项

### 2.1 注解

| 位置 | 字段 | 含义 |
|---|---|---|
| 方程 | `name = id` | 给方程命名，供 `tearingPairs` 引用 |
| 方程 | `ResidualEquation(enabled, level, nominal, hold, iterationVariable(start, min, max, nominal, hold) = v)` | 带 `iterationVariable` 时是组件级配对，否则是未配对残差 |
| 变量声明 | `IterationVariable(enabled, level, start, min, max, nominal, hold)` | 未配对迭代变量 |
| 类 | `tearingPairs(Pair(enabled, level, residualEquation(nominal, hold) = 方程名, iterationVariable(...) = v), ...)` | 系统级配对 |

- `enabled`、`level`、`hold` 必须是参数表达式。`enabled` 和 `level` 在前端求值，并把用到的参数标记为结构参数。
- `start`、`min`、`max`、`nominal` 保留为表达式。level 1 上它们只能依赖参数（错误 8006），level ≥ 2 允许依赖连续变量（OCT 的 R7）。但后端目前**只支持依赖参数的 min/max**，见 §4.7。
- `hold` 会解析、存储，但未实现，给警告 8009 后忽略；字面量 `hold = false` 等同于默认值，不报警告。
- 加了 `--acceptModelonHGT` 后，`__Modelon(...)` 也会读取，但只读其中的 `name`、`ResidualEquation`、`IterationVariable`、`tearingPairs`，其他内容静默忽略。
- `merge_blt_blocks` 和 `allow_multiple_residuals_in_hgt_blocks` 在 OCT 里是编译选项，OMC 也只做成选项（见下表），**不是**注解字段。写在注解里会得到警告 8000（未知字段）。

### 2.2 选项（`Util/Flags.mo`，注册在 `Util/FlagsUtil.mo`）

| 选项 | 编号 | 默认 | 作用 |
|---|---|---|---|
| `--handGuidedTearing` | config 173 | false | 总开关；同时自动启用后端模块 `hgtMatching` |
| `--acceptModelonHGT` | config 174 | false | 也读 `__Modelon` |
| `--hgtMergeBLTBlocks` | config 175 | false | 把所有 HGT 项合并进同一个 BLT 块（OCT `merge_blt_blocks`） |
| `--hgtAllowMultipleResiduals` | config 176 | `level1` | `false`、`level1`、`true`：每个块允许几个残差（OCT 的 R9） |
| `-d=hgtDump` | debug 202 | 关 | 打印前端收集到的规范和后端的分块结果 |

`.cmake/meta_modelica_source_list.cmake` 中登记了 `NFFrontEnd/NFHandGuidedTearing.mo` 和 `BackEnd/HandGuidedTearing.mo` 两个新文件。

## 3. 前端（NF）

主要代码在 `NFFrontEnd/NFHandGuidedTearing.mo`。

### 3.1 数据结构

**NF 内部**（`NFHandGuidedTearing.mo`）

| 类型 | 内容 |
|---|---|
| `IterationVariable.ITERATION_VARIABLE` | `name : ComponentRef`、`level`、`start/min/max/nominal/hold : Option<Expression>`、`info` |
| `ResidualEquation.RESIDUAL_EQUATION` | `name : String`、`level`、`nominal`、`hold`、`iterationVariable : Option<IterationVariable>`（SOME 表示配对）、`info` |
| `Spec.SPEC` | `residuals`（配对的和未配对的）、`iterationVariables`（只含未配对的） |
| `Collector.COLLECTOR` | 展平过程中的累积状态：`enabled`、`acceptModelon`、`found`、嵌套深度 `nested`、已注册的方程名 `equationNames`、组件级残差 `residuals`、待解析的系统级配对 `pairs`、未配对变量 `iterationVariables`、自动命名计数器 `nameIndex` |

常量：`ANNOTATION_NAME = "__OpenModelica_HGT"`、`MODELON_ANNOTATION_NAME = "__Modelon"`、`EQUATION_TAG = "__OpenModelica_HGTEquation"`。

**DAE 层**（`FrontEnd/DAE.mo`）：结构与上面对应，但用 DAE 的类型。

- `DAE.Element.HAND_GUIDED_TEARING(residuals, iterationVariables)`
- `HGTResidual.HGT_RESIDUAL(name, level, nominal, hold, iterationVariable, info)`
- `HGTIterationVariable.HGT_ITERATION_VARIABLE(name, level, start, min, max, nominal, hold, info)`

`DAEUtil` 的遍历函数和拆分函数会跳过这个元素。

**挂载位置**

- `NFFlatModel.FLAT_MODEL` 最后新增字段 `Option<HandGuidedTearing.Spec> handGuidedTearing`。
- `NFFlatten.FlattenSettings.SETTINGS` 新增 `hgt : Collector`。
- `NFConvertDAE.convertModel` 在规范存在时，用 `Spec.toDAE` 生成元素，放到 `DAE.COMP` 元素列表的最前面。

### 3.2 AbsynToSCode 的两处改动（`FrontEnd/AbsynToSCode.mo`）

1. **保留空修饰。** 正常情况下，空修饰（比如单独写的 `ResidualEquation`）在 SCode 转换时会被丢掉。`translateArgs` 现在对 `__OpenModelica_HGT` 和 `__Modelon`（由 `isHGTAnnotationPath` 判断）往下传 `keepEmpty`，所以单独写的 `ResidualEquation` 和 `IterationVariable` 能保留下来。
2. **合并多个 `tearingPairs`。** 一个类可以有多个 `annotation(...)` 子句，原来的合并逻辑只保留最后一个 `tearingPairs`。`translateCommentList` 现在在 `AbsynUtil.mergeAnnotationsList` 之后调用 `mergeHGTTearingPairs`，按源码顺序把所有 `Pair` 拼接起来；两个厂商名分开处理。

### 3.3 收集：在展平阶段完成

注解在**展平**时收集，不在实例化时收集。这时组件前缀已知，表达式也能求值。

| 对象 | 调用位置（NFFlatten.mo） | 处理函数 |
|---|---|---|
| 类 | `flattenClass`，`INSTANCED_CLASS` 分支，经 `collectHGTClass` | `collectClass`：只读 `tearingPairs`，配对先存进 `collector.pairs` |
| 变量 | `flattenSimpleComponent`（注释里有注解时） | `collectVariable`：读 `IterationVariable` |
| 方程 | `flattenEquations`，`EQUALITY` 分支（先用 `hasAnnotation` 快速判断） | `collectEquation`：读 `name` 和 `ResidualEquation`，返回打了标签的 source |
| for、when | 在 `enterNested` 和 `leaveNested` 之间 | 嵌套内的注解不收集，最外层报一次警告 8007 |
| if | `flattenIfEquation` 按分支处理 | 条件被求值为真、分支直接替代整个 if 方程时（例如由参数选中的稳态分支），注解照常收集；仍保留在 if 方程里的分支经 `flattenIfBranch`（`enterNestedEquations`）跳过并报警告 8007 |
| 展平结束 | `flatModel.handGuidedTearing := HandGuidedTearing.finish(settings.hgt)` | 见 §3.5 |

**前缀**

- 方程名按字符串加前缀：`prefixName(prefix, name)` 得到 `prefix.name`，例如 `mixer.dx`、`ba[2].res`。
- 迭代变量和属性表达式在注解所在的作用域里处理：先 `Inst.instExp` 实例化，再 `Typing.typeExp` 定型，最后通过 `flattenFn` 回调（也就是 NFFlatten 的 `flattenExp`）加前缀。

**给方程打标签**

- 带 `name` 的方程用这个名字。没有名字的残差方程自动命名为 `prefix.$hgtN`，N 是整个模型共用的计数器，从 1 开始。
- 名字在 `equationNames` 中注册，重名是错误 8003。
- 方程的 `ElementSource` 里会追加一条注释 `annotation(__OpenModelica_HGTEquation = "<名字>")`（`makeEquationTag`、`ElementSource.addCommentToSource`）。
- **后端只靠这个标签识别 HGT 方程。** 后端 `BackEnd/HandGuidedTearing.mo` 里也定义了同名常量 `EQUATION_TAG`，改名时两处都要改。

**多个注解子句的合并规则**

- 方程：后出现的 `name` 或 `ResidualEquation` 覆盖先出现的。
- 变量：每个 `IterationVariable` 都会收集，重复就是错误 8005。
- 类：`tearingPairs` 已在 AbsynToSCode 中合并（§3.2）。
- `__OpenModelica_HGT` 和 `__Modelon` 可以混用。

### 3.4 各字段的解析函数

| 函数 | 作用 |
|---|---|
| `getHGTMods` | 取出元素上所有 HGT 注解（`__Modelon` 只在 `acceptModelon` 时读取） |
| `parseResidualEquation` | 解析 `ResidualEquation(...)`，可带 `iterationVariable` 形成配对 |
| `parsePair` | 解析 `Pair(...)`；`residualEquation = 名字` 通过 `Dump.printComponentRefStr` 取文本 |
| `parsePairedIterationVariable`、`parseUnpairedIterationVariable` | 解析两种迭代变量写法；配对里的变量继承所在记录的 level |
| `resolveIterationVariable` | 实例化变量引用，检查它是标量 Real 的连续变量（错误 8002） |
| `parseRealAttribute` | 解析 start/min/max/nominal：Integer 转成 Real，level 1 上不许依赖连续变量（8006）；编译期能求值的 nominal 必须为正（`checkPositive`，8001），否则缩放时会除以 0 |
| `evalBoolean`、`evalLevel`、`evalParameterExp` | 求值 `enabled` 和 `level`（level ≥ 1），用 `Structural.markExp` 把相关参数标为结构参数 |
| `parseHold` | 解析 hold（目前只存储） |
| `checkFields`、`lookupFields` | 遇到未知字段报警告 8000 |

不支持的情况都是给警告、丢弃该项，然后继续：非标量 Real 的方程或变量（8007），for/when 内以及仍保留下来的 if 分支内的注解（8007）。

### 3.5 `finish` 与 `checkEquations`

`finish`（展平结束时调用）：

1. 如果 HGT 没打开但找到了注解：给通知 8008，返回 NONE()。
2. 解析系统级配对：引用的方程名必须已注册（否则错误 8004）；`checkUniqueEquation` 保证一个方程最多只有一个 HGT 规范（8005）。
3. 残差按名字排序。
4. `checkUniqueVariable`：一个变量在配对和未配对中合起来只能出现一次（8005）。
5. 有 hold 且不是字面量 `false` 时给警告 8009（`isHeld`）。
6. 打开 `-d=hgtDump` 时，用 `Spec.toString` 打印规范，以 `Hand guided tearing:` 开头。
7. 规范为空时返回 NONE()。

`checkEquations`（在 `NFInst.mo` 中，标量化之后调用）检查每个残差标签在方程和初始方程中恰好出现一次。不是一次就报错误 8010（被前端化简删掉了或复制了）。

**注意：** `tearingPairs` 不会从基类继承，`collectClass` 只读类自己的定义。这是已知限制，暂不处理。

## 4. 后端（旧后端）

主要代码在 `BackEnd/HandGuidedTearing.mo` 和 `BackEnd/Tearing.mo`。

### 4.1 数据进入后端

- `BackendDAE.Shared.SHARED` 最后新增字段 `Option<HGTSpec> handGuidedTearing`，其中 `HGTSpec.HGT_SPEC(residuals, iterationVariables, initialResiduals)` 的前两项直接复用 DAE 的记录，`initialResiduals` 是写在 initial equation 里的残差方程名。
- `BackendDAECreate.lower` 在 `lower2` 之后调用 `HandGuidedTearing.lower(elems, varlst, eqns, ieqns)`；`lower2` 遇到 `DAE.HAND_GUIDED_TEARING` 直接跳过。
- 初始化系统在 `Initialization.mo` 中用 `BackendDAEUtil.setSharedHandGuidedTearing` 复制这个规范。
- `HandGuidedTearing.lower` 做四件事：
  1. `findSpec` 找到规范元素（会递归进 `DAE.COMP`）。
  2. 对所有迭代变量（配对的和未配对的）调用 `lowerVariable`：设为不可替换（`setVarUnreplaceable`），有 start 或 nominal 就写进变量属性。
  3. 对带 nominal 的残差方程调用 `scaleResidual`，把 `lhs = rhs` 改写成 `0 = (lhs - rhs)/nominal`。这对 `eqns` 和 `ieqns` 都做。
  4. 记下 `ieqns` 中带标签的方程名，存进 `initialResiduals`。仿真 DAE 在后优化之前就清空了 `shared.initialEqs`（`Initialization.removeInitializationStuff`），所以只能在这里记。
- 识别 HGT 方程只靠 §3.3 的标签：
  - `equationName` 从方程 source 的注释中读出 `__OpenModelica_HGTEquation`；
  - `isTaggedEquation`、`anyTaggedEquation` 在它的基础上实现；
  - `isActive(shared)` 等价于 `isSome(shared.handGuidedTearing)`。

### 4.2 优化模块中的保护

HGT 方程必须原样保留到撕裂阶段，迭代变量也不能被消掉。下表列出每个模块的处理方式：

| 模块 | 位置 | 处理 |
|---|---|---|
| removeSimpleEquations | `RemoveSimpleEquations.simpleEquationsFinder` | 带标签的方程不算简单方程；迭代变量本身已设为不可替换 |
| resolveLoops | `ResolveLoops.getSimpleEquations` | 跳过带标签的方程 |
| solveSimpleEquations | `ExpressionSolve.mo` | 带标签的方程保持残差形式 |
| constantLinearSystem | `SymbolicJacobian.constantLinearSystemWork` | 含带标签方程的块原样返回 |
| wrapFunctionCalls | `CommonSubExpression.mo` | HGT 打开且系统中有带标签方程时，跳过第 2 阶段及以后（这些阶段重建方程会丢掉标签） |
| comSubExp | `CommonSubExpression.commonSubExpression` | 同上，整个系统跳过 |

兜底检查是 `hgtMatching` 中的 `checkPresence`（§4.3）。removeEqualRHS 没有单独保护，被它改掉的方程只能由这个兜底检查发现。

**新增优化模块时**，只要它可能删除、合并或改写方程，就要用 `HandGuidedTearing.isTaggedEquation` 跳过带标签的方程，或者保证改写后标签仍然保留。

### 4.3 `hgtMatching` 模块

> §4.3–§4.5 的逐段讲解、例子和读代码顺序见 [HGT_matching_and_tearing.md](HGT_matching_and_tearing.md)。

**注册**（`BackendDAEUtil.mo`）：放在 `allPostOptimizationModules` 和 `allInitOptimizationModules` 里，紧挨在 `tearingSystem` 之前。打开 `--handGuidedTearing` 时，`getPostOptModules` 和 `getInitOptModules` 会自动启用它，不需要用户再加 `--postOptModules+=`。`causalizeDAE` 只会重新匹配状态为 `NO_MATCHING` 的系统，所以这里写入的匹配能一直保留到 `tearingSystem`。

**入口** `hgtMatching`：

- HGT 不活跃时直接返回。
- 对仿真系统（`isSimulationDAE`）先调用 `simulationSpec`，去掉只属于初始化系统的项，并写回仿真 DAE 的 `shared`（Tearing 读的就是它）：
  - `initialResiduals` 中的残差方程，连同与它配对的迭代变量；
  - 某个 level 上的未配对残差全是初始方程时，这个 level 的未配对迭代变量。
- 然后只对仿真系统调用 `checkPresence`：
  - 统计所有系统的 `orderedEqs` 中各标签出现的次数，不是 1 次就报错误 8011；
  - 迭代变量不在任何系统里，报错误 8012；
  - 模型有状态变量时，给警告 8017（只保证稳态）。
- 然后对每个 EqSystem 调用 `matchSystem`。

**`matchSystem` 的步骤**

1. **定位 HGT 项**（`indexTags`、`varIndex`）。配对的方程和变量都在本系统中时才算这个系统的配对；只有一边在时报错误 8013。未配对项连同 level 一起收集。本系统没有 HGT 项就直接返回。
2. **R5 检查**（`checkUnpairedCounts`）：每个 level 上，未配对残差和未配对变量的个数必须相等，否则报错误 8014。
3. **建标量邻接矩阵**：匹配用 SOLVABLE 矩阵，排序用 NORMAL 矩阵。如果长度对得上，就从现有的 `syst.matching.ass2` 出发。
4. **释放并锁定 HGT 项**（`markVar`、`markRow`）：取消所有 HGT 变量和行的现有匹配，并标记为锁定。
5. **强制配对**（`assign`）：不检查可解性，这对应 OCT 的 R1（先撕用户指定的对）。
6. **修复匹配**（`augment`）：对每个未匹配的非 HGT 行，在 SOLVABLE 矩阵上找增广路径，绕开锁定的行和变量。
7. **绑定未配对项**（`bindUnpaired`、`dependentRows`、`bindAugment`）：
   - 对每个未配对变量，用 BFS 沿当前匹配找出直接或间接依赖它、且 level 相同的未配对残差行；
   - 再做二分增广匹配；
   - 绑不上的报错误 8015。
8. **剩余项**：仍然空着的行和变量任意配对，记为 `auto_rows`，撕裂时会成为自动补充的残差和迭代变量。个数不等时报内部错误 "the system is not square"。
9. **合并成环**（`addRing`）：只要存在 `auto_rows`，或打开了 `--hgtMergeBLTBlocks`，就把 `auto_rows` 和所有 HGT 行（各 level）串成一个人工依赖环：row[i] 依赖 row[i+1] 所匹配的变量。这样 Tarjan 会把这些行以及它们之间路径上的所有块并成一个 SCC。至少要有 2 行，而且只能合并同一个 EqSystem 内的块。
10. **重算 SCC**：`setAdjacencyAndMatching` 写回矩阵和匹配，然后调用 `BackendDAETransform.strongComponentsScalar`。
11. **校验**：
    - `checkDependence`：每个配对或绑定所在的 SCC 中，必须有方程用到对应的迭代变量，否则报错误 8016。
    - `checkResidualCounts`（R9）：按 `--hgtAllowMultipleResiduals` 统计每个块、每个 level 的用户残差数。值为 `false` 时任何块超过 1 个就报错；值为 `level1` 时 level > 1 的块超过 1 个才报错。错误号 8021。
12. **打开 `-d=hgtDump` 时**（`dumpComponents`）打印：
    ```
    Hand guided tearing matching (simulation system):
      block of N equations: residual equations {...}, iteration variables {...}
      K equations could not be matched and are torn automatically
    ```

### 4.4 `Tearing.handGuidedTearing`

**入口**：在 `Tearing.traverseComponent` 中，先于普通撕裂执行。

- 调用 `HandGuidedTearing.componentItems`，得到组件内 HGT 变量和方程的局部位置及 level。组件类型可以是 `EQUATIONSYSTEM` 或 `SINGLEEQUATION`。
- 如果是 HGT 组件，就调用 `handGuidedTearing(..., componentPairs(...))`，并设置 `outRunMatching := true`。
- 因此这类组件绕过了 `checkTearingSettings`、`tearingPaysOff` 和失败后回退到普通撕裂的逻辑。1×1 的 `SINGLEEQUATION` 也会变成 1×1 的撕裂系统。

**步骤**

1. **建子系统**，写法与 userDefinedTearing 相同：
   - NORMAL 标量邻接矩阵（删除负项）；
   - 增强矩阵用 `getAdjacencyMatrixEnhancedScalar(subsyst, shared, true)`，其中 `trytosolve=true` 表示按 **casual** 可解性判断，**与全局 `--tearingStrictness` 无关**。这样用户的选择才能生效：例如 `m = k*sqrt(pa - pb)` 可以反解出 `pa`。
2. **按 level 拆分**（`hgtSplitLevel`）：最低 level 的项是本层，其余是嵌套项（§4.5）。
3. **固定用户项**：在 `ass1`、`ass2` 中标记本层的迭代变量和残差行，嵌套组的行也一并标记；在矩阵副本中删去对应的行和列。
4. **贪心因果化**：反复取下一个可解的方程（`getNextSolvableEqn`）并赋值（`makeAssignment`），直到卡住。卡住时，如果某个嵌套组 k 的所有行只剩组内变量没有赋值（`hgtOnlyGroupVars`），就把整组一起赋值，在次序中记为 `-k`，然后继续。
5. **自动补撕裂变量**（`selectAdditionalTearingVar`）：
   - 还有变量没赋值时，从"未赋值且不属于嵌套组"的变量中，选出现在最多未赋值方程里的非离散变量，加入撕裂变量后重新执行第 4 步。
   - 没有候选变量，或者只剩离散变量时，报错误 8020。
6. **组装结果**：
   - 残差 = 用户残差 ∪ 剩下没赋值的行；
   - 残差数必须等于撕裂变量数（否则报 8020）；
   - 结果是 `TORNSYSTEM(TEARINGSET(tvars, residuals, innerEquations, EMPTY_JACOBIAN()), NONE(), linear and 没有嵌套组, mixed)`。
7. **内部方程与解检查**（`hgtInnerEquations`）：
   - 计算一次 **strict** 可解性：先用 `FlagsUtil.setConfigString` 把 `TEARING_STRICTNESS` 临时改成 `"strict"`，因为 `tryToSolveOrDerive` 读的是这个全局选项；算完恢复原值，出错时也恢复。
   - 对于"strict 下不可解、但 casual 下被解出"的单行方程 `lhs = rhs`（即通过反解 sqrt、log 等非线性函数求出变量），生成 `INNEREQUATIONCONSTRAINTS`，约束为：
     ```
     abs(lhs - rhs) <= 1e-8 * (abs(lhs) + abs(rhs) + 1.0)
     ```
     作用是在迭代中丢弃反函数分支选错的点，例如 HGTSolve1 中 m < 0 的伪根。
   - 次序中的 `-k` 替换成 `nestedComps[k]`。

**`-d=tearingdump` 的输出**：

```
Tearing type: hand guided (level L)
User iteration variables (local): ...
User residual equations (local): ...
Additional iteration variable (local): ...   （每补一个打印一行）
Iteration variables (local): ...
Residual equations (local): ...
Nested blocks: N
Automatically added: K
```

### 4.5 嵌套层（level ≥ 2）

level 更高的项会在外层块的内部构成一个**嵌套的撕裂系统**。外层每计算一次残差，都要先求解一次内层的非线性方程组。

- **前提**：组件中所有方程都是标量方程，否则报 8020（"nested levels are only supported for scalar equations"）。
- **`hgtNestedGroups`** 计算嵌套组：
  - 去掉外层的行和变量；
  - 强制嵌套层的配对；
  - 用 `hgtAugment` 把嵌套层的未配对行匹配给嵌套层的未配对变量；
  - 其余内部行匹配到允许的内部变量，匹配失败报 8020（结构奇异）；
  - 用 `hgtTarjan` 对内部行求 SCC，每个包含嵌套项的 SCC 就是一个组；同一 level 中互不相连的部分会成为不同的组。
- **`hgtNestedComponent`**：为每个组建一个 `EQUATIONSYSTEM`，把用户项、level 和配对换算成块内的局部位置，然后**递归**调用 `handGuidedTearing`（level 为组内最低的 level）。结果包装成 `BackendDAE.InnerEquation.INNERCOMPONENT(comp)`，`comp` 总是 TORNSYSTEM。

**其他模块如何处理 `INNERCOMPONENT`**

- `BackendDAEUtil.flattenInnerEquations`：递归地把 `INNERCOMPONENT` 展开成内部方程，加上 `INNEREQUATION(残差, {tvar})`。下面这些地方只需要"所有方程和变量"，都改成先调用它：
  - BackendDAEOptimize、BackendDAETransform、BackendDAEUtil
  - BackendDump、XMLDump
  - HpcOmEqSystems、HpcOmTaskGraph
  - RemoveSimpleEquations
  - SymbolicJacobian
  - `getEqnAndVarsFromInnerEquationLst`
- `hasInnerComponent`、`isNestedTornSystem`：判断函数，用法如下。
- `SymbolicJacobian.calculateTearingSetJacobian`：有嵌套组件时返回 `EMPTY_JACOBIAN()`，改用数值 Jacobian。
- `Tearing.recursiveTearingMain`、`BackendDAEOptimize.hetsWork`：跳过嵌套撕裂系统。
- HpcOm 和 OMSI 不支持嵌套层。

**新增需要遍历 `innerEquations` 的代码时**，要么先 `flattenInnerEquations`，要么显式处理 `INNERCOMPONENT`。不处理的话，`match` 遇到这个新记录会失败。

### 4.6 HandGuidedTearing.mo 函数速查

| 公开函数 | 作用 |
|---|---|
| `lower` | 读入规范，保护迭代变量，应用 start/nominal，缩放残差 |
| `iterationVariableBounds` | 只依赖参数的 min/max，供 SimCode 使用 |
| `isActive`、`equationName`、`isTaggedEquation`、`anyTaggedEquation` | 判断 HGT 是否活跃、读取方程标签 |
| `hgtMatching` | 后端优化模块（§4.3） |
| `componentItems`、`componentPairs` | 组件内的 HGT 项和配对，以局部位置表示，供 Tearing 使用 |

内部函数：

- 匹配相关：`matchSystem`、`markVar`/`markRow`、`assign`、`augment`、`bindUnpaired`、`dependentRows`、`bindAugment`、`addRing`、`setAdjacencyAndMatching`
- 检查相关：`checkPresence`、`checkUnpairedCounts`、`checkDependence`、`checkResidualCounts`、`checkBound`
- 输出：`dumpComponents`

### 4.7 迭代变量的 min/max

- `iterationVariableBounds(shared)` 返回每个带 min 或 max 的迭代变量 `(cref, min, max)`。
- `checkBound` 只保留**只依赖** `shared.globalKnownVars`（参数和常量）的界；依赖其他变量的界给警告 8019 后丢弃。也就是说，自适应界（B2.3）还没实现。
- 界**不写进**变量的 min/max 属性，以免生成范围检查 assert。它们只在非线性求解器里使用（§5、§6）。

## 5. SimCode 与模板

### 5.1 数据

- `SimCode.SIMCODE` 新增字段 `list<HGTAttribute> hgtAttributes`，其中 `HGTAttribute.HGT_ATTRIBUTE(cref, Option<DAE.Exp> min, Option<DAE.Exp> max)`。
- 旧后端路径中由 `SimCodeUtil.createHGTAttributes(dlow.shared)` 生成，数据来自 §4.7。`SimCodeMain` 的另一条路径和 `NSimCode.convert` 都把它设为 `{}`。
- `SimCodeUtil.getHGTBound(simCode, cref, isMin)` 按 cref 线性查找，在 `Template/SimCodeTV.mo` 中声明，供模板调用。

### 5.2 嵌套 NLS

`SimCodeUtil.createTornSystemInnerEqns` 遇到 `INNERCOMPONENT`（由 `isInnerComponent` 判断）时，会对内部组件调用 `createEquationsWork`，得到一个 `SES_NONLINEAR`，并把它作为外层系统的内部方程。

因此内层 NLS 是在外层残差函数里求解的，可以一层套一层，三层的例子见 HGTLevel2。这依赖于已有的"残差函数内嵌套 NLS"支持（#15433）。

### 5.3 解检查 assert

`createTornSystemInnerEqns` 新增输入参数 `dynamicTearingSet`（默认 false）。

- 动态撕裂的 casual 集合会传 `true`，这时约束仍按原来的方式由动态撕裂检查。
- 其他情况下，带约束的方程按无约束的方式生成，**紧接着**插入一个 `SES_ALGORITHM`，内容是 `constraintAssert` 生成的 assert（`ASSERTIONLEVEL_ERROR`）：

```
assert(abs(lhs - rhs) <= 1e-8 * (abs(lhs) + abs(rhs) + 1.0),
  "The equation ... is not satisfied after solving it for <var> (hand guided tearing). The iteration variables are probably outside of the range of the inverted function.");
```

这个 assert 在残差函数内执行。失败时由求解器已有的 `MMC_TRY` 机制捕获，相当于拒绝当前这个迭代点。

### 5.4 C 模板（`Template/CodegenC.tpl`，`generateStaticInitialData`）

对实数迭代变量，如果 `getHGTBound` 返回了 min 或 max，生成：

```c
/* static nls data for <cr> */
{
  sysData->hgtBounds = 1;
  sysData->nominal[i] = getNominalFromScalarIdx(...);
  sysData->min[i]     = <HGT min，或变量自身的 min>;
  sysData->max[i++]   = <HGT max，或变量自身的 max>;
}
```

只要系统中有一个迭代变量带 HGT 界，整个系统就会设置 `hgtBounds = 1`。HGT 界只替换 NLS 数组 `sysData->min`、`sysData->max` 中的值，不影响变量本身。

## 6. 运行时

### 6.1 C 运行时（`OMCompiler/SimulationRuntime/c/`）

| 位置 | 行为 |
|---|---|
| `simulation_data.h` | `NONLINEAR_SYSTEM_DATA` 中 `nominal` 之后新增 `modelica_boolean hgtBounds` |
| `nonlinearSystem.c`，`initializeNonlinearSystemData` | 调用 `initializeStaticNLSData` 之前先置 `hgtBounds = 0`，再由生成代码设置 |
| `nonlinearSystem.c`，`solve_nonlinear_system` | 取得初始猜测后，`hgtBounds` 为真时把 `nlsx` 投影到 [min, max]；对所有求解器都生效 |
| `nonlinearSolverHomotopy.c` | `projectToBounds`：在 `newtonAlgorithm` 的 4 处候选迭代点（全步长、λ1、λ2、λ）之后各投影一次；`xStart` 也投影 |
| `nonlinearSystem.c`，`checkHGTBounds`（在 `solveNLS` 末尾调用） | 任何求解器成功后检查解：容差 `1e-8*max(1,|nominal|)`，越界时警告并改判为 `NLS_FAILED` |

越界警告（`OMC_LOG_STDOUT`）：

```
Non-linear system <n>: the solution <var> = <x> is outside of the hand guided tearing bounds [<min>, <max>], the system is not solved.
```

各求解器的覆盖情况：

| 求解器 | 起点投影 | 迭代投影 | 解的检查 |
|---|---|---|---|
| homotopy，以及 mixed 中的 homotopy 部分 | ✓ | ✓ | ✓ |
| newton、hybrd、kinsol | ✓ | ✗ | ✓ |

hybrd 回退得到的越界解会被拒绝，见 HGTNetwork1 中 `m_set = 8` 的用例。

### 6.2 Rust 运行时（`--simCodeTarget=C+Rust`，可选）

`--simCodeTarget=C+Rust` 生成的 C 代码与 C 目标相同，只是链接 `libSimulationRuntimeRust`（CMake 选项 `OM_ENABLE_RUST_SIM_RUNTIME`，默认关闭）。该运行时已与 C 运行时保持同样的行为：

| 位置 | 行为 |
|---|---|
| `rust/openmodelica_simulation_runtime/src/abi.rs` | `NONLINEAR_SYSTEM_DATA` 镜像中，`nominal` 之后加 `hgtBounds` |
| `rust/openmodelica_simulation_runtime/src/nls.rs` | 初始化时置 `hgtBounds = 0`；把 `hgt_bounds` 传给求解器；求解后由 `hgt_bounds_hold` 检查解，警告文字与 C 相同 |
| `rust/openmodelica_nls/src/lib.rs` | `NlsSpec.hgt_bounds`；在 `solve_nls` 中投影起点（`guess` 和 `nlsx_old`）；`newton_c` 的 4 处更新之后投影 |
| `Compiler/OpenModelica.rs/openmodelica_codegen_wasm_jit_runtime/src/nls.rs` | `hgt_bounds: false`，即 wasm-jit 不支持 HGT 界 |

**修改 `simulation_data.h` 中任何结构体时，必须同步修改 `abi.rs`。** 否则 Rust 运行时读取的字段偏移会整体错位。`rust/openmodelica_simulation_runtime/tests/abi_layout.rs` 会对比两边的布局：

```bash
cd OMCompiler/SimulationRuntime/rust
OMC_SIMRT_INCLUDE_DIRS="$PWD/../c|$PWD/../../3rdParty/gc/include" \
  cargo test --release -p openmodelica_simulation_runtime --test abi_layout
```

## 7. 诊断信息一览（`Util/Error.mo`）

**前端（TRANSLATION）**

| 编号 | 级别 | 含义 |
|---|---|---|
| 8000 | 警告 | 注解中有未知字段 |
| 8001 | 错误 | 字段值不合法（名字、level、enabled、hold、类型、Pair 缺少某一边等） |
| 8002 | 错误 | 不能作为迭代变量（不是连续变量、不是变量、不是标量 Real） |
| 8003 | 错误 | 方程重名 |
| 8004 | 错误 | 配对引用的方程名不存在 |
| 8005 | 错误 | 同一方程或变量有多个 HGT 规范 |
| 8006 | 错误 | level 1 上的属性依赖连续变量 |
| 8007 | 警告 | 不支持的情况，已忽略（非标量、for/if/when 内） |
| 8008 | 通知 | 有注解但没打开 `--handGuidedTearing` |
| 8009 | 警告 | hold 未实现，已忽略 |
| 8010 | 错误 | 前端化简删除或复制了带标签的方程 |

**后端（SYMBOLIC）**

| 编号 | 级别 | 含义 |
|---|---|---|
| 8011 | 错误 | 后端优化删除或复制了带标签的方程 |
| 8012 | 错误 | 迭代变量被消去 |
| 8013 | 错误 | 配对的两边不在同一个独立方程系统中 |
| 8014 | 错误 | 某个 level 上未配对残差数与未配对变量数不等（R5） |
| 8015 | 错误 | 未配对变量绑不到同一 level 的未配对残差 |
| 8016 | 错误 | 残差方程不依赖它的迭代变量 |
| 8017 | 警告 | 模型有状态变量（只保证稳态） |
| 8019 | 警告 | min/max 依赖变量（自适应界未实现），已忽略 |
| 8020 | 错误 | HGT 撕裂失败，附原因 |
| 8021 | 错误 | 块中残差数超过 `--hgtAllowMultipleResiduals` 的限制（R9） |

## 8. 测试

**前端**：`testsuite/flattening/modelica/scodeinst/HGT*.mo`（已加入 Makefile）

| 测试 | 覆盖内容 |
|---|---|
| HGTComponentPair1 | 组件级配对：自动命名 `$hgt1`、带名字的配对、各属性，以及只有 name 的方程 |
| HGTDisabled1 | 没打开开关时给通知 8008 |
| HGTError1 | 参数作迭代变量（8002） |
| HGTError2 | Pair 引用的方程名不存在（8004） |
| HGTError3 | 方程重名（8003） |
| HGTError4 | level 1 上的 max 依赖连续变量（8006） |
| HGTError5 | 同一变量既配对又未配对（8005） |
| HGTError6 | `level = 0`（8001），未知字段（8000） |
| HGTError7 | 残差的 `nominal = 0`（8001） |
| HGTError8 | 迭代变量的 nominal 由值为负的参数给出（8001） |
| HGTLevel1 | level 由参数给出（变成结构参数）；level 2 上允许依赖连续变量 |
| HGTModelon1 | `--acceptModelonHGT`、hold 警告、忽略其他 `__Modelon` 内容 |
| HGTIf1 | 由参数选中的 if 分支中的注解（`__Modelon`、`hold = false` 不报警告）；保留下来的 if 分支中的注解被忽略（8007） |
| HGTNotSupported1 | 数组、for 循环（8007）；基类中的 `tearingPairs` 不继承 |
| HGTSystemPair1 | 跨组件的系统级配对，分写在两个注解子句中（合并）；数组组件 `ba[2].res` |
| HGTUnpaired1 | 子模型中的未配对项，名字带前缀 |

**仿真**：`testsuite/simulation/modelica/tearing/HGT*.mos`（模型在 `HGT.mo`、`HGTAlgebra.mo`、`HGTNetwork.mo`、`HGTPlant.mo`）

| 测试 | 覆盖内容 |
|---|---|
| HGTPair1 | 跨 SCC 的配对；环内配对加残差 nominal |
| HGTPair2 | 1×1 块；本会被 removeSimpleEquations 删掉的别名方程 |
| HGTSystem1 | 系统级配对；未配对项 |
| HGTError1 | 配对两边不在同一系统（8013）；未配对个数不等（8014） |
| HGTSolve1 | casual 可解性；解检查拒绝负初值下的伪根；与 `--tearingStrictness` 无关 |
| HGTBounds1 | max 界防止 log 的参数为负；多残差块；`--hgtAllowMultipleResiduals=false`（8021） |
| HGTLevel1 | OCT 文档中的 NonConvex 例子，嵌套 level 2；带状态模型给警告 8017 |
| HGTLevel2 | 三层嵌套 |
| HGTNetwork1 | 泵网络：组件级和系统级配对、设计目标、界；`m_set = 8` 时越界解被拒绝 |
| HGTPlant1 | 热工水力例子：`__Modelon` 语法、两个块、自动补全、`enabled = false`、各属性 |
| HGTAlgebra1 | 纯代数：多根选根、反问题、带界的未配对变量、自动补撕裂变量 |
| HGTIf1 | OCT 风格的稳态开关：参数 `isSteadyState` 选中带 HGT 注解的稳态分支 |
| HGTInit1 | initial equation 上的配对只用于初始化系统，仿真系统中没有这个配对 |

运行（需要先装好 omc）：

```bash
cd testsuite/simulation/modelica/tearing && ../../../rtest -v HGT*.mos
cd testsuite/flattening/modelica/scodeinst && ../../../rtest -v HGT*.mo
```

打开 `-d=hgtDump,tearingdump` 可以看到前端规范、`hgtMatching` 的分块和每个块的撕裂过程，排查问题时先看这几项。

## 9. 与设计文档的差异、限制和待办

**实现与 `HGT_design.md` §8 的差异**

- 函数改了名：`isProtectedEquation` → `isTaggedEquation`，`setSharedHGT` → `setSharedHandGuidedTearing`，`hgtTearing` → `Tearing.handGuidedTearing`。
- 残差 nominal 在 lower 阶段就改写成方程，没有等到撕裂时再处理。
- 剩余的子环不用 Cellier 撕裂，而是用贪心法补撕裂变量。
- 绑定未配对项用的是沿当前匹配的 BFS，没有用 `Sorting.Tarjan`。
- 只要存在 `auto_rows`，所有 HGT 行（各 level）都会合并成环，不只在 `--hgtMergeBLTBlocks` 打开时才这样做。

**已知限制**

- 只保证稳态模型；有状态时只给警告 8017。
- 新后端不支持。
- for/when 内的注解、运行时才能决定的 if 分支内的注解、数组方程和数组变量都不支持（由参数选中的 if 分支支持）。
- `tearingPairs` 不从基类继承。
- 只能合并同一个 EqSystem 内的块。
- 嵌套层要求组件中都是标量方程；HpcOm 和 OMSI 不支持嵌套层。
- 只有 homotopy 求解器会把 Newton 迭代点投影到界内，其他求解器只做起点投影和解的检查。

**未实现**

- 自适应属性（level ≥ 2 上依赖变量的 min/max/start/nominal，B2.3）：目前给警告 8019 后忽略。
- hold（R10）及交互式 FMU：目前给警告 8009 后忽略。
- 稳态专用求解路径：已决定暂不做。

## 10. 常见改动的入口

| 想做的事 | 从哪里改 |
|---|---|
| 新增注解字段 | `NFHandGuidedTearing.mo`：`parse*` 函数和字段白名单 `checkFields`；DAE 记录（`DAE.mo`）；`toDAE` |
| 新增前端校验或错误 | `NFHandGuidedTearing.finish` 和 `parse*` 函数；`Error.mo` 中 HGT 号段 8000–8021 之后的空号（8022 起；HGT 的错误号放在 8000 号段，以免和官方按顺序新增的错误号冲突） |
| 新增保护（新的优化模块） | 该模块中调用 `HandGuidedTearing.isTaggedEquation` 或 `anyTaggedEquation` |
| 改变分块规则 | `HandGuidedTearing.matchSystem` |
| 改变块内撕裂 | `Tearing.handGuidedTearing`、`hgtInnerEquations` |
| 实现自适应属性 | `HandGuidedTearing.checkBound` → `SimCodeUtil.createHGTAttributes` → `CodegenC.tpl` 中 min/max 的计算位置（需要在每次求解前重新计算） |
| 实现 hold | 前端已经存储了 hold；后端可以把被 hold 的残差替换成 `x - 固定值`（设计讨论见 HGT_design.md） |
| 修改运行时求解行为 | C：`nonlinearSystem.c`、`nonlinearSolverHomotopy.c`；Rust：`openmodelica_simulation_runtime/src/nls.rs`、`openmodelica_nls/src/lib.rs`，两边要保持一致 |
