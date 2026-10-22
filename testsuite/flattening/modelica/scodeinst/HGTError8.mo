// name: HGTError8
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// The nominal of an iteration variable must be positive, also when it is given
// by a parameter.
//

model HGTError8
  parameter Real p = -1;
  Real x(start = 1);
equation
  x ^ 2 = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(nominal = p) = x)));
end HGTError8;

// Result:
// Error processing file: HGTError8.mo
// [flattening/modelica/scodeinst/HGTError8.mo:14:60-14:94:writable] Error: Invalid value 'p' for 'nominal' in hand guided tearing annotation: it must be positive.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
