#!/usr/bin/env python3
"""Inspects an interactive FMU (OCT or OpenModelica) and reports

  1. the iter_N / res_N / *_hold variables and their causality,
  2. where dependencies of the residuals on the iteration variables are
     exported: <ModelStructure> (Outputs, InitialUnknowns), <VendorAnnotations>,
     files under resources/,
  3. whether iter_N can be set repeatedly and the residuals follow (needs FMPy),
     staying in initialization mode (OCT style) or after it (inputs),
  4. the dependencies found by perturbing each iteration variable, compared
     with the exported ones.

Usage:
    python3 inspect_interactive_fmu.py Model.fmu [--no-run] [--max-vars 50]

The FMU is only read and loaded; nothing is written except a temporary
extraction directory that FMPy removes. Only run FMUs you trust: loading an
FMU executes its binary.
"""

import argparse
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

ITER = re.compile(r"^iter_(\d+)$")
RES = re.compile(r"^res_(\d+)$")
HOLD = re.compile(r"^(iter|res)_(\d+)_hold$")
TYPES = ("Real", "Integer", "Boolean", "String", "Enumeration")


def heading(text):
    print("\n" + text)
    print("-" * len(text))


def read_model(path):
    z = zipfile.ZipFile(path)
    root = ET.fromstring(z.read("modelDescription.xml"))
    variables = []
    for i, sv in enumerate(root.find("ModelVariables").findall("ScalarVariable"), start=1):
        typ = next((c for c in sv if c.tag in TYPES), None)
        variables.append(dict(
            index=i, name=sv.get("name"), vr=int(sv.get("valueReference")),
            causality=sv.get("causality", "local"), variability=sv.get("variability", "continuous"),
            initial=sv.get("initial", ""), type=typ.tag if typ is not None else "?",
            start=typ.get("start") if typ is not None else None,
            description=sv.get("description", "")))
    return z, root, variables


def numbered(variables, pattern):
    found = {}
    for v in variables:
        m = pattern.match(v["name"])
        if m:
            found[int(m.group(1))] = v
    return found


def report_variables(variables):
    heading("1. Interactive variables")
    iters, ress = numbered(variables, ITER), numbered(variables, RES)
    holds = [v for v in variables if HOLD.match(v["name"])]
    print("iter_N: %d, res_N: %d, *_hold: %d" % (len(iters), len(ress), len(holds)))
    if not iters or not ress:
        print("  no iter_N or res_N: this is not an interactive FMU")
        return iters, ress

    def summary(items):
        kinds = {}
        for v in items:
            key = "causality=%s variability=%s initial=%s" % (v["causality"], v["variability"], v["initial"] or "-")
            kinds.setdefault(key, []).append(v["name"])
        for key, names in kinds.items():
            print("  %-70s %4d  e.g. %s" % (key, len(names), ", ".join(names[:3])))

    print("iter_N:")
    summary(iters.values())
    print("res_N:")
    summary(ress.values())
    if holds:
        print("*_hold:")
        summary(holds)
    for n in sorted(iters)[:3]:
        v = iters[n]
        print("  example iter_%d: vr=%d start=%s description=%r" % (n, v["vr"], v["start"], v["description"][:80]))
    for n in sorted(ress)[:2]:
        v = ress[n]
        print("  example res_%d: vr=%d description=%r" % (n, v["vr"], v["description"][:120]))
    return iters, ress


def report_structure(z, root, variables, iters, ress):
    heading("2. Exported dependencies")
    by_index = {v["index"]: v for v in variables}
    iter_vrs = {v["vr"] for v in iters.values()}
    # an alias of iter_N (same vr) counts as iter_N
    iter_like = {v["index"] for v in variables if v["vr"] in iter_vrs and v["type"] == "Real"}
    res_indices = {v["index"]: n for n, v in ress.items()}
    exported = {}

    structure = root.find("ModelStructure")
    for section in ("Outputs", "Derivatives", "InitialUnknowns"):
        node = structure.find(section) if structure is not None else None
        if node is None:
            print("<%s>: not present" % section)
            continue
        listed = with_iter = 0
        for u in node.findall("Unknown"):
            idx = int(u.get("index"))
            if idx not in res_indices:
                continue
            listed += 1
            deps = [int(d) for d in (u.get("dependencies") or "").split()]
            found = sorted(by_index[d]["name"] for d in deps if d in iter_like)
            if found:
                with_iter += 1
                exported.setdefault(res_indices[idx], set()).update(found)
        print("<%s>: %d of %d res_N listed, %d of them depend on an iteration variable"
              % (section, listed, len(ress), with_iter))

    vendor = root.find("VendorAnnotations")
    if vendor is None:
        print("<VendorAnnotations>: not present")
    else:
        tools = [t.get("name") for t in vendor.findall("Tool")]
        text = ET.tostring(vendor, encoding="unicode")
        print("<VendorAnnotations>: tools %s, %d characters, mentions iter_: %s, res_: %s"
              % (tools, len(text), "iter_" in text, "res_" in text))
        print("  first 600 characters:\n  " + text[:600].replace("\n", "\n  "))

    heading("2b. Files under resources/ and other non-binary files")
    for info in z.infolist():
        name = info.filename
        if name.endswith("/") or name.startswith("binaries/") or name == "modelDescription.xml":
            continue
        hit = ""
        if info.file_size < 50_000_000:
            data = z.read(name)
            if b"iter_" in data or b"res_" in data or b"dependen" in data.lower():
                hit = "  <- mentions iter_/res_/dependen"
        print("  %-60s %10d bytes%s" % (name, info.file_size, hit))
    return exported


def try_runtime(path, variables, iters, ress, exported, max_vars):
    heading("3. Setting iter_N and reading res_N (FMPy)")
    try:
        from fmpy import extract, read_model_description
        from fmpy.fmi2 import FMU2Model
    except ImportError:
        print("FMPy is not installed: pip install fmpy")
        return
    md = read_model_description(path)
    unzip = extract(path)
    ident = md.modelExchange.modelIdentifier if md.modelExchange else md.coSimulation.modelIdentifier
    order = sorted(iters)[:max_vars]
    iter_vrs = [iters[n]["vr"] for n in order]
    res_order = sorted(ress)
    res_vrs = [ress[n]["vr"] for n in res_order]

    def session(stay_in_init):
        fmu = FMU2Model(guid=md.guid, unzipDirectory=unzip, modelIdentifier=ident, instanceName="inspect")
        fmu.instantiate()
        fmu.setupExperiment(startTime=0.0)
        fmu.enterInitializationMode()
        if not stay_in_init:
            fmu.exitInitializationMode()
        return fmu

    for stay in (True, False):
        mode = "staying in initialization mode" if stay else "after initialization"
        try:
            fmu = session(stay)
            x0 = fmu.getReal(iter_vrs)
            r0 = fmu.getReal(res_vrs)
        except Exception as e:  # noqa: BLE001 - report whatever the FMU does
            print("%s: could not start or read: %s" % (mode, e))
            continue
        changed = 0
        errors = []
        probed = {}
        for k, n in enumerate(order):
            h = 1e-6 * max(1.0, abs(x0[k]))
            try:
                fmu.setReal([iter_vrs[k]], [x0[k] + h])
                r1 = fmu.getReal(res_vrs)
                fmu.setReal([iter_vrs[k]], [x0[k]])
            except Exception as e:  # noqa: BLE001
                errors.append("iter_%d: %s" % (n, e))
                continue
            moved = [res_order[j] for j in range(len(res_vrs)) if r1[j] != r0[j]]
            if moved:
                changed += 1
            for j in moved:
                probed.setdefault(j, set()).add("iter_%d" % n)
        print("%s: set %d iter_N, %d changed some res_N, %d errors"
              % (mode, len(order), changed, len(errors)))
        for e in errors[:5]:
            print("  " + e)
        if stay and exported:
            perturbed = {"iter_%d" % n for n in order}
            diff = [j for j in res_order
                    if probed.get(j, set()) != (exported.get(j, set()) & perturbed)]
            print("  probed dependencies equal to the exported ones for %d of %d residuals"
                  % (len(res_order) - len(diff), len(res_order)))
            for j in diff[:10]:
                print("    res_%d: exported {%s}, probed {%s}" % (
                    j, ", ".join(sorted(exported.get(j, set()) & perturbed)),
                    ", ".join(sorted(probed.get(j, set())))))
            if diff:
                print("    (probing at one point misses derivatives that happen to be 0 there)")
        elif stay and probed:
            print("  probed dependencies, first residuals:")
            for j in sorted(probed)[:5]:
                print("    res_%d <- %s" % (j, ", ".join(sorted(probed[j], key=lambda s: int(s[5:])))))
        try:
            fmu.terminate()
            fmu.freeInstance()
        except Exception:  # noqa: BLE001
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("fmu")
    parser.add_argument("--no-run", action="store_true", help="only read modelDescription.xml and the files")
    parser.add_argument("--max-vars", type=int, default=50, help="iteration variables to perturb in step 3")
    args = parser.parse_args()
    z, root, variables = read_model(args.fmu)
    print("FMU: %s  generationTool=%r  fmiVersion=%s" % (args.fmu, root.get("generationTool"), root.get("fmiVersion")))
    iters, ress = report_variables(variables)
    if not iters or not ress:
        return 1
    exported = report_structure(z, root, variables, iters, ress)
    if not args.no_run:
        try_runtime(args.fmu, variables, iters, ress, exported, args.max_vars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
