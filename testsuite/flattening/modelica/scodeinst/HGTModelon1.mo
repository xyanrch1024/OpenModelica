// name: HGTModelon1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing --acceptModelonHGT -d=hgtDump
//
// With --acceptModelonHGT the hand guided tearing part of __Modelon is read,
// other __Modelon annotations are ignored.
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
// Hand guided tearing:
//   pair: residual equation LongEq (level 1, hold = testHold1), iteration variable x (level 1, hold = testHold2)
//   pair: residual equation LongEq2 (level 1, hold = testHold2), iteration variable T (level 1, hold = testHold1)
// class HGTModelon1
//   Real x(start = 1.0);
//   Real T(start = 400.0);
//   parameter Boolean testHold1 = false;
//   parameter Boolean testHold2 = false;
// equation
//   0.0 = 120.0 * x - 75.0 * 0.12 * exp(12581.0 * (T - 298.0) / (298.0 * T)) * (1.0 - x);
//   0.0 = 11.0 * (T - 300.0) - x * (873.0 - T);
// end HGTModelon1;
// Warning: The hold attribute of hand guided tearing is not supported yet and is ignored.
//
// endResult
