// name: HGTError4
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// Attributes of level 1 iteration variables can't depend on continuous variables.
//

model HGTError4
  Real x, y;
equation
  x = y annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(max = y) = x)));
  y = 1;
end HGTError4;

// Result:
// Error processing file: HGTError4.mo
// [flattening/modelica/scodeinst/HGTError4.mo:12:56-12:86:writable] Error: The max attribute 'y' of the hand guided tearing iteration variable x depends on continuous variables, which is only allowed on level 2 or higher.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
