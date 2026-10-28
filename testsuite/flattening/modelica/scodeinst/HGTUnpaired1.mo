// name: HGTUnpaired1
// keywords: hand guided tearing
// status: incorrect
// cflags: --handGuidedTearing -d=hgtDump
//
// Unpaired iteration variables and residual equations, written like the
// TestUnpaired example of the OCT User's Guide, are not supported: only
// explicit pairs are. The errors give the names with the component prefix.
//

model HGTUnpaired1
  model Splitter
    Real x;
    parameter Real k = 1.0;
    parameter Real factor_guess = 0.5;
    Real factor(min = 0, max = 1, start = factor_guess)
      annotation(__OpenModelica_HGT(IterationVariable(enabled = true)));
    Real x1 = factor * k * x;
    Real x2 = (1 - factor) * k * x;
  end Splitter;

  model Mixer
    Real x1;
    Real x2;
    Real y;
  equation
    0 = x1 - x2 annotation(__OpenModelica_HGT(ResidualEquation, name = dx));
    y = x1;
  end Mixer;

  Splitter splitter;
  Mixer mixer;
equation
  splitter.x = 1;
  splitter.x1 = mixer.x1;
  splitter.x2 = mixer.x2;
end HGTUnpaired1;

// Result:
// Error processing file: HGTUnpaired1.mo
// [flattening/modelica/scodeinst/HGTUnpaired1.mo:27:5-27:76:writable] Error: The hand guided tearing residual equation mixer.dx is not paired. Only explicit pairs are supported, given by ResidualEquation(iterationVariable = ...) or tearingPairs(Pair(...)).
// [flattening/modelica/scodeinst/HGTUnpaired1.mo:17:37-17:70:writable] Error: The hand guided tearing iteration variable splitter.factor is not paired. Only explicit pairs are supported, given by ResidualEquation(iterationVariable = ...) or tearingPairs(Pair(...)).
//
// # Error encountered! Exiting...
// # Please check the error message and the flags.
//
// Execution failed!
// endResult
