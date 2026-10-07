// name: HGTError3
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// Equation names must be unique.
//

model HGTError3
  Real x, y;
equation
  x = 1 annotation(__OpenModelica_HGT(name = r));
  y = 2 annotation(__OpenModelica_HGT(name = r));
end HGTError3;

// Result:
// Error processing file: HGTError3.mo
// [flattening/modelica/scodeinst/HGTError3.mo:13:3-13:49:writable] Error: The equation name 'r' is used by more than one equation.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
