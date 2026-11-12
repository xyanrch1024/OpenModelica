import math

import pytest

from omsteady import Solver, HoldBalanceError, StructuralSingularityError
from models import two_eq_steady_state_para_hold, two_blocks, bound


def test_official_example_without_hold():
    p = two_eq_steady_state_para_hold()
    sol = Solver(p).solve()
    assert sol.success, sol.message
    x, T = p.get(["x", "T"])
    assert x == pytest.approx(0.963868, abs=1e-6)
    assert T == pytest.approx(346.16370, abs=1e-4)


def test_official_example_hold_temperature():
    # testHold1: T is held at the value set by the user, LongEq is dropped
    p = two_eq_steady_state_para_hold()
    p.set("testHold1", True)
    p.set("T", 330.0)
    sol = Solver(p).solve()
    assert sol.success, sol.message
    assert sol.held_variables == [1] and sol.held_residuals == [0]
    x, T = p.get(["x", "T"])
    assert T == 330.0
    assert x == pytest.approx(11 * 30 / 543, abs=1e-8)


def test_official_example_hold_conversion():
    # testHold2: x is held, LongEq2 is dropped, LongEq determines T
    p = two_eq_steady_state_para_hold()
    p.set("testHold2", True)
    p.set("x", 0.8)
    sol = Solver(p).solve()
    assert sol.success, sol.message
    x, T = p.get(["x", "T"])
    assert x == 0.8
    assert T == pytest.approx(328.98763, abs=1e-4)


def test_official_example_hold_at_start_is_singular():
    # x held at its start 1: LongEq = -120 for every T, the solver must fail
    p = two_eq_steady_state_para_hold()
    p.set("testHold2", True)
    sol = Solver(p).solve()
    assert not sol.success


def test_hold_keeps_the_current_value():
    # the second solve starts from the first solution and holds x there
    p = two_eq_steady_state_para_hold()
    assert Solver(p).solve().success
    x0 = p.get("x")
    p.set("testHold2", True)
    sol = Solver(p).solve()
    assert sol.success
    assert p.get("x") == x0
    assert p.get("T") == pytest.approx(346.16370, abs=1e-4)


@pytest.mark.parametrize("blocks", [False, True])
def test_two_blocks_without_hold(blocks):
    p = two_blocks()
    sol = Solver(p, blocks=blocks).solve()
    assert sol.success, sol.message
    assert p.get("p") == pytest.approx(2.0, abs=1e-9)
    assert p.get("m") == pytest.approx(1.0, abs=1e-9)
    if blocks:
        assert sol.blocks == [(["e1"], ["p"]), (["e2"], ["m"])]


@pytest.mark.parametrize("blocks", [False, True])
def test_two_blocks_hold_across_blocks(blocks):
    # hold m (block 2), drop e1 (block 1): e2 determines p
    p = two_blocks()
    p.set("design", True)
    p.set("m", 2.0)
    sol = Solver(p, blocks=blocks).solve()
    assert sol.success, sol.message
    assert p.get("p") == pytest.approx(5.0, abs=1e-9)
    assert sol.blocks == [(["e2"], ["p"])]


def test_two_blocks_reverse_hold_is_structurally_singular():
    # hold p and drop e2: e1 does not contain m
    p = two_blocks()
    p.holdIterationVariables(["p"])
    p.holdResiduals(["e2"])
    with pytest.raises(StructuralSingularityError) as e:
        Solver(p).solve()
    assert e.value.unmatched_residuals == [0] and e.value.unmatched_variables == [1]


def test_unbalanced_hold():
    p = two_eq_steady_state_para_hold()
    p.holdIterationVariables(["x"])
    with pytest.raises(HoldBalanceError):
        Solver(p).solve()


def test_api_and_parametric_hold_are_merged():
    p = two_eq_steady_state_para_hold()
    p.set("testHold1", True)               # holds T, drops LongEq
    p.holdIterationVariables(["x"])        # and x through the API
    p.holdResiduals(["LongEq2"])
    sol = Solver(p).solve()
    assert sol.success                      # nothing left to solve
    assert sol.held_variables == [0, 1] and sol.held_residuals == [0, 1]
    p.releaseIterationVariables(["x"])
    p.releaseResiduals(["LongEq2"])
    assert Solver(p).solve().success


def test_bound_keeps_log_defined():
    p = bound()
    sol = Solver(p).solve()
    assert sol.success, sol.message
    y = p.get("y")
    assert y <= 3.0
    assert math.log(30 - y ** 3) == pytest.approx(y, abs=1e-8)


def test_without_bound_the_start_can_not_be_evaluated():
    p = bound(max_y=float("inf"))
    sol = Solver(p).solve()
    assert not sol.success


@pytest.mark.parametrize("scaling", ["none", "automatic", "manual", "hybrid"])
def test_residual_scalings(scaling):
    p = two_eq_steady_state_para_hold()
    assert Solver(p, residual_scaling=scaling).solve().success
    assert p.get("T") == pytest.approx(346.16370, abs=1e-4)


def _chain(n):
    """r_0: x_0 = 1, r_i: x_i = x_{i-1} + 1: n blocks of one item, solved in a
    chain of length n (deeper than the Python recursion limit)."""
    from omsteady import FunctionProblem
    names = ["x%d" % i for i in range(n)]
    residuals = {"r0": lambda v: v["x0"] - 1}
    depends = {"r0": ["x0"]}
    for i in range(1, n):
        residuals["r%d" % i] = (lambda i: lambda v: v[names[i]] - v[names[i - 1]] - 1)(i)
        depends["r%d" % i] = [names[i - 1], names[i]]
    return FunctionProblem(variables={x: 0.0 for x in names}, residuals=residuals, depends=depends)


def test_long_chain_blocks():
    n = 1500
    p = _chain(n)
    sol = Solver(p, blocks=True).solve()
    assert sol.success, sol.message
    assert len(sol.blocks) == n and sol.blocks[0] == (["r0"], ["x0"])
    assert p.get("x%d" % (n - 1)) == pytest.approx(n, abs=1e-6)


def test_long_augmenting_path():
    from omsteady import structure
    n = 3000
    # r_0 depends on x_0, r_i on x_{i-1} and x_i. Matching r_1 ... r_{n-1} first
    # gives r_i the variable x_{i-1}, so r_0 needs an augmenting path through all
    # of them.
    deps = [{0}] + [{i - 1, i} for i in range(1, n)]
    m = structure.maximum_matching(list(range(1, n)) + [0], list(range(n)), deps)
    assert m.perfect
    assert m.residual_to_variable[0] == 0 and m.residual_to_variable[n - 1] == n - 1
