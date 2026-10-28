// name: HGTError11
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// An array attribute of an array iteration variable must have its size.
//

model HGTError11
  Real x[3];
equation
  x .^ 2 = {1, 2, 3} annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(start = {1, 2}) = x)));
end HGTError11;

// Result:
// Error processing file: HGTError11.mo
// [flattening/modelica/scodeinst/HGTError11.mo:12:69-12:106:writable] Error: Invalid value '{1, 2}' for 'start' in hand guided tearing annotation: expected a scalar Real expression or an array of size [3] of Real expressions.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
