package HGTAlgebra "pure algebraic loops: multiple roots and an inverse problem"
  model System
    // block 1: circle and hyperbola, 4 roots (1,-2), (-1,2), (2,-1), (-2,1); the start values select (1,-2)
    Real x(start = 0.8), y(start = -1.5);
    // block 2: find k such that z = z_set; two roots k = 0.8562 and k = -1.7655, the bounds keep k >= 0
    Real k(start = 1);
    Real v, z;
    parameter Real z_set = 2;
  equation
    x ^ 2 + y ^ 2 = 5 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = x)));
    x * y = -2 annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable = y)));

    v = k + 0.5 * sin(z);
    z = log(1 + v ^ 2) + x;
    z = z_set annotation(__OpenModelica_HGT(ResidualEquation(iterationVariable(min = 0, max = 5) = k)));
  end System;
end HGTAlgebra;
