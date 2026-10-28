// name: HGTOnly2
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing --hgtOnly
//
// --hgtOnly only supports explicit pairs: unpaired residual equations and
// iteration variables are an error, they are not bound automatically. The
// explicit pairs, component level and from tearingPairs, are fine.
//

model HGTOnly2
  Real x(start = 1), y(start = 1), z annotation(__OpenModelica_HGT(IterationVariable));
  Real u(start = 1), v(start = 1);
equation
  x ^ 2 + y = 3 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
  x + y ^ 2 = 3 annotation(__OpenModelica_HGT(name = r2));
  z ^ 3 + z = 2 annotation(__OpenModelica_HGT(ResidualEquation));
  u * v = 1;
  u + v = 3;
  annotation(__OpenModelica_HGT(tearingPairs(Pair(residualEquation = r2, iterationVariable = y))));
end HGTOnly2;

// Result:
// Error processing file: HGTOnly2.mo
// [flattening/modelica/scodeinst/HGTOnly2.mo:17:3-17:65:writable] Error: The hand guided tearing residual equation $hgt2 is not paired, but --hgtOnly only supports explicit pairs, given by ResidualEquation(iterationVariable = ...) or tearingPairs(Pair(...)).
// [flattening/modelica/scodeinst/HGTOnly2.mo:12:3-12:87:writable] Error: The hand guided tearing iteration variable z is not paired, but --hgtOnly only supports explicit pairs, given by ResidualEquation(iterationVariable = ...) or tearingPairs(Pair(...)).
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
