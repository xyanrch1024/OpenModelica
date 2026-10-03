package HgtExamples
  "Sample models exercising OCT/OpenModelica HGT annotation syntax.
   Frontend parses these into HgtIterationVariable / HgtResidualEquation;
   tearing consumption is not yet implemented."

  // Paired residual ↔ iteration variable (OpenModelica prefix)
  model PairedOM
    Real m_flow(start = 0.1);
    Real p;
    parameter Real R = 1.0;
  equation
    p = 1.0;
    0 = p - R * m_flow annotation(
      __OpenModelica_ResidualEquation(iterationVariable = m_flow, nominal = 1e-3));
  end PairedOM;

  // Unpaired IV + residual (compiler will pair later)
  model UnpairedOM
    Real T annotation(__OpenModelica_IterationVariable(nominal = 300, min = 250, max = 400));
    Real Q;
    parameter Real C = 1.0;
  equation
    Q = 10.0;
    0 = Q - C * (T - 300) annotation(__OpenModelica_ResidualEquation);
  end UnpairedOM;

  // OCT / Modelon alias forms
  model ModelonAlias
    Real x(start = 1.0) annotation(__Modelon(IterationVariable(hold = false, level = 1)));
    Real y;
  equation
    y = 2.0;
    0 = y - x annotation(__Modelon(ResidualEquation(iterationVariable = x), name = res_xy));
  end ModelonAlias;

  // Nested IV fields on residual
  model NestedIvFields
    Real c;
    Real r;
  equation
    r = 0.5;
    0 = r - c annotation(__OpenModelica_ResidualEquation(
      iterationVariable(min = 0, max = 1, nominal = 0.5, start = 0.1),
      enabled = true,
      level = 1));
  end NestedIvFields;

end HgtExamples;
