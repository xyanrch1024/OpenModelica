// name: HGTError7
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// The nominal of a residual equation must be positive.
//

model HGTError7
  Real x(start = 1);
equation
  x ^ 2 = 2 annotation(__OpenModelica_HGT(ResidualEquation(nominal = 0, iterationVariable = x)));
end HGTError7;

// Result:
// Error processing file: HGTError7.mo
// [flattening/modelica/scodeinst/HGTError7.mo:12:43-12:95:writable] Error: Invalid value '0' for 'nominal' in hand guided tearing annotation: it must be positive.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
