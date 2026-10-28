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

  model CrossComponentPair "system level pair of an equation and a variable of two components"
    model Splitter
      Real x;
      parameter Real k = 1.0;
      Real factor(start = 0.5);
      Real x1 = factor * k * x;
      Real x2 = (1 - factor) * k * x;
    end Splitter;
    model Mixer
      Real x1, x2, y;
    equation
      0 = x1 - x2 * 3 annotation(__OpenModelica_HGT(name = ratio));
      y = x1;
    end Mixer;
    Splitter splitter;
    Mixer mixer;
  equation
    splitter.x = 4;
    splitter.x1 = mixer.x1;
    splitter.x2 = mixer.x2;
    annotation(__OpenModelica_HGT(tearingPairs(Pair(residualEquation = mixer.ratio, iterationVariable = splitter.factor))));
  end CrossComponentPair;

  model NonConvex "OCT User's Guide example: level 2 solves x2 for given x1, level 1 solves x1"
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
  model ThreeLevels "y3 is solved for given y1 and y2, y2 for given y1, y1 outermost"
    Real y1(start = 1), y2(start = 1), y3(start = 1), a, b;
  equation
    a = y1 + y2 + y3;
    b = y2 * y3;
    y3 ^ 3 + y3 = b + 1 + y1 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y3, level = 3)));
    y2 + exp(y2) = 2 + y3 - y1 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y2, level = 2)));
    a = 4 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y1, level = 1)));
  end ThreeLevels;
  model SteadyStateSwitch "OCT style: a parameter selects the dynamic or the steady-state equations"
    parameter Boolean isSteadyState = true;
    Real x(start = 1);
    Real y(start = 1);
  equation
    if not isSteadyState then
      der(x) = -x + y * y;
      der(y) = x * x - 2 * y;
    else
      0 = -x + y * y annotation(__Modelon(ResidualEquation(iterationVariable(hold = false) = x, hold = false)));
      0 = x * x - 2 * y annotation(__Modelon(ResidualEquation(iterationVariable(hold = false) = y, hold = false)));
    end if;
  end SteadyStateSwitch;

  model InitialPair "a pair on an initial equation only applies to the initialization system"
    Real x(start = 1, fixed = false);
    parameter Real p = 2;
  initial equation
    x * x = p annotation(__OpenModelica_HGT(name = initialBalance, ResidualEquation(iterationVariable = x)));
  equation
    der(x) = -x;
  end InitialPair;

  model OnlySolvable "--hgtOnly: the other equations can be solved with the given iteration variable"
    Real x(start = 1), y, z;
  equation
    y = exp(x);
    z = y ^ 2 + x;
    z - 10 = 0 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
  end OnlySolvable;

  model OnlyStuck "--hgtOnly: z + sin(z) = y can not be solved for z, no iteration variable is added"
    Real x(start = 1), y, z(start = 1);
  equation
    y = exp(x);
    z + sin(z) = y;
    z * x = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
  end OnlyStuck;

  model OnlyUnmatched "--hgtOnly: the pair takes b, the only variable of b^3 + b = 2, so no residual equation is added"
    Real a(start = 1), b(start = 1);
  equation
    b ^ 3 + b = 2;
    a * a + b = 5 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = b)));
  end OnlyUnmatched;

  model ForPipe "pipe of n segments in a for-loop: segment i is the residual equation of the pressure behind it"
    parameter Integer n = 4;
    parameter Real k[n] = {2, 3, 4, 5};
    parameter Real p_in = 10, p_out = 1;
    Real p[n + 1];
    Real m(start = 1);
  equation
    p[1] = p_in;
    p[n + 1] = p_out;
    for i in 1:n - 1 loop
      m = k[i] * sqrt(p[i] - p[i + 1]) annotation(__OpenModelica_HGT(name = seg,
        ResidualEquation(iterationVariable(start = p_in - 2 * i) = p[i + 1])));
    end for;
    m = k[n] * sqrt(p[n] - p[n + 1]) annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = m)));
  end ForPipe;

  model ForPipeScalar "ForPipe written out"
    parameter Integer n = 4;
    parameter Real k[n] = {2, 3, 4, 5};
    parameter Real p_in = 10, p_out = 1;
    Real p[n + 1];
    Real m(start = 1);
  equation
    p[1] = p_in;
    p[n + 1] = p_out;
    m = k[1] * sqrt(p[1] - p[2]) annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(start = 8) = p[2])));
    m = k[2] * sqrt(p[2] - p[3]) annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(start = 6) = p[3])));
    m = k[3] * sqrt(p[3] - p[4]) annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(start = 4) = p[4])));
    m = k[4] * sqrt(p[4] - p[5]) annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = m)));
  end ForPipeScalar;

  model ArrayPipe "the segment equations as one array equation, paired element-wise with p[2:4]"
    parameter Real k[3] = {2, 3, 4}, c = 5, p_in = 10, p_out = 1;
    Real p[4], m[3](each start = 1);
  equation
    p[1] = p_in;
    m[1:2] = m[2:3];
    m[3] = c * (p[4] - p_out);
    m = k .* sqrt(p[1:3] - p[2:4]) annotation(__OpenModelica_HGT(name = seg,
      ResidualEquation(iterationVariable(start = {8, 6, 4}) = p[2:4])));
  end ArrayPipe;

  model ArrayPipeLoop "ArrayPipe with the segment equations in a for-loop"
    parameter Real k[3] = {2, 3, 4}, c = 5, p_in = 10, p_out = 1;
    Real p[4], m[3](each start = 1);
  equation
    p[1] = p_in;
    m[1:2] = m[2:3];
    m[3] = c * (p[4] - p_out);
    for i in 1:3 loop
      m[i] = k[i] * sqrt(p[i] - p[i + 1]) annotation(__OpenModelica_HGT(name = seg,
        ResidualEquation(iterationVariable(start = 10 - 2 * i) = p[i + 1])));
    end for;
  end ArrayPipeLoop;

  model MatrixPair "a matrix equation paired element-wise, each element only depends on its own variable"
    parameter Real c[2, 3] = {{2, 3, 4}, {5, 6, 7}};
    Real x[2, 3](each start = 1);
  equation
    x .^ 2 = c annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(nominal = c) = x)));
  end MatrixPair;
end HGT;
