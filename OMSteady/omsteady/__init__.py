"""omsteady: steady-state solving of OpenModelica hand guided tearing problems.

See doc/HGT_interactive_fmu_phase1.md in the OpenModelica repository.
"""

from .problem import SteadyProblem, FunctionProblem
from .solver import Solver, Solution
from .structure import HoldError, HoldBalanceError, StructuralSingularityError

__all__ = ["SteadyProblem", "FunctionProblem", "FMUProblem", "Solver", "Solution",
           "HoldError", "HoldBalanceError", "StructuralSingularityError"]


def __getattr__(name):
    # FMUProblem needs FMPy, load it only when it is used
    if name == "FMUProblem":
        from .fmu import FMUProblem
        return FMUProblem
    raise AttributeError(name)
