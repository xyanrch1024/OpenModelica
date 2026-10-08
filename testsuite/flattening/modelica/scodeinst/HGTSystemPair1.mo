// name: HGTSystemPair1
// keywords: hand guided tearing
// status: correct
// cflags: --handGuidedTearing -d=hgtDump
//
// System level tearing pairs (tearingPairs) between components, given in two
// annotation clauses like in the OCT User's Guide, and in an array component.
//

model HGTSystemPair1
  model B
    Real x, y;
  equation
    x = y + 1 annotation(__OpenModelica_HGT(name = res));
    y = 2 * x annotation(__OpenModelica_HGT(name = res2));
  end B;

  model C
    Real z, q;
  equation
    z = q;
  end C;

  parameter Boolean subSystem2Hold = true;
  B b;
  B ba[2];
  C c;
equation
  c.q = b.x + ba[2].y;
  annotation(__OpenModelica_HGT(tearingPairs(Pair(residualEquation = b.res, iterationVariable = c.z))));
  annotation(__OpenModelica_HGT(tearingPairs(
    Pair(residualEquation(nominal = 10, hold = subSystem2Hold) = b.res2,
         iterationVariable(start = 2, hold = subSystem2Hold) = c.q),
    Pair(residualEquation = ba[2].res, iterationVariable = ba[2].x, level = 2))));
end HGTSystemPair1;

// Result:
// Hand guided tearing:
//   pair: residual equation b.res (level 1), iteration variable c.z (level 1)
//   pair: residual equation b.res2 (level 1, nominal = 10.0, hold = subSystem2Hold), iteration variable c.q (level 1, start = 2.0, hold = subSystem2Hold)
//   pair: residual equation ba[2].res (level 2), iteration variable ba[2].x (level 2)
// class HGTSystemPair1
//   parameter Boolean subSystem2Hold = true;
//   Real b.x;
//   Real b.y;
//   Real ba[1].x;
//   Real ba[1].y;
//   Real ba[2].x;
//   Real ba[2].y;
//   Real c.z;
//   Real c.q;
// equation
//   b.x = b.y + 1.0;
//   b.y = 2.0 * b.x;
//   ba[1].x = ba[1].y + 1.0;
//   ba[1].y = 2.0 * ba[1].x;
//   ba[2].x = ba[2].y + 1.0;
//   ba[2].y = 2.0 * ba[2].x;
//   c.z = c.q;
//   c.q = b.x + ba[2].y;
// end HGTSystemPair1;
// Warning: The hold attribute of hand guided tearing is not supported yet and is ignored.
//
// endResult
