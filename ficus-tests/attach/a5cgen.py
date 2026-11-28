#!/usr/bin/env python3
"""a5cgen.py -- the A5c cases of the attach suite: the built-in `zero` of Int, Float and the sized types, and the texts of the
messages (docs/A5-INFERENCE-DESIGN.md section 4; the review's B3).  Standard library only.

  python3 ficus-tests/attach/a5cgen.py --write                 # write cases/a5c-*/, the twins, the rows of expected.tsv
  python3 ficus-tests/attach/a5cgen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case

The expected output of a RUN case is never written by hand: it is the output of a *twin* program (in a5c-twins/<id>/).
  elm   plain Elm, compiled by bin/elm0193 and run by node
  oldc  a Ficus program that bin/elmficA3b compiles to C (the same program with `zero` written out), run with gcc

a5agen is imported with an empty command line: g71gen (which a5agen imports) rewrites every G71 case on import when it sees
--write (the trap of docs/attach/A5B-NOTES.md)."""
import argparse, json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a5c-twins")
sys.path.insert(0, HERE)
import attach, mkhome
_argv, sys.argv = sys.argv, sys.argv[:1]
import a5agen, g71gen
sys.argv = _argv

main_of, blocks = a5agen.main_of, a5agen.blocks
TYPES, HELPERS, CASH = a5agen.TYPES, a5agen.HELPERS, g71gen.CASH
MONEY = TYPES.split("\n\n\ntype Vec")[0] + "\n"

RUN = ("RUN", "c", "")

SUM = ("sum : List a -> a\n    where\n        a has zero : a\n        a has add : a -> a -> a\nsum xs =\n    List.foldl add zero xs\n")
SIZED = "import Float32 exposing (Float32)\nimport Word8 exposing (Word8)"
OWN_ZERO = ("type Money\n    = Money Int\n    where\n        zero : Money\n        zero =\n            Money 7\n\n        add : Money -> Money -> Money\n"
            "        add (Money a) (Money b) =\n            Money (a + b)\n")
SCALE = ("type Money\n    = Money Int\n    where\n        scale : Money -> Int -> Money\n        scale (Money a) k =\n            Money (a * k)\n\n\n"
         "type Vec\n    = Vec Float Float\n    where\n        scale : Float -> Vec -> Vec\n        scale k (Vec a b) =\n            Vec (a * k) (b * k)\n")
ADD_ONLY = "type T\n    = T Int\n    where\n        add : T -> T -> T\n        add (T a) (T b) =\n            T (a + b)\n"
DOUBLE_ONLY = ("type Money\n    = Money Int\n    where\n        double : Money -> Money\n        double (Money a) =\n            Money (a * 2)\n")


# id, desc, files, row, twin (kind, files) or None
CASES_NEW = [
    # ---- the built-in zero (A5c decision: Int, Float and the sized types; not in the `number` bundle)
    ("a5c-zero-int", "built-in zero of Int: a written sum (a has zero, a has add) at a list of Int, and at the empty list",
     {"Main.elm": main_of(blocks(SUM), "( sum [ 1, 2, 3 ], sum [] + 0 )")}, RUN,
     ("elm", {"Main.elm": main_of("", "( List.foldl (+) 0 [ 1, 2, 3 ], 0 )")})),
    ("a5c-zero-float", "built-in zero of Float: the written sum at a list of Float",
     {"Main.elm": main_of(blocks(SUM), "( sum [ 1.5, 2 ], sum [ 0.25 ] )")}, RUN,
     ("elm", {"Main.elm": main_of("", "( List.foldl (+) 0 [ 1.5, 2 ], List.foldl (+) 0 [ 0.25 ] )")})),
    ("a5c-zero-sized", "the zero of the sized types (Word8, Float32): a member of their overlay modules",
     {"Main.elm": main_of(blocks(SUM), "( Word8.toInt (sum [ Word8.fromInt 200, Word8.fromInt 100 ]), Float32.toString (sum [ Float32.fromFloat 0.5, Float32.fromFloat 0.25 ]) )", imports=SIZED)},
     RUN,
     ("oldc", {"Main.elm": main_of("", "( Word8.toInt (List.foldl (+) (Word8.fromInt 0) [ Word8.fromInt 200, Word8.fromInt 100 ]), "
                                       "Float32.toString (List.foldl (+) (Float32.fromInt 0) [ Float32.fromFloat 0.5, Float32.fromFloat 0.25 ]) )", imports=SIZED)})),
    ("a5c-zero-selector", "a list sum through the bare names (total xs = List.foldl add zero xs, inferred) at Int, Float and Money",
     {"Main.elm": main_of(blocks(TYPES, "total xs =\n    List.foldl add zero xs"), "( total [ 1, 2, 3 ], total [ 0.5, 1 ], total [ Money 1, Money 2 ] )")}, RUN,
     ("elm", {"Main.elm": main_of("type Money\n    = Money Int", "( 6, 1.5, Money 3 )")})),
    ("a5c-zero-own-wins", "a user type with its own zero (Money 7) keeps it; Int next to it uses the built-in one",
     {"Main.elm": main_of(blocks(OWN_ZERO, SUM), "( sum [ Money 1, Money 2 ], sum [ 4 ] )")}, RUN,
     ("oldc", {"Main.elm": main_of(blocks(OWN_ZERO), "( List.foldl Money.add Money.zero [ Money 1, Money 2 ], 4 )")})),
    ("a5c-zero-neither", "a type with add but no zero still has no zero",
     {"Main.elm": main_of(blocks(ADD_ONLY, SUM), "sum [ T 1 ]")},
     ("REJECTC", "NO ATTACHED FUNCTION", "needs `T` to have an attached `zero` function"), None),
    # ---- texts (section 4)
    ("a5c-js-idiv", "review B3: the JavaScript refusal suggests the defaulted type of the operator (h y = y // 4: Int -> Int)",
     {"Main.elm": main_of(blocks(CASH, "h y =\n    y // 4"), "( h 9, h (Cash 800) )")},
     ("REJECT", "NOT AVAILABLE IN JAVASCRIPT YET", "give it one such as `h : Int -> Int`"), None),
    ("a5c-js-let", "review B3: f c = let k = 8 // 2 in ( k, c ) suggests the defaulted type with the variable kept",
     {"Main.elm": main_of(blocks(CASH, "f c =\n    let\n        k =\n            8 // 2\n    in\n    ( k, c )"), "f 1")},
     ("REJECT", "NOT AVAILABLE IN JAVASCRIPT YET", "give it one such as `f : a -> ( Int, a )`"), None),
    ("a5c-js-neutral", "review B3: a requirement that Int and Float do not meet: the refusal says it in words",
     {"Main.elm": main_of(blocks(DOUBLE_ONLY, "twice x =\n    double (double x)"), "twice (Money 1)")},
     ("REJECT", "NOT AVAILABLE IN JAVASCRIPT YET", "give it one that names the types it is used at"), None),
    ("a5c-mr-hint", "L2 hint: a let value (MR) used at two types; the mismatch at the call of the enclosing function says why",
     {"Main.elm": main_of(blocks(TYPES, "f m v =\n    let\n        g =\n            add\n    in\n    ( g m m, g v v )"), "f (Money 2) (Vec 1 2)")},
     ("REJECTC", "TYPE MISMATCH", "`g` in `f` is a value, not a function"), None),
    ("a5c-l6-hint", "L6 hint: `<` on an annotated variable in a module with attached functions: Elm's hint, then the `where` line",
     {"Main.elm": main_of(blocks(TYPES, "smaller : a -> a -> a\nsmaller a b =\n    if a < b then\n        a\n\n    else\n        b"), "smaller (Money 1) (Money 2)")},
     ("REJECTC", "TYPE MISMATCH", "Or keep `a` and say that it can be compared"), None),
    ("a5c-incomplete-one-type", "INCOMPLETE TYPE ANNOTATION for a bare name with one type in sight: write Money.zero",
     {"Main.elm": main_of(blocks(MONEY, "total : (a -> a -> a) -> List a -> a\ntotal f xs =\n    List.foldl f zero xs"), "total Money.add [ Money 1 ]")},
     ("REJECTC", "INCOMPLETE TYPE ANNOTATION", "If you mean the one of `Money`, write `Money.zero`."), None),
    ("a5c-incomplete-show", "INCOMPLETE TYPE ANNOTATION shows the annotation with its where lines and the line to add",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "twice : a -> a\n    where\n        a has zero : a\ntwice m =\n    plus (plus m zero) m"), "twice (Money 2)")},
     ("REJECTC", "INCOMPLETE TYPE ANNOTATION", "            a has add : a -> a -> a"), None),
    ("a5c-incomplete-let", "INCOMPLETE TYPE ANNOTATION for an annotated let function: remove the annotation (no where in a let)",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "f m =\n    let\n        g : a -> a\n        g x =\n            plus x x\n    in\n    g m"), "f (Money 2)")},
     ("REJECTC", "INCOMPLETE TYPE ANNOTATION", "cannot have a `where` block. Remove the type annotation"), None),
    ("a5c-ambiguous-value", "AMBIGUOUS TYPE for a value whose whole type is the subject: the example annotation",
     {"Main.elm": main_of(blocks(TYPES, "empty =\n    zero"), "1")},
     ("REJECTC", "AMBIGUOUS TYPE", "    empty : Money"), None),
    ("a5c-ambiguous-literal", "AMBIGUOUS TYPE for a literal that neither Int nor Float can be (L5): write a value of the type",
     {"Main.elm": main_of(blocks(DOUBLE_ONLY, "quad x =\n    double (double x)"), "quad 1")},
     ("REJECTC", "AMBIGUOUS TYPE", "Only a number literal gives the type"), None),
    ("a5c-naming-shapes", "NAMING ERROR for an attached function name whose types do not line up",
     {"Main.elm": main_of(blocks(SCALE), "scale (Money 2) 3")},
     ("REJECT", "NAMING ERROR", "`scale` is an attached function of `Money` and of `Vec`"), None),
    ("a5c-naming-elm", "an Elm program's NAMING ERROR keeps Elm's text (no attached functions anywhere)",
     {"Main.elm": main_of("", "ad 1 2")},
     ("REJECT", "NAMING ERROR", "I cannot find a `ad` variable"), None),
]


# existing rows whose outcome changes in A5c: id -> (row, twin)
CASES_CONVERTED = {
    # the built-in zero: `sum [ 1, 2 ]` defaults to Int (D3), which now has every member (decision of 2026-11-26)
    "constraint-no-members-at-all": (RUN, ("elm", {"Main.elm": main_of("", "List.foldl (+) 0 [ 1, 2 ]")})),
}


def write():
    a5agen.TWINS = TWINS
    rows = {}
    for cid, desc, files, row, twin in CASES_NEW:
        d = os.path.join(CASES, cid)
        os.makedirs(d, exist_ok=True)
        for fn in os.listdir(d):
            if fn.endswith(".elm") and fn not in files: os.remove(os.path.join(d, fn))
        for fn, src in files.items():
            open(os.path.join(d, fn), "w", encoding="utf-8").write(src)
        meta = {"desc": desc}
        if any("import Float32" in src or "import Word8" in src for src in files.values()): meta["c_only"] = True
        json.dump(meta, open(os.path.join(d, "case.json"), "w"))
        rows[cid] = row
        if twin: a5agen.put_twin(cid, twin)
        elif os.path.exists(os.path.join(d, "expected.out")): os.remove(os.path.join(d, "expected.out"))
    for cid, (row, twin) in CASES_CONVERTED.items():
        rows[cid] = row
        if twin: a5agen.put_twin(cid, twin)
    path = os.path.join(HERE, "expected.tsv")
    out, seen = [], set()
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if not line.startswith("#") and f[0] in rows:
            out.append("\t".join((f[0],) + tuple(rows[f[0]])) + "\n"); seen.add(f[0])
        else:
            out.append(line)
    new = [cid for cid, _, _, _, _ in CASES_NEW if cid not in seen]
    if new and not any(l.startswith("# A5c") for l in out):
        out.append("# A5c (a5cgen.py): the built-in zero, the texts of the messages\n")
    for cid in new:
        out.append("\t".join((cid,) + tuple(rows[cid])) + "\n")
    open(path, "w", encoding="utf-8").writelines(out)
    print("wrote %d new cases, %d converted rows" % (len(CASES_NEW), len(CASES_CONVERTED)))


def expect(only):
    a5agen.TWINS = TWINS
    root = attach.ROOT
    elm0193 = os.path.join(root, "bin", "elm0193")
    old = os.path.join(root, "bin", "elmficA3b")
    home = tempfile.mkdtemp(prefix="a5ctwin-home-")
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
