// name: HGTComponentPair1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// Component level tearing pairs, with named and unnamed residual equations
// and iteration variable attributes.
//

model HGTComponentPair1
  parameter Real p = 2;
  Real x(start = 1), y, z, q;
equation
  x + y = 3 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
  x - y = z annotation(__OpenModelica_HGT(name = res2, ResidualEquation(
    iterationVariable(start = p, min = -10, max = 10, nominal = 2) = y, nominal = 100)));
  z = 2 * q annotation(__OpenModelica_HGT(name = res3));
  q = 1;
end HGTComponentPair1;

// Result:
// Hand guided tearing:
//   pair: residual equation $hgt1 (level 1), iteration variable x (level 1)
//   pair: residual equation res2 (level 1, nominal = 100.0), iteration variable y (level 1, start = p, min = -10.0, max = 10.0, nominal = 2.0)
// class HGTComponentPair1
//   parameter Real p = 2.0;
//   Real x(start = 1.0);
//   Real y;
//   Real z;
//   Real q;
// equation
//   x + y = 3.0;
//   x - y = z;
//   z = 2.0 * q;
//   q = 1.0;
// end HGTComponentPair1;
// endResult
