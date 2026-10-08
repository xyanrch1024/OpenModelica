// name: HGTUnpaired1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// Unpaired iteration variables and residual equations, written like the
// TestUnpaired example of the OCT User's Guide.
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
// Hand guided tearing:
//   unpaired residual equation mixer.dx (level 1)
//   unpaired iteration variable splitter.factor (level 1)
// class HGTUnpaired1
//   Real splitter.x;
//   parameter Real splitter.k = 1.0;
//   parameter Real splitter.factor_guess = 0.5;
//   Real splitter.factor(min = 0.0, max = 1.0, start = splitter.factor_guess);
//   Real splitter.x1 = splitter.factor * splitter.k * splitter.x;
//   Real splitter.x2 = (1.0 - splitter.factor) * splitter.k * splitter.x;
//   Real mixer.x1;
//   Real mixer.x2;
//   Real mixer.y;
// equation
//   0.0 = mixer.x1 - mixer.x2;
//   mixer.y = mixer.x1;
//   splitter.x = 1.0;
//   splitter.x1 = mixer.x1;
//   splitter.x2 = mixer.x2;
// end HGTUnpaired1;
// endResult
