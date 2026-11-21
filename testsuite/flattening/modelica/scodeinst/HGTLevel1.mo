// name: HGTLevel1
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing -d=hgtDump
//
// Nested hand guided tearing (level 2 and higher), written like the NHGT
// examples of the OCT User's Guide, is not supported. The level is given by a
// parameter here.
//

model HGTLevel1
  parameter Real f = 10;
  parameter Integer innerLevel = 2;
  Real x1(min = 0, max = 20, start = 15);
  Real x2(min = 0, max = 20, start = 15);
  Real k;
  Real l;
  Real s;
equation
  0 = k + (x1 - 9) / (-2);
  0 = l + (x2 - f) / (-2);
  0 = x2 / 40 + x1 / 20 - s;
  0 = exp(-exp(k) + k + 1.0) - 0.3 * exp(-exp(l) + l + 1.0) - 0.5
    annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x1, level = 1)));
  0 = s + x1 * x2 / 16^2 - 1
    annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x2, level = innerLevel)));
end HGTLevel1;

// Result:
// Error processing file: HGTLevel1.mo
// [flattening/modelica/scodeinst/HGTLevel1.mo:26:35-26:95:writable] Error: Invalid value 'innerLevel' for 'level' in hand guided tearing annotation: only level 1 is supported.
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
