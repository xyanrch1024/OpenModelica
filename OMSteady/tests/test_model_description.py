import pytest

from omsteady.fmu import parse_model_description

# The interactive FMU of twoEqSteadyStateParaHold as omc --interactiveFMU is to
# generate it (doc/HGT_interactive_fmu_phase1.md section 4), plus a residual
# that is not listed in ModelStructure.
MODEL_DESCRIPTION = """<?xml version="1.0" encoding="UTF-8"?>
<fmiModelDescription fmiVersion="2.0" modelName="twoEq" guid="{abc}" variableNamingConvention="structured">
  <ModelExchange modelIdentifier="twoEq" providesDirectionalDerivative="true"/>
  <ModelVariables>
    <ScalarVariable name="x" valueReference="0" causality="input"><Real start="1.0" nominal="1.0"/></ScalarVariable>
    <ScalarVariable name="T" valueReference="1" causality="input"><Real start="400.0" nominal="100.0" min="200.0"/></ScalarVariable>
    <ScalarVariable name="iter_0" valueReference="0" description="x"><Real/></ScalarVariable>
    <ScalarVariable name="iter_1" valueReference="1" description="T"><Real/></ScalarVariable>
    <ScalarVariable name="res_0" valueReference="2" causality="output" initial="calculated" description="0 = 120*x - ... annotation(...)"><Real nominal="0"/></ScalarVariable>
    <ScalarVariable name="res_1" valueReference="3" causality="output" initial="calculated" description="0 = -x*(873 - T) + ..."><Real nominal="10"/></ScalarVariable>
    <ScalarVariable name="res_2" valueReference="4" causality="output" initial="calculated"><Real/></ScalarVariable>
    <ScalarVariable name="iter_2" valueReference="5" causality="input"><Real start="0"/></ScalarVariable>
    <ScalarVariable name="testHold1" valueReference="0" causality="parameter" variability="fixed" initial="exact"><Boolean start="false"/></ScalarVariable>
    <ScalarVariable name="iter_0_hold" valueReference="1" causality="calculatedParameter" variability="fixed" initial="calculated"><Boolean/></ScalarVariable>
    <ScalarVariable name="res_0_hold" valueReference="2" causality="parameter" variability="fixed" initial="exact"><Boolean start="true"/></ScalarVariable>
  </ModelVariables>
  <ModelStructure>
    <Outputs>
      <Unknown index="5" dependencies="1 2" dependenciesKind="dependent dependent"/>
      <Unknown index="6" dependencies="1 2" dependenciesKind="dependent constant"/>
    </Outputs>
  </ModelStructure>
</fmiModelDescription>
"""


def test_items_and_attributes():
    m = parse_model_description(MODEL_DESCRIPTION)
    assert m.model_identifier == "twoEq" and m.provides_directional_derivative
    assert [i.name for i in m.iteration_variables] == ["iter_0", "iter_1", "iter_2"]
    assert [r.name for r in m.residuals] == ["res_0", "res_1", "res_2"]
    T = m.iteration_variables[1].variable
    # attributes and the ModelStructure index come from the input iter_1 is an alias of
    assert (T.index, T.causality, T.nominal, T.min, T.description) == (2, "input", 100.0, 200.0, "T")
    assert m.residuals[0].variable.nominal == 0.0
    assert m.residuals[1].variable.nominal == 10.0


def test_hold_variables():
    m = parse_model_description(MODEL_DESCRIPTION)
    assert m.iteration_variables[0].hold.name == "iter_0_hold"
    assert m.iteration_variables[1].hold is None
    assert m.residuals[0].hold.causality == "parameter"


def test_dependencies():
    m = parse_model_description(MODEL_DESCRIPTION)
    # res_0, res_1 list x and T; res_2 is not listed and depends on everything
    assert m.dependencies == [{0, 1}, {0, 1}, {0, 1, 2}]


def test_oct_fmu_with_parameter_iteration_variables_is_rejected():
    oct_like = MODEL_DESCRIPTION.replace(
        '<ScalarVariable name="iter_2" valueReference="5" causality="input">',
        '<ScalarVariable name="iter_2" valueReference="5" causality="calculatedParameter" variability="fixed">')
    with pytest.raises(ValueError, match="OCT"):
        parse_model_description(oct_like)
