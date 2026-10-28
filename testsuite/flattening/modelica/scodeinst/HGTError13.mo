// name: HGTError13
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// Array residual equations and iteration variables are only supported on
// level 1.
//

model HGTError13
  Real x[2], y;
equation
  x .^ 2 + {y, y} = {2, 3} annotation(__OpenModelica_HGT(ResidualEquation(level = 2, iterationVariable = x)));
  x[1] + x[2] = y annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y)));
end HGTError13;

// Result:
// Error processing file: HGTError13.mo
// [flattening/modelica/scodeinst/HGTError13.mo:13:58-13:108:writable] Error: Invalid value '2' for 'level' in hand guided tearing annotation: array residual equations and iteration variables are only supported on level 1.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
