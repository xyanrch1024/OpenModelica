// name: HGTError12
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// A system level pair of a scalar equation and an array variable.
//

model HGTError12
  Real x[2];
equation
  x[1] + x[2] = 3 annotation(__OpenModelica_HGT(name = s));
  x[1] = 1;
  annotation(__OpenModelica_HGT(tearingPairs(Pair(residualEquation = s, iterationVariable = x))));
end HGTError12;

// Result:
// Error processing file: HGTError12.mo
// [flattening/modelica/scodeinst/HGTError12.mo:14:46-14:95:writable] Error: Invalid value 'x[1], x[2]' for 'iterationVariable' in hand guided tearing annotation: the residual equation is a scalar but the iteration variable is an array of size [2], they are paired element-wise.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
