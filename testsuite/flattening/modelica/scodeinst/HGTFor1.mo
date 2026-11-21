// name: HGTFor1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// Hand guided tearing annotations in for-loops: each iteration is an equation of
// its own whose name gets the iterator values as subscripts, and the annotation
// is evaluated with them. Nested loops, tearingPairs referring to an iteration,
// unnamed equations and a reversed index mapping.
//

model HGTFor1
  parameter Integer n = 2;
  Real x[n, 2], y[n], z[n];
equation
  for i in 1:n loop
    for j in 1:2 loop
      x[i, j] ^ 2 = i + j annotation(__OpenModelica_HGT(name = r,
        ResidualEquation(iterationVariable(start = i * j) = x[i, j])));
    end for;
    y[i] ^ 3 = i annotation(__OpenModelica_HGT(name = s));
    z[i] = 2 * i annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = z[n + 1 - i])));
  end for;
  annotation(__OpenModelica_HGT(tearingPairs(
    Pair(residualEquation = s[1], iterationVariable = y[1]),
    Pair(residualEquation = s[2], iterationVariable = y[2]))));
end HGTFor1;

// Result:
// Hand guided tearing:
//   pair: residual equation $hgt1[1], iteration variable z[2]
//   pair: residual equation $hgt1[2], iteration variable z[1]
//   pair: residual equation r[1,1], iteration variable x[1, 1] (start = 1.0 * 1.0)
//   pair: residual equation r[1,2], iteration variable x[1, 2] (start = 1.0 * 2.0)
//   pair: residual equation r[2,1], iteration variable x[2, 1] (start = 2.0 * 1.0)
//   pair: residual equation r[2,2], iteration variable x[2, 2] (start = 2.0 * 2.0)
//   pair: residual equation s[1], iteration variable y[1]
//   pair: residual equation s[2], iteration variable y[2]
// class HGTFor1
//   final parameter Integer n = 2;
//   Real x[1,1];
//   Real x[1,2];
//   Real x[2,1];
//   Real x[2,2];
//   Real y[1];
//   Real y[2];
//   Real z[1];
//   Real z[2];
// equation
//   x[1,1] ^ 2.0 = 2.0;
//   x[1,2] ^ 2.0 = 3.0;
//   y[1] ^ 3.0 = 1.0;
//   z[1] = 2.0;
//   x[2,1] ^ 2.0 = 3.0;
//   x[2,2] ^ 2.0 = 4.0;
//   y[2] ^ 3.0 = 2.0;
//   z[2] = 4.0;
// end HGTFor1;
// endResult
