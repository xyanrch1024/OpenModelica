// name: HGTDisabled1
// keywords: hand guided tearing
// status: correct
//
// Without --handGuidedTearing the annotations are ignored with a notification.
//

model HGTDisabled1
  Real x;
equation
  x = 1 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
end HGTDisabled1;

// Result:
// class HGTDisabled1
//   Real x;
// equation
//   x = 1.0;
// end HGTDisabled1;
// Notification: The model contains hand guided tearing annotations, which are ignored since --handGuidedTearing is not set.
//
// endResult
