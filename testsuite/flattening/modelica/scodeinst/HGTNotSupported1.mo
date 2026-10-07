// name: HGTNotSupported1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// Hand guided tearing annotations in for-equations, on array equations and on
// array variables are not supported yet, and annotations in base classes'
// tearingPairs are not inherited.
//

model HGTNotSupported1
  model Base
    Real a, b;
  equation
    a = 1 annotation(__OpenModelica_HGT(name = ra));
    b = a annotation(__OpenModelica_HGT(name = rb));
    annotation(__OpenModelica_HGT(tearingPairs(Pair(residualEquation = ra, iterationVariable = a))));
  end Base;

  model Derived
    extends Base;
  end Derived;

  Derived d;
  Real x[2];
  Real y[2] annotation(__OpenModelica_HGT(IterationVariable));
equation
  for i in 1:2 loop
    x[i] = i annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x[i])));
  end for;
  y = {1, 2} annotation(__OpenModelica_HGT(ResidualEquation));
end HGTNotSupported1;

// Result:
// class HGTNotSupported1
//   Real d.a;
//   Real d.b;
//   Real x[1];
//   Real x[2];
//   Real y[1];
//   Real y[2];
// equation
//   d.a = 1.0;
//   d.b = d.a;
//   x[1] = 1.0;
//   x[2] = 2.0;
//   y[1] = 1.0;
//   y[2] = 2.0;
// end HGTNotSupported1;
// [flattening/modelica/scodeinst/HGTNotSupported1.mo:26:3-26:62:writable] Warning: The hand guided tearing annotation is ignored: only scalar Real variables are supported as iteration variables.
// [flattening/modelica/scodeinst/HGTNotSupported1.mo:29:5-29:88:writable] Warning: The hand guided tearing annotation is ignored: annotations in for-, if- and when-equations are not supported yet.
// [flattening/modelica/scodeinst/HGTNotSupported1.mo:31:3-31:62:writable] Warning: The hand guided tearing annotation is ignored: only scalar Real equations are supported as residual equations.
//
// endResult
