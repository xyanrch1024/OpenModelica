// name: HGTError6
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// The level must be at least 1, and unknown fields are reported.
//

model HGTError6
  Real x;
equation
  x = 1 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x, level = 0, foo = 1), bar = 2));
end HGTError6;

// Result:
// Error processing file: HGTError6.mo
// [flattening/modelica/scodeinst/HGTError6.mo:12:100-12:107:writable] Warning: Unknown field 'bar' in hand guided tearing annotation of an equation, it is ignored.
// [flattening/modelica/scodeinst/HGTError6.mo:12:90-12:97:writable] Warning: Unknown field 'foo' in hand guided tearing annotation ResidualEquation, it is ignored.
// [flattening/modelica/scodeinst/HGTError6.mo:12:39-12:98:writable] Error: Invalid value '0' for 'level' in hand guided tearing annotation: expected an Integer parameter expression that is at least 1.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
