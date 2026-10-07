// name: HGTError2
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing
//
// A tearing pair must refer to an existing equation name.
//

model HGTError2
  Real x;
equation
  x = 1;
  annotation(__OpenModelica_HGT(tearingPairs(Pair(residualEquation = nothere, iterationVariable = x))));
end HGTError2;

// Result:
// Error processing file: HGTError2.mo
// [flattening/modelica/scodeinst/HGTError2.mo:13:46-13:101:writable] Error: The hand guided tearing pair refers to the equation 'nothere', but no equation has that name (equations are named with __OpenModelica_HGT(name=...)).
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
