// name: HGTError14
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// A system level pair with an array iteration variable on level 2.
//

model HGTError14
  Real x[2], y;
equation
  x .^ 2 + {y, y} = {2, 3} annotation(__OpenModelica_HGT(name = bx));
  x[1] + x[2] = y annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y)));
  annotation(__OpenModelica_HGT(tearingPairs(Pair(level = 2, residualEquation = bx, iterationVariable = x))));
end HGTError14;

// Result:
// Error processing file: HGTError14.mo
// [flattening/modelica/scodeinst/HGTError14.mo:14:46-14:107:writable] Error: Invalid value '2' for 'level' in hand guided tearing annotation: array residual equations and iteration variables are only supported on level 1.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
