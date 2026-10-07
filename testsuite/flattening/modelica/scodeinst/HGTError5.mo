// name: HGTError5
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// A variable can only be one iteration variable.
//

model HGTError5
  Real x, y annotation(__OpenModelica_HGT(IterationVariable));
equation
  x = y annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y)));
  y = x - 1 annotation(__OpenModelica_HGT(ResidualEquation));
end HGTError5;

// Result:
// Error processing file: HGTError5.mo
// [flattening/modelica/scodeinst/HGTError5.mo:10:3-10:62:writable] Error: The variable y is given more than one hand guided tearing specification.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
