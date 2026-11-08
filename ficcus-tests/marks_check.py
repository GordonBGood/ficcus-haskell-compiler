#!/usr/bin/env python3
"""Marks regression test (stage (iii) slice 0): the Haskell marks (`Ficcus.Mono.Marks`, printed in x.mono)
against the Python reference (`scheme_stats.py` fixpoint, run on the x.types of the same compile).

Runs the typed corpus check with `--output=x.mono` (which also writes x.types beside it) and, per project:
  * equatable marks: the set of (definition id, variable) must be equal;
  * kinds: every variable of kind number / comparable / appendable / compappend / row of a definition in the dump
    must appear with that kind in a `mark` line, and a `mark` line must not name a definition or kind the dump lacks.
Then it totals the union over all projects and compares it with scheme_stats.json (equatable_marked_vars, and the
number of callees marked per kind), if given with --reference.

  OUTD=<dir> python3 marks_check.py --elm bin/elmfic16 --safe tools/safe --elm-home H --out DIR --jobs 2 --timeout 120 \\
        [--reference scheme_stats.json] <projects dir>
Exit status 1 if any project differs.
"""
import sys, os, re, json, collections, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["TYPED_OUT"] = "x.mono"
import typed_check as tc
import scheme_stats as ss

LOCK = threading.Lock()
MARK = re.compile(r"^mark (\S+)   (.*)$")
RES = {"projects": 0, "diff": [], "eq_union": set(), "kinds": collections.defaultdict(set), "kind_seen": collections.defaultdict(set)}


def hs_marks(path):
    eq, kinds = set(), {}
    for line in open(path, encoding="utf-8"):
        m = MARK.match(line.rstrip("\n"))
        if not m: continue
        did = m.group(1)
        for tok in m.group(2).split():
            v, rest = tok.split("=", 1)
            parts = rest.split("+")
            kinds[(did, v)] = parts[0]
            if "equatable" in parts[1:]: eq.add((did, v))
    return eq, kinds


def py_equatable(defs, uses):
    by_callee = collections.defaultdict(list)
    for u in uses: by_callee[u[0]].append(u)
    eq = set(ss.ROOTS); work = list(ss.ROOTS)
    while work:
        cv = work.pop()
        for (c, h, binds) in by_callee.get(cv[0], ()):
            for v, text in binds:
                if v != cv[1]: continue
                acc = set(); ss.tokens_of(ss.parse_type(text), acc)
                for tk in acc:
                    key = ss.tok_split(tk)
                    if key not in eq: eq.add(key); work.append(key)
    return {k for k in eq if k[0] in defs}


def check_project(d):
    types, mono = os.path.join(d, "p", "x.types"), os.path.join(d, "p", "x.mono")
    if not (os.path.exists(types) and os.path.exists(mono)): return
    defs, uses = ss.parse(types)
    py_eq = py_equatable(defs, uses)
    hs_eq, hs_kinds = hs_marks(mono)
    want = {(did, v): k for did, (ks, _) in defs.items() for v, k in ks.items() if k != "any"}
    problems = []
    if py_eq != hs_eq:
        problems.append("equatable: only python %d %s; only haskell %d %s" % (len(py_eq - hs_eq), sorted(py_eq - hs_eq)[:3], len(hs_eq - py_eq), sorted(hs_eq - py_eq)[:3]))
    miss = {k for k in want if hs_kinds.get(k) != want[k]}
    extra = {k for k, v in hs_kinds.items() if v != "any" and want.get(k) != v}
    if miss or extra:
        problems.append("kinds: missing %d %s; extra %d %s" % (len(miss), sorted(miss)[:3], len(extra), sorted(extra)[:3]))
    with LOCK:
        RES["projects"] += 1
        RES["eq_union"] |= hs_eq
        for k, v in hs_kinds.items():
            if v != "any": RES["kinds"][v].add(k)
        if problems: RES["diff"].append((os.path.basename(d), problems))


def main():
    ref = None
    if "--reference" in sys.argv:
        i = sys.argv.index("--reference"); ref = json.load(open(sys.argv[i + 1])); del sys.argv[i:i + 2]
    outd = os.environ["OUTD"]
    real = tc.shutil.rmtree

    def rm(d, **kw):
        check_project(d)
        real(d, **kw)
    tc.shutil.rmtree = rm
    rc = tc.main()
    summary = {"projects_checked": RES["projects"], "projects_differing": len(RES["diff"]),
               "equatable_union": len(RES["eq_union"]),
               "callees_marked": {k: len({d for d, _ in v}) for k, v in RES["kinds"].items()},
               "row_vars": len(RES["kinds"].get("row", ()))}
    if ref:
        summary["reference"] = {"equatable_marked_vars": ref["equatable_marked_vars"], "row_vars": ref["row_vars"],
                                "callees_marked": {k: ref[k]["callees_marked"] for k in ("number", "comparable", "appendable", "compappend")}}
    summary["differences"] = RES["diff"][:20]
    json.dump(summary, open(os.path.join(outd, "marks_check.json"), "w"), indent=1)
    print(json.dumps(summary, indent=1))
    return 1 if RES["diff"] else rc


if __name__ == "__main__":
    sys.exit(main())
