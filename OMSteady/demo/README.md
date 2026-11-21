# HGT 稳态求解演示：冷却水回路

一个可以现场运行的演示：同一个模型、同一个 FMU，不重新编译，在校核、设计、限温几种工况之间切换。

## 运行

```
pip install numpy fmpy
python3 OMSteady/demo/demo.py              # 每一步之后按回车继续
python3 OMSteady/demo/demo.py --no-pause   # 一次跑完
```

需要这个分支编译出的 omc。脚本依次在这些位置找：`--omc` 参数、环境变量 `OMC`、仓库里的
`build_cmake/install_cmake/bin/omc`、`PATH`。整个演示约 15 秒，其中大部分是编译 FMU。

## 模型

`CoolingLoop.mo`：一台泵，两条并联支路（支路 1 带调节阀），每条支路一台冷却器。

```
          ┌── 调节阀 ── 冷却器 1 (Q1) ──┐   m1, T1
 泵 ──────┤                             ├────
  n, m    └──────────── 冷却器 2 (Q2) ──┘   m2, T2
```

6 个配对，每个是一条残差方程和一个迭代变量：

| 残差方程 | 含义 | 迭代变量 | hold |
|---|---|---|---|
| `loopBalance` | 泵的扬程 = 总管压降 + 支路压降 | 总流量 `m` | 变量：`designFlow` |
| `branchBalance` | 两条支路压降相等 | 支路 1 流量 `m1` | |
| `energy1` | 冷却器 1 的能量平衡 | 出口温度 `T1` | 变量：`limitT1` |
| `energy2` | 冷却器 2 的能量平衡 | 出口温度 `T2` | |
| `pumpSpec` | `n = n_set` | 泵转速 `n` | 方程：`designFlow` |
| `valveSpec` | `opening = opening_set` | 阀门开度 `opening` | 方程：`limitT1` |

hold 是交叉的：`designFlow` hold 住的是 `loopBalance` 这个配对的**变量** `m`，去掉的是 `pumpSpec`
这个配对的**方程**。于是回路压力平衡不再用来求 `m`，而是用来求 `n`。

## 演示的步骤和要点

| 步骤 | 内容 | 想说明什么 |
|---|---|---|
| 1 | 模型里的一个配对 | 工程师用注解告诉编译器：迭代哪个变量、用哪条方程当残差 |
| 2 | `omc --handGuidedTearing --interactiveFMU` | 迭代变量变成 FMU 的输入 `iter_N`，残差变成输出 `res_N`，hold 变成参数；FMU 里没有代数环，是一个标准的 FMI 2.0 FMU |
| 3 | 校核：转速、开度给定 | 结果 m = 13.78 kg/s、T1 = 35.77、T2 = 31.59，和普通仿真（现有运行时）一致 |
| 4 | 设计：总流量 16 kg/s，求转速 | 只改一个参数就换了工况，不改模型、不重新编译；n = 1.161 |
| 5 | 限温：T1 = 45，求开度 | 求解顺序随 hold 变化：先由能量平衡求 `m1`，再求开度；opening = 0.517 |
| 6 | 两个要求同时给 | 参数可以组合；n = 1.380，opening = 0.348 |
| 7 | T2 = 28，求转速 | 模型里没写的工况，用 `holdIterationVariables` / `holdResiduals` 直接指定；n = 1.448 |
| 8 | 给错的工况 | 求解之前做个数检查和结构检查，指出是哪些变量和方程，不会算出一个错的结果 |
| 9 | 改设备参数再校核 | 参数随时可改 |

每一步都打印"求解顺序"：求解器按当前的 hold 重新做匹配和分块，这是在求解时做的，不是编译时。

## 现在的范围

- 只支持没有状态、没有事件的稳态模型；FMI 2.0 Model Exchange，C 运行时。
- 迭代变量和残差都要由用户写成配对（默认 `--hgtOnly`）：FMU 里还剩代数环时编译报错。
- 雅可比矩阵默认用差分，稠密求解。1000 个配对的模型能编译和求解（编译约 100 秒，
  几乎都是 C 编译；求解约 1 秒），再大需要稀疏雅可比和稀疏线性求解器。
- 和 OCT 的交互式 FMU 命名一致（`iter_N`、`res_N`、`iter_N_hold`、`res_N_hold`），
  但迭代变量是 FMI 输入而不是参数，两边的 FMU 不能互换。

设计文档：`doc/HGT_interactive_fmu_phase1.md`。
