# HGT 前端导读

本文讲解手动引导撕裂（HGT）在新前端（NF）中的实现：注解怎样从源码走到 `DAE.HAND_GUIDED_TEARING`，每个函数做什么，读代码从哪里入手，以及改代码时要注意什么。

- 主要代码：`OMCompiler/Compiler/NFFrontEnd/NFHandGuidedTearing.mo`（约 1300 行）
- 调用方：`NFFlatten.mo`、`NFInst.mo`、`NFConvertDAE.mo`、`FrontEnd/AbsynToSCode.mo`
- 后端部分见 [HGT_matching_and_tearing.md](HGT_matching_and_tearing.md)，整体说明见 [HGT_developer_guide.md](HGT_developer_guide.md)

## 目录

1. [一句话概括](#1-一句话概括)
2. [在前端流水线中的位置](#2-在前端流水线中的位置)
3. [注解语法与数据结构](#3-注解语法与数据结构)
4. [三个收集入口](#4-三个收集入口)
5. [解析函数](#5-解析函数)
6. [名字与方程标签](#6-名字与方程标签)
7. [for、if、when 方程与数组](#7-forifwhen-方程与数组)
8. [finish：收尾检查](#8-finish收尾检查)
9. [checkEquations 与转换成 DAE](#9-checkequations-与转换成-dae)
10. [一个完整例子](#10-一个完整例子)
11. [前端的诊断信息](#11-前端的诊断信息)
12. [读代码的顺序、调试与测试](#12-读代码的顺序调试与测试)
13. [改代码时要注意的地方](#13-改代码时要注意的地方)

---

## 1. 一句话概括

前端在**展平（flatten）阶段**顺带收集 HGT 注解：
- 每遇到一条带注解的方程、一个带注解的变量声明、一个带 `tearingPairs` 的类，就解析注解，把其中的名字解析成**全限定名**；
- 给残差方程的 `source` 打上标签 `__OpenModelica_HGTEquation = "名字"`。

展平结束后得到一个 `Spec`（配对的列表，每个配对是一条残差方程加它的迭代变量），存进 `FlatModel.handGuidedTearing`，最后转换成 `DAE.HAND_GUIDED_TEARING` 交给后端。

前端**只负责收集和校验**，不改变方程，也不做任何撕裂。

## 2. 在前端流水线中的位置

```
解析 → Absyn
  │
AbsynToSCode                       ← 改动 1：HGT 注解里的空修饰不丢
  │                                ← 改动 2：多个 tearingPairs 合并
SCode
  │
NFInst：实例化、类型检查
  │
NFFlatten.flatten                  ← 收集（Collector）
  │   flattenComponent  → collectVariable
  │   flattenClass      → collectClass（tearingPairs）
  │   flattenEquation   → collectEquation（打标签）
  │   unrollForLoop     → enterIteration / leaveIteration（每次迭代）
  │   if/when           → enterNested / leaveNested
  │   结束              → finish → FlatModel.handGuidedTearing
  │
NFInst：化简、函数求值、标量化……
  │                                ← NFScalarize：带标签的数组方程总是拆开，元素标签改名（indexEquationTag）
  │                                ← checkEquations：标签方程没被删掉、没被复制
NFConvertDAE                       ← Spec.toDAE → DAE.HAND_GUIDED_TEARING
  │
旧后端 BackendDAECreate.lower → HandGuidedTearing.lower
```

**为什么放在展平阶段**

1. 名字要在注解所在的作用域里解析。例如 `iterationVariable = m` 写在 `Pipe` 里，`m` 是 `Pipe` 的成员；展平时才知道这个 `Pipe` 实例是 `p1` 还是 `p2`，名字才能补成 `p1.m`。展平时手上同时有作用域（`InstNode`）和前缀（`Prefix`），这两样都需要。
2. 一个类被实例化多次时，每个实例都要各自生成一份 HGT 项。展平本来就是逐个实例进行的。
3. 展平之后，方程会被化简、合并、展开，在那之后就很难再找到"用户写的那条方程"了。所以趁方程还完整时打上标签，后面的阶段只认标签。

### 2.1 AbsynToSCode 的两处改动（`FrontEnd/AbsynToSCode.mo`）

1. **保留空修饰**。正常情况下，没有绑定也没有子修饰的修饰（例如单独写的 `ResidualEquation`、`IterationVariable`）在转换成 SCode 时会被丢掉。`translateArgs` 现在对 `isHGTAnnotationPath` 认出的注解（`__OpenModelica_HGT`、`__Modelon`）传 `keepEmpty`，保留这些空修饰。
2. **合并 `tearingPairs`**。一个类可以有多个 `annotation(...)` 子句，原来的合并逻辑只保留最后一个 `tearingPairs`。`mergeHGTTearingPairs` 会按源码顺序把所有 `Pair` 拼接起来；两个厂商名分别处理。

这两处是前端里唯一不在 `NFHandGuidedTearing.mo` 中的逻辑改动。

## 3. 注解语法与数据结构

### 3.1 三种写法

```modelica
// ① 方程上：组件级配对，或者只起名字
x = y + 1 annotation(__OpenModelica_HGT(name = res));
x = y + 1 annotation(__OpenModelica_HGT(ResidualEquation(
  iterationVariable(start = 1) = z, level = 1, nominal = 1)));

// ② 类上：系统级配对，名字可以跨组件
annotation(__OpenModelica_HGT(tearingPairs(
  Pair(residualEquation = b.res, iterationVariable = c.z))));
```

打开 `--acceptModelonHGT` 后，`__Modelon(...)` 也按同样的语法读取（OCT 兼容）。

**只支持显式配对**。OCT 还允许两种未配对的写法：不带 `iterationVariable` 的 `ResidualEquation`（未配对残差），以及变量声明上的 `IterationVariable(...)`（未配对迭代变量），由编译器按依赖关系自动绑定。OMC 不做这种绑定：这两种写法仍然会被解析（为了给出准确的错误位置），然后在 `finish` 中报错误 8022（见 §8）。

### 3.2 数据结构

都定义在 `NFHandGuidedTearing.mo` 的开头：

```modelica
uniontype IterationVariable
  record ITERATION_VARIABLE
    ComponentRef name;            // 全限定名，例如 p1.m
    Integer level;
    Option<Expression> start, min, max, nominal;   // NONE() = 用变量自己的属性
    Option<Expression> hold;
    SourceInfo info;
  end ITERATION_VARIABLE;
end IterationVariable;

uniontype ResidualEquation
  record RESIDUAL_EQUATION
    String name;                  // 方程标签里的名字，例如 p1.law、$hgt1
    Integer level;
    Option<Expression> nominal;   // NONE() = 1
    Option<Expression> hold;
    Option<IterationVariable> iterationVariable;   // SOME() = 配对
    SourceInfo info;
  end RESIDUAL_EQUATION;
end ResidualEquation;

uniontype Spec
  record SPEC
    list<ResidualEquation> residuals;          // 都是配对：iterationVariable 总是 SOME()
    list<IterationVariable> iterationVariables; // 未配对的迭代变量，总是空
  end SPEC;
end Spec;
```

几点说明：
- **配对的迭代变量挂在残差方程上**，不进 `iterationVariables`。后端用 `allIterationVariables` 把两处合起来。
- 方程用**名字**标识（字符串），变量用 `ComponentRef` 标识。原因是方程本身没有名字，只能靠标签；变量有正式的引用。
- `level`、`enabled` 在前端就**求值成常量**；`start`、`min`、`max`、`nominal`、`hold` 保留为表达式，只做了展平，也就是补上前缀。
- 每个类型都有 `toString`，供 `-d=hgtDump` 使用；也都有 `toDAE`，转换成 `DAE.HGT_RESIDUAL` / `DAE.HGT_ITERATION_VARIABLE`，字段一一对应。

### 3.3 收集器 `Collector`

展平期间的可变状态都放在这里，作为 `FlattenSettings.hgt` 一路传下去：

| 字段 | 作用 |
|---|---|
| `enabled` | `--handGuidedTearing`。关闭时仍然会扫描注解，只是为了在最后给出提示 8008 |
| `acceptModelon` | `--acceptModelonHGT` |
| `found` | 是否见过任何 HGT 注解 |
| `nested` | 当前在几层 for、if、when 里面，大于 0 时不收集 |
| `equationNames` | 所有起了名字的方程：名字 → 位置，用于检查重名，也用于 `tearingPairs` 查名字 |
| `residuals` | 残差方程：名字 → `ResidualEquation` |
| `pairs` | `tearingPairs` 中的配对，每个是"按变量元素展开的配对列表 + 变量的维数"。它们引用的方程可能还没展平，所以先存下来，在 `finish` 里检查 |
| `arrayEquations` | 起了名字的数组方程：名字 → (各元素的名字, 维数)，`finish` 用它展开引用整条数组方程的 `Pair` |
| `iterationVariables` | 未配对的迭代变量，只为了在 `finish` 中报错而收集 |
| `nameIndex` | 自动命名 `$hgtN` 用的计数器 |
| `iterators` | 展开 for 循环时当前的 `(迭代变量名, 值)` 栈，最内层在前（§7.2） |
| `loopNames` | for 循环中没写名字的方程的自动名字，按前缀和源码位置记录，让所有迭代共用一个名字 |

Collector 是一个记录，但字段大多是 `Pointer` 或 `UnorderedMap`，所以在展平的递归过程中可以原地修改，不需要层层返回。

## 4. 三个收集入口

三个入口的共同模式：

```
mods := getHGTMods(注释, collector)      // 找出 HGT 注解的修饰，可能有多个
if listEmpty(mods) then return
found := true
if not enabled (or nested > 0) then return
对每个 mod：checkFields → 解析 → 加入 collector
```

### 4.1 `collectEquation`：方程

**调用位置**：`NFFlatten.flattenEquation` 的 `Equation.EQUALITY()` 分支，在左右两边展平之后：

```modelica
if HandGuidedTearing.hasAnnotation(eq.source) then
  eq.source := HandGuidedTearing.collectEquation(eq.source, ty,
    Equation.scope(eq), prefixString(prefix),
    function flattenExp(prefix = prefix, info = info), settings.hgt);
end if;
```

- `hasAnnotation` 是一个快速检查：方程没有任何注解就直接跳过，不影响没用 HGT 的模型的性能。
- 返回值是**新的 source**：如果这条方程起了名字或者是残差方程，source 上会多一个标签注释（见 §6）。
- 参数：
  - `ty`：方程的类型。标量 Real 方程，或者 Real 数组方程（逐元素配对，见 §7.3）能作残差；其他类型报 8007 并忽略 `ResidualEquation`；
  - `scope`：方程所在类的作用域，用来解析注解里的名字；
  - `prefix`：所在组件的名字，用来给方程名加前缀；
  - `flattenFn`：给注解里的表达式补前缀。
- 流程：
  1. 读出 `name` 和 `ResidualEquation`，可以来自多个注解子句，例如 OMC 和 Modelon 各一个；
  2. 有 `name` 就用它，没有就自动命名 `$hgtN`；然后加前缀；在 for 循环里再加上迭代值作下标（§7.2）；
  3. 数组方程：按行优先算出各元素的名字（`bal[1]`、`bal[1,2]`……），并把"名字 → (元素名, 维数)"记进 `arrayEquations`；
  4. 检查是否重名（8003），名字和所有元素名都记入 `equationNames`；
  5. 有 `ResidualEquation` 就调用 `parseResidualEquation`，得到每个元素一个 `ResidualEquation`，记入 `residuals`；
  6. 返回加了标签的 source。数组方程的标签是整条方程的名字，标量化时再改成各元素的名字（§7.3）。

**只起名字、不作残差的方程**，例如 `name = law`，也会被打上标签。后面 `tearingPairs` 要靠名字引用它。

### 4.2 `collectVariable`：变量声明

**调用位置**：`NFFlatten.flattenSimpleComponent`，在创建 `Variable.VARIABLE` 之后：

```modelica
if isSome(cmt.annotation_) then
  HandGuidedTearing.collectVariable(cmt, name, ty, var, InstNode.parent(comp_node),
    function flattenExp(prefix = prefix, info = info), info, settings.hgt);
end if;
```

- `name` 已经是变量的全限定名，所以不需要再解析。
- 作用域取 `InstNode.parent(comp_node)`，也就是**声明所在的类**。注解里的 `min = p` 这类表达式在那里求值。
- 检查：不是 Real 时报 8007 并忽略；不是连续变量（参数、离散变量）时报 8002。Real 数组变量上的 `IterationVariable` 也属于未配对项，不解析属性，直接留给 `finish` 报 8022。
- 只支持显式配对，所以这里收集到的未配对迭代变量最终都会在 `finish` 中报 8022。仍然完整地解析它，是为了让错误信息带着全限定名和准确的位置。

### 4.3 `collectClass`：`tearingPairs`

**调用位置**：`NFFlatten.flattenClass` 开头的 `collectHGTClass(prefix, settings)`。根节点和每个组件的类都会经过这里。

```modelica
node := if Prefix.isEmpty(prefix) then Prefix.rootNode(prefix) else
  InstNode.classScope(ComponentRef.node(Prefix.prefix(prefix)));
if InstNode.isClass(node) then
  HandGuidedTearing.collectClass(InstNode.definition(node), node, prefixString(prefix), ...);
end if;
```

- 读取的是**类定义**（`InstNode.definition`）上的注释，所以基类里的 `tearingPairs` 不会被继承（测试 `HGTNotSupported1` 覆盖了这一点）。
- 每个 `Pair` 由 `parsePair` 解析成一个带 `iterationVariable` 的 `ResidualEquation`。
- 方程名 `residualEquation = b.res` 加上当前前缀，变成例如 `plant.b.res`。
- 配对先放进 `collector.pairs`，等到 `finish` 再检查名字是否存在。原因是 `collectHGTClass` 在类的方程展平**之前**就调用了，这时方程还没有被命名。

## 5. 解析函数

### 5.1 找注解：`getHGTMods`

在注释里查找 `__OpenModelica_HGT`，以及在 `acceptModelon` 打开时查找 `__Modelon`。返回值是 `(修饰, 是否是 OMC 语法)` 的列表。

`__Modelon` 里还会有 OCT 的其他内容，所以只有在它含有 `name`、`ResidualEquation`、`IterationVariable` 或 `tearingPairs` 之一时才收下。另外，`checkFields`、`lookupFields` 只对 OMC 语法报"未知字段"（8000），对 `__Modelon` 不报，因为里面合法的其他内容我们不认识。

### 5.2 各种记录

| 函数 | 解析什么 | 允许的字段 |
|---|---|---|
| `parseResidualEquation` | 方程上的 `ResidualEquation(...)` | `enabled, level, nominal, iterationVariable, hold` |
| `parsePair` | `tearingPairs` 里的 `Pair(...)` | `enabled, level, residualEquation, iterationVariable`；其中 `residualEquation` 允许 `nominal, hold` |
| `parsePairedIterationVariable` | `iterationVariable(...) = x` | `max, min, nominal, start, hold` |
| `parseUnpairedIterationVariable` | 声明上的 `IterationVariable(...)`，结果只用于报错 8022 | `enabled, level, max, min, nominal, start, hold` |
| `parseIterationVariableAttributes` | 上面两个共用的属性部分 | |

几个规则：
- `enabled = false` 时整个项被丢弃，返回 `NONE()`。
- 配对时，迭代变量的 level 就是配对的 level。

### 5.3 解析名字：`resolveIterationVariable`

```
Absyn.Exp → Inst.instExp(在 scope 中) → Typing.typeExp → flattenFn（补前缀）→ 必须是 CREF
```

然后检查：元素类型必须是 Real（8002），必须是连续变量（8002）。返回值是**元素列表**和维数：
- 标量变量：一个元素，维数 `{}`；
- 数组变量或切片（`m`、`m[2:4]`、`w[i, :]`）：用 `ExpandExp.expand` 展开，`Expression.arrayScalarElements` 按行优先取出各元素。

每个元素的下标都用 `ComponentRef.evaluateSubscripts` 求值，所以 for 循环里代入迭代值后的 `p[1 + 1]` 会变成 `p[2]`，和变量的名字对得上。

这一步复用了前端正常的实例化和类型检查，所以 `x`、`sub.x`、`arr[2]` 这些写法都和在方程里写的效果一样，查找规则也完全一致。

### 5.4 属性和求值

| 函数 | 作用 | 规则 |
|---|---|---|
| `parseRealAttribute` | `start`、`min`、`max`、`nominal`，返回每个元素一个值 | 元素类型必须是 Real 或 Integer，Integer 会转成 Real；值是标量时用于所有元素，是数组时维数必须和所属的方程或变量相同（否则 8001），逐元素对应；**level 1 上不许依赖连续变量**（8006，OCT 的 R7）；可求值的 `nominal` 必须为正（`checkPositive`，8001） |
| `parseHold` | `hold` | 必须是 Boolean 参数表达式；保留为表达式 |
| `evalBoolean` | `enabled` | 用 `evalParameterExp` 求值成 `true` 或 `false` |
| `evalLevel` | `level` | 求值成 Integer，且必须 ≥ 1（8001） |
| `evalParameterExp` | 前两者共用 | instExp、typeExp，必须是参数表达式；**用 `Structural.markExp` 标记成结构参数**，然后 `Ceval.evalExp` |

**为什么 `level` 和 `enabled` 要标记成结构参数**：它们决定模型怎么撕裂，属于编译期的结构信息。被标记之后，参数会变成 `final parameter`，用户不能在仿真时再修改它们（见 §10 例子中的 `lvl`）。

### 5.5 修饰的工具函数

`hasField`、`lookupField`、`lookupFields`、`checkFields`、`getEquationName`、`bindingString`、`getInfo`，都是对 `SCode.Mod` 的简单操作。注意：
- `getInfo` 在修饰没有位置信息时（例如只写了记录名），退回到外层传入的 info。所以错误信息总能指到源码里的某个位置。
- `getEquationName` 只接受没有下标的标识符（`name = res`），否则报 8001。

## 6. 名字与方程标签

**命名规则**
- 写了 `name = res` 的，就用 `res`；没写名字的残差方程自动命名为 `$hgt1`、`$hgt2`……（`nameIndex` 在整个模型内递增）。
- 然后加上组件前缀：`prefixName("p1", "law")` 得到 `p1.law`。
- 同一个类被实例化两次时，两条方程分别是 `p1.law` 和 `p2.law`，所以不会重名。

**打标签**

```modelica
source := ElementSource.addCommentToSource(source, SOME(makeEquationTag(name)));
```

`makeEquationTag` 生成一个注释，内容是 `annotation(__OpenModelica_HGTEquation = "p1.law")`，追加到方程 source 的注释列表里。

- **前端读标签**：`getEquationTag`，供 `checkEquations` 使用。
- **后端读标签**：`HandGuidedTearing.equationName`（`BackEnd/HandGuidedTearing.mo`）。

**为什么用标签而不用下标或位置**：展平之后，方程会被化简、标量化、转成 DAE，在后端又会被别名消除、求解、重排。一路上方程的位置一直在变，只有 source 会跟着方程走。

标签的名字以 `__OpenModelica` 开头，不会和用户的注解冲突；它只存在于编译器内部，不会出现在 `instantiateModel` 的输出里。

## 7. for、if、when 方程与数组

### 7.1 if、when 和不展开的 for：嵌套计数

用嵌套计数 `nested` 控制：进入这些方程之前调用 `enterNested`，离开时调用 `leaveNested`。

- `enterNestedEquations` 只在**最外层**（`nested == 0`）扫描并报告 8007，所以嵌套的方程只报一次警告。
- `nested > 0` 时，`collectEquation` 直接返回，不收集。
- **when 方程**：不支持。
- **if 方程**（`flattenIfEquation`）分情况处理：
  - 条件求值为 true、并且它前面没有保留下来的分支（`listEmpty(bl)`）：这个分支的方程会**替换掉整个 if 方程**，所以按普通方程展平，注解有效。OCT 风格的 `if isSteadyState then ... else ... end if` 就属于这种情况，见测试 `HGTIf1`。
  - 其他被保留下来的分支：用 `flattenIfBranch` 展平，内部调用 enterNested 和 leaveNested，注解被忽略并给出警告。
  - 条件为 false 的分支：直接丢掉，不扫描，也不报警告。
- **不展开的 for 方程**（关掉标量化时走 `splitForLoop`）：不支持。

### 7.2 展开的 for 方程

默认开着标量化，for 方程由 `unrollForLoop` 展开：每次迭代代入迭代变量的值，再展平循环体。HGT 就借这一步：

```modelica
// NFFlatten.unrollForLoop
unrolled_body := Equation.replaceIteratorList(body, iter, val);
HandGuidedTearing.enterIteration(InstNode.name(iter), val, settings.hgt);   // 压栈
unrolled_body := flattenEquations(unrolled_body, prefix, settings);
HandGuidedTearing.leaveIteration(settings.hgt);                            // 出栈
```

`Collector.iterators` 是 `(迭代变量名, 当前值)` 的栈，最内层在前。每次迭代里，`collectEquation` 把这条方程当作一条独立的方程处理：
- **注解里的表达式**：注解是 `SCode.Mod`，循环展开时不会被代入，所以先用 `substituteIterators` 把 `ResidualEquation` 里所有的迭代变量名替换成当前值的字面量（`Expression.toAbsyn`），再走原来的解析。于是 `iterationVariable = p[i + 1]`、`start = 2 * i`、`level = …` 都按当前迭代求值。同名时内层迭代变量遮住外层的。
- **名字**：`appendSubscripts` 把迭代值追加成下标：`name = seg` 得到 `seg[1]`、`seg[2]`……，两层循环得到 `seg[1,2]`。没写名字的方程在所有迭代中共用一个自动名字（`generateName` 按前缀和源码位置记在 `loopNames` 里），得到 `$hgt1[1]`、`$hgt1[2]`……
- `tearingPairs` 可以用 `Pair(residualEquation = seg[2], …)` 引用某一次迭代。用户写的 `seg[1, 2]` 经 `Dump.printComponentRefStr` 打印成 `seg[1,2]`，和生成的名字格式一致。

### 7.3 数组方程和数组变量

**只支持逐元素的显式配对**：数组残差方程与形状完全相同的数组迭代变量（或切片）配对，第 k 个元素对第 k 个元素。

```modelica
m = k .* sqrt(p[1:3] - p[2:4]) annotation(__OpenModelica_HGT(name = seg,
  ResidualEquation(iterationVariable(start = {8, 6, 4}) = p[2:4])));
// seg[1] <-> p[2], seg[2] <-> p[3], seg[3] <-> p[4]
```

- **形状**：方程和变量的维数必须完全相同（`checkShape`），否则报 8001，信息里给出两边的维数。别的对应关系（例如倒序）用 for 方程写。
- **属性**：标量用于所有元素，数组必须和变量（残差的 nominal 则和方程）同形状，逐元素对应。`level`、`enabled`、`hold` 只能是标量。
- **只在 level 1**：数组残差方程和数组迭代变量（包括切片）暂时只支持 level 1，level ≥ 2 报 8001（`checkArrayLevel`）。for 循环不受影响，因为每次迭代都是标量配对。
- **元素的名字**：按行优先在名字后加元素下标：`seg[1]`、`bal[1,2]`。for 循环里的数组方程先加迭代值、再加元素下标：`w[i, :]` 在 i = 2 时得到 `bw[2,1]`、`bw[2,2]`。
- **`tearingPairs`**：`Pair(residualEquation = bal, iterationVariable = x)` 逐元素配对整条数组方程；`Pair(residualEquation = bal[2], iterationVariable = x[3])` 配单个元素。`parsePair` 先按变量展开成每个元素一个配对，`finish` 再查 `arrayEquations`：是数组方程就检查形状并换成元素名，是标量方程就要求变量也是标量。

**标签怎么到元素上**：展平时数组方程还是一条 `EQUALITY`，只能打一个标签（整条方程的名字）。`NFScalarize.scalarizeEquation` 把它拆成元素方程时：
- 带 HGT 标签的数组方程**总是**拆开（即使含 `sqrt(数组)` 这类向量化调用，平时这种方程是不拆的）；
- 第 k 个元素调用 `HandGuidedTearing.indexEquationTag(src, subs)`，把标签改成元素名。`subs` 来自 `elementSubscripts(dims)`，按行优先排列，和 `ExpressionIterator` 展开元素的顺序一致。

这样每个元素标签只出现一次，`checkEquations` 照常工作，后端拿到的就是普通的标量配对，不需要任何改动。测试 `HGTArray1.mos` 里的矩阵方程，每个元素是一个独立的 1×1 块：如果元素顺序错了，残差就不依赖它的迭代变量，会报 8016。

关掉标量化（`-d=-nfScalarize`）时数组方程不会被拆开，带 HGT 注解的数组方程报 8007 并被忽略。

## 8. finish：收尾检查

展平结束时，`NFFlatten.flatten` 调用：

```modelica
flatModel.handGuidedTearing := HandGuidedTearing.finish(settings.hgt);
```

`finish` 的步骤：
1. 没开 `--handGuidedTearing`：如果见过注解，给提示 8008；返回 `NONE()`。
2. **加入 `tearingPairs` 的配对**：这时所有方程都已经命名，可以检查：
   - 名字不存在 → 8004；
   - 这条方程已经有组件级的 `ResidualEquation` → 8005（`checkUniqueEquation`）。
3. 残差方程按名字排序（`isNameGreater`），让输出和测试结果稳定，不受哈希顺序影响。
4. **每个变量只能有一个 HGT 规定**：配对的变量和未配对的变量合在一起检查重复（8005，`checkUniqueVariable`）。
5. **只接受显式配对**（`checkOnlyPairs`）：每个未配对的残差方程和迭代变量各报一条 8022，全部报完再失败。放在这里检查，是因为这时 `tearingPairs` 的配对也已经加进来了，能准确判断哪些项确实没有配对。
6. 没有任何项 → `NONE()`。
7. 有任何 `hold` 不是字面量 `false` 的 → 警告 8009（hold 尚未支持）。
8. `-d=hgtDump` → 打印 `Spec.toString`。

## 9. checkEquations 与转换成 DAE

**checkEquations**（`NFInst.mo`，在标量化之后调用）：统计 `equations` 和 `initialEquations` 中每个标签出现的次数，残差方程的标签必须**正好出现一次**，否则报 8010。

它防范的是：展平之后，前端的化简或者方程展开把用户的方程删掉了，或者复制了。数组方程的元素标签由 `indexEquationTag` 逐个改名，所以不会出现重复。这个检查保证后端看到的标签和规范是一一对应的。

**转换成 DAE**（`NFConvertDAE.mo`）：

```modelica
if isSome(flatModel.handGuidedTearing) then
  elems := HandGuidedTearing.Spec.toDAE(Util.getOption(flatModel.handGuidedTearing)) :: elems;
end if;
```

于是 DAE 元素列表里多了一个 `DAE.HAND_GUIDED_TEARING(residuals, iterationVariables)`，记录定义在 `FrontEnd/DAE.mo`。表达式也在这里通过 `Expression.toDAE` 转换成 `DAE.Exp`。旧后端的 `HandGuidedTearing.lower` 从这里读取规范；`BackendDAECreate.lower2` 遇到这个元素会跳过。

新后端（`--newBackend`）直接使用 `FlatModel`，目前没有读取 `FlatModel.handGuidedTearing`，见 [NewBackend_architecture.md](NewBackend_architecture.md) §9。

## 10. 一个完整例子

```modelica
package F
  model Pipe
    parameter Real k = 2;
    Real m(start = 1), dp;
  equation
    m = k * sqrt(dp) annotation(__OpenModelica_HGT(name = law));
  end Pipe;

  model Plant
    parameter Integer lvl = 1;
    Pipe p1, p2;
    Real z;
  equation
    p1.dp + p2.dp = 10;
    p1.m = p2.m;
    z ^ 2 = p1.m annotation(__OpenModelica_HGT(ResidualEquation(level = lvl, iterationVariable(min = 0) = z)));
    annotation(__OpenModelica_HGT(tearingPairs(
      Pair(residualEquation = p1.law, iterationVariable(start = 2, nominal = 2) = p1.m))));
  end Plant;
end F;
```

`instantiateModel(F.Plant)`，开 `--handGuidedTearing -d=hgtDump`：

```
Hand guided tearing:
  pair: residual equation $hgt1 (level 1), iteration variable z (level 1, min = 0.0)
  pair: residual equation p1.law (level 1), iteration variable p1.m (level 1, start = 2.0, nominal = 2.0)
class F.Plant
  final parameter Integer lvl = 1;
  ...
```

逐项看收集的过程：

| 源码 | 经过的入口 | 结果 |
|---|---|---|
| `Plant` 类上的 `tearingPairs` | `collectClass`（前缀为空） | 配对 `p1.law ↔ p1.m` 先存进 `pairs`；`iterationVariable` 在 `Plant` 中解析成 `p1.m` |
| `p1` 中的 `m = k*sqrt(dp)` | `collectEquation`（前缀 `p1`） | 名字 `p1.law`，打上标签；它不是残差，只是有了名字 |
| `p2` 中的同一条方程 | `collectEquation`（前缀 `p2`） | 名字 `p2.law`，打上标签，不会重名 |
| `z ^ 2 = p1.m` 上的 `ResidualEquation(level = lvl, iterationVariable(min = 0) = z)` | `collectEquation` | 没写名字，自动命名为 `$hgt1`；和 `z` 配对；`level = lvl` 求值为 1，**`lvl` 变成 `final parameter`** |
| 展平结束 | `finish` | `pairs` 中 `p1.law` 的名字存在，于是加入；按名字排序，`$hgt1` 排在 `p1.law` 前面 |

后端拿到的就是这两个配对。`p2.law` 有名字但没有被任何配对引用，所以只是一个普通方程。

## 11. 前端的诊断信息

| 编号 | 级别 | 含义 | 由谁报告 |
|---|---|---|---|
| 8000 | 警告 | 未知字段，被忽略（只对 OMC 语法） | `checkFields`、`lookupFields` |
| 8001 | 错误 | 字段的值无效：名字不是标识符、level < 1、不是参数表达式、nominal ≤ 0、Pair 缺字段…… | 各解析函数 |
| 8002 | 错误 | 不能作迭代变量：不是变量、不是 Real、不是连续变量 | `resolveIterationVariable`、`collectVariable` |
| 8003 | 错误 | 方程重名 | `collectEquation` |
| 8004 | 错误 | `tearingPairs` 引用的方程名不存在 | `finish` |
| 8005 | 错误 | 同一个方程或变量有多个 HGT 规定 | `finish` |
| 8006 | 错误 | level 1 上的属性依赖连续变量 | `parseRealAttribute` |
| 8007 | 警告 | 不支持，被忽略：非 Real 的方程或变量、没有标量化时的数组方程、when 方程和保留下来的 if 分支中的注解 | `collectEquation`、`collectVariable`、`enterNestedEquations` |
| 8008 | 提示 | 模型里有 HGT 注解，但没开 `--handGuidedTearing` | `finish` |
| 8009 | 警告 | `hold` 尚未支持 | `finish` |
| 8010 | 错误 | 标签方程在化简过程中被删掉或复制了 | `checkEquations` |
| 8022 | 错误 | 有未配对的残差方程或迭代变量（只支持显式配对） | `checkOnlyPairs`（`finish` 中） |

8011–8021 由后端报告，见开发指南 §7。

## 12. 读代码的顺序、调试与测试

**阅读顺序**

1. 文件开头的包注释和 §3.2 的几个记录，先知道产出是什么。
2. `Collector`，知道展平期间维护了哪些状态。
3. `collectEquation`：最完整的入口，看懂它，另外两个入口就很快了。
4. `NFFlatten.mo` 里的调用点：`flattenEquation`、`flattenSimpleComponent`、`collectHGTClass`、`flattenIfEquation`、`flattenIfBranch`。在文件里搜索 `HandGuidedTearing.` 就能找到全部。
5. `parseResidualEquation` → `parsePairedIterationVariable` → `resolveIterationVariable` → `parseRealAttribute`。
6. `finish`、`checkEquations`、`Spec.toDAE`。
7. `AbsynToSCode.mo` 里的 `isHGTAnnotationPath`、`translateArgs` 的 `keepEmpty`、`mergeHGTTearingPairs`。

**调试**

- `-d=hgtDump`：打印 `finish` 得到的规范，最常用。
- `instantiateModel(...)`：看展平后的模型，确认 level 和 enabled 用到的参数变成了 `final`。
- 错误信息都带源码位置。位置指向的是注解中的那个字段（`getInfo`），而不是整条方程。

**测试**

前端测试在 `testsuite/flattening/modelica/scodeinst/HGT*.mo`，用 `rtest` 运行：

| 测试 | 覆盖内容 |
|---|---|
| `HGTComponentPair1` | 组件级配对、自动命名、带名字的配对、各属性、只有名字的方程 |
| `HGTSystemPair1` | 系统级配对，分写在两个注解子句里（合并）；数组组件 `ba[2].res` |
| `HGTUnpaired1` | OCT TestUnpaired 例子中的未配对项：报 8022，名字带前缀 |
| `HGTLevel1` | level 由参数给出（变成结构参数）；level 2 上允许依赖连续变量 |
| `HGTModelon1` | `--acceptModelonHGT`、hold 警告、忽略 `__Modelon` 的其他内容 |
| `HGTIf1` | 参数选中的 if 分支；保留下来的 if 分支中的注解被忽略 |
| `HGTNotSupported1` | when 方程中的注解（8007）；基类的 `tearingPairs` 不继承 |
| `HGTFor1` | for 循环：嵌套循环、两个下标的名字、`tearingPairs` 引用某次迭代、自动命名、倒序的下标对应 |
| `HGTArray1` | 数组方程逐元素配对：切片、矩阵、标量和数组属性、`tearingPairs` 引用整条数组方程和单个元素、for 循环里的数组方程 |
| `HGTDisabled1` | 没开开关时的提示 8008 |
| `HGTError1`–`HGTError5` | 参数作迭代变量（8002）、Pair 的方程名不存在（8004）、方程重名（8003）、level 1 上的属性依赖连续变量（8006）、同一变量既配对又未配对（8005） |
| `HGTError6` | `level = 0`（8001），未知字段（8000） |
| `HGTError7`、`HGTError8` | 残差和迭代变量的 nominal ≤ 0（8001），后者由参数给出 |
| `HGTError9` | 未配对项报 8022，显式配对（组件级和 `tearingPairs`）不受影响 |
| `HGTError10`–`HGTError12` | 数组方程与切片尺寸不同、数组属性尺寸不对、标量方程配数组变量（8001） |
| `HGTError13`、`HGTError14` | level 2 上的数组配对，组件级和 `tearingPairs`（8001） |

## 13. 改代码时要注意的地方

**加一个新字段**（例如给 `ResidualEquation` 加一个属性）
1. 加进对应 `parse*` 函数的 `checkFields` 列表，否则会报"未知字段"。
2. 在记录里加字段，同时更新 `toString` 和 `toDAE`。
3. 在 `FrontEnd/DAE.mo` 的 `HGT_RESIDUAL` 或 `HGT_ITERATION_VARIABLE` 里加对应字段，再到后端去使用它。
4. 记得更新测试的期望输出：`hgtDump` 的格式变了，多个测试的输出都会变。

**表达式什么时候求值，什么时候保留**
- 决定**结构**的（level、enabled）：用 `evalParameterExp` 求值，并标记为结构参数。
- 运行时才用到的（start、min、max、nominal、hold）：保留为表达式，只调用 `flattenFn` 补前缀。不要提前求值，否则用户在仿真时改参数就不起作用了。

**作用域**
- 方程：`Equation.scope(eq)`。不要直接用 `eq.scope`，它的类型是 `ScopeRef`，在 Rust 移植版里是弱引用，直接用会编译失败（提交 `2488a46c`）。
- 变量：`InstNode.parent(comp_node)`，也就是声明所在的类。
- 类：`InstNode.classScope(...)`，也就是组件的类。

**为了兼容 Rust 移植版 omc**（mmtorust 会把 MetaModelica 转译成 Rust）
- 不要对内置函数做偏应用，例如 `function listMember(lst = ...)`，改写成循环；
- 局部变量不要叫 `cons` 之类与内置函数同名的名字；
- `match` 不能用在输出参数的默认值里，要放到 algorithm 部分；
- 不能直接对函数调用的结果取字段，要用模式匹配。

C 版 omc 对这些写法都不报错，只有编 Rust 版时才暴露出来。改完之后最好两个版本都编一次，至少要过 `build_rust`。

**性能**：`hasAnnotation` 和 `getHGTMods` 是唯一会对每条方程、每个变量都执行的代码。没用 HGT 的模型几乎没有额外开销，加新检查时要保持这一点。
