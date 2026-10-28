// name: HGTNotSupported1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// Hand guided tearing annotations in when-equations, on array equations and on
// array variables are not supported, and annotations in base classes'
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
  Real x(start = 1);
  discrete Real w(start = 0, fixed = true);
  Real y[2] annotation(__OpenModelica_HGT(IterationVariable));
equation
  x = 1;
  when time > 0.5 then
    w = 1 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
  end when;
  y = {1, 2} annotation(__OpenModelica_HGT(ResidualEquation));
end HGTNotSupported1;

// Result:
// class HGTNotSupported1
//   Real d.a;
//   Real d.b;
//   Real x(start = 1.0);
//   discrete Real w(start = 0.0, fixed = true);
//   Real y[1];
//   Real y[2];
// equation
//   d.a = 1.0;
//   d.b = d.a;
//   x = 1.0;
//   when time > 0.5 then
//     w = 1.0;
//   end when;
//   y[1] = 1.0;
//   y[2] = 2.0;
// end HGTNotSupported1;
// [flattening/modelica/scodeinst/HGTNotSupported1.mo:27:3-27:62:writable] Warning: The hand guided tearing annotation is ignored: only scalar Real variables are supported as iteration variables.
// [flattening/modelica/scodeinst/HGTNotSupported1.mo:31:5-31:82:writable] Warning: The hand guided tearing annotation is ignored: annotations in when-equations, in if-equations that are not resolved and in for-loops that are not unrolled are not supported.
// [flattening/modelica/scodeinst/HGTNotSupported1.mo:33:3-33:62:writable] Warning: The hand guided tearing annotation is ignored: only scalar Real equations are supported as residual equations.
//
// endResult
