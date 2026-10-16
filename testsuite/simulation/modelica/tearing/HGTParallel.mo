package HGTParallel "Coupled pump, parallel heat exchangers, mixer and return"

model HeatedBranch
  parameter Real resistance = 1
    "Linear pressure loss [bar/(kg/s)]";
  parameter Real UA = 1
    "Heat transfer conductance [kW/K]";
  parameter Real cp = 4.18
    "Specific heat [kJ/(kg.K)]";
  parameter Real Tin = 300
    "Inlet temperature [K]";
  parameter Real Thot = 370
    "Heating-side temperature [K]";
  parameter Real flowStart = 0.8;

  Real dp "Branch pressure drop [bar]";
  Real m(start = flowStart)
    "Branch mass flow [kg/s]";
  Real Tout(start = 320)
    "Outlet temperature [K]";
  Real Q "Heat duty [kW]";

equation
  dp = resistance * exp(-0.015 * (Tout - Tin)) * m
       + 0.08 * m^3
       annotation(
         __OpenModelica_HGT(ResidualEquation(
           level = 3,
           iterationVariable(
             min = 0.02,
             max = 5,
             nominal = 1) = m)));

  Tout = Thot - (Thot - Tin) * exp(-UA / (cp * m));
  Q = cp * m * (Tout - Tin);

end HeatedBranch;


model Plant
  parameter Integer n = 12;
  parameter Real targetFlow = 12
    "Required total flow [kg/s]";
  parameter Real flowStart = 0.8;
  parameter Real pressureStart = 1;
  parameter Real speedStart = 1;

  HeatedBranch branch[n](
    resistance = {0.5 + 0.08 * i for i in 1:n},
    UA = {0.5 + 0.1 * i for i in 1:n},
    each flowStart = flowStart);

  Real speed(start = speedStart)
    "Normalized pump speed";
  Real dp(start = pressureStart)
    "Common branch pressure drop [bar]";
  Real totalFlow(start = targetFlow)
    "Pump and return flow [kg/s]";
  Real pumpHead
    "Pump pressure rise [bar]";
  Real returnDrop
    "Return-pipe pressure drop [bar]";
  Real mixedTemperature
    "Mixed outlet temperature [K]";
  Real heatDuty
    "Total heat duty [kW]";

equation
  pumpHead = 12 * speed^2 - 0.02 * totalFlow^2;
  returnDrop = 0.004 * totalFlow^2;
  pumpHead = dp + returnDrop
    annotation(
      __OpenModelica_HGT(ResidualEquation(
        level = 2,
        iterationVariable(
          min = 0.001,
          max = 6,
          nominal = 1) = dp)));

  branch.dp = fill(dp, n);

  totalFlow = sum(branch.m);

  totalFlow = targetFlow
    annotation(
      __OpenModelica_HGT(ResidualEquation(
        level = 1,
        iterationVariable(
          min = 0.15,
          max = 1.5,
          nominal = 1) = speed)));

  mixedTemperature =
    sum(branch.m .* branch.Tout) / totalFlow;

  heatDuty = sum(branch.Q);

end Plant;

end HGTParallel;
