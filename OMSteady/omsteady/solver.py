"""Damped Newton solver for a steady-state problem with held items."""

from dataclasses import dataclass, field

import numpy as np

from . import structure

_RESIDUAL_SCALINGS = ("none", "automatic", "manual", "hybrid")


@dataclass
class Solution:
    success: bool
    iterations: int
    residual_norm: float
    message: str
    held_variables: list = field(default_factory=list)
    held_residuals: list = field(default_factory=list)
    blocks: list = field(default_factory=list)


class Solver:
    """Solves the released residuals for the released iteration variables.

    tol              -- convergence tolerance of the scaled residual (max norm)
    max_iter         -- Newton iterations per block
    residual_scaling -- 'none', 'automatic' (largest scaled Jacobian entry of
                        each row), 'manual' (residual nominal), 'hybrid'
                        (nominal where given, otherwise automatic)
    blocks           -- solve the blocks of the structure one after the other
                        instead of all released variables together
    log_level        -- 0 quiet, 1 per solve, 2 per iteration
    """

    def __init__(self, problem, tol=1e-8, max_iter=100, residual_scaling="hybrid",
                 blocks=False, line_search=True, log_level=0):
        if residual_scaling not in _RESIDUAL_SCALINGS:
            raise ValueError("residual_scaling must be one of %s" % ", ".join(_RESIDUAL_SCALINGS))
        self.problem = problem
        self.tol = tol
        self.max_iter = max_iter
        self.residual_scaling = residual_scaling
        self.use_blocks = blocks
        self.line_search = line_search
        self.log_level = log_level

    def solve(self):
        """Solves the problem from the current values. Held iteration variables
        keep their current value. Raises a structure.HoldError if the held items
        leave an unbalanced or structurally singular problem."""
        p = self.problem
        held_vars, held_res = p.held()
        variables = [i for i in range(len(p.variable_names)) if i not in held_vars]
        residuals = [i for i in range(len(p.residual_names)) if i not in held_res]
        matching = structure.check(residuals, variables, p.dependencies,
                                   p.residual_names, p.variable_names)

        if self.use_blocks:
            parts = structure.blocks(matching, p.dependencies, variables)
        else:
            parts = [(residuals, variables)]

        self._log(1, "holding {%s}, dropping {%s}, %d unknowns in %d block(s)" % (
            ", ".join(p.variable_names[i] for i in sorted(held_vars)),
            ", ".join(p.residual_names[i] for i in sorted(held_res)), len(variables), len(parts)))

        total = 0
        result = Solution(True, 0, 0.0, "solved", sorted(held_vars), sorted(held_res),
                          [([p.residual_names[r] for r in rows], [p.variable_names[v] for v in cols])
                           for rows, cols in parts])
        for rows, cols in parts:
            ok, iterations, norm, message = self._newton(rows, cols)
            total += iterations
            result.residual_norm = max(result.residual_norm, norm)
            if not ok:
                result.success = False
                result.message = message
                break
        result.iterations = total
        if result.success and residuals:
            # the max norm over all released residuals at the final point
            r = self._residuals(residuals)
            result.residual_norm = float(np.max(np.abs(r / self._manual_scale(residuals)))) if r is not None else np.inf
        return result

    # --- Newton -----------------------------------------------------------------

    def _newton(self, rows, cols):
        p = self.problem
        if not cols:
            return True, 0, 0.0, "nothing to solve"
        x = p.get_iteration_values()
        x[cols] = self._project(x[cols], cols)
        p.set_iteration_values(x)
        sx = np.abs(p.variable_nominal[cols])
        sx[sx == 0] = 1.0

        f = self._residuals(rows)
        if f is None:
            return False, 0, np.inf, "the residuals can not be evaluated at the start values"

        for it in range(self.max_iter + 1):
            jac = self._jacobian(rows, cols, f)
            if jac is None:
                return False, it, np.inf, "the Jacobian can not be evaluated"
            sr = self._residual_scale(rows, jac, sx)
            fs = f / sr
            norm = float(np.max(np.abs(fs)))
            self._log(2, "  iteration %d: |F| = %.3e" % (it, norm))
            if norm <= self.tol:
                return True, it, norm, "solved"
            if it == self.max_iter:
                break

            js = jac / sr[:, None] * sx[None, :]
            try:
                dz = np.linalg.solve(js, -fs)
            except np.linalg.LinAlgError:
                dz = np.linalg.lstsq(js, -fs, rcond=None)[0]
                self._log(1, "  singular Jacobian, using a least squares step")
            dx = dz * sx

            x0 = p.get_iteration_values()
            lam = 1.0
            while True:
                x = x0.copy()
                x[cols] = self._project(x0[cols] + lam * dx, cols)
                p.set_iteration_values(x)
                f_new = self._residuals(rows)
                if f_new is not None:
                    new_norm = float(np.max(np.abs(f_new / sr)))
                    if not self.line_search or new_norm <= (1.0 - 1e-4 * lam) * norm:
                        f = f_new
                        break
                lam /= 2.0
                if lam < 1e-8:
                    p.set_iteration_values(x0)
                    return False, it + 1, norm, "the line search failed to reduce the residuals"

        return False, self.max_iter, norm, "no convergence in %d iterations" % self.max_iter

    def _residuals(self, rows):
        try:
            with np.errstate(all="ignore"):
                r = np.asarray(self.problem.evaluate_residuals(), dtype=float)[rows]
        except (ArithmeticError, ValueError):
            return None
        return r if np.all(np.isfinite(r)) else None

    def _jacobian(self, rows, cols, f):
        p = self.problem
        jac = np.zeros((len(rows), len(cols)))
        x0 = p.get_iteration_values()
        for k, v in enumerate(cols):
            column = p.jacobian_column(v)
            if column is not None:
                jac[:, k] = np.asarray(column, dtype=float)[rows]
                continue
            h = 1e-7 * max(abs(x0[v]), abs(p.variable_nominal[v]) or 1.0)
            for step in (h, -h):
                x = x0.copy()
                x[v] += step
                p.set_iteration_values(x)
                f_h = self._residuals(rows)
                if f_h is not None:
                    jac[:, k] = (f_h - f) / step
                    break
            else:
                p.set_iteration_values(x0)
                return None
        p.set_iteration_values(x0)
        return jac

    def _residual_scale(self, rows, jac, sx):
        if self.residual_scaling == "none":
            return np.ones(len(rows))
        automatic = np.max(np.abs(jac * sx[None, :]), axis=1, initial=0.0)
        automatic[automatic < 1e-12] = 1.0
        if self.residual_scaling == "automatic":
            return automatic
        nominal = np.abs(self.problem.residual_nominal[rows])
        if self.residual_scaling == "manual":
            return np.where(nominal > 0, nominal, 1.0)
        return np.where(nominal > 0, nominal, automatic)

    def _manual_scale(self, rows):
        nominal = np.abs(self.problem.residual_nominal[rows])
        if self.residual_scaling in ("manual", "hybrid"):
            return np.where(nominal > 0, nominal, 1.0)
        return np.ones(len(rows))

    def _project(self, values, cols):
        p = self.problem
        return np.minimum(np.maximum(values, p.variable_min[cols]), p.variable_max[cols])

    def _log(self, level, message):
        if self.log_level >= level:
            print(message)
