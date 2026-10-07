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

encapsulated package NFHandGuidedTearing
  "Collects the hand guided tearing (HGT) specification of a model while it is
   flattened. The __OpenModelica_HGT annotations correspond one to one to the
   hand guided tearing annotations of OCT (__Modelon), which are also read with
   --acceptModelonHGT:

     x = y + 1 annotation(__OpenModelica_HGT(name = res));
     x = y + 1 annotation(__OpenModelica_HGT(ResidualEquation(
       iterationVariable(start = 1) = z, level = 1, nominal = 1)));
     Real z annotation(__OpenModelica_HGT(IterationVariable(level = 1)));
     annotation(__OpenModelica_HGT(tearingPairs(
       Pair(residualEquation = b.res, iterationVariable = c.z))));

   All names are resolved in the scope of the annotation and prefixed with the
   name of the enclosing component, so the resulting specification only
   contains fully qualified names. The residual equations are identified by a
   name that is added to their source as an __OpenModelica_HGTEquation
   annotation. See doc/HGT_design.md."

  import Absyn;
  import DAE;
  import SCode;
  import ComponentRef = NFComponentRef;
  import Expression = NFExpression;
  import NFInstNode.InstNode;
  import NFPrefixes.Variability;
  import Type = NFType;

protected
  import AbsynUtil;
  import Ceval = NFCeval;
  import Dump;
  import ElementSource;
  import Equation = NFEquation;
  import Error;
  import Flags;
  import Inst = NFInst;
  import InstContext = NFInstContext;
  import List;
  import NFInstContext;
  import Pointer;
  import SCodeUtil;
  import Structural = NFStructural;
  import Typing = NFTyping;
  import UnorderedMap;
  import Util;

public
  constant String ANNOTATION_NAME = "__OpenModelica_HGT";
  constant String MODELON_ANNOTATION_NAME = "__Modelon";
  constant String EQUATION_TAG = "__OpenModelica_HGTEquation";

  partial function FlattenExpFn
    "Flattens an expression found in an annotation, i.e. adds the prefix of the
     component the annotation belongs to."
    input output Expression exp;
  end FlattenExpFn;

  uniontype IterationVariable
    record ITERATION_VARIABLE
      ComponentRef name;
      Integer level;
      Option<Expression> start "NONE() means the start attribute of the variable.";
      Option<Expression> min "NONE() means the min attribute of the variable.";
      Option<Expression> max "NONE() means the max attribute of the variable.";
      Option<Expression> nominal "NONE() means the nominal attribute of the variable.";
      Option<Expression> hold;
      SourceInfo info;
    end ITERATION_VARIABLE;

    function toString
      input IterationVariable var;
      output String str;
    algorithm
      str := ComponentRef.toString(var.name) + " (level " + intString(var.level) +
        optAttrString("start", var.start) + optAttrString("min", var.min) +
        optAttrString("max", var.max) + optAttrString("nominal", var.nominal) +
        optAttrString("hold", var.hold) + ")";
    end toString;

    function toDAE
      input IterationVariable var;
      output DAE.HGTIterationVariable daeVar;
    algorithm
      daeVar := DAE.HGT_ITERATION_VARIABLE(ComponentRef.toDAE(var.name), var.level,
        Util.applyOption(var.start, function Expression.toDAE(allowEmpty = false)),
        Util.applyOption(var.min, function Expression.toDAE(allowEmpty = false)),
        Util.applyOption(var.max, function Expression.toDAE(allowEmpty = false)),
        Util.applyOption(var.nominal, function Expression.toDAE(allowEmpty = false)),
        Util.applyOption(var.hold, function Expression.toDAE(allowEmpty = false)),
        var.info);
    end toDAE;
  end IterationVariable;

  uniontype ResidualEquation
    record RESIDUAL_EQUATION
      String name "The name in the __OpenModelica_HGTEquation tag of the equation.";
      Integer level;
      Option<Expression> nominal "NONE() means 1.";
      Option<Expression> hold;
      Option<IterationVariable> iterationVariable "SOME() for a tearing pair.";
      SourceInfo info;
    end RESIDUAL_EQUATION;

    function toString
      input ResidualEquation residual;
      output String str;
    protected
      IterationVariable var;
    algorithm
      str := residual.name + " (level " + intString(residual.level) +
        optAttrString("nominal", residual.nominal) +
        optAttrString("hold", residual.hold) + ")";

      if isSome(residual.iterationVariable) then
        SOME(var) := residual.iterationVariable;
        str := "pair: residual equation " + str + ", iteration variable " +
          IterationVariable.toString(var);
      else
        str := "unpaired residual equation " + str;
      end if;
    end toString;

    function toDAE
      input ResidualEquation residual;
      output DAE.HGTResidual daeResidual;
    algorithm
      daeResidual := DAE.HGT_RESIDUAL(residual.name, residual.level,
        Util.applyOption(residual.nominal, function Expression.toDAE(allowEmpty = false)),
        Util.applyOption(residual.hold, function Expression.toDAE(allowEmpty = false)),
        Util.applyOption(residual.iterationVariable, IterationVariable.toDAE),
        residual.info);
    end toDAE;

    function isNameGreater
      input ResidualEquation residual1;
      input ResidualEquation residual2;
      output Boolean greater = stringCompare(residual1.name, residual2.name) > 0;
    end isNameGreater;
  end ResidualEquation;

  uniontype Spec
    "The hand guided tearing specification of a model."
    record SPEC
      list<ResidualEquation> residuals "Paired and unpaired residual equations.";
      list<IterationVariable> iterationVariables "Unpaired iteration variables.";
    end SPEC;

    function toString
      input Spec spec;
      output String str;
    protected
      list<String> strl = {};
    algorithm
      for r in spec.residuals loop
        strl := ("  " + ResidualEquation.toString(r)) :: strl;
      end for;

      for v in spec.iterationVariables loop
        strl := ("  unpaired iteration variable " + IterationVariable.toString(v)) :: strl;
      end for;

      str := "Hand guided tearing:\n" + stringDelimitList(listReverse(strl), "\n") + "\n";
    end toString;

    function toDAE
      input Spec spec;
      output DAE.Element element;
    algorithm
      element := DAE.HAND_GUIDED_TEARING(
        list(ResidualEquation.toDAE(r) for r in spec.residuals),
        list(IterationVariable.toDAE(v) for v in spec.iterationVariables));
    end toDAE;
  end Spec;

  uniontype Collector
    "Collects the specification while a model is flattened."
    record COLLECTOR
      Boolean enabled "--handGuidedTearing";
      Boolean acceptModelon "--acceptModelonHGT";
      Pointer<Boolean> found "Whether any hand guided tearing annotation was found.";
      Pointer<Integer> nested "> 0 while flattening the body of for-, if- and when-equations.";
      UnorderedMap<String, SourceInfo> equationNames "All named equations.";
      UnorderedMap<String, ResidualEquation> residuals "Residual equations, by equation name.";
      Pointer<list<ResidualEquation>> pairs "Pairs from tearingPairs, the equations are checked by finish.";
      Pointer<list<IterationVariable>> iterationVariables "Unpaired iteration variables.";
      Pointer<Integer> nameIndex "Used to name residual equations that have no name.";
    end COLLECTOR;

    function new
      output Collector collector;
    algorithm
      collector := COLLECTOR(
        Flags.getConfigBool(Flags.HAND_GUIDED_TEARING),
        Flags.getConfigBool(Flags.ACCEPT_MODELON_HGT),
        Pointer.create(false),
        Pointer.create(0),
        UnorderedMap.new<SourceInfo>(stringHashDjb2, stringEq),
        UnorderedMap.new<ResidualEquation>(stringHashDjb2, stringEq),
        Pointer.create({}),
        Pointer.create({}),
        Pointer.create(0));
    end new;
  end Collector;

  function hasAnnotation
    "Returns true if the source has a comment with an annotation, a quick check
     done before collectEquation."
    input DAE.ElementSource source;
    output Boolean res = false;
  algorithm
    for cmt in ElementSource.getComments(source) loop
      if isSome(cmt.annotation_) then
        res := true;
        return;
      end if;
    end for;
  end hasAnnotation;

  function collectEquation
    "Collects the hand guided tearing annotations of an equality equation, and
     returns the source of the equation with a name tag added if the equation
     is a residual equation or has a name."
    input output DAE.ElementSource source;
    input Boolean isScalarReal "Whether the equation is a scalar Real equation.";
    input InstNode scope;
    input String prefix "The name of the enclosing component, or the empty string.";
    input FlattenExpFn flattenFn;
    input Collector collector;
  protected
    list<tuple<SCode.Mod, Boolean>> mods;
    SCode.Mod mod;
    Boolean is_omc;
    Option<String> opt_name = NONE();
    Option<SCode.Mod> res_mod = NONE();
    Option<ResidualEquation> residual;
    String name;
    SourceInfo info = ElementSource.getInfo(source);
  algorithm
    mods := getHGTMods(ElementSource.getComments(source), collector);

    if listEmpty(mods) then
      return;
    end if;

    Pointer.update(collector.found, true);

    // Annotations in for-, if- and when-equations are reported by enterNested.
    if not collector.enabled or Pointer.access(collector.nested) > 0 then
      return;
    end if;

    for m in mods loop
      (mod, is_omc) := m;
      checkFields(mod, {"name", "ResidualEquation"}, "of an equation", is_omc);

      if isSome(SCodeUtil.getModifierBinding(lookupField(mod, "name"))) then
        opt_name := SOME(getEquationName(lookupField(mod, "name")));
      end if;

      if hasField(mod, "ResidualEquation") then
        res_mod := SOME(lookupField(mod, "ResidualEquation"));
      end if;
    end for;

    if isSome(res_mod) and not isScalarReal then
      Error.addSourceMessage(Error.HGT_NOT_SUPPORTED,
        {"only scalar Real equations are supported as residual equations"}, info);
      res_mod := NONE();
    end if;

    if isNone(opt_name) and isNone(res_mod) then
      return;
    end if;

    if isSome(opt_name) then
      name := prefixName(prefix, Util.getOption(opt_name));
    else
      Pointer.update(collector.nameIndex, Pointer.access(collector.nameIndex) + 1);
      name := prefixName(prefix, "$hgt" + intString(Pointer.access(collector.nameIndex)));
    end if;

    if UnorderedMap.contains(name, collector.equationNames) then
      Error.addSourceMessage(Error.HGT_DUPLICATE_EQUATION_NAME, {name}, info);
      fail();
    end if;

    UnorderedMap.add(name, info, collector.equationNames);

    if isSome(res_mod) then
      residual := parseResidualEquation(Util.getOption(res_mod), name, scope, flattenFn, info);

      if isSome(residual) then
        UnorderedMap.add(name, Util.getOption(residual), collector.residuals);
      end if;
    end if;

    source := ElementSource.addCommentToSource(source, SOME(makeEquationTag(name)));
  end collectEquation;

  function collectVariable
    "Collects an IterationVariable annotation on a variable declaration."
    input SCode.Comment comment;
    input ComponentRef name "The flattened name of the variable.";
    input Type ty;
    input Variability variability;
    input InstNode scope "The scope of the declaration.";
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    input Collector collector;
  protected
    list<tuple<SCode.Mod, Boolean>> mods;
    SCode.Mod mod;
    Boolean is_omc;
    Option<IterationVariable> var;
  algorithm
    mods := getHGTMods({comment}, collector);

    if listEmpty(mods) then
      return;
    end if;

    Pointer.update(collector.found, true);

    if not collector.enabled then
      return;
    end if;

    for m in mods loop
      (mod, is_omc) := m;
      checkFields(mod, {"IterationVariable"}, "of a variable declaration", is_omc);

      if hasField(mod, "IterationVariable") then
        if not (Type.isReal(ty) and Type.isScalar(ty)) then
          Error.addSourceMessage(Error.HGT_NOT_SUPPORTED,
            {"only scalar Real variables are supported as iteration variables"}, info);
        elseif variability <> Variability.CONTINUOUS then
          Error.addSourceMessage(Error.HGT_INVALID_ITERATION_VARIABLE,
            {ComponentRef.toString(name), "it is not a continuous variable"}, info);
          fail();
        else
          var := parseUnpairedIterationVariable(lookupField(mod, "IterationVariable"),
            name, scope, flattenFn, info);

          if isSome(var) then
            Pointer.update(collector.iterationVariables,
              Util.getOption(var) :: Pointer.access(collector.iterationVariables));
          end if;
        end if;
      end if;
    end for;
  end collectVariable;

  function collectClass
    "Collects the tearingPairs annotation of a class."
    input SCode.Element cls "The definition of the class.";
    input InstNode scope "The instance of the class.";
    input String prefix "The name of the component the class belongs to, or the empty string.";
    input FlattenExpFn flattenFn;
    input Collector collector;
  protected
    list<tuple<SCode.Mod, Boolean>> mods;
    SCode.Mod mod;
    Boolean is_omc;
    Option<ResidualEquation> pair;
  algorithm
    mods := getHGTMods({Util.getOptionOrDefault(SCodeUtil.getElementComment(cls),
      SCode.COMMENT(NONE(), NONE()))}, collector);

    if listEmpty(mods) then
      return;
    end if;

    Pointer.update(collector.found, true);

    if not collector.enabled then
      return;
    end if;

    for m in mods loop
      (mod, is_omc) := m;
      checkFields(mod, {"tearingPairs"}, "of a class", is_omc);

      for pair_mod in lookupFields(lookupField(mod, "tearingPairs"), "Pair", "tearingPairs", is_omc) loop
        pair := parsePair(pair_mod, prefix, scope, flattenFn);

        if isSome(pair) then
          Pointer.update(collector.pairs, Util.getOption(pair) :: Pointer.access(collector.pairs));
        end if;
      end for;
    end for;
  end collectClass;

  function enterNested
    "Called before the body of a for-, if- or when-equation is flattened.
     Hand guided tearing annotations are not supported in such equations yet."
    input Equation eq;
    input Collector collector;
  protected
    Pointer<Option<SourceInfo>> found_info = Pointer.create(NONE());
  algorithm
    if Pointer.access(collector.nested) == 0 then
      Equation.apply(eq, function findAnnotation(collector = collector, foundInfo = found_info));

      if isSome(Pointer.access(found_info)) then
        Pointer.update(collector.found, true);

        if collector.enabled then
          Error.addSourceMessage(Error.HGT_NOT_SUPPORTED,
            {"annotations in for-, if- and when-equations are not supported yet"},
            Util.getOption(Pointer.access(found_info)));
        end if;
      end if;
    end if;

    Pointer.update(collector.nested, Pointer.access(collector.nested) + 1);
  end enterNested;

  function leaveNested
    input Collector collector;
  algorithm
    Pointer.update(collector.nested, Pointer.access(collector.nested) - 1);
  end leaveNested;

  function finish
    "Checks the collected specification once the model has been flattened, and
     returns it if hand guided tearing is enabled and the model uses it."
    input Collector collector;
    output Option<Spec> spec;
  protected
    list<ResidualEquation> residuals;
    list<IterationVariable> vars;
    UnorderedMap<String, SourceInfo> var_names;
    Spec s;
  algorithm
    if not collector.enabled then
      if Pointer.access(collector.found) then
        Error.addMessage(Error.HGT_DISABLED, {});
      end if;

      spec := NONE();
      return;
    end if;

    // Add the pairs from tearingPairs, now that all equations have been named.
    for pair in listReverse(Pointer.access(collector.pairs)) loop
      if not UnorderedMap.contains(pair.name, collector.equationNames) then
        Error.addSourceMessage(Error.HGT_EQUATION_NAME_NOT_FOUND, {pair.name}, pair.info);
        fail();
      end if;

      checkUniqueEquation(pair, collector.residuals);
      UnorderedMap.add(pair.name, pair, collector.residuals);
    end for;

    residuals := List.sort(UnorderedMap.valueList(collector.residuals), ResidualEquation.isNameGreater);
    vars := listReverse(Pointer.access(collector.iterationVariables));

    // Each variable can only be one iteration variable.
    var_names := UnorderedMap.new<SourceInfo>(stringHashDjb2, stringEq);
    for r in residuals loop
      if isSome(r.iterationVariable) then
        checkUniqueVariable(Util.getOption(r.iterationVariable), var_names);
      end if;
    end for;

    for v in vars loop
      checkUniqueVariable(v, var_names);
    end for;

    if listEmpty(residuals) and listEmpty(vars) then
      spec := NONE();
      return;
    end if;

    s := SPEC(residuals, vars);

    if hasHold(s) then
      Error.addMessage(Error.HGT_HOLD_NOT_SUPPORTED, {});
    end if;

    if Flags.isSet(Flags.HGT_DUMP) then
      print(Spec.toString(s));
    end if;

    spec := SOME(s);
  end finish;

  function checkEquations
    "Checks that each residual equation of the specification is still present
     exactly once in the given equations, since the frontend could have removed
     or duplicated equations after they were flattened."
    input Spec spec;
    input list<Equation> equations;
    input list<Equation> initialEquations;
  protected
    UnorderedMap<String, Integer> counts;
    Integer count;
  algorithm
    counts := UnorderedMap.new<Integer>(stringHashDjb2, stringEq);
    Equation.applyList(equations, function countEquationTags(counts = counts));
    Equation.applyList(initialEquations, function countEquationTags(counts = counts));

    for r in spec.residuals loop
      count := UnorderedMap.getOrDefault(r.name, counts, 0);

      if count <> 1 then
        Error.addSourceMessage(Error.HGT_EQUATION_LOST,
          {r.name, if count == 0 then "was removed" else "was duplicated"}, r.info);
        fail();
      end if;
    end for;
  end checkEquations;

  function getEquationTag
    "Returns the hand guided tearing name of an equation, if it has one."
    input DAE.ElementSource source;
    output Option<String> name = NONE();
  protected
    SCode.Annotation ann;
    SCode.Mod mod;
    String str;
  algorithm
    for cmt in ElementSource.getComments(source) loop
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
  end getEquationTag;

protected
  constant InstContext.Type CONTEXT = NFInstContext.EQUATION;

  partial function TypeCheckFn
    input Type ty;
    output Boolean res;
  end TypeCheckFn;

  function getHGTMods
    "Returns the hand guided tearing annotation modifiers in the given comments,
     each with a flag that is true for __OpenModelica_HGT and false for __Modelon."
    input list<SCode.Comment> comments;
    input Collector collector;
    output list<tuple<SCode.Mod, Boolean>> mods = {};
  protected
    SCode.Annotation ann;
    SCode.Mod mod;
  algorithm
    for cmt in comments loop
      if isSome(cmt.annotation_) then
        SOME(ann) := cmt.annotation_;

        for m in SCodeUtil.lookupAnnotations(ann, ANNOTATION_NAME) loop
          mods := (m, true) :: mods;
        end for;

        if collector.acceptModelon then
          for m in SCodeUtil.lookupAnnotations(ann, MODELON_ANNOTATION_NAME) loop
            // __Modelon also contains other things than hand guided tearing.
            if hasField(m, "name") or hasField(m, "ResidualEquation") or
               hasField(m, "IterationVariable") or hasField(m, "tearingPairs") then
              mods := (m, false) :: mods;
            end if;
          end for;
        end if;
      end if;
    end for;

    mods := listReverse(mods);
  end getHGTMods;

  function findAnnotation
    input Equation eq;
    input Collector collector;
    input Pointer<Option<SourceInfo>> foundInfo;
  protected
    DAE.ElementSource source;
  algorithm
    if isNone(Pointer.access(foundInfo)) then
      source := Equation.source(eq);

      if not listEmpty(getHGTMods(ElementSource.getComments(source), collector)) then
        Pointer.update(foundInfo, SOME(ElementSource.getInfo(source)));
      end if;
    end if;
  end findAnnotation;

  function countEquationTags
    input Equation eq;
    input UnorderedMap<String, Integer> counts;
  protected
    Option<String> name;
  algorithm
    name := getEquationTag(Equation.source(eq));

    if isSome(name) then
      UnorderedMap.addUpdate(Util.getOption(name),
        function incrementCount(), counts);
    end if;
  end countEquationTags;

  function incrementCount
    input Option<Integer> count;
    output Integer outCount = Util.getOptionOrDefault(count, 0) + 1;
  end incrementCount;

  function makeEquationTag
    input String name;
    output SCode.Comment cmt;
  protected
    SCode.Mod mod;
  algorithm
    mod := SCode.MOD(SCode.NOT_FINAL(), SCode.NOT_EACH(),
      {SCode.NAMEMOD(EQUATION_TAG, SCode.MOD(SCode.NOT_FINAL(), SCode.NOT_EACH(), {},
        SOME(Absyn.STRING(name)), NONE(), Absyn.dummyInfo))},
      NONE(), NONE(), Absyn.dummyInfo);
    cmt := SCode.COMMENT(SOME(SCode.ANNOTATION(mod)), NONE());
  end makeEquationTag;

  function prefixName
    input String prefix;
    input String name;
    output String fullName = if stringEmpty(prefix) then name else prefix + "." + name;
  end prefixName;

  function optAttrString
    input String name;
    input Option<Expression> exp;
    output String str;
  algorithm
    str := match exp
      local
        Expression e;
      case SOME(e) then ", " + name + " = " + Expression.toString(e);
      else "";
    end match;
  end optAttrString;

  function hasHold
    input Spec spec;
    output Boolean hold = false;
  protected
    IterationVariable var;
  algorithm
    for r in spec.residuals loop
      if isSome(r.hold) then
        hold := true;
        return;
      end if;

      if isSome(r.iterationVariable) then
        SOME(var) := r.iterationVariable;

        if isSome(var.hold) then
          hold := true;
          return;
        end if;
      end if;
    end for;

    for v in spec.iterationVariables loop
      if isSome(v.hold) then
        hold := true;
        return;
      end if;
    end for;
  end hasHold;

  function checkUniqueEquation
    input ResidualEquation residual;
    input UnorderedMap<String, ResidualEquation> residuals;
  algorithm
    if UnorderedMap.contains(residual.name, residuals) then
      Error.addSourceMessage(Error.HGT_DUPLICATE_SPECIFICATION,
        {"The equation " + residual.name}, residual.info);
      fail();
    end if;
  end checkUniqueEquation;

  function checkUniqueVariable
    input IterationVariable var;
    input UnorderedMap<String, SourceInfo> names;
  protected
    String name = ComponentRef.toString(var.name);
  algorithm
    if UnorderedMap.contains(name, names) then
      Error.addSourceMessage(Error.HGT_DUPLICATE_SPECIFICATION,
        {"The variable " + name}, var.info);
      fail();
    end if;

    UnorderedMap.add(name, var.info, names);
  end checkUniqueVariable;

  // Parsing of the annotation records.

  function parseResidualEquation
    "Parses a component level ResidualEquation record, which is either paired
     (with iterationVariable) or unpaired."
    input SCode.Mod mod;
    input String name "The name of the equation.";
    input InstNode scope;
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    output Option<ResidualEquation> residual;
  protected
    Integer level;
    Option<Expression> nominal, hold;
    Option<IterationVariable> var = NONE();
    SourceInfo mod_info = getInfo(mod, info);
  algorithm
    checkFields(mod, {"enabled", "level", "nominal", "iterationVariable", "hold"}, "ResidualEquation", true);

    if not evalBoolean(mod, "enabled", true, scope, mod_info) then
      residual := NONE();
      return;
    end if;

    level := evalLevel(mod, scope, mod_info);
    nominal := parseRealAttribute(mod, "nominal", "residual equation " + name, level, scope, flattenFn, mod_info);
    hold := parseHold(mod, scope, flattenFn, mod_info);

    if hasField(mod, "iterationVariable") then
      var := SOME(parsePairedIterationVariable(lookupField(mod, "iterationVariable"),
        level, scope, flattenFn, mod_info));
    end if;

    residual := SOME(RESIDUAL_EQUATION(name, level, nominal, hold, var, mod_info));
  end parseResidualEquation;

  function parsePair
    "Parses a Pair record from tearingPairs."
    input SCode.Mod mod;
    input String prefix;
    input InstNode scope;
    input FlattenExpFn flattenFn;
    output Option<ResidualEquation> pair;
  protected
    SourceInfo info = SCodeUtil.getModifierInfo(mod);
    Integer level;
    SCode.Mod res_mod;
    String name;
    Option<Expression> nominal, hold;
    IterationVariable var;
  algorithm
    checkFields(mod, {"enabled", "level", "residualEquation", "iterationVariable"}, "Pair", true);

    if not evalBoolean(mod, "enabled", true, scope, info) then
      pair := NONE();
      return;
    end if;

    level := evalLevel(mod, scope, info);

    if not hasField(mod, "residualEquation") or not hasField(mod, "iterationVariable") then
      Error.addSourceMessage(Error.HGT_INVALID_VALUE,
        {"", "Pair", "both residualEquation and iterationVariable must be given"}, info);
      fail();
    end if;

    res_mod := lookupField(mod, "residualEquation");
    checkFields(res_mod, {"nominal", "hold"}, "residualEquation", true);

    name := match SCodeUtil.getModifierBinding(res_mod)
      local
        Absyn.ComponentRef cref;

      case SOME(Absyn.CREF(componentRef = cref)) then Dump.printComponentRefStr(cref);
      else
        algorithm
          Error.addSourceMessage(Error.HGT_INVALID_VALUE,
            {bindingString(res_mod), "residualEquation", "expected the name of an equation"}, info);
        then
          fail();
    end match;

    name := prefixName(prefix, name);
    nominal := parseRealAttribute(res_mod, "nominal", "residual equation " + name, level, scope, flattenFn, info);
    hold := parseHold(res_mod, scope, flattenFn, info);
    var := parsePairedIterationVariable(lookupField(mod, "iterationVariable"), level, scope, flattenFn, info);
    pair := SOME(RESIDUAL_EQUATION(name, level, nominal, hold, SOME(var), info));
  end parsePair;

  function parsePairedIterationVariable
    "Parses the iterationVariable field of a ResidualEquation or a Pair, e.g.
     iterationVariable(start = 1) = x."
    input SCode.Mod mod;
    input Integer level "The level of the pair.";
    input InstNode scope;
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    output IterationVariable var;
  protected
    ComponentRef name;
    SourceInfo mod_info = getInfo(mod, info);
  algorithm
    checkFields(mod, {"max", "min", "nominal", "start", "hold"}, "iterationVariable", true);

    name := match SCodeUtil.getModifierBinding(mod)
      local
        Absyn.Exp aexp;

      case SOME(aexp) then resolveIterationVariable(aexp, scope, flattenFn, mod_info);
      else
        algorithm
          Error.addSourceMessage(Error.HGT_INVALID_VALUE,
            {"", "iterationVariable", "expected the name of a variable"}, mod_info);
        then
          fail();
    end match;

    var := parseIterationVariableAttributes(mod, name, level, scope, flattenFn, mod_info);
  end parsePairedIterationVariable;

  function parseUnpairedIterationVariable
    "Parses an IterationVariable record on a variable declaration."
    input SCode.Mod mod;
    input ComponentRef name;
    input InstNode scope;
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    output Option<IterationVariable> var;
  protected
    SourceInfo mod_info = getInfo(mod, info);
  algorithm
    checkFields(mod, {"enabled", "level", "max", "min", "nominal", "start", "hold"}, "IterationVariable", true);

    if evalBoolean(mod, "enabled", true, scope, mod_info) then
      var := SOME(parseIterationVariableAttributes(mod, name,
        evalLevel(mod, scope, mod_info), scope, flattenFn, mod_info));
    else
      var := NONE();
    end if;
  end parseUnpairedIterationVariable;

  function parseIterationVariableAttributes
    input SCode.Mod mod;
    input ComponentRef name;
    input Integer level;
    input InstNode scope;
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    output IterationVariable var;
  protected
    String var_str = "iteration variable " + ComponentRef.toString(name);
  algorithm
    var := ITERATION_VARIABLE(name, level,
      parseRealAttribute(mod, "start", var_str, level, scope, flattenFn, info),
      parseRealAttribute(mod, "min", var_str, level, scope, flattenFn, info),
      parseRealAttribute(mod, "max", var_str, level, scope, flattenFn, info),
      parseRealAttribute(mod, "nominal", var_str, level, scope, flattenFn, info),
      parseHold(mod, scope, flattenFn, info),
      info);
  end parseIterationVariableAttributes;

  function resolveIterationVariable
    "Looks up the variable referenced by an iterationVariable field and returns
     its flattened name."
    input Absyn.Exp aexp;
    input InstNode scope;
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    output ComponentRef name;
  protected
    Expression exp;
    Type ty;
    Variability var;
  algorithm
    if not AbsynUtil.isCref(aexp) then
      Error.addSourceMessage(Error.HGT_INVALID_VALUE,
        {Dump.printExpStr(aexp), "iterationVariable", "expected the name of a variable"}, info);
      fail();
    end if;

    exp := Inst.instExp(aexp, scope, CONTEXT, info);
    (exp, ty, var) := Typing.typeExp(exp, CONTEXT, info);
    exp := flattenFn(exp);

    name := match exp
      case Expression.CREF() then exp.cref;
      else
        algorithm
          Error.addSourceMessage(Error.HGT_INVALID_ITERATION_VARIABLE,
            {Dump.printExpStr(aexp), "it is not a variable"}, info);
        then
          fail();
    end match;

    if not (Type.isReal(ty) and Type.isScalar(ty)) then
      Error.addSourceMessage(Error.HGT_INVALID_ITERATION_VARIABLE,
        {ComponentRef.toString(name), "only scalar Real variables can be iteration variables"}, info);
      fail();
    end if;

    if var <> Variability.CONTINUOUS then
      Error.addSourceMessage(Error.HGT_INVALID_ITERATION_VARIABLE,
        {ComponentRef.toString(name), "it is not a continuous variable"}, info);
      fail();
    end if;
  end resolveIterationVariable;

  function parseRealAttribute
    "Parses an optional Real attribute such as start, min, max or nominal.
     Continuous variables may only be used on level 2 or higher."
    input SCode.Mod mod;
    input String attrName;
    input String owner "Description of what the attribute belongs to, for error messages.";
    input Integer level;
    input InstNode scope;
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    output Option<Expression> attr;
  protected
    Absyn.Exp aexp;
    Expression exp;
    Type ty;
    Variability var;
  algorithm
    attr := match SCodeUtil.getModifierBinding(lookupField(mod, attrName))
      case SOME(aexp)
        algorithm
          exp := Inst.instExp(aexp, scope, CONTEXT, info);
          (exp, ty, var) := Typing.typeExp(exp, CONTEXT, info);

          if not Type.isScalar(ty) or not (Type.isReal(ty) or Type.isInteger(ty)) then
            Error.addSourceMessage(Error.HGT_INVALID_VALUE,
              {Dump.printExpStr(aexp), attrName, "expected a scalar Real expression"}, info);
            fail();
          end if;

          if var > Variability.NON_STRUCTURAL_PARAMETER and level < 2 then
            Error.addSourceMessage(Error.HGT_CONTINUOUS_ATTRIBUTE_ON_LEVEL_ONE,
              {attrName, Dump.printExpStr(aexp), owner}, info);
            fail();
          end if;

          if Type.isInteger(ty) then
            exp := Expression.typeCast(exp, Type.REAL());
          end if;
        then
          SOME(flattenFn(exp));

      else NONE();
    end match;
  end parseRealAttribute;

  function parseHold
    "Parses the optional hold field, which must be a Boolean parameter expression."
    input SCode.Mod mod;
    input InstNode scope;
    input FlattenExpFn flattenFn;
    input SourceInfo info;
    output Option<Expression> hold;
  protected
    Absyn.Exp aexp;
    Expression exp;
    Type ty;
    Variability var;
  algorithm
    hold := match SCodeUtil.getModifierBinding(lookupField(mod, "hold"))
      case SOME(aexp)
        algorithm
          exp := Inst.instExp(aexp, scope, CONTEXT, info);
          (exp, ty, var) := Typing.typeExp(exp, CONTEXT, info);

          if not (Type.isBoolean(ty) and Type.isScalar(ty)) or var > Variability.NON_STRUCTURAL_PARAMETER then
            Error.addSourceMessage(Error.HGT_INVALID_VALUE,
              {Dump.printExpStr(aexp), "hold", "expected a Boolean parameter expression"}, info);
            fail();
          end if;
        then
          SOME(flattenFn(exp));

      else NONE();
    end match;
  end parseHold;

  function evalBoolean
    "Evaluates an optional Boolean field such as enabled."
    input SCode.Mod mod;
    input String fieldName;
    input Boolean default;
    input InstNode scope;
    input SourceInfo info;
    output Boolean value;
  protected
    Absyn.Exp aexp;
    Expression exp;
  algorithm
    value := match SCodeUtil.getModifierBinding(lookupField(mod, fieldName))
      case SOME(aexp)
        algorithm
          exp := evalParameterExp(aexp, fieldName, "Boolean", Type.isBoolean, scope, info);
        then
          match exp
            case Expression.BOOLEAN() then exp.value;
            else
              algorithm
                Error.addSourceMessage(Error.HGT_INVALID_VALUE,
                  {Dump.printExpStr(aexp), fieldName, "expected a Boolean parameter expression"}, info);
              then
                fail();
          end match;

      else default;
    end match;
  end evalBoolean;

  function evalLevel
    "Evaluates the optional level field, which must be at least 1."
    input SCode.Mod mod;
    input InstNode scope;
    input SourceInfo info;
    output Integer level;
  protected
    Absyn.Exp aexp;
    Expression exp;
  algorithm
    level := match SCodeUtil.getModifierBinding(lookupField(mod, "level"))
      case SOME(aexp)
        algorithm
          exp := evalParameterExp(aexp, "level", "Integer", Type.isInteger, scope, info);
        then
          match exp
            case Expression.INTEGER() guard exp.value >= 1 then exp.value;
            else
              algorithm
                Error.addSourceMessage(Error.HGT_INVALID_VALUE,
                  {Dump.printExpStr(aexp), "level", "expected an Integer parameter expression that is at least 1"}, info);
              then
                fail();
          end match;

      else 1;
    end match;
  end evalLevel;

  function evalParameterExp
    "Instantiates, types and evaluates a parameter expression. The parameters
     used by the expression are marked as structural since they decide how the
     model is torn."
    input Absyn.Exp aexp;
    input String fieldName;
    input String typeName;
    input TypeCheckFn typeCheck;
    input InstNode scope;
    input SourceInfo info;
    output Expression exp;
  protected
    Type ty;
    Variability var;
  algorithm
    exp := Inst.instExp(aexp, scope, CONTEXT, info);
    (exp, ty, var) := Typing.typeExp(exp, CONTEXT, info);

    if not (typeCheck(ty) and Type.isScalar(ty)) or var > Variability.PARAMETER then
      Error.addSourceMessage(Error.HGT_INVALID_VALUE,
        {Dump.printExpStr(aexp), fieldName, "expected a " + typeName + " parameter expression"}, info);
      fail();
    end if;

    Structural.markExp(exp);
    exp := Ceval.evalExp(exp, Ceval.EvalTarget.new(info));
  end evalParameterExp;

  // Helpers for the annotation modifiers.

  function hasField
    input SCode.Mod mod;
    input String name;
    output Boolean res;
  algorithm
    res := match mod
      case SCode.MOD()
        then List.any(mod.subModLst, function isSubModNamed(name = name));
      else false;
    end match;
  end hasField;

  function lookupField
    "Returns the modifier of the field with the given name, or NOMOD."
    input SCode.Mod mod;
    input String name;
    output SCode.Mod field = SCode.NOMOD();
  algorithm
    () := match mod
      case SCode.MOD()
        algorithm
          for sm in mod.subModLst loop
            if sm.ident == name then
              field := sm.mod;
              return;
            end if;
          end for;
        then
          ();

      else ();
    end match;
  end lookupField;

  function lookupFields
    "Returns the modifiers of all fields with the given name, e.g. all Pair
     records in tearingPairs."
    input SCode.Mod mod;
    input String name;
    input String recordName;
    input Boolean warnUnknown;
    output list<SCode.Mod> fields = {};
  algorithm
    () := match mod
      case SCode.MOD()
        algorithm
          for sm in mod.subModLst loop
            if sm.ident == name then
              fields := sm.mod :: fields;
            elseif warnUnknown then
              Error.addSourceMessage(Error.HGT_UNKNOWN_FIELD,
                {sm.ident, recordName}, SCodeUtil.getModifierInfo(sm.mod));
            end if;
          end for;
        then
          ();

      else ();
    end match;

    fields := listReverse(fields);
  end lookupFields;

  function checkFields
    "Warns about fields of an annotation record that are not in the given list."
    input SCode.Mod mod;
    input list<String> knownFields;
    input String recordName;
    input Boolean warnUnknown;
  algorithm
    if not warnUnknown then
      return;
    end if;

    () := match mod
      case SCode.MOD()
        algorithm
          for sm in mod.subModLst loop
            if not List.isMemberOnTrue(sm.ident, knownFields, stringEq) then
              Error.addSourceMessage(Error.HGT_UNKNOWN_FIELD,
                {sm.ident, recordName}, SCodeUtil.getModifierInfo(sm.mod));
            end if;
          end for;
        then
          ();

      else ();
    end match;
  end checkFields;

  function isSubModNamed
    input SCode.SubMod subMod;
    input String name;
    output Boolean res = subMod.ident == name;
  end isSubModNamed;

  function getEquationName
    "Returns the identifier given by name = IDENT."
    input SCode.Mod mod;
    output String name;
  algorithm
    name := match mod
      case SCode.MOD(binding = SOME(Absyn.CREF(componentRef = Absyn.CREF_IDENT(name = name, subscripts = {}))))
        then name;
      else
        algorithm
          Error.addSourceMessage(Error.HGT_INVALID_VALUE,
            {bindingString(mod), "name", "expected an identifier"}, SCodeUtil.getModifierInfo(mod));
        then
          fail();
    end match;
  end getEquationName;

  function bindingString
    input SCode.Mod mod;
    output String str;
  algorithm
    str := match SCodeUtil.getModifierBinding(mod)
      local
        Absyn.Exp aexp;
      case SOME(aexp) then Dump.printExpStr(aexp);
      else "";
    end match;
  end bindingString;

  function getInfo
    "Returns the source info of a modifier, or the given info if the modifier
     has none (e.g. a record given only by its name)."
    input SCode.Mod mod;
    input SourceInfo info;
    output SourceInfo outInfo;
  algorithm
    outInfo := match mod
      case SCode.MOD() then mod.info;
      else info;
    end match;
  end getInfo;

  annotation(__OpenModelica_Interface="nf_frontend");
end NFHandGuidedTearing;
