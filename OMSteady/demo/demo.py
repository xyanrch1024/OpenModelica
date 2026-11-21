#!/usr/bin/env python3
"""HGT 稳态求解演示：冷却水回路的校核、设计和限温工况。

用法：
    python3 demo.py              # 每一步之后按回车继续
    python3 demo.py --no-pause   # 一次跑完
    python3 demo.py --omc /path/to/omc

需要这个分支编译出的 omc，以及 pip install numpy fmpy。
说明见同目录的 README.md。
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

from omsteady import FMUProblem, Solver, HoldBalanceError, StructuralSingularityError  # noqa: E402

MODEL = os.path.join(HERE, "CoolingLoop.mo")
SHOWN = ["m", "m1", "T1", "T2", "n", "opening"]
UNITS = {"m": "kg/s", "m1": "kg/s", "T1": "degC", "T2": "degC", "n": "", "opening": ""}
TEXT = {"m": "总流量", "m1": "支路 1 流量", "T1": "冷却器 1 出口温度", "T2": "冷却器 2 出口温度",
        "n": "泵转速", "opening": "阀门开度"}

PAUSE = True


def step(title, *lines):
    if PAUSE:
        try:
            input("\n[按回车继续] ")
        except EOFError:
            pass
    print("\n" + "=" * 78)
    print(title)
    print("=" * 78)
    for line in lines:
        print(line)
    print()


def find_omc(given):
    candidates = [given, os.environ.get("OMC"),
                  os.path.join(ROOT, "build_cmake", "install_cmake", "bin", "omc"),
                  shutil.which("omc")]
    omc = next((c for c in candidates if c and os.path.isfile(c)), None)
    if omc is None:
        sys.exit("找不到 omc：用 --omc 或环境变量 OMC 指定这个分支编译出的 omc")
    return omc


def run_omc(omc, workdir, name, commands):
    script = os.path.join(workdir, name + ".mos")
    with open(script, "w") as f:
        f.write("\n".join(commands) + "\n")
    t = time.time()
    out = subprocess.run([omc, script], cwd=workdir, capture_output=True, text=True, timeout=900)
    return out.stdout + out.stderr, time.time() - t


def build_fmu(omc, workdir):
    out, seconds = run_omc(omc, workdir, "build", [
        'loadFile("%s"); getErrorString();' % MODEL,
        'setCommandLineOptions("--handGuidedTearing --interactiveFMU -d=hgtDump"); getErrorString();',
        'buildModelFMU(CoolingLoop, version = "2.0", fmuType = "me"); getErrorString();'])
    fmu = os.path.join(workdir, "CoolingLoop.fmu")
    if not os.path.isfile(fmu):
        sys.exit("omc 没有生成 FMU：\n" + out)
    # 只显示 hgtDump 的部分
    dump = [l for l in out.splitlines() if l.startswith(("Hand guided", "  "))]
    return fmu, "\n".join(dump), seconds


def simulate_reference(omc, workdir):
    """同一个模型用普通的 HGT 撕裂和现有运行时求解，作为对照。"""
    out, _ = run_omc(omc, workdir, "simulate", [
        'loadFile("%s"); getErrorString();' % MODEL,
        'setCommandLineOptions("--handGuidedTearing"); getErrorString();',
        'simulate(CoolingLoop, stopTime = 0);',
        'print("REF " + String(val(m, 0)) + " " + String(val(m1, 0)) + " " + String(val(T1, 0)) + " " + String(val(T2, 0)) + "\\n");'])
    for line in out.splitlines():
        if line.startswith("REF "):
            return [float(x) for x in line.split()[1:]]
    return None


def solve(p, **options):
    t = time.time()
    sol = Solver(p, blocks=True, **options).solve()
    ms = (time.time() - t) * 1e3
    held_v = [p.descriptions[p.variable_names[i]] for i in sol.held_variables]
    held_r = [p_label(p, i) for i in sol.held_residuals]
    print("hold 的变量: %s    去掉的方程: %s" % (", ".join(held_v) or "无", ", ".join(held_r) or "无"))
    print("求解顺序（按当前的 hold 重新分块）:")
    for k, (res, var) in enumerate(sol.blocks, start=1):
        print("  块 %d: 由 {%s} 解 {%s}" % (
            k, ", ".join(p_label(p, p.residual_names.index(r)) for r in res),
            ", ".join(p.descriptions[v] for v in var)))
    status = "收敛" if sol.success else "失败: " + sol.message
    print("%s，Newton 迭代 %d 次，残差 %.1e，用时 %.1f ms" % (status, sol.iterations, sol.residual_norm, ms))
    return sol


def show(p, highlight=()):
    values = p.get(SHOWN)
    for name, value in zip(SHOWN, values):
        mark = "  <-- " + highlight[name] if name in highlight else ""
        print("  %s %-8s = %9.4f %-5s%s" % (pad(TEXT[name], 20), name, value, UNITS[name], mark))
    return dict(zip(SHOWN, values))


def main():
    global PAUSE
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--omc", help="omc 的路径")
    parser.add_argument("--no-pause", action="store_true", help="不在每一步之间停顿")
    parser.add_argument("--keep", action="store_true", help="保留工作目录（FMU 和 omc 的输出）")
    args = parser.parse_args()
    PAUSE = not args.no_pause
    omc = find_omc(args.omc)
    workdir = tempfile.mkdtemp(prefix="hgt_demo_")

    print("HGT 稳态求解演示：冷却水回路")
    print("omc: %s" % omc)
    print("模型: %s" % MODEL)

    # ------------------------------------------------------------------------------
    step("1. 模型：工程师在方程上标出迭代变量和残差方程",
         "一台泵，两条并联支路（支路 1 带调节阀），每条支路一台冷却器。",
         "6 个配对，写在方程的注解里，例如回路压力平衡决定总流量 m：")
    with open(MODEL, encoding="utf-8") as f:
        lines = f.read().splitlines()
    start = next(i for i, l in enumerate(lines) if "回路压力平衡" in l)
    print("\n".join(lines[start:start + 4]))
    print("\n  hold = designFlow：这个参数为 true 时，m 不再求解，保持给定的值。")

    # ------------------------------------------------------------------------------
    step("2. 编译：omc --handGuidedTearing --interactiveFMU",
         "迭代变量变成 FMU 的输入 iter_N，残差方程变成输出 res_N，hold 变成参数。",
         "FMU 内部没有任何代数环：给定迭代变量，其余方程依次直接算出。")
    fmu, dump, seconds = build_fmu(omc, workdir)
    print(dump)
    print("\n生成 %s（%.0f kB），用时 %.1f s" % (os.path.basename(fmu), os.path.getsize(fmu) / 1e3, seconds))

    p = FMUProblem(fmu)

    # ------------------------------------------------------------------------------
    step("3. 校核工况：泵转速和阀门开度给定，求流量和温度",
         "所有 hold 都是 false：6 个未知量，6 条残差。")
    solve(p)
    base = show(p)
    ref = simulate_reference(omc, workdir)
    if ref:
        diff = max(abs(a - b) for a, b in zip(ref, [base["m"], base["m1"], base["T1"], base["T2"]]))
        print("\n对照：同一个模型用普通的 HGT 撕裂和现有仿真运行时求解（精度 1e-6），最大偏差 %.1e" % diff)

    # ------------------------------------------------------------------------------
    step("4. 设计工况：要求总流量 16 kg/s，泵要转多快？",
         "不改模型、不重新编译，只设一个参数：designFlow = true。",
         "它 hold 住 m（保持 16），同时去掉方程 n = n_set；回路压力平衡改为用来求 n。")
    p.set("designFlow", True)
    p.set("m", 16.0)
    solve(p)
    show(p, {"m": "给定", "n": "反算出来"})

    # ------------------------------------------------------------------------------
    step("5. 限温工况：冷却器 1 的出口温度定在 45 degC，阀门开多大？",
         "回到额定转速；limitT1 = true：hold 住 T1，去掉方程 opening = opening_set。",
         "注意求解顺序变了：先由能量平衡求 m1，再求开度。")
    p.set("designFlow", False)
    p.set("limitT1", True)
    p.set("T1", 45.0)
    solve(p)
    show(p, {"T1": "给定", "opening": "反算出来"})

    # ------------------------------------------------------------------------------
    step("6. 两个要求同时给：总流量 16 kg/s，并且 T1 = 45 degC",
         "两个参数都为 true：同时反算泵转速和阀门开度。")
    p.set("designFlow", True)
    p.set("m", 16.0)
    solve(p)
    show(p, {"m": "给定", "T1": "给定", "n": "反算出来", "opening": "反算出来"})

    # ------------------------------------------------------------------------------
    step("7. 模型里没有预先写的工况：用 API 直接 hold",
         "要求冷却器 2 的出口温度是 28 degC，泵要转多快？",
         "模型里没有为 T2 写 hold 参数，直接在求解器里 hold 变量 T2、去掉方程 pumpSpec。")
    p.set("designFlow", False)
    p.set("limitT1", False)
    p.holdIterationVariables(["T2"])
    p.holdResiduals(["pumpSpec"])
    p.set("T2", 28.0)
    solve(p)
    show(p, {"T2": "给定", "n": "反算出来"})
    p.releaseIterationVariables(["T2"])
    p.releaseResiduals(["pumpSpec"])

    # ------------------------------------------------------------------------------
    step("8. 工况给错时：求解之前就报错，并指出是哪些变量和方程",
         "(a) 只固定总流量，没有去掉任何方程：方程比未知量多。")
    p.holdIterationVariables(["m"])
    try:
        Solver(p).solve()
    except HoldBalanceError:
        held_v, held_r = p.held()
        print("  HoldBalanceError: 释放的迭代变量有 %d 个，释放的残差方程有 %d 条" % (
            len(p.variable_names) - len(held_v), len(p.residual_names) - len(held_r)))
    print("\n(b) 固定总流量，去掉冷却器 1 的能量平衡：个数对了，但剩下的方程定不出 T1。")
    p.holdResiduals(["energy1"])
    try:
        Solver(p).solve()
    except StructuralSingularityError as e:
        print("  StructuralSingularityError: 没有方程能确定 {%s}，多出来的方程是 {%s}" % (
            ", ".join(p.descriptions[p.variable_names[i]] for i in e.unmatched_variables),
            ", ".join(p_label(p, i) for i in e.unmatched_residuals)))
    p.releaseIterationVariables(["m"])
    p.releaseResiduals(["energy1"])

    # ------------------------------------------------------------------------------
    step("9. 换设备参数：支路 2 的阻力减半，重新校核",
         "参数可以随时改，求解从上一次的解出发。")
    p.set("k2", 0.015)
    solve(p)
    show(p)

    p.terminate()
    if args.keep:
        print("\n工作目录: %s" % workdir)
    else:
        shutil.rmtree(workdir, ignore_errors=True)
    print("\n演示结束。")


def p_label(p, i):
    """残差的 HGT 方程名（res_N 的描述里的 name = ...）。"""
    from omsteady.fmu import equation_name
    name = p.residual_names[i]
    return equation_name(p.descriptions[name]) or name


def pad(text, width):
    """按显示宽度补空格（汉字占两格）。"""
    shown = sum(2 if ord(c) > 0x2e80 else 1 for c in text)
    return text + " " * max(0, width - shown)


if __name__ == "__main__":
    main()
