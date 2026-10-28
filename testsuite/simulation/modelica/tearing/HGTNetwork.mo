package HGTNetwork "pump - distribution manifold - 3 parallel branches - collector - return pipe"
  function flowLaw "turbulent flow, smoothed around dp = 0"
    input Real k;
    input Real dp;
    output Real m;
  algorithm
    m := k * dp / sqrt(abs(dp) + 1e-4);
  end flowLaw;

  model Pump "quadratic pump curve dp = a - b*m^2"
    parameter Real a = 5 "shut-off head [bar]";
    parameter Real b = 0.02 "[bar/(kg/s)^2]";
    Real p_in, p_out, m;
  equation
    p_out - p_in = a - b * m ^ 2;
  end Pump;

  model Branch "valve + pipe"
    parameter Real k = 2 "[kg/s/sqrt(bar)]";
    Real opening = 1;
    Real pa, pb, m;
  equation
    m = flowLaw(k * opening, pa - pb);
  end Branch;

  model Junction "mass balance of a manifold, used as residual equation"
    parameter Integer n = 3;
    Real m_in, m_out[n];
  equation
    m_in = sum(m_out) annotation(__OpenModelica_HGT(name = balance));
  end Junction;

  model System
    parameter Real p_tank = 1 "[bar]";
    parameter Real m_set = 4 "required flow of branch 1 [kg/s]";
    Pump pump;
    Branch b1(k = 4, opening = u), b2(k = 2), b3(k = 3);
    Branch ret(k = 10) "return pipe";
    Junction manifold, collector;
    Real p_m(start = 3, min = 1, max = 6) "manifold pressure [bar]";
    Real p_c(start = 2) "collector pressure [bar]";
    Real u(start = 0.5) "opening of the valve of branch 1";
  equation
    pump.p_in = p_tank;  pump.p_out = p_m;
    b1.pa = p_m; b2.pa = p_m; b3.pa = p_m;
    b1.pb = p_c; b2.pb = p_c; b3.pb = p_c;
    ret.pa = p_c; ret.pb = p_tank;
    manifold.m_in = pump.m;   manifold.m_out = {b1.m, b2.m, b3.m};
    collector.m_in = ret.m;   collector.m_out = {b1.m, b2.m, b3.m};
    b1.m = m_set annotation(__OpenModelica_HGT(ResidualEquation(nominal = 10,  // design spec
      iterationVariable(min = 0.05, max = 1) = u)));
    annotation(__OpenModelica_HGT(tearingPairs(
      Pair(residualEquation = manifold.balance, iterationVariable(max = p_tank + 4.99) = p_m),
      Pair(residualEquation = collector.balance, iterationVariable = p_c))));
  end System;
end HGTNetwork;
