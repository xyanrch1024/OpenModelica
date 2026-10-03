# OpenModelica HGT 注解前端实现

> 对齐 OCT Hand-Guided Tearing（PbS/HGT）。本阶段只做**解析与存储**，不消费于撕裂算法。

## 支持的注解

| 形态 | 含义 |
|---|---|
| `__OpenModelica_IterationVariable(...)` | 变量级迭代变量（IV） |
| `__OpenModelica_ResidualEquation(...)` | 方程级残差 |
| `__OpenModelica_name = id` | 方程名标签（供后续 tearingPairs） |
| `__Modelon(IterationVariable(...))` | OCT 别名 → 同上 |
| `__Modelon(ResidualEquation(...))` | OCT 别名 → 同上 |
| `__Modelon(name = id)` | OCT 方程名别名 |

### 字段

**IterationVariable：** `enabled`, `level`, `name`/`=` 绑定 cref, `min`, `max`, `nominal`, `start`, `hold`

**ResidualEquation：** `enabled`, `level`, `nominal`, `hold`, `name`, `iterationVariable`（嵌套 IV 或 `= cref`）

裸注解（无字段）合法，例如：

```modelica
Real x annotation(__Modelon(IterationVariable));
0 = f(x) annotation(__OpenModelica_ResidualEquation);
```

`SCode` 中裸名存为 `NAMEMOD(..., NOMOD())`；前端用 `tryLookupAnnotation` 区分「缺失」与「裸存在」。

## 代码落点

```
注释 / SCode.Annotation
        │
        ├─ 变量 comment ──► Annotations.create
        │                      └─ HgtIterationVariable → Annotations.iterationVariable
        │                         （BackendInfo）
        │
        └─ 方程 ElementSource ──► HgtResidualEquation.createFromSource
                                   └─ EquationAttributes.residualHgt
                                      （NBackendDAE.lowerEquationAttributes）
```

| 文件 | 改动 |
|---|---|
| `NFBackendExtension.mo` | `HgtIterationVariable` / `HgtResidualEquation` / lookup helpers |
| `NBVariable.mo` | `getHgtIterationVariable` / `hasHgtIterationVariable` |
| `NBEquation.mo` | `residualHgt` + getter/setter + dump |
| `NBackendDAE.mo` | equality 方程 lower 时解析 source |
| `Obfuscate.mo` | 白名单不混淆注解名 |

## 示例

见 [`examples/HgtAnnotationExamples.mo`](./examples/HgtAnnotationExamples.mo)。

## 未做（后续）

- `NBTearing` / 旧 `Tearing.mo` 按配对优先于自动撕裂
- class 级 `__Modelon(tearingPairs(...))`
- 旧后端变量路径对称解析（当前 IV 走 NF `Annotations`，残差走 NB lower）
- dump / `-d=` 专用调试开关
