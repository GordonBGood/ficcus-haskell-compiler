#!/usr/bin/env python3
"""a5fgen.py -- the A5f cases of the attach suite: the reproducers of the A5a review (docs/A5A-REVIEW.md, cases in
ficcus-tests/a5ar/) that the fixes M1, M2, B1, B2 change, and a few neighbours.  Standard library only.

  python3 ficcus-tests/attach/a5fgen.py --write                 # write cases/a5f-*/, the twins, the rows of expected.tsv
  python3 ficcus-tests/attach/a5fgen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case

The expected output of a RUN case is never written by hand: it is the output of a *twin* program (in a5f-twins/<id>/).
  elm   plain Elm, compiled by bin/elm0193 and run by node
  oldc  a Ficcus program that bin/elmficA3b compiles to C (A3b ran the B1 cases as they are), run with gcc
The sources of the review's cases are copied from ficcus-tests/a5ar/cases/<id>/ (written by its gen.py).

a5agen is imported with an empty command line: g71gen (which a5agen imports) rewrites every G71 case on import when it sees
--write (the trap of docs/attach/A5B-NOTES.md)."""
import argparse, json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a5f-twins")
REVIEW = os.path.join(HERE, "..", "a5ar", "cases")
sys.path.insert(0, HERE)
import attach, mkhome
_argv, sys.argv = sys.argv, sys.argv[:1]
import a5agen
sys.argv = _argv

main_of, blocks = a5agen.main_of, a5agen.blocks

RUN = ("RUN", "c", "")
SHAPE = "OPERATOR FUNCTION WITH THE WRONG TYPE"


def review(cid):
    """the Elm files of a review case (not its twin)"""
    d = os.path.join(REVIEW, cid)
    return {fn: open(os.path.join(d, fn), encoding="utf-8").read() for fn in sorted(os.listdir(d)) if fn.endswith(".elm")}


def deep_chain(n):
    """review B2: types T0 .. Tn, each with `f` peeling one level; `deep w` calls the selector-free `get` n+1 times (inferred)"""
    types = ["type T0 = T0 Int\n    where\n        f : T0 -> Int\n        f (T0 k) = k\n"]
    for i in range(1, n + 1):
        types.append("type T%d = T%d T%d\n    where\n        f : T%d -> T%d\n        f (T%d t) = t\n" % (i, i, i - 1, i, i - 1, i))
    get = "get : a -> b\n    where\n        a has f : a -> b\nget x =\n    f x\n"
    call = "w"
    for _ in range(n + 1): call = "get (%s)" % call
    value = "T0 42"
    for i in range(1, n + 1): value = "T%d (%s)" % (i, value)
    return main_of(blocks(*types, get, "deep w =\n    " + call), "deep (%s) + 1" % value)


def deep_chain_elm(n):
    """the same chain in plain Elm: one function per level"""
    types = ["type T0\n    = T0 Int\n\n\nf0 : T0 -> Int\nf0 (T0 k) =\n    k\n"]
    for i in range(1, n + 1):
        types.append("type T%d\n    = T%d T%d\n\n\nf%d : T%d -> T%d\nf%d (T%d t) =\n    t\n" % (i, i, i - 1, i, i, i - 1, i, i))
    call = "w"
    for i in range(n, -1, -1): call = "f%d (%s)" % (i, call)
    value = "T0 42"
    for i in range(1, n + 1): value = "T%d (%s)" % (i, value)
    return main_of(blocks(*types, "deep w =\n    " + call), "deep (%s) + 1" % value)


APPEND_OK = ("appz : a -> a -> a\n    where\n        a has append : a -> a -> a\nappz x y =\n    append x y\n\n\n"
             "app2 x y =\n    Debug.toString (appz x y)\n\n\nlenOf x y =\n    String.length (app2 x y)\n")
APPEND_ELM = "app2 x y =\n    Debug.toString (x ++ y)\n\n\nlenOf x y =\n    String.length (app2 x y)\n"
APPEND_OUT = "( app2 \"a\" \"b\", app2 [ 1 ] [ 2 ], lenOf \"ab\" \"cd\" )"

F32_OK = ("conv : a -> a\n    where\n        a has fromInt : Int -> a\nconv _ =\n    fromInt 3\n\n\n"
          "show : Float32 -> String\nshow x =\n    Float32.toString x\n")
F32_IMPORT = "import Float32 exposing (Float32)"


# id, desc, files, row, twin (kind, files) or None
CASES_NEW = [
    # ---- M1: a well known name in a signature's `where` line has the well known shape
    ("a5f-m1-builtin-append", "review M1 (builtin-decides-append): `a has append : a -> a -> z` is not the shape of append; it gave {} for String and List",
     review("builtin-decides-append"), ("REJECTC", SHAPE, "a has append : a -> a -> a"), None),
    ("a5f-m1-builtin-inferred", "review M1 (builtin-decides-inferred): `a has compare : a -> a -> z`; the C returned an int as fic_ref",
     review("builtin-decides-inferred"), ("REJECTC", SHAPE, "a has compare : a -> a -> Order"), None),
    ("a5f-m1-builtin-written", "review M1 (builtin-decides-written): the written D2 path with `compare : a -> a -> z` is rejected too",
     review("builtin-decides-written"), ("REJECTC", SHAPE, "a has compare : a -> a -> Order"), None),
    ("a5f-m1-float32", "review M1 (builtin-decides-float32, failed on A3b too): `a has fromInt : Int -> z` at Float32",
     review("builtin-decides-float32"), ("REJECTC", SHAPE, "a has fromInt : Int -> a"), None),
    ("a5f-m1-append-ok", "M1 neighbour: the well known shape of append, the caller inferred, at String and List",
     {"Main.elm": main_of(APPEND_OK, APPEND_OUT)}, RUN,
     ("elm", {"Main.elm": main_of(APPEND_ELM, APPEND_OUT)})),
    ("a5f-m1-float32-ok", "M1 neighbour: the well known shape of fromInt at Float32",
     {"Main.elm": main_of(F32_OK, "show (conv (Float32.fromFloat 1))", imports=F32_IMPORT)}, RUN,
     ("oldc", {"Main.elm": main_of(F32_OK, "show (conv (Float32.fromFloat 1))", imports=F32_IMPORT)})),
    # ---- M2: in a recursive group a requirement goes into the scheme only when every name's type determines it
    ("a5f-m2-recursive-ambiguous", "review M2 (share-recursive-ambiguous): gb's call of fa (sum []) leaves `a has add, zero` undetermined for gb",
     review("share-recursive-ambiguous"), ("REJECTC", "AMBIGUOUS TYPE", "call each other"), None),
    ("a5f-m2-recursive-todo", "review M2 (share-recursive-top): the same with Debug.todo for the argument",
     review("share-recursive-top"), ("REJECTC", "AMBIGUOUS TYPE", "call each other"), None),
    # ---- B1: rule 1 only when a requirement goes into a scheme (A3b ran these)
    ("a5f-b1-let", "review B1 (order-rule1-let): a polymorphic member at two instances inside a let value",
     review("order-rule1-let"), RUN, ("oldc", review("order-rule1-let"))),
    ("a5f-b1-let-after", "review B1 (order-rule1-let-after): with `k = q == Q 1` before the let value",
     review("order-rule1-let-after"), RUN, ("oldc", review("order-rule1-let-after"))),
    ("a5f-b1-let-swapped", "review B1 (order-rule1-let-swapped): the two let definitions in the other order",
     review("order-rule1-let-swapped"), RUN, ("oldc", review("order-rule1-let-swapped"))),
    ("a5f-b1-let-renamed", "review B1 (order-rule1-let-renamed): k renamed zk (it ran before the fix)",
     review("order-rule1-let-renamed"), RUN, ("oldc", review("order-rule1-let-renamed"))),
    # ---- B2: the specializer's fixpoints have no fixed fuel
    ("a5f-b2-deep-9", "review B2 (spec-deep-inferred-9): an inferred chain of 10 member calls", {"Main.elm": deep_chain(9)}, RUN,
     ("elm", {"Main.elm": deep_chain_elm(9)})),
    ("a5f-b2-deep-12", "review B2 (spec-deep-inferred-12)", {"Main.elm": deep_chain(12)}, RUN, ("elm", {"Main.elm": deep_chain_elm(12)})),
    ("a5f-b2-deep-30", "B2: an inferred chain of 31 member calls", {"Main.elm": deep_chain(30)}, RUN, ("elm", {"Main.elm": deep_chain_elm(30)})),
]


# existing rows whose outcome changes in A5f: id -> row
ROWS_CHANGED = {
    # M1: `a has add : a -> Int -> a` is not the shape of add; the shape check comes before the mismatch with `sum`'s line
    "constraint-given-mismatch": ("REJECT", SHAPE, "a has add : a -> a -> a"),
}


def write():
    a5agen.TWINS = TWINS
    rows = dict(ROWS_CHANGED)
    for cid, desc, files, row, twin in CASES_NEW:
        d = os.path.join(CASES, cid)
        os.makedirs(d, exist_ok=True)
        for fn in os.listdir(d):
            if fn.endswith(".elm") and fn not in files: os.remove(os.path.join(d, fn))
        for fn, src in files.items():
            open(os.path.join(d, fn), "w", encoding="utf-8").write(src)
        meta = {"desc": desc}
        if any("import Float32" in src for src in files.values()): meta["c_only"] = True
        json.dump(meta, open(os.path.join(d, "case.json"), "w"))
        rows[cid] = row
        if twin: a5agen.put_twin(cid, twin)
        elif os.path.exists(os.path.join(d, "expected.out")): os.remove(os.path.join(d, "expected.out"))
    path = os.path.join(HERE, "expected.tsv")
    out, seen = [], set()
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if not line.startswith("#") and f[0] in rows:
            out.append("\t".join((f[0],) + tuple(rows[f[0]])) + "\n"); seen.add(f[0])
        else:
            out.append(line)
    new = [cid for cid, _, _, _, _ in CASES_NEW if cid not in seen]
    if new and not any(l.startswith("# A5f") for l in out):
        out.append("# A5f (a5fgen.py): the fixes of the A5a review (M1, M2, B1, B2)\n")
    for cid in new:
        out.append("\t".join((cid,) + tuple(rows[cid])) + "\n")
    open(path, "w", encoding="utf-8").writelines(out)
    print("wrote %d new cases, %d changed rows" % (len(CASES_NEW), len(ROWS_CHANGED)))


def expect(only):
    a5agen.TWINS = TWINS
    root = attach.ROOT
    elm0193 = os.path.join(root, "bin", "elm0193")
    old = os.path.join(root, "bin", "elmficA3b")
    home = tempfile.mkdtemp(prefix="a5ftwin-home-")
    mkhome.make(home)
    try:
        ids = sorted(os.listdir(TWINS))
        if only: ids = [i for i in ids if i in only.split(",")]
        for cid in ids:
            out = a5agen.run_twin(cid, elm0193, old, home)
            open(os.path.join(CASES, cid, "expected.out"), "w", encoding="utf-8").write(out)
            print("%-28s %r" % (cid, out))
    finally:
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true"); ap.add_argument("--expect", action="store_true"); ap.add_argument("--only")
    a = ap.parse_args()
    if a.write: write()
    if a.expect: expect(a.only)
