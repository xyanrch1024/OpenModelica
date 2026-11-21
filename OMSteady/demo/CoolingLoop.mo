model CoolingLoop "冷却水回路的稳态模型：一台泵，两条并联支路（支路 1 带调节阀），每条支路一台冷却器"
  // ---- 设备参数 ----
  parameter Real H0 = 4.0 "泵在额定转速、零流量时的扬程 [bar]";
  parameter Real a = 0.01 "泵特性曲线的系数 [bar/(kg/s)^2]";
  parameter Real k0 = 0.005 "总管阻力系数 [bar/(kg/s)^2]";
  parameter Real kv = 0.02 "阀门全开时支路 1 的阻力系数 [bar/(kg/s)^2]";
  parameter Real k2 = 0.03 "支路 2 的阻力系数 [bar/(kg/s)^2]";
  parameter Real cp = 4.18 "水的比热 [kJ/(kg.K)]";
  parameter Real T_in = 20 "供水温度 [degC]";
  parameter Real Q1 = 500 "冷却器 1 的热负荷 [kW]";
  parameter Real Q2 = 300 "冷却器 2 的热负荷 [kW]";

  // ---- 操作条件（校核工况下给定）----
  parameter Real n_set = 1.0 "泵的相对转速";
  parameter Real opening_set = 1.0 "阀门开度";

  // ---- 工况开关：都为 false 是校核工况 ----
  parameter Boolean designFlow = false "true：总流量 m 给定，反算泵转速";
  parameter Boolean limitT1 = false "true：冷却器 1 的出口温度 T1 给定，反算阀门开度";

  // ---- 迭代变量（由求解器迭代，或者被 hold 住）----
  Real m(start = 10, min = 0.1) "总流量 [kg/s]";
  Real m1(start = 5, min = 0.1) "支路 1 的流量 [kg/s]";
  Real T1(start = 40, max = 95) "冷却器 1 的出口温度 [degC]";
  Real T2(start = 40, max = 95) "冷却器 2 的出口温度 [degC]";
  Real n(start = 1, min = 0.2, max = 1.5) "泵的相对转速";
  Real opening(start = 1, min = 0.05, max = 1) "阀门开度";

  // ---- 其余变量：给定迭代变量之后都能直接算出 ----
  Real m2 "支路 2 的流量 [kg/s]";
  Real H "泵的扬程 [bar]";
  Real dp0 "总管压降 [bar]";
  Real dp1 "支路 1 压降 [bar]";
  Real dp2 "支路 2 压降 [bar]";
equation
  m2 = m - m1;
  H = n ^ 2 * H0 - a * m ^ 2;
  dp0 = k0 * m ^ 2;
  dp1 = kv * m1 ^ 2 / opening ^ 2;
  dp2 = k2 * m2 ^ 2;

  // 回路压力平衡，决定总流量；设计工况下 m 被 hold 住
  H = dp0 + dp1
    annotation(__OpenModelica_HGT(name = loopBalance,
      ResidualEquation(iterationVariable(hold = designFlow) = m)));

  // 两条支路压降相等，决定流量分配
  dp1 = dp2
    annotation(__OpenModelica_HGT(name = branchBalance,
      ResidualEquation(iterationVariable = m1)));

  // 冷却器的能量平衡；限温工况下 T1 被 hold 住
  Q1 = m1 * cp * (T1 - T_in)
    annotation(__OpenModelica_HGT(name = energy1,
      ResidualEquation(nominal = 100, iterationVariable(hold = limitT1) = T1)));
  Q2 = m2 * cp * (T2 - T_in)
    annotation(__OpenModelica_HGT(name = energy2,
      ResidualEquation(nominal = 100, iterationVariable = T2)));

  // 操作条件；设计工况下去掉转速的设定，限温工况下去掉开度的设定
  n = n_set
    annotation(__OpenModelica_HGT(name = pumpSpec,
      ResidualEquation(hold = designFlow, iterationVariable = n)));
  opening = opening_set
    annotation(__OpenModelica_HGT(name = valveSpec,
      ResidualEquation(hold = limitT1, iterationVariable = opening)));
end CoolingLoop;
