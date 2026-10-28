// name: HGTModelon1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// The hand guided tearing annotations of OCT (__Modelon) are not read: like
// other vendors' annotations they are ignored, without any message.
//

model HGTModelon1
  Real x(start = 1);
  Real T(start = 400);
  parameter Boolean testHold1 = false;
  parameter Boolean testHold2 = false;
equation
  0 = 120*x - 75*(0.12*exp(12581*(T - 298)/(298*T)))*(1 - x)
    annotation(__Modelon(ResidualEquation(hold = testHold1,
      iterationVariable(hold = testHold2) = x), name = LongEq));
  0 = -x*(873 - T) + 11.0*(T - 300)
    annotation(__Modelon(ResidualEquation(hold = testHold2,
      iterationVariable(hold = testHold1) = T), name = LongEq2));
  annotation(__Modelon(somethingElse = true));
end HGTModelon1;

// Result:
// class HGTModelon1
//   Real x(start = 1.0);
//   Real T(start = 400.0);
//   parameter Boolean testHold1 = false;
//   parameter Boolean testHold2 = false;
// equation
//   0.0 = 120.0 * x - 75.0 * 0.12 * exp(12581.0 * (T - 298.0) / (298.0 * T)) * (1.0 - x);
//   0.0 = 11.0 * (T - 300.0) - x * (873.0 - T);
// end HGTModelon1;
// endResult
