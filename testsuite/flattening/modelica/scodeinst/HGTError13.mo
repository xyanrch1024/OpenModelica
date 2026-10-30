// name: HGTError13
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// A pair is held as a whole: the residual equation and its iteration variable
// can not have different hold attributes.
//

model HGTError13
  parameter Boolean h1 = true, h2 = false;
  Real x(start = 1), y(start = 1);
equation
  x + y = 3;
  x * y = 2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(hold = h2) = x, hold = h1)));
end HGTError13;

// Result:
// Error processing file: HGTError13.mo
// [flattening/modelica/scodeinst/HGTError13.mo:15:43-15:104:writable] Error: A hand guided tearing pair is held as a whole, but the residual equation $hgt1 has hold = h1 and its iteration variable x has hold = h2.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
