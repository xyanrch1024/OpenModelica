// name: HGTIf1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// The hand guided tearing annotations of the branch of an if-equation that a
// parameter selects apply, as the branch replaces the if-equation; hold = false
// needs no warning. In an if-equation that remains, they are ignored.
//

model HGTIf1
  parameter Boolean isSteadyState = true;
  Real x(start = 1), y(start = 1), z;
equation
  if not isSteadyState then
    der(x) = -x + y * y;
    der(y) = x * x - 2 * y;
  else
    0 = -x + y * y annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(hold = false) = x, hold = false)));
    0 = x * x - 2 * y annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(hold = false) = y, hold = false)));
  end if;

  if time > 0.5 then
    z = x annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = z)));
  else
    z = y;
  end if;
end HGTIf1;

// Result:
// Hand guided tearing:
//   pair: residual equation $hgt1 (hold = false), iteration variable x (hold = false)
//   pair: residual equation $hgt2 (hold = false), iteration variable y (hold = false)
// class HGTIf1
//   final parameter Boolean isSteadyState = true;
//   Real x(start = 1.0);
//   Real y(start = 1.0);
//   Real z;
// equation
//   0.0 = y * y - x;
//   0.0 = x * x - 2.0 * y;
//   if time > 0.5 then
//     z = x;
//   else
//     z = y;
//   end if;
// end HGTIf1;
// [flattening/modelica/scodeinst/HGTIf1.mo:24:5-24:82:writable] Warning: The hand guided tearing annotation is ignored: annotations in when-equations, in if-equations that are not resolved and in for-loops that are not unrolled are not supported.
//
// endResult
