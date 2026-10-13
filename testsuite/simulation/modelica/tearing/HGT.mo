package HGT "Hand guided tearing (OCT compatible) test models, steady state"
  model CrossSCC "the pair is in different blocks without hand guided tearing"
    Real v, w;
  equation
    w = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = v)));
    v + w = 1 + time;
  end CrossSCC;

  model Loop "residual nominal and a pair inside an algebraic loop"
    Real x(start = 1), y(start = 1), z;
  equation
    x + y + z = 6;
    x * y = z + 1 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y, nominal = 10)));
    z = x ^ 2 - y;
  end Loop;

  model Single "1x1 pair, solved explicitly without hand guided tearing"
    Real x;
  equation
    2 * x = 6 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
  end Single;

  model Simple "the alias equation is kept by removeSimpleEquations"
    Real a, b;
  equation
    a = b annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = a)));
    b = sin(time) + 2;
  end Simple;

  model SystemPair "system level tearingPairs, kept by comSubExp"
    model B
      Real x, y;
    equation
      x = y + 1 annotation(__OpenModelica_HGT(name = res));
      y = 2 * x - 3;
    end B;
    B b;
    annotation(__OpenModelica_HGT(tearingPairs(Pair(residualEquation = b.res, iterationVariable = b.y))));
  end SystemPair;

  model Unpaired "unpaired residual equation and iteration variable"
    model Splitter
      Real x;
      parameter Real k = 1.0;
      Real factor(start = 0.5) annotation(__OpenModelica_HGT(IterationVariable));
      Real x1 = factor * k * x;
      Real x2 = (1 - factor) * k * x;
    end Splitter;
    model Mixer
      Real x1, x2, y;
    equation
      0 = x1 - x2 * 3 annotation(__OpenModelica_HGT(ResidualEquation));
      y = x1;
    end Mixer;
    Splitter splitter;
    Mixer mixer;
  equation
    splitter.x = 4;
    splitter.x1 = mixer.x1;
    splitter.x2 = mixer.x2;
  end Unpaired;

  model NonConvex "OCT User's Guide example, level 2 is torn as level 1"
    parameter Real f = 10;
    Real x1(min = 0, max = 20, start = 15);
    Real x2(min = 0, max = 20, start = 15);
    Real k, l, s;
  equation
    0 = k + (x1 - 9) / (-2);
    0 = l + (x2 - f) / (-2);
    0 = x2 / 40 + x1 / 20 - s;
    0 = exp(-exp(k) + k + 1.0) - 0.3 * exp(-exp(l) + l + 1.0) - 0.5
      annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x1, level = 1)));
    0 = s + x1 * x2 / 16^2 - 1
      annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x2, level = 2)));
  end NonConvex;

  model WithStates "hand guided tearing is only supported for steady state"
    Real x(start = 1, fixed = true), y, z(start = 1);
  equation
    der(x) = -x + y;
    y + z = x annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = z)));
    y = z ^ 3;
  end WithStates;

  model Independent "error: the residual does not depend on its variable"
    Real a, b;
  equation
    b = 3 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = a)));
    a = 2 * time;
  end Independent;

  model Count "error: different numbers of unpaired equations and variables"
    Real a;
    Real b(start = 1) annotation(__OpenModelica_HGT(IterationVariable));
    Real c annotation(__OpenModelica_HGT(IterationVariable));
  equation
    a + b + c = 1 annotation(__OpenModelica_HGT(ResidualEquation));
    a * b = 0.2;
    c = b * 2;
  end Count;

  model Pipe "turbulent flow, the hand guided tearing solves it for the pressures"
    parameter Real k = 1;
    Real pa, pb, m;
  equation
    m = k * sqrt(pa - pb);
  end Pipe;

  model Chain "iterate on the flow of 10 pipes in series, independent of --tearingStrictness"
    parameter Real p_in = 100, p_out = 1;
    Pipe pipe[10](k = {1, 2, 1.5, 3, 1, 2.5, 1, 2, 4, 1});
    Real m(start = 1);
  equation
    pipe[1].pa = p_in;
    for i in 1:9 loop
      pipe[i].pb = pipe[i+1].pa;
    end for;
    for i in 1:10 loop
      pipe[i].m = m;
    end for;
    pipe[10].pb = p_out annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = m)));
  end Chain;

  model ChainNegativeStart "the inverted sqrt has a spurious root m < 0, the check rejects it"
    extends Chain(m(start = -5));
  end ChainNegativeStart;
  model Bound "bad residual choice, the solver keeps y <= ymax so that log(x) is defined"
    parameter Real ymax = 3;
    Real x, y(start = 4);
  equation
    y = log(x) annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(max = ymax) = y)));
    x + y ^ 3 = 30;
  end Bound;

  model Multi "two residual equations in one block of level 1"
    Real x(start = 1), y(start = 1);
  equation
    x + y = 3 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
    x * y = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y)));
  end Multi;
end HGT;
