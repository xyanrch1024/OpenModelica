"""Test problems written as Python functions, mirroring the Modelica models of
doc/HGT_cross_hold.md and testsuite/simulation/modelica/tearing/HGT.mo."""

import math

from omsteady import FunctionProblem


def two_eq_steady_state_para_hold():
    """OCT's twoEqSteadyStateParaHold: pair 0 is LongEq / x, pair 1 is LongEq2 / T.
    testHold1 holds T and drops LongEq, testHold2 holds x and drops LongEq2."""
    k = lambda T: 0.12 * math.exp(12581 * (T - 298) / (298 * T))
    return FunctionProblem(
        variables={"x": 1.0, "T": 400.0},
        residuals={
            "LongEq": lambda v: 0 - (120 * v["x"] - 75 * k(v["T"]) * (1 - v["x"])),
            "LongEq2": lambda v: 0 - (-v["x"] * (873 - v["T"]) + 11.0 * (v["T"] - 300)),
        },
        depends={"LongEq": ["x", "T"], "LongEq2": ["x", "T"]},
        parameters={"testHold1": False, "testHold2": False},
        variable_hold={"x": lambda p: p["testHold2"], "T": lambda p: p["testHold1"]},
        residual_hold={"LongEq": lambda p: p["testHold1"], "LongEq2": lambda p: p["testHold2"]},
        nominal={"T": 100.0})


def two_blocks():
    """e1 only contains p, so without hold e1 / p and e2 / m are two blocks.
    design holds m and drops e1: e2 then determines p (a hold across blocks)."""
    return FunctionProblem(
        variables={"p": 1.0, "m": 1.0},
        residuals={
            "e1": lambda v: v["p"] ** 3 + v["p"] - 10,
            "e2": lambda v: v["m"] ** 2 - v["k"] * (v["p"] - v["p_out"]),
        },
        depends={"e1": ["p"], "e2": ["p", "m"]},
        parameters={"design": False, "k": 1.0, "p_out": 1.0},
        variable_hold={"m": lambda p: p["design"]},
        residual_hold={"e1": lambda p: p["design"]})


def bound(max_y=3.0):
    """HGT.Bound: y = log(x), x + y^3 = 30, iterate on y from 4. Without the
    max bound the first point already has x < 0."""
    return FunctionProblem(
        variables={"y": 4.0},
        residuals={"r": lambda v: math.log(30 - v["y"] ** 3) - v["y"]},
        depends={"r": ["y"]},
        max={"y": max_y})
