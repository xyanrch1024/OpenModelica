"""The steady-state problem: iteration variables, residuals and their holds.

SteadyProblem holds what every backend shares: the names, the structure, the
attributes, the holds set through the API, and printInfo. A backend
(FunctionProblem here, FMUProblem in fmu.py) implements how values are set and
residuals are evaluated.
"""

import sys

import numpy as np


class SteadyProblem:
    """Base class of a steady-state problem with n iteration variables and m
    residuals. Pair N is iteration variable N and residual N (as iter_N and
    res_N of an interactive FMU), but a held item does not need its pair."""

    def __init__(self, variable_names, residual_names, dependencies,
                 variable_nominal=None, variable_min=None, variable_max=None,
                 residual_nominal=None):
        n = len(variable_names)
        m = len(residual_names)
        self.variable_names = list(variable_names)
        self.residual_names = list(residual_names)
        self.dependencies = [set(d) for d in dependencies]
        if len(self.dependencies) != m:
            raise ValueError("one dependency set per residual expected")
        self.variable_nominal = _array(variable_nominal, n, 1.0)
        self.variable_min = _array(variable_min, n, -np.inf)
        self.variable_max = _array(variable_max, n, np.inf)
        # 0 means no nominal was given, as in OCT interactive FMUs
        self.residual_nominal = _array(residual_nominal, m, 0.0)
        self._api_held_variables = set()
        self._api_held_residuals = set()

    # --- to be implemented by a backend -------------------------------------

    def get_iteration_values(self):
        """Current values of all iteration variables."""
        raise NotImplementedError

    def set_iteration_values(self, values):
        """Sets all iteration variables."""
        raise NotImplementedError

    def evaluate_residuals(self):
        """Residuals at the current iteration values. May raise, or return
        non-finite values, if the model can not be evaluated there."""
        raise NotImplementedError

    def parametric_hold(self):
        """(held variables, held residuals) as Boolean arrays, from the hold
        parameters of the model (iter_N_hold, res_N_hold)."""
        return (np.zeros(len(self.variable_names), dtype=bool),
                np.zeros(len(self.residual_names), dtype=bool))

    def jacobian_column(self, variable):
        """d residuals / d iteration variable, or None if not available (then
        the solver uses finite differences)."""
        return None

    # --- holds ----------------------------------------------------------------

    def variable_index(self, item):
        return _index(item, self.variable_names, "iteration variable")

    def residual_index(self, item):
        return _index(item, self.residual_names, "residual")

    def holdIterationVariables(self, items):
        """Holds iteration variables (names or indices) at their current value."""
        self._api_held_variables.update(self.variable_index(i) for i in items)

    def releaseIterationVariables(self, items):
        self._api_held_variables.difference_update(self.variable_index(i) for i in items)

    def holdResiduals(self, items):
        """Drops residuals (names or indices) from the problem."""
        self._api_held_residuals.update(self.residual_index(i) for i in items)

    def releaseResiduals(self, items):
        self._api_held_residuals.difference_update(self.residual_index(i) for i in items)

    def held(self):
        """(held variables, held residuals): the union of the API holds and the
        parametric holds."""
        hv, hr = self.parametric_hold()
        held_vars = self._api_held_variables | {i for i, h in enumerate(hv) if h}
        held_res = self._api_held_residuals | {i for i, h in enumerate(hr) if h}
        return held_vars, held_res

    # --- information ----------------------------------------------------------

    def printInfo(self, what="all", file=None):
        """Prints the iteration variables and residuals: 'all', 'held' or
        'parametricHold'."""
        file = file or sys.stdout
        hv, hr = self.parametric_hold()
        held_vars, held_res = self.held()
        values = self.get_iteration_values()
        for i, name in enumerate(self.variable_names):
            if what == "held" and i not in held_vars:
                continue
            if what == "parametricHold" and not hv[i]:
                continue
            print("iteration variable %d %s = %g%s" % (
                i, name, values[i], " (held)" if i in held_vars else ""), file=file)
        for i, name in enumerate(self.residual_names):
            if what == "held" and i not in held_res:
                continue
            if what == "parametricHold" and not hr[i]:
                continue
            print("residual %d %s%s" % (i, name, " (held)" if i in held_res else ""), file=file)


class FunctionProblem(SteadyProblem):
    """A problem given by Python functions, for tests and small examples.

    variables  -- {name: start value}
    residuals  -- {name: f(v)}, v maps the names of the variables and the
                  parameters to their current values
    depends    -- {residual name: [variable names]}; the structure
    parameters -- {name: value}
    variable_hold, residual_hold -- {name: bool or f(p)}, p maps the parameter
                  names to their values; missing items are not held
    """

    def __init__(self, variables, residuals, depends, parameters=None,
                 variable_hold=None, residual_hold=None,
                 nominal=None, min=None, max=None, residual_nominal=None):
        var_names = list(variables)
        res_names = list(residuals)
        dependencies = [{var_names.index(v) for v in depends[r]} for r in res_names]
        attr = lambda d, default: [(d or {}).get(v, default) for v in var_names]
        super().__init__(var_names, res_names, dependencies,
                         attr(nominal, 1.0), attr(min, -np.inf), attr(max, np.inf),
                         [(residual_nominal or {}).get(r, 0.0) for r in res_names])
        self._values = np.array([float(variables[v]) for v in var_names])
        self._functions = [residuals[r] for r in res_names]
        self.parameters = dict(parameters or {})
        self._variable_hold = dict(variable_hold or {})
        self._residual_hold = dict(residual_hold or {})

    def get_iteration_values(self):
        return self._values.copy()

    def set_iteration_values(self, values):
        self._values = np.array(values, dtype=float)

    def evaluate_residuals(self):
        env = dict(self.parameters)
        env.update(zip(self.variable_names, self._values))
        return np.array([float(f(env)) for f in self._functions])

    def parametric_hold(self):
        held = lambda spec, names: np.array(
            [bool(spec[n](self.parameters) if callable(spec[n]) else spec[n]) if n in spec else False
             for n in names], dtype=bool)
        return held(self._variable_hold, self.variable_names), held(self._residual_hold, self.residual_names)

    def set(self, name, value):
        """Sets a parameter or (the current value of) an iteration variable."""
        if name in self.parameters:
            self.parameters[name] = value
        else:
            self._values[self.variable_index(name)] = float(value)

    def get(self, names):
        """Values of parameters or iteration variables."""
        single = isinstance(names, str)
        result = [self.parameters[n] if n in self.parameters else self._values[self.variable_index(n)]
                  for n in ([names] if single else names)]
        return result[0] if single else result


def _array(values, n, default):
    if values is None:
        return np.full(n, default, dtype=float)
    a = np.array([default if v is None else v for v in values], dtype=float)
    if a.shape != (n,):
        raise ValueError("expected %d values" % n)
    return a


def _index(item, names, kind):
    if isinstance(item, (int, np.integer)):
        if not 0 <= item < len(names):
            raise IndexError("no %s with index %d" % (kind, item))
        return int(item)
    try:
        return names.index(item)
    except ValueError:
        raise KeyError("no %s named %s" % (kind, item)) from None
