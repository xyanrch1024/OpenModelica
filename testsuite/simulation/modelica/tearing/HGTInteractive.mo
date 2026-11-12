package HGTInteractive "Steady-state models for --interactiveFMU, see doc/HGT_interactive_fmu_phase1.md"
  model TwoEq "OCT's twoEqSteadyStateParaHold: cross hold, testHold1 holds T and drops LongEq, testHold2 holds x and drops LongEq2"
    Real x(start = 1);
    Real T(start = 400, nominal = 100);
    parameter Boolean testHold1 = false;
    parameter Boolean testHold2 = false;
  equation
    0 = 120*x - 75*(0.12*exp(12581*(T - 298)/(298*T)))*(1 - x)
      annotation(__OpenModelica_HGT(ResidualEquation(hold = testHold1,
        iterationVariable(hold = testHold2) = x), name = LongEq));
    0 = -x*(873 - T) + 11.0*(T - 300)
      annotation(__OpenModelica_HGT(ResidualEquation(hold = testHold2,
        iterationVariable(hold = testHold1) = T), name = LongEq2));
  end TwoEq;

  model TwoBlocks "e1 only contains p: design holds m and drops e1, so that e2 determines p (a hold across blocks)"
    parameter Boolean design = false;
    parameter Real k = 1, p_out = 1;
    Real p(start = 1), m(start = 1);
  equation
    p ^ 3 + p = 10 annotation(__OpenModelica_HGT(name = e1, ResidualEquation(hold = design, iterationVariable = p)));
    m ^ 2 = k * (p - p_out) annotation(__OpenModelica_HGT(name = e2, ResidualEquation(iterationVariable(hold = design) = m)));
  end TwoBlocks;

  model Plant "a component with an inner pair, explicit equations between the pairs, a residual nominal and bounds"
    model Pipe
      parameter Real k = 1;
      Real pa, pb, m;
    equation
      m = k * sqrt(pa - pb);
    end Pipe;
    parameter Real p_in = 100, p_out = 1;
    Pipe pipe1(k = 2), pipe2(k = 3);
    Real m(start = 1, min = 0);
    Real p_mid(start = 50);
  equation
    pipe1.pa = p_in;
    pipe1.pb = p_mid;
    pipe2.pa = p_mid;
    pipe2.pb = p_out;
    pipe1.m = m annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(start = 5, max = 100) = p_mid, nominal = 10)));
    pipe2.m = m annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = m)));
  end Plant;

  model Dynamic "error: a model with states"
    Real x(start = 1, fixed = true), y(start = 1);
  equation
    der(x) = -x;
    y * y = x annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y)));
  end Dynamic;
end HGTInteractive;
