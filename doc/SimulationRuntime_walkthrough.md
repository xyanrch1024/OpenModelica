# OpenModelica 仿真运行时代码走读

本文讲解 OMC 的 C 仿真运行时：代码怎么组织，生成的模型代码和运行时怎么分工，一次仿真从 `main` 到结束经过哪些函数，代数系统（尤其是非线性系统）怎么求解，FMU 走的是哪条路径。最后简单介绍 Rust 运行时，以及 HGT 在运行时里的位置。

- 运行时代码：`OMCompiler/SimulationRuntime/c/`
- FMI 导出：`OMCompiler/SimulationRuntime/fmi/export/openmodelica/`
- Rust 运行时：`OMCompiler/SimulationRuntime/rust/`
- 例子是一个小模型 `Hold`：x + y = 3，x·y = 2，用 HGT 把 x·y = 2 配给 x（`ResidualEquation(iterationVariable = x, nominal = 2)`），编译后的文件名前缀为 `Hold`。它最初来自 hold 实现时的测试模型 `HGT.Hold`，hold 实现已撤销，这里只用它演示运行时的结构。

文中的行号对应当前分支，函数名不会变，行号可能会漂移。

## 目录

1. [总体分工](#1-总体分工)
2. [目录结构](#2-目录结构)
3. [生成的模型代码](#3-生成的模型代码)
4. [核心数据结构](#4-核心数据结构)
5. [执行流程总览](#5-执行流程总览)
6. [启动：读入模型和参数](#6-启动读入模型和参数)
7. [初始化](#7-初始化)
8. [主仿真循环](#8-主仿真循环)
9. [代数系统的求解](#9-代数系统的求解)
10. [FMU 的执行路径](#10-fmu-的执行路径)
11. [横切机制](#11-横切机制)
12. [Rust 运行时](#12-rust-运行时)
13. [HGT 在运行时中的位置](#13-hgt-在运行时中的位置)
14. [读代码的顺序与调试](#14-读代码的顺序与调试)

---

## 1. 总体分工

```
            omc（编译器）                               运行时（libSimulationRuntimeC）
┌─────────────────────────────────┐          ┌──────────────────────────────────────────┐
│ 生成模型代码 Hold*.c             │          │ main 之后的一切：                        │
│  - 每条方程一个 eqFunction        │  callback│  - 命令行、init.xml、数据结构分配         │
│  - functionODE / Algebraics / DAE ├─────────►│  - 初始化（含 homotopy）                  │
│  - 非线性系统的残差函数、雅可比    │  表      │  - 积分器（dassl、cvode、ida、gbode…）    │
│  - 零点函数、断言、初始方程        │◄─────────┤  - 事件处理                              │
│  - 回调表 Hold_callback          │  调用     │  - 线性/非线性/混合系统求解器             │
│ Hold_init.xml（变量、参数、选项） │  solve_* │  - 结果文件（mat、csv…）、日志            │
└─────────────────────────────────┘          └──────────────────────────────────────────┘
```

- **生成的代码**只描述"这个模型怎么算"：给定当前时刻和状态，按顺序把方程算一遍；遇到代数环就调用运行时的 `solve_nonlinear_system` / `solve_linear_system`。
- **运行时**负责"什么时候算、算几次"：时间推进、积分、事件、初始化，以及代数环的数值求解。
- 两者通过一张**回调表**（`struct OpenModelicaGeneratedFunctionCallbacks`，定义在 `openmodelica_func.h`）连接：运行时只通过 `data->callback->xxx(data, threadData)` 调用模型。

## 2. 目录结构

`OMCompiler/SimulationRuntime/c/`：

| 目录 / 文件 | 内容 |
|---|---|
| `simulation_data.h` | 核心数据结构：`DATA`、`MODEL_DATA`、`SIMULATION_INFO`、`SIMULATION_DATA`、`NONLINEAR_SYSTEM_DATA`、`LINEAR_SYSTEM_DATA` 等 |
| `openmodelica_func.h` | 回调表 `OpenModelicaGeneratedFunctionCallbacks` 的定义 |
| `simulation/simulation_runtime.cpp` | 入口：`_main_initRuntimeAndSimulation`、`_main_SimulationRuntime`、`startNonInteractiveSimulation`、`callSolver` |
| `simulation/simulation_input_xml.c` | 读 `<model>_init.xml`：变量、参数、start 值、仿真选项 |
| `simulation/options.c`，`util/simulation_options.c` | 运行时命令行选项（`-override`、`-lv`、`-nls`、`-s` 等）的名字、说明和解析 |
| `simulation/solver/solver_main.c` | `solver_main`：选积分器、初始化、调用主循环、收尾；`solver_main_step`：一步积分的分发 |
| `simulation/solver/perform_simulation.c.inc` | 主仿真循环 `performSimulation`。以 `.inc` 形式被生成代码包含，所以函数名带模型前缀（`Hold_performSimulation`） |
| `simulation/solver/initialization/initialization.c` | 初始化：`initialization`、`symbolic_initialization`（含全局 homotopy） |
| `simulation/solver/model_help.c` | 杂项：`initializeDataStruc`、`updateDiscreteSystem`（事件迭代）、`storePreValues`、`copyStartValuestoInitValues` 等 |
| `simulation/solver/events.c` | 事件检测与处理：`checkEvents`、`handleEvents`、`checkForSampleEvent` |
| `simulation/solver/synchronous.c` | 同步语言特性（clock、timer） |
| `simulation/solver/dassl.c`、`ida_solver.c`、`cvode_solver.c`、`gbode_*.c`、`sym_solver_ssc.c` | 积分器 |
| `simulation/solver/nonlinearSystem.c` | 非线性系统的入口 `solve_nonlinear_system`、分发 `solveNLS`、初值、HGT 的界检查 |
| `simulation/solver/nonlinearSolverHybrd.c`、`kinsolSolver.c`、`kinsol_b.c`、`nonlinearSolverNewton.c`、`nonlinearSolverHomotopy.c` | 具体的非线性求解器 |
| `simulation/solver/linearSystem.c` + `linearSolver*.c` | 线性系统（LAPACK、KLU、UMFPACK、LIS、全主元） |
| `simulation/solver/mixedSystem.c` + `mixedSearchSolver.c` | 混合（连续 + 离散）系统 |
| `simulation/solver/stateset.c` | 动态状态选择 |
| `simulation/solver/delay.c`、`spatialDistribution.c` | `delay`、`spatialDistribution` 算子 |
| `simulation/results/` | 结果输出的抽象 `sim_result`（mat、csv、plt、ia…） |
| `simulation/jacobian_*.c` | 雅可比矩阵的着色、稀疏模式 |
| `util/` | 数组、字符串、错误与日志（`omc_error.c`）、读写 csv/mat、计时等基础库 |
| `gc/` | 内存管理（`omc_alloc_interface`）、`OMC_TRY_INTERNAL` 等异常宏（`omc_gc.h`） |
| `linearization/`、`optimization/`、`dataReconciliation/` | 线性化、动态优化（ipopt）、数据协调 |
| `RuntimeSources.mo` | 打包进 source-code FMU 的运行时源文件清单 |

## 3. 生成的模型代码

`buildModel(Hold)` 生成一组按功能编号的文件：

| 文件 | 内容 |
|---|---|
| `Hold.c` | `main`、回调表 `Hold_callback`、`Hold_setupDataStruc`、`functionDAE`、`functionODE`、`functionLocalKnownVars` |
| `Hold_01exo.c` | 外部对象的析构 |
| `Hold_02nls.c` | **非线性系统**：残差函数 `residualFuncN`、稀疏模式、`initializeStaticDataNLSN`、`getIterationVarsNLSN`、注册函数 `Hold_initialNonLinearSystem` |
| `Hold_03lsy.c` | 线性系统 |
| `Hold_04set.c` | 状态集（动态状态选择） |
| `Hold_05evt.c` | 零点函数 `function_ZeroCrossings`、关系 `function_updateRelations`、sample |
| `Hold_06inz.c` | 初始化方程 `functionInitialEquations` |
| `Hold_07dly.c` | `delay` 的存储 |
| `Hold_08bnd.c` | 依赖参数的参数和属性：`updateBoundParameters`、`updateBoundVariableAttributes` |
| `Hold_09alg.c` | `functionAlgebraics`：只影响输出、不影响导数的方程 |
| `Hold_10asr.c` | 断言 `checkForAsserts` |
| `Hold_11mix.c` | 混合系统 |
| `Hold_12jac.c` | 雅可比矩阵：A/B/C/D、非线性系统的 `NLSJac` |
| `Hold_13opt.c`、`Hold_14lnz.c` | 优化、线性化 |
| `Hold_15syn.c` | 同步特性 |
| `Hold_16dae.c` | DAE 模式 |
| `Hold_17inl.c`、`Hold_18spd.c` | 内联求解器、`spatialDistribution` |
| `Hold_init.xml` | 变量和参数的名字、start、属性，仿真选项（startTime、stopTime、tolerance、solver…） |
| `Hold_info.json` | 方程和变量的描述，供调试器和日志使用 |

### 3.1 一条方程

每条方程生成一个 `eqFunction`，直接读写 `data->localData[0]` 中的变量：

```c
void Hold_eqFunction_1(DATA *data, threadData_t *threadData)
{
  const int equationIndexes[2] = {1,1};
  (data->localData[0]->realVars[1] /* y */) = 3.0 - (data->localData[0]->realVars[0] /* x */);
  threadData->lastEquationSolved = 1;
}
```

### 3.2 一个代数环

代数环在调用处只是一句 `solve_nonlinear_system(data, threadData, 0)`（`Hold_06inz.c`）。真正的内容在 `Hold_02nls.c` 的残差函数里：**把迭代变量写进 `localData`，算内部方程，再算残差**：

```c
void residualFunc4(RESIDUAL_USERDATA* userData, const double* xloc, double* res, const int* iflag)
{
  ...
  (data->localData[0]->realVars[0] /* x */) = xloc[0];   /* 迭代变量 */
  Hold_eqFunction_1(data, threadData);                    /* 内部方程：y = 3 - x */
  res[0] = 0.5 * (x * y) - 1.0;                           /* 残差：(x*y - 2)/2，nominal = 2 */
}
```

`Hold_initialNonLinearSystem` 把每个系统登记到 `NONLINEAR_SYSTEM_DATA` 数组：大小、残差函数、雅可比函数、稀疏模式、取迭代变量的函数等。

### 3.3 回调表和 main

```c
struct OpenModelicaGeneratedFunctionCallbacks Hold_callback = {
  Hold_performSimulation,         /* 主循环，来自 perform_simulation.c.inc */
  Hold_performQSSSimulation,
  Hold_updateContinuousSystem,
  ...
  Hold_initialNonLinearSystem,    /* 登记非线性系统 */
  ...
  Hold_functionODE,               /* 状态导数 */
  Hold_functionAlgebraics,        /* 只影响输出的代数量 */
  Hold_functionDAE,               /* 全部方程，事件时用 */
  ...
  Hold_functionInitialEquations,  /* 初始化方程 */
  ...
  Hold_function_ZeroCrossings, Hold_function_updateRelations, Hold_checkForAsserts, ...
};

int main(int argc, char**argv)
{
  ...
  Hold_setupDataStruc(&data, threadData);   /* data.callback = &Hold_callback，变量个数等 */
  res = _main_initRuntimeAndSimulation(argc, argv, &data, threadData);
  if (res == 0)
    res = _main_SimulationRuntime(argc, argv, &data, threadData);   /* 或 _main_OptimizationRuntime */
}
```

三个主要的求值函数：

| 回调 | 算什么 | 什么时候调用 |
|---|---|---|
| `functionODE` | 由状态算出状态导数所需的全部方程 | 积分器每次求导数 |
| `functionAlgebraics` | 只影响输出、不影响导数的方程 | 每个输出点前 |
| `functionDAE` | 全部方程，并处理离散变量 | 初始化之后、事件迭代中 |

没有状态的模型（例如 `Hold`）`functionODE` 是空的，代数环都在 `functionDAE` 里。

## 4. 核心数据结构

### 4.1 DATA（`simulation_data.h:1001`）

```c
typedef struct DATA {
  RINGBUFFER* simulationData;        /* SIMULATION_DATA 的环形缓冲 */
  SIMULATION_DATA **localData;       /* localData[0] 当前时刻，[1] 上一时刻，[2] 再上一时刻 */
  MODEL_DATA *modelData;             /* 静态信息：变量个数、名字、属性、方程信息 */
  SIMULATION_INFO *simulationInfo;   /* 运行时状态：参数、pre 值、事件、求解器数据 */
  struct OpenModelicaGeneratedFunctionCallbacks *callback;
  ...
} DATA;
```

| 结构 | 内容 |
|---|---|
| `SIMULATION_DATA` | 一个时刻的变量值：`timeValue`、`realVars`、`integerVars`、`booleanVars`、`stringVars`。环形缓冲大小为 `SIZERINGBUFFER = 3`，每一步 `rotateRingBuffer` 后 `localData[0]` 指向新的一格，旧值留给外推初值和积分器 |
| `MODEL_DATA` | 不随时间变化：变量个数（`nStates`、`nVariablesReal`…）、`realVarsData[i].attribute`（start、min、max、nominal）、参数的静态数据、`modelDataXml`（方程信息） |
| `SIMULATION_INFO` | 随运行变化：参数值（`realParameter`、`booleanParameter`…）、pre 值、关系和零点、sample、`nonlinearSystemData`、`linearSystemData`、`mixedSystemData`、选项（`nlsMethod`、`tolerance`…） |
| `NONLINEAR_SYSTEM_DATA`（`simulation_data.h:400`） | 一个非线性系统：`size`、`residualFunc`、`analyticalJacobianColumn`、`nlsx`（当前迭代变量）、`nlsxOld`、`nlsxExtrapolation`、`min`/`max`/`nominal`、`nlsMethod`、`solverData`、统计、`hgtBounds` |
| `SOLVER_INFO`（`solver_main.h:56`） | 积分器状态：`currentTime`、`currentStepSize`、`solverMethod`、事件列表、`didEventStep`、积分器私有数据 `solverData` |
| `threadData_t` | 每个线程一份：错误跳转点（`mmc_jumper`、`simulationJumpBuffer`、`globalJumpBuffer`）、`currentErrorStage`、`lastEquationSolved` |

### 4.2 变量怎么访问

生成代码中所有变量都是数组下标：`data->localData[0]->realVars[i]`、`data->simulationInfo->realParameter[i]`、`data->modelData->realVarsData[i].attribute.start`。下标由编译器在 SimCode 阶段分配，`init.xml` 中的 `valueReference` 也是这个下标。

## 5. 执行流程总览

```
main                                                    （生成，Hold.c）
├─ Hold_setupDataStruc                                   回调表、变量个数
├─ _main_initRuntimeAndSimulation                        simulation_runtime.cpp
│   └─ initRuntimeAndSimulation
│       ├─ 解析命令行、日志设置
│       ├─ read_input_xml                                读 Hold_init.xml
│       ├─ callback->updateStructuralParameters（可选）
│       ├─ initializeDataStruc                           分配 DATA（model_help.c）
│       ├─ 读 -nls、-ls、-newton、-nlsLS 等
│       ├─ setAllParamsToStart                           参数取 start
│       └─ initializeMixedSystems / LinearSystems / NonlinearSystems
└─ _main_SimulationRuntime
    ├─ startNonInteractiveSimulation
    │   ├─ 读 -override 等，构造输出过滤
    │   └─ callSolver                                    选积分器、initializeResultData
    │       └─ solver_main                               solver_main.c
    │           ├─ initializeSolverData                  积分器初始化
    │           ├─ initializeModel
    │           │   ├─ copyStartValuestoInitValues、输入函数
    │           │   └─ initialization                     initialization.c
    │           │       ├─ updateBoundParameters / updateBoundVariableAttributes
    │           │       ├─ symbolic_initialization
    │           │       │   └─ callback->functionInitialEquations   （可能经 homotopy）
    │           │       │       └─ eqFunction… / solve_nonlinear_system / solve_linear_system
    │           │       └─ initSample、事件、pre 值
    │           ├─ updateSolverNominals
    │           ├─ sim_result.emit                        写初始点
    │           ├─ callback->performSimulation           主循环（perform_simulation.c.inc）
    │           │   └─ while t < stopTime:
    │           │       ├─ rotateRingBuffer
    │           │       ├─ 步长、checkForSynchronous、checkForSampleEvent
    │           │       ├─ simulationStep → solver_main_step → dassl/cvode/ida/gbode…
    │           │       │                                    （内部调用 functionODE）
    │           │       ├─ simulationUpdate
    │           │       │   ├─ updateContinuousSystem: functionODE + functionAlgebraics + 输出
    │           │       │   ├─ saveZeroCrossings、handleTimers
    │           │       │   ├─ checkEvents → handleEvents → updateDiscreteSystem（functionDAE 迭代）
    │           │       │   └─ checkForAsserts、storePreValues
    │           │       ├─ sim_result.emit                写输出点
    │           │       └─ check_nonlinear/linear/mixed_solutions
    │           └─ finishSimulation                       统计、-output 变量、关闭结果文件
    ├─ freeMixed/Linear/NonlinearSystems
    └─ deInitializeDataStruc
```

## 6. 启动：读入模型和参数

`initRuntimeAndSimulation`（`simulation_runtime.cpp:941`）：

1. 解析命令行（`-lv` 日志、`-override`、`-s`、`-nls` 等），选项表在 `util/simulation_options.c`，名字、说明、类型、能否重复都在那里登记。
2. `read_input_xml`（`simulation_input_xml.c:1350`）读 `Hold_init.xml`：每个变量和参数的名字、start、fixed、min/max/nominal，仿真选项。`-override` 在这里覆盖 start 和参数值。
3. 有结构参数时，`callback->updateStructuralParameters` 重新算变量大小。
4. `initializeDataStruc`（`model_help.c:1337`）：分配环形缓冲、参数数组、pre 值、零点、sample、delay 等。
5. 读 `-nls`、`-ls`、`-lss`、`-newton`、`-nlsLS`，存进 `simulationInfo`。
6. `setAllParamsToStart`：参数取 start 值（之后初始化时由 `updateBoundParameters` 算出依赖其他参数的参数）。
7. `initializeMixedSystems`、`initializeLinearSystems`、`initializeNonlinearSystems`：先调生成的 `Hold_initialNonLinearSystem` 登记系统，再为每个系统分配求解器数据（`initializeNonlinearSystemData`，`nonlinearSystem.c:392`），并决定求解方法（见 §9.3）。

`startNonInteractiveSimulation` 再处理输出过滤、`-output`、结果格式，`callSolver`（`simulation_runtime.cpp:760`）把 `-s` 翻译成 `SOLVER_METHOD`，初始化结果文件后调用 `solver_main`。

## 7. 初始化

### 7.1 `solver_main` 和 `initializeModel`

`solver_main`（`solver_main.c:629`）：

1. 修正太小的步长；`initializeSolverData` 初始化积分器。
2. `initializeModel`（`solver_main.c:394`）：
   - `copyStartValuestoInitValues`：变量取 start；
   - 调用输入函数（外部输入、`input_function_init`）；
   - `initialization(...)`，失败时把 `stopTime` 设成 `startTime`，返回错误；
   - 成功时打印 "The initialization finished successfully without homotopy method."；
   - 把初始化后的参数再写一次结果文件。
3. `updateSolverNominals`。
4. 按情况分三条路：
   - 模型没有随时间变化的变量：写一个点，直接 `finishSimulation`；
   - QSS：`performQSSSimulation`；
   - 其他：`sim_result.emit` 写初始点，`callback->performSimulation` 进主循环，最后 `finishSimulation`。

### 7.2 `initialization`（`initialization.c:783`）

1. `updateBoundParameters`、`updateBoundVariableAttributes`：算出依赖参数的参数和 start/min/max/nominal（例如 HGT 中 `start = x0`）。
2. `function_initSpatialDistribution`。
3. 初始化方法（`-iim`）：默认 `symbolic`，调用 `symbolic_initialization`；`none` 跳过。
4. 之后初始化 sample、关系、pre 值，准备进入仿真。

### 7.3 `symbolic_initialization`（`initialization.c:297`）

- 检查有没有非线性系统支持 homotopy（模型中用了 `homotopy()` 算子）。
- 没有 homotopy：`lambda = 1`，直接 `callback->functionInitialEquations`。
- 有 homotopy：
  - 先试不用 homotopy 解一次（除非 `-homotopyOnFirstTry`）；
  - 失败后按 `homotopyMethod` 走全局等距、全局自适应或局部 homotopy：等距时外层循环 `lambda = 0 … 1`，每一步都调用 `functionInitialEquations`。

`functionInitialEquations`（`Hold_06inz.c`）按顺序执行初始化系统的方程；遇到代数环调用 `solve_nonlinear_system`，于是进入 §9。

## 8. 主仿真循环

`performSimulation`（`perform_simulation.c.inc:452` 起，实际函数名 `Hold_performSimulation`）：

```
while currentTime < stopTime:
    -steadyState：所有状态导数都足够小就提前结束
    rotateRingBuffer、continueSimulationData       新的一格 localData[0]
    算下一步长：到下一个输出点；事件之后的步、上次失败后缩短的步另行处理
    checkForSynchronous、checkForSampleEvent        时间事件可能缩短这一步
    simulationStep → solver_main_step              一步积分（dassl/cvode/ida/gbode/euler…）
    simulationUpdate                               见下
    成功：恢复步长上限，fmtEmitStep（写输出点），统计，检查终止
          integrator / 非线性 / 线性 / 混合系统失败 → 结束
    失败（longjmp 回来）：步长减半重试，最多 -maxStepRetries 次
```

`solver_main_step`（`solver_main.c:95`）按 `solverMethod` 分发：`dassl_step`、`ida_solver_step`、`cvode_solver_step`、`gbode_main`、`euler_ex_step`、`rungekutta_step`、`sym_solver_step`、`ipopt_step`。积分器内部需要导数时调用 `functionODE`（DAE 模式下调用 DAE 残差）。

`simulationUpdate`（`perform_simulation.c.inc:107`）是一步积分之后的"整理"：

1. `updateContinuousSystem`：外部输入，`functionODE` + `functionAlgebraics`（DAE 模式下 `evaluateDAEResiduals`），输出函数，`setc`/`setb`，`storeDelayed`。
2. `saveZeroCrossings`；`handleTimers`（同步特性）。
3. 循环：
   - `checkEvents`（`events.c:126`）：时间事件或零点变号；
   - 有事件：先写左极限，`handleEvents`（`events.c:176`）定位事件时刻，调用 `updateDiscreteSystem`；
   - `stateSelection`：动态状态选择可能切换；
   - `checkForAsserts`、`storePreValues`、`storeOldValues`。
4. 有事件时再存 `delay` 和 `spatialDistribution`。

`updateDiscreteSystem`（`model_help.c:102`）是**事件迭代**：调用 `functionDAE`，只要离散变量或关系还在变化（`checkForDiscreteChanges`、`checkRelations`、`needToIterate`），就 `storePreValues` 后再调用一次，直到不动点。

## 9. 代数系统的求解

### 9.1 入口 `solve_nonlinear_system`（`nonlinearSystem.c:1236`）

生成代码中每个代数环都是一句 `solve_nonlinear_system(data, threadData, sysNumber)`。它做的事：

1. **初值**：
   - 上次求解时刻离现在不远（`< 5 * stepSize`）时，`getInitialGuess` 用前几个时刻的解外推；
   - 否则用当前变量值（`getIterationVars`）和 `nlsxOld`；
   - HGT 块（`hgtBounds`）：初值投影到 `[min, max]`。
2. **homotopy 的决定**：只有初始化系统且这个系统支持 homotopy 时才考虑；按 `homotopyMethod`（全局/局部、等距/自适应）和 `-homotopyOnFirstTry` 决定先不用 homotopy 试一次，还是直接沿 `lambda` 路径求解（`solveWithInitHomotopy`）。
3. **求解**：`solveNLS`。
4. 记录结果、统计、日志；失败时根据 `currentErrorStage` 决定是抛错还是交给上层（初始化失败、积分步重试）。

### 9.2 分发 `solveNLS`（`nonlinearSystem.c:1044`）

按 `nonlinsys->nlsMethod`：

| 方法 | 函数 | 说明 |
|---|---|---|
| `NLS_HYBRID` | `solveHybrd`（`nonlinearSolverHybrd.c`） | MINPACK 的 Powell hybrid，带多种重试策略 |
| `NLS_KINSOL` | `nlsKinsolSolve`（`kinsolSolver.c`） | SUNDIALS KINSOL，Newton + 线搜索，支持稀疏（KLU） |
| `NLS_KINSOL_B` | `B_nlsKinsolSolve`（`kinsol_b.c`） | KINSOL 的另一种封装 |
| `NLS_NEWTON` | `solveNewton`（`nonlinearSolverNewton.c`） | 阻尼 Newton |
| `NLS_HOMOTOPY` | `solveHomotopy`（`nonlinearSolverHomotopy.c`） | 带 Newton 的 homotopy 求解器 |
| `NLS_MIXED`（默认） | 先 `solveHomotopy`，失败再 `solveHybrd` | |

每种方法都包在 `OMC_TRY_INTERNAL(simulationJumpBuffer)` 里：残差函数里的断言或除零会 `longjmp` 回来，被当成这次求解失败。用了动态撕裂（casual tearing set）时，失败后再用 strict tearing set 解一次。

成功之后，HGT 块再经过 `checkHGTBounds`（`nonlinearSystem.c:1020`）检查解是否在界内。

### 9.3 求解方法怎么选

`initializeNonlinearSystemData`（`nonlinearSystem.c:392`）：

- 默认用 `-nls` 指定的方法（默认 `mixed`）。
- 稀疏格式、有稀疏模式的系统，如果没有指定 KINSOL，强制改成 KINSOL + KLU。
- 1×1 系统没有稀疏模式时，KINSOL 退回 hybrid，并给警告。

### 9.4 求解器怎么用残差函数

所有求解器都只通过三个接口和模型交互：

- `residualFunc(userData, x, res, iflag)`：§3.2，写入迭代变量，算内部方程和残差；
- `analyticalJacobianColumn`：符号雅可比矩阵的一列（`Hold_12jac.c`），没有就用差分；
- `getIterationVars`：把当前变量值读成迭代向量。

求解器之间的差别只在"怎么迭代"：初值、缩放（例如 KINSOL 的 `nlsKinsolFScaling` 按雅可比矩阵每行的最大值缩放残差）、步长控制、失败后的重试。

### 9.5 线性系统和混合系统

- `solve_linear_system`（`linearSystem.c:408`）：生成代码提供系数矩阵和右端项（或残差函数），按 `-ls` 选 LAPACK、KLU、UMFPACK、LIS、全主元。
- `solve_mixed_system`（`mixedSystem.c:118`）：连续未知量和离散未知量耦合的系统，外层枚举离散变量（`mixedSearchSolver.c`），内层解连续部分。

## 10. FMU 的执行路径

FMU 用的是**同一套**运行时代码（打包进 FMU 的文件清单在 `RuntimeSources.mo`），但没有 `main` 和主循环，由 FMI 函数驱动（`fmu2_model_interface.c`）：

| FMI 调用 | 运行时做什么 |
|---|---|
| `fmi2Instantiate`（663） | `setupDataStruc`、`initializeDataStruc`（788）、读模型数据、`initializeNonlinearSystems`（801） |
| `fmi2SetReal` 等 | 写参数、输入、状态；标记需要重新求值 |
| `fmi2ExitInitializationMode`（1018） | `initialization(...)`（1041），和独立仿真的初始化相同 |
| `fmi2GetReal` 等 | `updateIfNeeded`（560）：需要时调用 `functionODE` + `functionAlgebraics`，代数环在这里求解 |
| `fmi2GetDerivatives`（2250） | `functionODE` |
| `fmi2NewDiscreteStates`（2051） | 事件迭代（`functionDAE`） |
| `fmi2GetDirectionalDerivative`（1941） | 生成的 FMIDER 雅可比矩阵 |
| `fmi2DoStep`（2559，Co-Simulation） | FMU 内部用 CVODE 或 Euler 积分 |

和独立仿真的区别：

- 时间推进、积分器、事件定位由 FMI 的使用者负责（Model Exchange），或者由 FMU 内部的 `fmi2DoStep` 负责（Co-Simulation）；
- 代数环仍然在 FMU 内部求解，打包进 FMU 的非线性求解器只有 hybrid 和 homotopy（没有 KINSOL）；
- 没有结果文件，变量通过 `fmi2GetReal` 读出。

## 11. 横切机制

### 11.1 错误处理

运行时用 `setjmp/longjmp` 模拟异常（`gc/omc_gc.h:159`）：

```c
OMC_TRY_INTERNAL(simulationJumpBuffer)   /* setjmp，保存跳转点 */
  solver_status = solveHybrd(...);
OMC_CATCH_INTERNAL(simulationJumpBuffer) /* 恢复旧的跳转点 */
```

- 生成代码中的断言、除零、求解失败调用 `throwStreamPrint` / `omc_throw`，`longjmp` 到最近的跳转点。
- 跳转点有几层：`globalJumpBuffer`（整次运行）、`simulationJumpBuffer`（一次初始化、一步积分、一次非线性求解）。
- `threadData->currentErrorStage`（`ERROR_SIMULATION`、`ERROR_EVENTHANDLING`、初始化…）决定错误怎么处理，例如积分步失败会缩短步长重试。
- 主循环中，积分步失败后步长减半重试（`retrySimulationStep`）。

### 11.2 日志

- `-lv=LOG_INIT,LOG_NLS,LOG_EVENTS,...` 打开日志流；代码中用 `infoStreamPrint(OMC_LOG_xxx, indent, ...)`、`warningStreamPrint`、`errorStreamPrint`、`messageClose`。
- `-w` 打开更多警告，`-lv=LOG_STATS` 打印统计。
- OMEdit 中通过 `-logFormat=xmltcp` 把日志以 XML 发到 socket。

### 11.3 结果输出

`sim_result` 是一个函数指针结构（`simulation/results/simulation_result.h`）：`init`、`emit`、`writeParameterData`、`free`。`initializeResultData` 按 `-outputFormat`（mat、csv、plt、empty、ia）选择实现。主循环只调用 `sim_result.emit`。`-variableFilter` 和 `-output` 在 `startNonInteractiveSimulation` 中处理。

### 11.4 内存

`omc_alloc_interface`（`gc/`）是可替换的分配器；仿真中周期性调用 `collect_a_little()`。生成的 MetaModelica 函数和字符串用它分配。

## 12. Rust 运行时

`--simCodeTarget=C+Rust` 时，生成的 C 代码**完全不变**，链接的不是 `libSimulationRuntimeC`，而是 `libSimulationRuntimeRust`（`OMCompiler/SimulationRuntime/rust/openmodelica_simulation_runtime`）。它实现同一套 ABI：

| 文件 | 作用 |
|---|---|
| `run.rs` | 入口 `_main_initRuntimeAndSimulation`、`_main_SimulationRuntime`：解析命令行、读 init.xml、分配 `DATA`、运行驱动、写结果 |
| `abi.rs` | `DATA`、`SIMULATION_INFO`、`NONLINEAR_SYSTEM_DATA` 等 C 结构的镜像（字段顺序必须和 C 一致） |
| `engine.rs` | `SimEngine`：通过 `data->callback` 调用生成的模型函数 |
| `nls.rs`、`systems.rs`、`mixed.rs` | 代数系统，对应 `nonlinearSystem.c`、`linearSystem.c`、`mixedSystem.c` |
| `fmi*.rs` | FMU 导出 |
| `operators.rs`、`spatial.rs`、`stateset.rs`、`sync.rs` | 各种算子和特性 |

积分、事件等驱动逻辑在 `openmodelica_sim_meta::driver`，求解器在 `openmodelica_solvers`、`openmodelica_nls`（KINSOL 的移植等），和 wasm-jit 目标共用。

改运行时行为时，C 和 Rust 两边要保持一致。HGT 的界检查就是这样做的：C 在 `nonlinearSystem.c`，Rust 在 `nls.rs`，警告文字也相同。

## 13. HGT 在运行时中的位置

HGT 的大部分工作在编译器里完成，运行时只多了一点：

| 位置 | 内容 |
|---|---|
| `simulation_data.h` | `NONLINEAR_SYSTEM_DATA.hgtBounds`：这个系统是否有 HGT 迭代变量的界 |
| 生成的 `initializeStaticDataNLSN` | 用 HGT 的 min/max 设置 `sysData->min/max`，并置 `hgtBounds` |
| `solve_nonlinear_system` | `hgtBounds` 时初值投影到界内 |
| `checkHGTBounds`（`nonlinearSystem.c:1020`） | 求解成功后检查解在界内，越界警告并改判为失败 |
| `kinsolSolver.c:1324` | 用 min/max 设置 KINSOL 的符号约束 |
| `nonlinearSolverHomotopy.c` | Newton 迭代点投影到界内 |
| Rust `nls.rs` | 以上逻辑的 Rust 版 |

hold 现在不支持（只解析，给警告 8009 后忽略）。已撤销的按配对实现（[HGT_hold.md](HGT_hold.md)）也不需要运行时支持：它把开关编译进生成的残差表达式。

## 14. 读代码的顺序与调试

### 14.1 推荐的顺序

1. 编译一个小模型（`buildModel`），先读生成的 `Hold.c`、`Hold_02nls.c`、`Hold_06inz.c`，知道运行时会调用什么。
2. `simulation_data.h` 中的 `DATA`、`SIMULATION_DATA`、`NONLINEAR_SYSTEM_DATA`。
3. `simulation_runtime.cpp`：`initRuntimeAndSimulation`、`startNonInteractiveSimulation`、`callSolver`。
4. `solver_main.c`：`solver_main`、`initializeModel`、`solver_main_step`。
5. `initialization.c`：`initialization`、`symbolic_initialization`。
6. `perform_simulation.c.inc`：主循环、`simulationUpdate`。
7. `events.c`、`model_help.c` 中的 `updateDiscreteSystem`。
8. `nonlinearSystem.c`：`initializeNonlinearSystemData`、`solve_nonlinear_system`、`solveNLS`，再挑一个求解器（建议先读 `nonlinearSolverNewton.c`，再读 `kinsolSolver.c`）。
9. `fmu2_model_interface.c`：对照 §10，看 FMU 怎么复用上面这些。

### 14.2 调试方法

| 手段 | 用途 |
|---|---|
| `-lv=LOG_INIT,LOG_INIT_V` | 初始化过程、初始值 |
| `-lv=LOG_NLS,LOG_NLS_V,LOG_NLS_RES,LOG_NLS_JAC` | 非线性系统：初值、每次迭代、残差、雅可比 |
| `-lv=LOG_EVENTS,LOG_EVENTS_V` | 事件 |
| `-lv=LOG_SOLVER,LOG_SOLVER_V` | 积分器 |
| `-lv=LOG_STATS` | 统计：函数调用次数、各部分耗时 |
| `-output=x,y` | 结束时打印变量 |
| `-nls=kinsol`、`-ls=klu`、`-s=ida` | 换求解器对比 |
| `simulate(..., simflags="-lv=LOG_NLS_V")` | 在 omc 脚本中传运行时选项 |
| gdb | 生成的可执行文件可以直接调试；`-d=gendebugsymbols` 生成调试信息，断点设在 `solve_nonlinear_system`、`residualFuncN` |
| `<model>_info.json` | 由方程编号（日志中的 `equationIndexes`）查到源方程 |
