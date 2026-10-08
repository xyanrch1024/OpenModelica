// name: HGTLevel1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// Nested hand guided tearing with an adaptive bound on level 2, written like
// the NHGT examples of the OCT User's Guide. The level is given by a
// parameter, which becomes structural.
//

model HGTLevel1
  parameter Real f = 10;
  parameter Integer innerLevel = 2;
  Real x1(min = 0, max = 20, start = 15);
  Real x2(min = 0, max = 20, start = 15);
  Real k;
  Real l;
  Real s;
equation
  0 = k + (x1 - 9) / (-2);
  0 = l + (x2 - f) / (-2);
  0 = x2 / 40 + x1 / 20 - s;
  0 = exp(-exp(k) + k + 1.0) - 0.3 * exp(-exp(l) + l + 1.0) - 0.5
    annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x1, level = 1)));
  0 = s + x1 * x2 / 16^2 - 1
    annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(max = 20 - x1) = x2, level = innerLevel)));
end HGTLevel1;

// Result:
// Hand guided tearing:
//   pair: residual equation $hgt1 (level 1), iteration variable x1 (level 1)
//   pair: residual equation $hgt2 (level 2), iteration variable x2 (level 2, max = 20.0 - x1)
// class HGTLevel1
//   parameter Real f = 10.0;
//   final parameter Integer innerLevel = 2;
//   Real x1(min = 0.0, max = 20.0, start = 15.0);
//   Real x2(min = 0.0, max = 20.0, start = 15.0);
//   Real k;
//   Real l;
//   Real s;
// equation
//   0.0 = k + (x1 - 9.0) / (-2.0);
//   0.0 = l + (x2 - f) / (-2.0);
//   0.0 = x2 / 40.0 + x1 / 20.0 - s;
//   0.0 = exp(k - exp(k) + 1.0) - 0.3 * exp(l - exp(l) + 1.0) - 0.5;
//   0.0 = s + x1 * x2 / 256.0 - 1.0;
// end HGTLevel1;
// endResult
