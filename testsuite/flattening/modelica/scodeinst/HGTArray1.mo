// name: HGTArray1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// Array equations are paired element-wise with array iteration variables or
// slices of the same size: the element equations are named with the element
// subscripts. Attributes are scalars for all elements or arrays of the same
// size. tearingPairs can pair a whole array equation or one element, and an
// array equation in a for-loop gets the iterator and the element subscripts.
//

model HGTArray1
  parameter Real c[2, 2] = {{1, 2}, {3, 4}};
  Real x[3], y[2, 2], z[3], w[2, 2];
equation
  x .^ 2 = {1, 2, 3} annotation(__OpenModelica_HGT(name = bx,
    ResidualEquation(nominal = 2, iterationVariable(start = {1, 2, 3}, min = 0) = x)));
  y .^ 3 = c annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(nominal = c) = y)));
  z[1:2] .^ 2 = {4, 9} annotation(__OpenModelica_HGT(name = bz));
  z[3] ^ 2 = 16 annotation(__OpenModelica_HGT(name = bz3));
  for i in 1:2 loop
    w[i, :] .^ 2 = c[i, :] annotation(__OpenModelica_HGT(name = bw, ResidualEquation(iterationVariable = w[i, :])));
  end for;
  annotation(__OpenModelica_HGT(tearingPairs(
    Pair(residualEquation = bz, iterationVariable = z[1:2]),
    Pair(residualEquation = bz3, iterationVariable = z[3]))));
end HGTArray1;

// Result:
// Hand guided tearing:
//   pair: residual equation $hgt1[1,1] (level 1), iteration variable y[1, 1] (level 1, nominal = c[1, 1])
//   pair: residual equation $hgt1[1,2] (level 1), iteration variable y[1, 2] (level 1, nominal = c[1, 2])
//   pair: residual equation $hgt1[2,1] (level 1), iteration variable y[2, 1] (level 1, nominal = c[2, 1])
//   pair: residual equation $hgt1[2,2] (level 1), iteration variable y[2, 2] (level 1, nominal = c[2, 2])
//   pair: residual equation bw[1,1] (level 1), iteration variable w[1, 1] (level 1)
//   pair: residual equation bw[1,2] (level 1), iteration variable w[1, 2] (level 1)
//   pair: residual equation bw[2,1] (level 1), iteration variable w[2, 1] (level 1)
//   pair: residual equation bw[2,2] (level 1), iteration variable w[2, 2] (level 1)
//   pair: residual equation bx[1] (level 1, nominal = 2.0), iteration variable x[1] (level 1, start = 1.0, min = 0.0)
//   pair: residual equation bx[2] (level 1, nominal = 2.0), iteration variable x[2] (level 1, start = 2.0, min = 0.0)
//   pair: residual equation bx[3] (level 1, nominal = 2.0), iteration variable x[3] (level 1, start = 3.0, min = 0.0)
//   pair: residual equation bz3 (level 1), iteration variable z[3] (level 1)
//   pair: residual equation bz[1] (level 1), iteration variable z[1] (level 1)
//   pair: residual equation bz[2] (level 1), iteration variable z[2] (level 1)
// class HGTArray1
//   parameter Real c[1,1] = 1.0;
//   parameter Real c[1,2] = 2.0;
//   parameter Real c[2,1] = 3.0;
//   parameter Real c[2,2] = 4.0;
//   Real x[1];
//   Real x[2];
//   Real x[3];
//   Real y[1,1];
//   Real y[1,2];
//   Real y[2,1];
//   Real y[2,2];
//   Real z[1];
//   Real z[2];
//   Real z[3];
//   Real w[1,1];
//   Real w[1,2];
//   Real w[2,1];
//   Real w[2,2];
// equation
//   x[1] ^ 2.0 = 1.0;
//   x[2] ^ 2.0 = 2.0;
//   x[3] ^ 2.0 = 3.0;
//   y[1,1] ^ 3.0 = c[1,1];
//   y[1,2] ^ 3.0 = c[1,2];
//   y[2,1] ^ 3.0 = c[2,1];
//   y[2,2] ^ 3.0 = c[2,2];
//   z[1] ^ 2.0 = 4.0;
//   z[2] ^ 2.0 = 9.0;
//   z[3] ^ 2.0 = 16.0;
//   w[1,1] ^ 2.0 = c[1,1];
//   w[1,2] ^ 2.0 = c[1,2];
//   w[2,1] ^ 2.0 = c[2,1];
//   w[2,2] ^ 2.0 = c[2,2];
// end HGTArray1;
// endResult
