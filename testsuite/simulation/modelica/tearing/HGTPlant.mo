package HGTPlant "pump - manifold - 2 heated branches - collector/mixer - return pipe (Colebrook)"
  function flowLaw "turbulent flow, smoothed around dp = 0"
    input Real k;
    input Real dp;
    output Real m;
  algorithm
    m := k * dp / sqrt(abs(dp) + 1e-4);
  end flowLaw;

  model Pump "dp = a - b*m^2"
    parameter Real a = 5, b = 0.02;
    Real p_in, p_out, m;
  equation
    // enabled = false: this annotation is ignored
    p_out - p_in = a - b * m ^ 2 annotation(__OpenModelica_HGT(ResidualEquation(enabled = false)));
  end Pump;

  model Junction "pressure node, component level pair: mass balance <-> node pressure"
    parameter Integer n = 2;
    Real p(start = 2);
    Real m_in, m_out[n];
  equation
    m_in = sum(m_out) annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(nominal = 1) = p)));
  end Junction;

  model HeatedBranch "valve/pipe + heater with constant wall temperature (effectiveness-NTU)"
    parameter Real k = 2, UA = 20, cp = 4.2;
    Real pa, pb, m, T_in, T_wall, Q, T_out;
  equation
    m = flowLaw(k, pa - pb);
    Q = (1 - exp(-UA / (m * cp))) * m * cp * (T_wall - T_in);
    T_out = T_in + Q / (m * cp);
  end HeatedBranch;

  model ReturnPipe "dp = R*f*m*|m|, Colebrook friction factor (implicit in f)"
    parameter Real R = 50, c = 2e4, rr = 1e-3;
    Real pa, pb, m, Re;
    Real f(start = 0.03) "friction factor, iteration variable with bounds";
  equation
    Re = c * abs(m) + 1;
    1 / sqrt(f) = -2 * log10(2.51 / (Re * sqrt(f)) + rr / 3.7)
      annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(min = 0.005, max = 0.1, nominal = 0.03) = f)));
    pa - pb = R * f * m * abs(m);
  end ReturnPipe;

  model Mixer "energy balance, named residual equation"
    Real m[2], T[2], T_mix(start = 320);
  equation
    m[1] * T[1] + m[2] * T[2] = (m[1] + m[2]) * T_mix annotation(__OpenModelica_HGT(name = energy));
  end Mixer;

  model System
    parameter Real p_tank = 1, T_tank = 290, T_set = 330;
    Pump pump;
    HeatedBranch h1(k = 3, UA = 25), h2(k = 2, UA = 15);
    ReturnPipe ret;
    Junction manifold, collector;
    Mixer mixer;
    Real T_wall(start = 350) "wall temperature of both heaters, the design variable";
  equation
    // hydraulics
    pump.p_in = p_tank;  pump.p_out = manifold.p;
    h1.pa = manifold.p;  h2.pa = manifold.p;
    h1.pb = collector.p; h2.pb = collector.p;
    ret.pa = collector.p; ret.pb = p_tank;
    manifold.m_in = pump.m;   manifold.m_out = {h1.m, h2.m};
    collector.m_in = ret.m;   collector.m_out = {h1.m, h2.m};
    // thermal
    h1.T_in = T_tank; h2.T_in = T_tank;
    h1.T_wall = T_wall; h2.T_wall = T_wall;
    mixer.m = {h1.m, h2.m}; mixer.T = {h1.T_out, h2.T_out};
    // design spec: T_wall is iterated to reach T_set
    mixer.T_mix = T_set annotation(__OpenModelica_HGT(ResidualEquation(nominal = 10,
      iterationVariable(min = 300, max = 450, nominal = 100) = T_wall)));
    // system level pair in OCT syntax (--acceptModelonHGT)
    annotation(__Modelon(tearingPairs(Pair(residualEquation(nominal = 1000) = mixer.energy,
                                           iterationVariable(start = 320, nominal = 300) = mixer.T_mix))));
  end System;
end HGTPlant;
