"""FMUProblem: a steady-state problem given by an OpenModelica interactive FMU.

An interactive FMU (omc --handGuidedTearing --interactiveFMU) follows the naming
of OCT interactive FMUs, see doc/HGT_interactive_fmu_phase1.md section 4:

  iter_N       iteration variable N; an alias of the original variable, which is
               an FMU input (same valueReference)
  res_N        residual N, an FMU output
  iter_N_hold  Boolean parameter, iteration variable N is held
  res_N_hold   Boolean parameter, residual N is dropped

The dependency of the residuals on the iteration variables is read from
<ModelStructure><Outputs>.
"""

import re
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

import numpy as np

from .problem import SteadyProblem

_ITER = re.compile(r"^iter_(\d+)$")
_RES = re.compile(r"^res_(\d+)$")
_ITER_HOLD = re.compile(r"^iter_(\d+)_hold$")
_RES_HOLD = re.compile(r"^res_(\d+)_hold$")
_TYPES = ("Real", "Integer", "Boolean", "String", "Enumeration")


@dataclass
class Variable:
    index: int                  # 1-based position in <ModelVariables>
    name: str
    value_reference: int
    causality: str
    variability: str
    type: str
    description: str = ""
    start: object = None
    nominal: float = None
    min: float = None
    max: float = None


@dataclass
class Item:
    """An iteration variable or a residual of the interactive FMU."""
    number: int                 # N of iter_N / res_N
    name: str                   # iter_N or res_N
    variable: Variable          # the variable that is set or read
    hold: Variable = None       # iter_N_hold / res_N_hold


@dataclass
class InteractiveModel:
    guid: str
    model_identifier: str
    provides_directional_derivative: bool
    variables: list
    iteration_variables: list = field(default_factory=list)
    residuals: list = field(default_factory=list)
    dependencies: list = field(default_factory=list)   # per residual: set of positions in iteration_variables

    def variable(self, name):
        for v in self.variables:
            if v.name == name:
                return v
        raise KeyError("the FMU has no variable %s" % name)


def parse_model_description(xml_text):
    """Reads the interactive part of a modelDescription.xml."""
    root = ET.fromstring(xml_text)
    me = root.find("ModelExchange")
    if me is None:
        raise ValueError("the FMU does not support Model Exchange")

    variables = []
    for i, sv in enumerate(root.find("ModelVariables").findall("ScalarVariable"), start=1):
        typ = next(child for child in sv if child.tag in _TYPES)
        a = typ.attrib
        variables.append(Variable(
            index=i, name=sv.get("name"), value_reference=int(sv.get("valueReference")),
            causality=sv.get("causality", "local"), variability=sv.get("variability", "continuous"),
            type=typ.tag, description=sv.get("description", ""),
            start=a.get("start"), nominal=_float(a.get("nominal")),
            min=_float(a.get("min")), max=_float(a.get("max"))))

    by_index = {v.index: v for v in variables}

    def numbered(pattern):
        found = {}
        for v in variables:
            m = pattern.match(v.name)
            if m:
                found[int(m.group(1))] = v
        return found

    iters, ress = numbered(_ITER), numbered(_RES)
    iter_holds, res_holds = numbered(_ITER_HOLD), numbered(_RES_HOLD)
    if not iters or not ress:
        raise ValueError("the FMU is not an interactive FMU: no iter_N or res_N variables")

    model = InteractiveModel(
        guid=root.get("guid"), model_identifier=me.get("modelIdentifier"),
        provides_directional_derivative=me.get("providesDirectionalDerivative") == "true",
        variables=variables)

    for n in sorted(iters):
        alias = iters[n]
        # the input that iter_N is an alias of carries the value and the attributes
        base = next((v for v in variables if v.value_reference == alias.value_reference
                     and v.type == alias.type and v.causality == "input"), alias)
        if base.causality != "input":
            raise ValueError("%s is not an FMU input (causality %s); OCT interactive FMUs, where it "
                             "is a parameter, are not supported" % (alias.name, alias.causality))
        merged = Variable(**{**alias.__dict__, **{k: getattr(base, k) for k in
                                                   ("index", "causality", "start", "nominal", "min", "max")
                                                   if getattr(base, k) is not None}})
        merged.description = alias.description or base.name
        model.iteration_variables.append(Item(n, alias.name, merged, iter_holds.get(n)))
    for n in sorted(ress):
        model.residuals.append(Item(n, ress[n].name, ress[n], res_holds.get(n)))

    # ModelStructure/Outputs refers to the base variables; map them by valueReference
    position_by_vr = {item.variable.value_reference: k for k, item in enumerate(model.iteration_variables)}
    outputs = {}
    structure = root.find("ModelStructure")
    if structure is not None and structure.find("Outputs") is not None:
        for u in structure.find("Outputs").findall("Unknown"):
            outputs[int(u.get("index"))] = u.get("dependencies")
    for item in model.residuals:
        deps = outputs.get(item.variable.index)
        if deps is None:
            # not listed, or no dependencies attribute: depends on everything
            model.dependencies.append(set(range(len(model.iteration_variables))))
            continue
        positions = set()
        for idx in deps.split():
            v = by_index.get(int(idx))
            if v is not None and v.value_reference in position_by_vr:
                positions.add(position_by_vr[v.value_reference])
        model.dependencies.append(positions)
    return model


class FMUProblem(SteadyProblem):
    """A steady-state problem given by an interactive FMU (FMI 2.0 Model
    Exchange), evaluated with FMPy."""

    def __init__(self, path, instance_name="omsteady"):
        from fmpy import extract
        from fmpy.fmi2 import FMU2Model

        with zipfile.ZipFile(path) as z:
            self.model = parse_model_description(z.read("modelDescription.xml").decode("utf-8"))
        m = self.model
        it = m.iteration_variables
        super().__init__(
            [i.name for i in it], [r.name for r in m.residuals], m.dependencies,
            [i.variable.nominal for i in it], [i.variable.min for i in it],
            [i.variable.max for i in it], [r.variable.nominal for r in m.residuals])
        self.descriptions = {i.name: i.variable.description for i in it + m.residuals}
        self._iter_vrs = [i.variable.value_reference for i in it]
        self._res_vrs = [r.variable.value_reference for r in m.residuals]
        self._unzipdir = extract(path)
        self._fmu = FMU2Model(guid=m.guid, unzipDirectory=self._unzipdir,
                              modelIdentifier=m.model_identifier, instanceName=instance_name)
        self._fmu.instantiate()
        self._parameters = {}
        self._initialize()

    # --- FMU life cycle ---------------------------------------------------------

    def _initialize(self, iteration_values=None):
        fmu = self._fmu
        fmu.setupExperiment(startTime=0.0)
        fmu.enterInitializationMode()
        for name, value in self._parameters.items():
            self._set_variable(self.model.variable(name), value)
        if iteration_values is not None:
            fmu.setReal(self._iter_vrs, list(iteration_values))
        fmu.exitInitializationMode()
        # Model Exchange: event iteration, then continuous time mode for setReal on inputs
        while True:
            info = fmu.newDiscreteStates()
            if not info[0]:      # newDiscreteStatesNeeded
                break
        fmu.enterContinuousTimeMode()

    def _reinitialize(self):
        values = self.get_iteration_values()
        self._fmu.reset()
        self._initialize(values)

    def terminate(self):
        self._fmu.terminate()
        self._fmu.freeInstance()

    # --- SteadyProblem ------------------------------------------------------------

    def get_iteration_values(self):
        return np.array(self._fmu.getReal(self._iter_vrs))

    def set_iteration_values(self, values):
        self._fmu.setReal(self._iter_vrs, [float(v) for v in values])

    def evaluate_residuals(self):
        from fmpy.fmi1 import FMICallException
        try:
            return np.array(self._fmu.getReal(self._res_vrs))
        except FMICallException as e:
            raise ValueError(str(e)) from e

    def parametric_hold(self):
        def flags(items):
            vrs = [i.hold.value_reference for i in items if i.hold is not None]
            values = iter(self._fmu.getBoolean(vrs)) if vrs else iter(())
            return np.array([bool(next(values)) if i.hold is not None else False for i in items], dtype=bool)
        return flags(self.model.iteration_variables), flags(self.model.residuals)

    def jacobian_column(self, variable):
        if not self.model.provides_directional_derivative:
            return None
        return np.array(self._fmu.getDirectionalDerivative(
            vUnknown_ref=self._res_vrs, vKnown_ref=[self._iter_vrs[variable]], dvKnown=[1.0]))

    # --- names ----------------------------------------------------------------------

    def variable_index(self, item):
        """iter_N, the name of the original variable, or an index."""
        if isinstance(item, str):
            k = self._iteration_position(item)
            if k is not None:
                return k
        return super().variable_index(item)

    def residual_index(self, item):
        """res_N, the hand guided tearing name of the equation, or an index."""
        if isinstance(item, str) and item not in self.residual_names:
            for k, r in enumerate(self.model.residuals):
                if equation_name(r.variable.description) == item:
                    return k
        return super().residual_index(item)

    # --- user API -------------------------------------------------------------------

    def set(self, name, value):
        """Sets an iteration variable (iter_N or the original name) or a
        parameter. Changing a parameter re-initializes the FMU and keeps the
        current values of the iteration variables."""
        k = self._iteration_position(name)
        if k is not None:
            values = self.get_iteration_values()
            values[k] = float(value)
            self.set_iteration_values(values)
            return
        v = self.model.variable(name)
        if v.causality == "input":
            self._set_variable(v, value)
        elif v.causality == "parameter":
            self._parameters[name] = value
            self._reinitialize()
        else:
            raise ValueError("%s can not be set (causality %s)" % (name, v.causality))

    def get(self, names):
        single = isinstance(names, str)
        result = []
        for name in [names] if single else names:
            k = self._iteration_position(name)
            v = self.model.iteration_variables[k].variable if k is not None else self.model.variable(name)
            result.append(self._get_variable(v))
        return result[0] if single else result

    def _iteration_position(self, name):
        for k, item in enumerate(self.model.iteration_variables):
            if name in (item.name, item.variable.description) or name == self.model.variables[item.variable.index - 1].name:
                return k
        return None

    def _set_variable(self, v, value):
        fmu, vr = self._fmu, [v.value_reference]
        if v.type == "Real":
            fmu.setReal(vr, [float(value)])
        elif v.type == "Boolean":
            fmu.setBoolean(vr, [bool(value)])
        elif v.type in ("Integer", "Enumeration"):
            fmu.setInteger(vr, [int(value)])
        else:
            fmu.setString(vr, [str(value)])

    def _get_variable(self, v):
        fmu, vr = self._fmu, [v.value_reference]
        if v.type == "Real":
            return fmu.getReal(vr)[0]
        if v.type == "Boolean":
            return bool(fmu.getBoolean(vr)[0])
        if v.type in ("Integer", "Enumeration"):
            return fmu.getInteger(vr)[0]
        return fmu.getString(vr)[0]


_NAME = re.compile(r"\bname\s*=\s*([A-Za-z_$][\w$.\[\],]*?)\s*[,)]")


def equation_name(description):
    """The name = ... of the hand guided tearing annotation in the description
    of res_N (the equation and its annotation), or None."""
    _, sep, annotation = description.partition(" annotation(")
    m = _NAME.search(annotation) if sep else None
    return m.group(1) if m else None


def _float(text):
    return None if text is None else float(text)
