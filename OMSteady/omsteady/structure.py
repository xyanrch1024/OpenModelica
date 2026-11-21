"""Structural checks of a steady-state problem with held items.

The structure is the dependency of each residual on the iteration variables.
A problem whose released residuals E and released iteration variables U have
the same number is structurally solvable if a perfect matching between E and U
exists in that dependency graph.
"""

from dataclasses import dataclass


class HoldError(Exception):
    """The held items leave a problem that can not be solved."""


class HoldBalanceError(HoldError):
    """The number of released iteration variables differs from the number of
    released residuals."""


class StructuralSingularityError(HoldError):
    """No perfect matching exists between the released residuals and the
    released iteration variables."""

    def __init__(self, message, unmatched_residuals, unmatched_variables):
        super().__init__(message)
        self.unmatched_residuals = unmatched_residuals
        self.unmatched_variables = unmatched_variables


@dataclass
class Matching:
    """A maximum matching: residual index -> iteration variable index."""

    residual_to_variable: dict
    unmatched_residuals: list
    unmatched_variables: list

    @property
    def perfect(self):
        return not self.unmatched_residuals and not self.unmatched_variables


def maximum_matching(residuals, variables, dependencies):
    """Maximum bipartite matching with augmenting paths.

    residuals    -- residual indices (rows)
    variables    -- iteration variable indices (columns)
    dependencies -- dependencies[r] is the set of variable indices residual r
                    depends on
    """
    allowed = set(variables)
    var_to_res = {}

    def candidates(r):
        return iter(sorted(dependencies[r] & allowed))

    def augment(root):
        # depth-first search for an augmenting path with an explicit stack, so
        # that long chains of thousands of items do not hit the recursion limit:
        # path[k] is the residual at depth k, chosen[k] the variable it tries
        visited = set()
        path, its, chosen = [root], [candidates(root)], []
        while path:
            for v in its[-1]:
                if v in visited:
                    continue
                visited.add(v)
                if v not in var_to_res:
                    for r, w in zip(path, chosen + [v]):
                        var_to_res[w] = r
                    return True
                chosen.append(v)
                path.append(var_to_res[v])
                its.append(candidates(var_to_res[v]))
                break
            else:
                path.pop()
                its.pop()
                if chosen:
                    chosen.pop()
        return False

    for r in residuals:
        augment(r)

    res_to_var = {r: v for v, r in var_to_res.items()}
    return Matching(
        residual_to_variable=res_to_var,
        unmatched_residuals=[r for r in residuals if r not in res_to_var],
        unmatched_variables=[v for v in variables if v not in var_to_res],
    )


def check(residuals, variables, dependencies, residual_names, variable_names):
    """Checks the count and the structure, returns the perfect matching or
    raises a HoldError that names the offending items."""
    if len(residuals) != len(variables):
        raise HoldBalanceError(
            "%d iteration variables are released ({%s}), but %d residual equations "
            "are released ({%s})" % (
                len(variables), ", ".join(variable_names[v] for v in variables),
                len(residuals), ", ".join(residual_names[r] for r in residuals)))

    matching = maximum_matching(residuals, variables, dependencies)
    if not matching.perfect:
        raise StructuralSingularityError(
            "with the held items the residual equations {%s} can not determine the "
            "iteration variables {%s}" % (
                ", ".join(residual_names[r] for r in matching.unmatched_residuals),
                ", ".join(variable_names[v] for v in matching.unmatched_variables)),
            matching.unmatched_residuals, matching.unmatched_variables)
    return matching


def blocks(matching, dependencies, variables):
    """Splits a structurally regular problem into blocks that can be solved one
    after the other (Tarjan's algorithm on the matched dependency graph).

    Returns a list of (residuals, variables) in solution order.
    """
    var_to_res = {v: r for r, v in matching.residual_to_variable.items()}
    released = set(variables)
    # v -> w: the residual matched to v depends on w, so w is solved first
    edges = {v: sorted((dependencies[var_to_res[v]] & released) - {v}) for v in variables}

    index = {}
    low = {}
    stack = []
    on_stack = set()
    result = []
    counter = [0]

    def strongconnect(root):
        # Tarjan's algorithm with an explicit stack instead of recursion
        work = [(root, iter(edges[root]))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            v, it = work[-1]
            for w in it:
                if w not in index:
                    index[w] = low[w] = counter[0]
                    counter[0] += 1
                    stack.append(w)
                    on_stack.add(w)
                    work.append((w, iter(edges[w])))
                    break
                elif w in on_stack:
                    low[v] = min(low[v], index[w])
            else:
                work.pop()
                if work:
                    u = work[-1][0]
                    low[u] = min(low[u], low[v])
                if low[v] == index[v]:
                    component = []
                    while True:
                        w = stack.pop()
                        on_stack.discard(w)
                        component.append(w)
                        if w == v:
                            break
                    component.sort()
                    result.append(([var_to_res[w] for w in component], component))

    for v in variables:
        if v not in index:
            strongconnect(v)
    return result
