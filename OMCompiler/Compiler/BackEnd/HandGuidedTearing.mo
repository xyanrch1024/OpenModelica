/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2026, Open Source Modelica Consortium (OSMC),
 * c/o Linköpings universitet, Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF AGPL VERSION 3 LICENSE OR
 * THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.8.
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
 * RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GNU AGPL
 * VERSION 3, ACCORDING TO RECIPIENTS CHOICE.
 *
 * The OpenModelica software and the OSMC (Open Source Modelica Consortium)
 * Public License (OSMC-PL) are obtained from OSMC, either from the above
 * address, from the URLs:
 * http://www.openmodelica.org or
 * https://github.com/OpenModelica/ or
 * http://www.ida.liu.se/projects/OpenModelica,
 * and in the OpenModelica distribution.
 *
 * GNU AGPL version 3 is obtained from:
 * https://www.gnu.org/licenses/licenses.html#GPL
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package HandGuidedTearing
  "Hand guided tearing (HGT) in the old backend, see doc/HGT_design.md section 8.
   The frontend (NFHandGuidedTearing) collects the specification and tags the
   residual equations with their name in an __OpenModelica_HGTEquation source
   annotation. This package:
     - lower: protects the iteration variables, applies their start and nominal
       attributes, scales the residual equations by their nominal and makes
       the held ones keep their iteration variable at its start value,
     - hgtMatching: a post-optimization module that forces the tearing pairs
       into the matching, so that each residual equation and its iteration
       variable end up in the same strong component,
     - componentItems: tells Tearing which items of a strong component were
       given by the user, Tearing.handGuidedTearing then tears the component."

public
import BackendDAE;
import DAE;

protected
import Absyn;
import Array;
import AvlTreePathFunction;
import BackendDAEUtil;
import BackendDAETransform;
import BackendDump;
import BackendEquation;
import BackendVariable;
import ComponentReference;
import ComponentReferenceBasics;
import ElementSource;
import Error;
import Expression;
import ExpressionBasics;
import ExpressionDump;
import Flags;
import List;
import SCode;
import SCodeUtil;
import UnorderedMap;
import UnorderedSet;
import Util;

constant String EQUATION_TAG = "__OpenModelica_HGTEquation";

public

// ============================================================================
// Lowering
// ============================================================================

function lower
  "Called by BackendDAECreate.lower. Finds the hand guided tearing specification
   in the DAE, marks the iteration variables as unreplaceable so that they are
   not removed as aliases, applies their start and nominal attributes, and
   rewrites the residual equations with a nominal or a hold attribute, see
   rewriteResidual."
  input list<DAE.Element> elements;
  output Option<BackendDAE.HGTSpec> spec;
  input output list<BackendDAE.Var> vars;
  input output list<BackendDAE.Equation> eqns;
  input output list<BackendDAE.Equation> initialEqns;
protected
  BackendDAE.HGTSpec s;
  UnorderedMap<String, DAE.HGTIterationVariable> var_map;
  UnorderedMap<String, DAE.HGTResidual> residual_map;
  list<DAE.HGTIterationVariable> iter_vars;
algorithm
  spec := findSpec(elements);

  if isNone(spec) then
    return;
  end if;

  SOME(s) := spec;
  iter_vars := allIterationVariables(s);

  var_map := UnorderedMap.new<DAE.HGTIterationVariable>(stringHashDjb2, stringEq);
  for v in iter_vars loop
    UnorderedMap.add(crefString(v.name), v, var_map);
  end for;

  vars := list(lowerVariable(v, var_map) for v in vars);

  residual_map := UnorderedMap.new<DAE.HGTResidual>(stringHashDjb2, stringEq);
  for r in s.residuals loop
    if isSome(r.nominal) or isSome(pairHold(r)) then
      UnorderedMap.add(r.name, r, residual_map);
    end if;
  end for;

  if not UnorderedMap.isEmpty(residual_map) then
    eqns := list(rewriteResidual(e, residual_map) for e in eqns);
    initialEqns := list(rewriteResidual(e, residual_map) for e in initialEqns);
  end if;

  // The initial equations are gone from the simulation DAE when hgtMatching
  // runs, remember which residual equations they were.
  s.initialResiduals := list(Util.getOption(n) for n guard isSome(n) in list(equationName(e) for e in initialEqns));
  spec := SOME(s);
end lower;

function iterationVariableBounds
  "Returns the min and max attributes of the hand guided tearing iteration
   variables. They are only used by the non-linear solver (not as attributes of
   the variables, which would add range checks). Bounds that depend on
   variables (adaptive bounds) are not supported yet and are ignored."
  input BackendDAE.Shared shared;
  output list<tuple<DAE.ComponentRef, Option<DAE.Exp>, Option<DAE.Exp>>> bounds = {};
protected
  BackendDAE.HGTSpec spec;
algorithm
  if isNone(shared.handGuidedTearing) then
    return;
  end if;

  SOME(spec) := shared.handGuidedTearing;

  for v in allIterationVariables(spec) loop
    if hasMinMax(v) then
      bounds := (v.name, checkBound(v.min, "min", v, shared), checkBound(v.max, "max", v, shared)) :: bounds;
    end if;
  end for;
end iterationVariableBounds;

function isActive
  "Returns true if the DAE has a hand guided tearing specification."
  input BackendDAE.Shared shared;
  output Boolean active = isSome(shared.handGuidedTearing);
end isActive;

// ============================================================================
// Equation tags
// ============================================================================

function equationName
  "Returns the hand guided tearing name of an equation, if it has one."
  input BackendDAE.Equation eq;
  output Option<String> name = NONE();
protected
  SCode.Annotation ann;
  SCode.Mod mod;
  String str;
algorithm
  for cmt in ElementSource.getComments(BackendEquation.equationSource(eq)) loop
    if isSome(cmt.annotation_) then
      SOME(ann) := cmt.annotation_;
      mod := SCodeUtil.lookupAnnotation(ann, EQUATION_TAG);

      name := match mod
        case SCode.MOD(binding = SOME(Absyn.STRING(value = str))) then SOME(str);
        else NONE();
      end match;

      if isSome(name) then
        return;
      end if;
    end if;
  end for;
end equationName;

function isTaggedEquation
  "Returns true for equations that hand guided tearing refers to. Optimization
   modules that would remove or rewrite such an equation skip it."
  input BackendDAE.Equation eq;
  output Boolean tagged = isSome(equationName(eq));
end isTaggedEquation;

function anyTaggedEquation
  "Returns true if any of the given equations is tagged."
  input list<Integer> eqnIndices;
  input BackendDAE.EquationArray eqns;
  output Boolean tagged = false;
algorithm
  for i in eqnIndices loop
    if isTaggedEquation(BackendEquation.get(eqns, i)) then
      tagged := true;
      return;
    end if;
  end for;
end anyTaggedEquation;

// ============================================================================
// Post-optimization module hgtMatching
// ============================================================================

function hgtMatching
  "Forces the hand guided tearing pairs into the matching and recomputes the
   strong components, see doc/HGT_design.md section 8.5. Must run right before
   tearingSystem."
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE = inDAE;
protected
  BackendDAE.HGTSpec spec;
algorithm
  if not isActive(inDAE.shared) then
    return;
  end if;

  SOME(spec) := inDAE.shared.handGuidedTearing;

  if BackendDAEUtil.isSimulationDAE(inDAE.shared) then
    spec := simulationSpec(spec);
    outDAE.shared := BackendDAEUtil.setSharedHandGuidedTearing(outDAE.shared, SOME(spec));
    checkPresence(outDAE, spec);
  end if;

  outDAE := BackendDAEUtil.mapEqSystem(outDAE, function matchSystem(spec = spec));
end hgtMatching;

function simulationSpec
  "Removes the pairs that only apply to the initialization system from the
   specification, i.e. those whose residual equation is an initial equation."
  input output BackendDAE.HGTSpec spec;
algorithm
  if listEmpty(spec.initialResiduals) then
    return;
  end if;

  spec.residuals := list(r for r guard not listMember(r.name, spec.initialResiduals) in spec.residuals);
  spec.initialResiduals := {};
end simulationSpec;

// ============================================================================
// Tearing support
// ============================================================================

function componentItems
  "Returns the hand guided tearing iteration variables and residual equations of
   a strong component, as indices local to the component (positions in its
   variable and equation lists)."
  input BackendDAE.StrongComponent comp;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  output Boolean isHGT = false;
  output list<Integer> localVars = {};
  output list<Integer> localEqns = {};
protected
  BackendDAE.HGTSpec spec;
  list<Integer> eqns, vars;
  Integer i;
  Option<String> name;
  UnorderedSet<String> res_names, var_names;
algorithm
  if not isActive(shared) then
    return;
  end if;

  (eqns, vars) := match comp
    case BackendDAE.EQUATIONSYSTEM() then (comp.eqns, comp.vars);
    case BackendDAE.SINGLEEQUATION() then ({comp.eqn}, {comp.var});
    else ({}, {});
  end match;

  if listEmpty(eqns) then
    return;
  end if;

  SOME(spec) := shared.handGuidedTearing;
  res_names := UnorderedSet.fromList(list(r.name for r in spec.residuals), stringHashDjb2, stringEq);
  var_names := UnorderedSet.fromList(list(crefString(v.name) for v in allIterationVariables(spec)), stringHashDjb2, stringEq);

  i := 1;
  for e in eqns loop
    name := equationName(BackendEquation.get(syst.orderedEqs, e));

    if isSome(name) and UnorderedSet.contains(Util.getOption(name), res_names) then
      localEqns := i :: localEqns;
    end if;

    i := i + 1;
  end for;

  i := 1;
  for v in vars loop
    if UnorderedSet.contains(crefString(BackendVariable.varCref(BackendVariable.getVarAt(syst.orderedVars, v))), var_names) then
      localVars := i :: localVars;
    end if;

    i := i + 1;
  end for;

  localEqns := listReverse(localEqns);
  localVars := listReverse(localVars);
  isHGT := not (listEmpty(localEqns) and listEmpty(localVars));
end componentItems;

protected

// ============================================================================
// Specification helpers
// ============================================================================

function findSpec
  input list<DAE.Element> elements;
  output Option<BackendDAE.HGTSpec> spec = NONE();
algorithm
  for e in elements loop
    spec := match e
      case DAE.HAND_GUIDED_TEARING() then SOME(BackendDAE.HGT_SPEC(e.residuals, {}));
      case DAE.COMP() then findSpec(e.dAElist);
      else NONE();
    end match;

    if isSome(spec) then
      return;
    end if;
  end for;
end findSpec;

function allIterationVariables
  "Returns the iteration variables of the pairs."
  input BackendDAE.HGTSpec spec;
  output list<DAE.HGTIterationVariable> vars = list(r.iterationVariable for r in spec.residuals);
end allIterationVariables;

function crefString
  "With subscripts: the items of the elements of a component array differ only
   in them."
  input DAE.ComponentRef cref;
  output String str = ComponentReferenceBasics.printComponentRefStr(cref);
end crefString;

function hasMinMax
  input DAE.HGTIterationVariable var;
  output Boolean res = isSome(var.min) or isSome(var.max);
end hasMinMax;

function checkBound
  "Returns a min or max attribute if it only depends on parameters and constants."
  input Option<DAE.Exp> bound;
  input String attr;
  input DAE.HGTIterationVariable var;
  input BackendDAE.Shared shared;
  output Option<DAE.Exp> outBound = bound;
protected
  DAE.Exp e;
algorithm
  if isSome(bound) then
    SOME(e) := bound;

    if not List.all(Expression.extractCrefsFromExp(e), function BackendVariable.containsCref(inVariables = shared.globalKnownVars)) then
      Error.addSourceMessage(Error.HGT_MIN_MAX_NOT_SUPPORTED, {attr, crefString(var.name), ExpressionBasics.printExpStr(e)}, var.info);
      outBound := NONE();
    end if;
  end if;
end checkBound;

function lowerVariable
  "Marks an iteration variable as unreplaceable and applies its start and
   nominal attributes."
  input output BackendDAE.Var var;
  input UnorderedMap<String, DAE.HGTIterationVariable> iterationVariables;
protected
  Option<DAE.HGTIterationVariable> opt_hgt_var;
  DAE.HGTIterationVariable hgt_var;
algorithm
  opt_hgt_var := UnorderedMap.get(crefString(BackendVariable.varCref(var)), iterationVariables);

  if isSome(opt_hgt_var) then
    SOME(hgt_var) := opt_hgt_var;
    var := BackendVariable.setVarUnreplaceable(var, true);

    if isSome(hgt_var.start) then
      var := BackendVariable.setVarStartValue(var, Util.getOption(hgt_var.start));
    end if;

    if isSome(hgt_var.nominal) then
      var := BackendVariable.setVarNominalValue(var, Util.getOption(hgt_var.nominal));
    end if;
  end if;
end lowerVariable;

function pairHold
  "The hold attribute of a pair: the one of the residual equation, else the one
   of its iteration variable (the frontend checks that they are the same if
   both are given). NONE() if the pair is never held."
  input DAE.HGTResidual residual;
  output Option<DAE.Exp> hold;
algorithm
  hold := match (residual.hold, residual.iterationVariable.hold)
    case (SOME(DAE.BCONST(false)), _) then NONE();
    case (SOME(_), _) then residual.hold;
    case (_, SOME(DAE.BCONST(false))) then NONE();
    else residual.iterationVariable.hold;
  end match;
end pairHold;

function rewriteResidual
  "Rewrites a residual equation lhs = rhs with a nominal as 0 = (lhs - rhs) / nominal.
   A held pair keeps its iteration variable x at its start value instead, which
   keeps the structure of the system, so that hold can be changed at runtime:
     0 = if hold then x - $START.x else (lhs - rhs) / nominal"
  input output BackendDAE.Equation eq;
  input UnorderedMap<String, DAE.HGTResidual> residuals;
protected
  Option<String> name;
  Option<DAE.HGTResidual> opt_residual;
  DAE.HGTResidual residual;
  DAE.ComponentRef var;
  DAE.Exp res, held;
algorithm
  name := equationName(eq);

  if isNone(name) then
    return;
  end if;

  opt_residual := UnorderedMap.get(Util.getOption(name), residuals);

  if isNone(opt_residual) then
    return;
  end if;

  SOME(residual) := opt_residual;

  eq := match eq
    case BackendDAE.EQUATION()
      algorithm
        res := Expression.expSub(eq.exp, eq.scalar);

        if isSome(residual.nominal) then
          res := Expression.makeDiv(res, Util.getOption(residual.nominal));
        end if;

        res := match pairHold(residual)
          case NONE() then res;
          case SOME(DAE.BCONST(true))
            then holdResidual(residual.iterationVariable.name);
          case SOME(held)
            then DAE.IFEXP(held, holdResidual(residual.iterationVariable.name), res);
        end match;

        eq.scalar := res;
        eq.exp := DAE.RCONST(0.0);
      then
        eq;

    else
      algorithm
        if isSome(pairHold(residual)) then
          Error.addSourceMessage(Error.HGT_NOT_SUPPORTED,
            {"hold of the residual equation " + residual.name + ", which is not a scalar equation"}, residual.info);
        end if;
      then
        eq;
  end match;
end rewriteResidual;

function holdResidual
  "x - $START.x, the residual that keeps x at its start value."
  input DAE.ComponentRef var;
  output DAE.Exp res;
algorithm
  res := Expression.expSub(Expression.crefExp(var),
    Expression.crefExp(ComponentReference.crefPrefixStart(var)));
end holdResidual;

// ============================================================================
// hgtMatching implementation
// ============================================================================

function checkPresence
  "Checks that the optimization modules didn't remove any residual equation or
   iteration variable, and warns if the model is not a steady-state model."
  input BackendDAE.BackendDAE dae;
  input BackendDAE.HGTSpec spec;
protected
  UnorderedMap<String, Integer> counts;
  Integer count;
  Boolean found, has_states = false;
algorithm
  counts := UnorderedMap.new<Integer>(stringHashDjb2, stringEq);

  for syst in dae.eqs loop
    countTags(syst.orderedEqs, counts);
    has_states := has_states or List.any(BackendVariable.varList(syst.orderedVars), BackendVariable.isStateVar);
  end for;

  for r in spec.residuals loop
    count := UnorderedMap.getOrDefault(r.name, counts, 0);

    if count <> 1 then
      Error.addSourceMessage(Error.HGT_EQUATION_REMOVED_BACKEND,
        {r.name, if count == 0 then "removed" else "duplicated"}, r.info);
      fail();
    end if;
  end for;

  for v in allIterationVariables(spec) loop
    found := false;

    for syst in dae.eqs loop
      if isSome(varIndex(v.name, syst.orderedVars)) then
        found := true;
        break;
      end if;
    end for;

    if not found then
      Error.addSourceMessage(Error.HGT_VARIABLE_REMOVED_BACKEND, {crefString(v.name)}, v.info);
      fail();
    end if;
  end for;

  if has_states then
    Error.addMessage(Error.HGT_ONLY_STEADY_STATE, {});
  end if;
end checkPresence;

function countTags
  input BackendDAE.EquationArray eqns;
  input UnorderedMap<String, Integer> counts;
protected
  Option<String> name;
algorithm
  for i in 1:BackendEquation.getNumberOfEquations(eqns) loop
    name := equationName(BackendEquation.get(eqns, i));

    if isSome(name) then
      UnorderedMap.addUpdate(Util.getOption(name), incrementCount, counts);
    end if;
  end for;
end countTags;

function incrementCount
  input Option<Integer> count;
  output Integer outCount = Util.getOptionOrDefault(count, 0) + 1;
end incrementCount;

function matchSystem
  "Forces the hand guided tearing pairs of one equation system into its
   matching and recomputes the strong components."
  input BackendDAE.EqSystem inSyst;
  input BackendDAE.Shared shared;
  input BackendDAE.HGTSpec spec;
  output BackendDAE.EqSystem syst = inSyst;
  output BackendDAE.Shared outShared = shared;
protected
  UnorderedMap<String, Integer> eqn_index;
  list<tuple<Integer, Integer>> pairs = {} "(variable, equation)";
  Option<Integer> oe, ov;
  Integer e, v, n_rows, n_vars, r;
  AvlTreePathFunction.Tree funcs;
  Boolean is_init;
  BackendDAE.AdjacencyMatrix m_s, mt_s, m_n, mt_n, m_ring, mt_ring;
  array<list<Integer>> map_eqn_row;
  array<Integer> map_row_eqn, ass1, ass2, old_ass2;
  array<Boolean> hgt_rows, hgt_vars;
  list<Integer> free_rows, free_vars, auto_rows = {}, merge_rows = {};
  BackendDAE.StrongComponents comps;
  DAE.HGTIterationVariable hgt_var;
algorithm
  // Locate the residual equations and iteration variables in this system.
  eqn_index := UnorderedMap.new<Integer>(stringHashDjb2, stringEq);
  indexTags(syst.orderedEqs, eqn_index);

  for res in spec.residuals loop
    oe := UnorderedMap.get(res.name, eqn_index);
    hgt_var := res.iterationVariable;
    ov := varIndex(hgt_var.name, syst.orderedVars);

    if isSome(oe) and isSome(ov) then
      pairs := (Util.getOption(ov), Util.getOption(oe)) :: pairs;
    elseif isSome(oe) or isSome(ov) then
      Error.addSourceMessage(Error.HGT_NOT_SAME_SYSTEM, {res.name, crefString(hgt_var.name)}, res.info);
      fail();
    end if;
  end for;

  if listEmpty(pairs) then
    return;
  end if;

  // Scalar adjacency matrices: solvable for the matching, normal for sorting.
  funcs := BackendDAEUtil.getFunctions(shared);
  is_init := BackendDAEUtil.isInitializationDAE(shared);
  (syst, m_s, mt_s, map_eqn_row, map_row_eqn) := BackendDAEUtil.getAdjacencyMatrixScalar(syst, BackendDAE.SOLVABLE(), SOME(funcs), is_init);
  (syst, m_n, mt_n, _, _) := BackendDAEUtil.getAdjacencyMatrixScalar(syst, BackendDAE.NORMAL(), SOME(funcs), is_init);
  n_rows := arrayLength(m_n);
  n_vars := arrayLength(mt_n);

  // Start from the current matching (ass2 is row -> variable).
  ass1 := arrayCreate(n_vars, -1);
  ass2 := arrayCreate(n_rows, -1);

  () := match syst.matching
    case BackendDAE.MATCHING(ass2 = old_ass2) guard arrayLength(old_ass2) == n_rows
      algorithm
        for row in 1:n_rows loop
          v := old_ass2[row];
          if v > 0 and v <= n_vars then
            arrayUpdate(ass2, row, v);
            arrayUpdate(ass1, v, row);
          end if;
        end for;
      then
        ();

    else ();
  end match;

  // Unassign all hand guided tearing variables and residual equations.
  hgt_rows := arrayCreate(n_rows, false);
  hgt_vars := arrayCreate(n_vars, false);

  for p in pairs loop
    (v, e) := p;
    markVar(v, hgt_vars, ass1, ass2);
    markRow(eqnRow(e, map_eqn_row), hgt_rows, ass1, ass2);
  end for;

  // Force the user pairs, i.e. let each residual equation "solve" its variable.
  for p in pairs loop
    (v, e) := p;
    assign(v, eqnRow(e, map_eqn_row), ass1, ass2);
  end for;

  // Repair the matching of the other equations with augmenting paths.
  for row in 1:n_rows loop
    if ass2[row] < 0 and not hgt_rows[row] then
      augment(row, m_s, ass1, ass2, hgt_vars, hgt_rows, arrayCreate(n_vars, false));
    end if;
  end for;

  // What is still unmatched couldn't be repaired: let those equations solve the
  // remaining variables for now, the tearing makes them residual equations and
  // iteration variables (OCT: "the automatic algorithm will kick in").
  free_rows := list(row for row guard ass2[row] < 0 in 1:n_rows);
  free_vars := list(var for var guard ass1[var] < 0 in 1:n_vars);

  if listLength(free_rows) <> listLength(free_vars) then
    Error.addInternalError(getInstanceName() + ": the system is not square", sourceInfo());
    fail();
  end if;

  if not listEmpty(free_rows) and Flags.getConfigBool(Flags.HGT_ONLY) then
    Error.addMessage(Error.HGT_NOT_SOLVABLE, {
      stringDelimitList(list(Util.getOptionOrDefault(equationName(BackendEquation.get(syst.orderedEqs, Util.tuple22(p))), "")
        for p in pairs), ", "),
      "no matching exists for the equations {" + stringDelimitList(list(BackendDump.equationString(
        BackendEquation.get(syst.orderedEqs, map_row_eqn[row])) for row in free_rows), "; ") +
      "} and the variables {" + stringDelimitList(list(crefString(BackendVariable.varCref(
        BackendVariable.getVarAt(syst.orderedVars, var))) for var in free_vars), ", ") + "}"});
    fail();
  end if;

  for p in List.zip(free_vars, free_rows) loop
    (v, r) := p;
    assign(v, r, ass1, ass2);
  end for;

  auto_rows := free_rows;

  // Rows that have to end up in one strong component are connected by a ring
  // of artificial dependencies, Tarjan then also merges all blocks in between.
  if not listEmpty(auto_rows) or Flags.getConfigBool(Flags.HGT_MERGE_BLT_BLOCKS) then
    merge_rows := List.unique(listAppend(auto_rows, list(row for row guard hgt_rows[row] in 1:n_rows)));
  end if;

  (m_ring, mt_ring) := addRing(merge_rows, m_n, mt_n, ass2);

  syst := setAdjacencyAndMatching(syst, m_ring, mt_ring, BackendDAE.MATCHING(ass1, ass2, {}));
  (syst, comps) := BackendDAETransform.strongComponentsScalar(syst, shared, map_eqn_row, map_row_eqn);

  // Each residual equation must depend on its iteration variable.
  checkDependence(list((Util.tuple21(p), eqnRow(Util.tuple22(p), map_eqn_row)) for p in pairs),
    comps, m_n, map_eqn_row, map_row_eqn, syst);
  checkResidualCounts(comps, syst, spec);

  if Flags.isSet(Flags.HGT_DUMP) then
    dumpComponents(comps, syst, shared, hgt_vars, hgt_rows, auto_rows, map_eqn_row);
  end if;
end matchSystem;

function checkResidualCounts
  "R9, OCT option allow_multiple_residuals_in_hgt_blocks: with
   --hgtAllowMultipleResiduals=false a hand guided tearing block may only have
   one residual equation of the user."
  input BackendDAE.StrongComponents comps;
  input BackendDAE.EqSystem syst;
  input BackendDAE.HGTSpec spec;
protected
  UnorderedSet<String> res_names;
  list<String> names;
  list<Integer> eqns;
  Option<String> name;
algorithm
  if Flags.getConfigBool(Flags.HGT_ALLOW_MULTIPLE_RESIDUALS) then
    return;
  end if;

  res_names := UnorderedSet.fromList(list(r.name for r in spec.residuals), stringHashDjb2, stringEq);

  for comp in comps loop
    eqns := match comp
      case BackendDAE.EQUATIONSYSTEM() then comp.eqns;
      else {};
    end match;

    names := {};
    for e in eqns loop
      name := equationName(BackendEquation.get(syst.orderedEqs, e));

      if isSome(name) and UnorderedSet.contains(Util.getOption(name), res_names) then
        names := Util.getOption(name) :: names;
      end if;
    end for;

    if listLength(names) > 1 then
      Error.addMessage(Error.HGT_MULTIPLE_RESIDUALS, {intString(listLength(names)),
        stringDelimitList(listReverse(names), ", ")});
      fail();
    end if;
  end for;
end checkResidualCounts;

function indexTags
  "Adds the names of all tagged equations to the map, name -> equation index."
  input BackendDAE.EquationArray eqns;
  input UnorderedMap<String, Integer> index;
protected
  Option<String> name;
algorithm
  for i in 1:BackendEquation.getNumberOfEquations(eqns) loop
    name := equationName(BackendEquation.get(eqns, i));

    if isSome(name) then
      UnorderedMap.add(Util.getOption(name), i, index);
    end if;
  end for;
end indexTags;

function varIndex
  input DAE.ComponentRef cref;
  input BackendDAE.Variables vars;
  output Option<Integer> index;
protected
  list<Integer> indices;
algorithm
  try
    (_, indices) := BackendVariable.getVar(cref, vars);
    index := SOME(listHead(indices));
  else
    index := NONE();
  end try;
end varIndex;

function eqnRow
  "Returns the scalar row of a (scalar) equation."
  input Integer eqn;
  input array<list<Integer>> mapEqnIncRow;
  output Integer row = listHead(mapEqnIncRow[eqn]);
end eqnRow;

function markVar
  input Integer var;
  input array<Boolean> marked;
  input array<Integer> ass1, ass2;
algorithm
  arrayUpdate(marked, var, true);

  if ass1[var] > 0 then
    arrayUpdate(ass2, ass1[var], -1);
    arrayUpdate(ass1, var, -1);
  end if;
end markVar;

function markRow
  input Integer row;
  input array<Boolean> marked;
  input array<Integer> ass1, ass2;
algorithm
  arrayUpdate(marked, row, true);

  if ass2[row] > 0 then
    arrayUpdate(ass1, ass2[row], -1);
    arrayUpdate(ass2, row, -1);
  end if;
end markRow;

function assign
  input Integer var;
  input Integer row;
  input array<Integer> ass1, ass2;
algorithm
  arrayUpdate(ass1, var, row);
  arrayUpdate(ass2, row, var);
end assign;

function augment
  "Tries to find an augmenting path from an unmatched row, without using the
   blocked (hand guided tearing) rows and variables."
  input Integer row;
  input BackendDAE.AdjacencyMatrix m;
  input array<Integer> ass1, ass2;
  input array<Boolean> blockedVars, blockedRows;
  input array<Boolean> visited;
  output Boolean found = false;
algorithm
  for v in m[row] loop
    if v > 0 then
      if not blockedVars[v] and not visited[v] then
        arrayUpdate(visited, v, true);

        if ass1[v] < 0 then
          found := true;
        elseif not blockedRows[ass1[v]] then
          found := augment(ass1[v], m, ass1, ass2, blockedVars, blockedRows, visited);
        end if;

        if found then
          assign(v, row, ass1, ass2);
          return;
        end if;
      end if;
    end if;
  end for;
end augment;

function addRing
  "Returns copies of the adjacency matrices where the given rows depend on each
   other in a ring, so that Tarjan puts them, and every block on a path between
   them, into one strong component."
  input list<Integer> rows;
  input BackendDAE.AdjacencyMatrix m;
  input BackendDAE.AdjacencyMatrixT mt;
  input array<Integer> ass2;
  output BackendDAE.AdjacencyMatrix outM;
  output BackendDAE.AdjacencyMatrixT outMT;
protected
  array<Integer> ring;
  Integer n, r, x;
algorithm
  if listLength(rows) < 2 then
    outM := m;
    outMT := mt;
    return;
  end if;

  outM := arrayCopy(m);
  outMT := arrayCopy(mt);
  ring := listArray(rows);
  n := arrayLength(ring);

  for i in 1:n loop
    r := ring[i];
    x := ass2[ring[if i == n then 1 else i + 1]];
    arrayUpdate(outM, r, x :: outM[r]);
    arrayUpdate(outMT, x, r :: outMT[x]);
  end for;
end addRing;

function setAdjacencyAndMatching
  input output BackendDAE.EqSystem syst;
  input BackendDAE.AdjacencyMatrix m;
  input BackendDAE.AdjacencyMatrixT mt;
  input BackendDAE.Matching matching;
algorithm
  syst := match syst
    case BackendDAE.EQSYSTEM()
      algorithm
        syst.m := SOME(m);
        syst.mT := SOME(mt);
        syst.matching := matching;
      then
        syst;
  end match;
end setAdjacencyAndMatching;

function checkDependence
  "Checks that the strong component of each residual equation contains an
   equation that uses its iteration variable, otherwise the residual doesn't
   depend on the variable and the torn system would be singular."
  input list<tuple<Integer, Integer>> pairs "(variable, row)";
  input BackendDAE.StrongComponents comps;
  input BackendDAE.AdjacencyMatrix m;
  input array<list<Integer>> mapEqnIncRow;
  input array<Integer> mapIncRowEqn;
  input BackendDAE.EqSystem syst;
protected
  Integer v, r, e;
  list<Integer> eqns;
  Boolean uses;
algorithm
  for p in pairs loop
    (v, r) := p;
    e := mapIncRowEqn[r];
    eqns := {};

    for comp in comps loop
      (eqns, _) := BackendDAETransform.getEquationAndSolvedVarIndxes(comp);

      if listMember(e, eqns) then
        break;
      end if;

      eqns := {};
    end for;

    uses := false;
    for ce in eqns loop
      for row in mapEqnIncRow[ce] loop
        if listMember(v, list(intAbs(x) for x in m[row])) then
          uses := true;
        end if;
      end for;
    end for;

    if not uses then
      Error.addMessage(Error.HGT_RESIDUAL_INDEPENDENT, {
        Util.getOptionOrDefault(equationName(BackendEquation.get(syst.orderedEqs, e)), intString(e)),
        crefString(BackendVariable.varCref(BackendVariable.getVarAt(syst.orderedVars, v)))});
      fail();
    end if;
  end for;
end checkDependence;

function dumpComponents
  input BackendDAE.StrongComponents comps;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input array<Boolean> hgtVars, hgtRows;
  input list<Integer> autoRows;
  input array<list<Integer>> mapEqnIncRow;
protected
  list<Integer> eqns, vars;
  list<String> res_strs, var_strs;
algorithm
  print("Hand guided tearing matching (" + (if BackendDAEUtil.isInitializationDAE(shared) then "initialization" else "simulation") + " system):\n");

  for comp in comps loop
    (eqns, vars) := BackendDAETransform.getEquationAndSolvedVarIndxes(comp);
    res_strs := list(Util.getOptionOrDefault(equationName(BackendEquation.get(syst.orderedEqs, e)), intString(e))
      for e guard hgtRows[eqnRow(e, mapEqnIncRow)] in eqns);
    var_strs := list(crefString(BackendVariable.varCref(BackendVariable.getVarAt(syst.orderedVars, v)))
      for v guard hgtVars[v] in vars);

    if not (listEmpty(res_strs) and listEmpty(var_strs)) then
      print("  block of " + intString(listLength(eqns)) + " equations: residual equations {" +
        stringDelimitList(res_strs, ", ") + "}, iteration variables {" + stringDelimitList(var_strs, ", ") + "}\n");
    end if;
  end for;

  if not listEmpty(autoRows) then
    print("  " + intString(listLength(autoRows)) + " equations could not be matched and are torn automatically\n");
  end if;
end dumpComponents;

annotation(__OpenModelica_Interface="backend");
end HandGuidedTearing;
