// name: HGTError1
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// The iteration variable must be a continuous variable.
//

model HGTError1
  parameter Real p = 1;
  Real x;
equation
  x = p annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = p)));
end HGTError1;

// Result:
// Error processing file: HGTError1.mo
// [flattening/modelica/scodeinst/HGTError1.mo:13:56-13:77:writable] Error: 'p' cannot be a hand guided tearing iteration variable: it is not a continuous variable.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
