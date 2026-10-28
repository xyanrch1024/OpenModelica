// name: HGTError10
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// An array residual equation is paired element-wise, the iteration variable
// must have the same size.
//

model HGTError10
  Real x[3];
equation
  x .^ 2 = {1, 2, 3} annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x[1:2])));
end HGTError10;

// Result:
// Error processing file: HGTError10.mo
// [flattening/modelica/scodeinst/HGTError10.mo:13:52-13:96:writable] Error: Invalid value 'x[1], x[2]' for 'iterationVariable' in hand guided tearing annotation: the residual equation is an array of size [3] but the iteration variable is an array of size [2], they are paired element-wise.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
