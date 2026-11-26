#!/usr/bin/env python3
"""a5bgen.py -- the A5b cases of the attach suite: bare names of attached functions (selectors; docs/A5-INFERENCE-DESIGN.md
section 2, decision D5).  Standard library only.

  python3 ficcus-tests/attach/a5bgen.py --write                 # write cases/a5b-*/, the twins, the rows of expected.tsv
  python3 ficcus-tests/attach/a5bgen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case

The expected output of a RUN case is never written by hand: it is the output of a *twin* program (in a5b-twins/<id>/).
  elm   plain Elm, compiled by bin/elm0193 and run by node
  oldc  a Ficcus program that the previous binary (bin/elmficA5a) compiles to C: the same program with each bare name
        written out (the qualified member `Money.add`, a helper with a `where` line, an annotated function), run with gcc
The converted cases (g71-q1-nosig-bare-member, g71-q2-missing-all, g71-q2-missing-one) keep their sources; only their
twin and their row are here.  g71expect.py holds the same outcomes (its A5b block); --expect says when they disagree."""
import argparse, contextlib, io, json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a5b-twins")
sys.path.insert(0, HERE)
import attach, mkhome
import a5agen

TYPES, HELPERS, CASH, B3_TYPES, B4_TYPES = a5agen.TYPES, a5agen.HELPERS, a5agen.CASH, a5agen.B3_TYPES, a5agen.B4_TYPES
main_of, blocks = a5agen.main_of, a5agen.blocks

RUN = ("RUN", "c", "")

MONEY_ELM = "type Money\n    = Money Int"
MONEY_VEC_ELM = "type Money\n    = Money Int\n\n\ntype Vec\n    = Vec Int Int"
TOTAL_SIG = "total : List a -> a\n    where\n        a has zero : a\n        a has add : a -> a -> a\ntotal xs =\n    List.foldl add zero xs"

LIB_TYPES = "module Lib exposing (Money(..), Vec(..))\n\n\n" + TYPES
LIB_OPAQUE = ("module Lib exposing (Money, mk)\n\n\n" + TYPES.split("\n\n\ntype Vec")[0] +
              "\n\n\nmk : Int -> Money\nmk n =\n    Money n\n")
# Lib2 has the type; Lib only passes values of it on: its members travel in Lib's interface, but Main cannot name the type
LIB2 = "module Lib2 exposing (Money(..))\n\n\n" + TYPES.split("\n\n\ntype Vec")[0] + "\n"
LIB_VIA = "module Lib exposing (mk)\n\nimport Lib2 exposing (Money(..))\n\n\nmk : Int -> Lib2.Money\nmk n =\n    Money n\n"

SCALE_TYPES = ("type Money\n    = Money Int\n    where\n        scale : Money -> Int -> Money\n        scale (Money a) k =\n            Money (a * k)\n\n\n"
               "type Vec\n    = Vec Float Float\n    where\n        scale : Float -> Vec -> Vec\n        scale k (Vec a b) =\n            Vec (a * k) (b * k)\n")
BOX_TYPES = ("type Box x\n    = Box x\n    where\n        unwrap : Box x -> x\n        unwrap (Box v) =\n            v\n\n\n"
             "type Tag\n    = Tag String\n    where\n        unwrap : Tag -> String\n        unwrap (Tag s) =\n            s\n")


# id, desc, files, row, twin (kind, files) or None
CASES_NEW = [
    # ---- selectors in inferred, let and top level code
    ("a5b-bare-inferred", "D5: total xs = List.foldl add zero xs without a signature: both bare names are selectors, total is inferred; at Money and Vec",
     {"Main.elm": main_of(blocks(TYPES, "total xs =\n    List.foldl add zero xs"), "( total [ Money 1, Money 2 ], total [ Vec 1 2, Vec 3 4 ] )")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(TYPES, TOTAL_SIG), "( total [ Money 1, Money 2 ], total [ Vec 1 2, Vec 3 4 ] )")})),
    ("a5b-let-two-types", "a let function using a selector (g x = add x x) generalized and used at Money and Vec",
     {"Main.elm": main_of(blocks(TYPES, "f m v =\n    let\n        g x =\n            add x x\n    in\n    ( g m, g v )"), "f (Money 2) (Vec 1 2)")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(TYPES), "( Money.add (Money 2) (Money 2), Vec.add (Vec 1 2) (Vec 1 2) )")})),
    ("a5b-value-typed", "a selector at a value with a type annotation (empty : Money; empty = zero) and in an expression of known type",
     {"Main.elm": main_of(blocks(TYPES, "empty : Money\nempty =\n    zero"), "( empty, add empty (Money 5), add (Vec 1 1) zero )")},
     RUN,
     ("elm", {"Main.elm": main_of(MONEY_VEC_ELM, "( Money 0, Money 5, Vec 1 1 )")})),
    ("a5b-default-literal", "D3: a top level value with a selector at literals (three = add 1 2) is defaulted to Int",
     {"Main.elm": main_of(blocks(TYPES, "three =\n    add 1 2"), "three")},
     RUN,
     ("elm", {"Main.elm": main_of("", "1 + 2")})),
    ("a5b-fromint", "a well known selector with a fixed argument type (fromInt : Int -> a) decided by the annotation",
     {"Main.elm": main_of(blocks(CASH, "c : Cash\nc =\n    fromInt 5"), "( c, add c (fromInt 1) )")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(CASH), "( Cash.fromInt 5, Cash.add (Cash.fromInt 5) (Cash.fromInt 1) )")})),
    ("a5b-mr-let-value", "D4 (MR): a let value g = add is not a function: not generalized, so its use at Money and Vec is a type mismatch",
     {"Main.elm": main_of(blocks(TYPES, "f m v =\n    let\n        g =\n            add\n    in\n    ( g m m, g v v )"), "f (Money 2) (Vec 1 2)")},
     ("REJECTC", "TYPE MISMATCH", "But `f` needs the 2nd argument to be:"), None),
    # ---- the selector's type: anti-unification
    ("a5b-subject-decides", "anti-unification: T.f : T -> Int and W.f : W -> T give f : a -> b; get2 w = f (f w) (the member decides b)",
     {"Main.elm": main_of(blocks(B4_TYPES, "get2 w =\n    f (f w)"), "( get2 (W (T 41)) + 1, f (W (T 5)), f (T 3) )")},
     RUN,
     ("elm", {"Main.elm": main_of("type T\n    = T Int", "( 41 + 1, T 5, 3 )")})),
    ("a5b-parameterized", "anti-unification with a type parameter: Box.unwrap : Box x -> x and Tag.unwrap : Tag -> String",
     {"Main.elm": main_of(blocks(BOX_TYPES), "( unwrap (Box 3), unwrap (Tag \"t\"), unwrap (Box [ 1 ]) )")},
     RUN,
     ("elm", {"Main.elm": main_of("", "( 3, \"t\", [ 1 ] )")})),
    ("a5b-shapes-differ", "shapes that do not line up (Money.scale : Money -> Int -> Money, Vec.scale : Float -> Vec -> Vec): not a selector, NAMING ERROR",
     {"Main.elm": main_of(blocks(SCALE_TYPES), "scale (Money 2) 3")},
     ("REJECT", "NAMING ERROR", "I cannot find a `scale` variable"), None),
    ("a5b-poly-member", "D9 (rule 1): the polymorphic member pick used bare at Int and String in one inferred function: one type per name",
     {"Main.elm": main_of(blocks(B3_TYPES, "both q =\n    ( pick q 1, pick q \"s\" )"), "both (Q 1)")},
     ("REJECTC", "MEMBER TYPE MISMATCH", "pick"), None),
    # ---- names that are not selectors
    ("a5b-typo", "a misspelled name (ad for add) is still a NAMING ERROR",
     {"Main.elm": main_of(blocks(TYPES, "total xs =\n    List.foldl ad zero xs"), "total [ Money 1 ]")},
     ("REJECT", "NAMING ERROR", "I cannot find a `ad` variable"), None),
    ("a5b-no-type-has-it", "D5: a well known name that no candidate type has (mul) is not a selector",
     {"Main.elm": main_of(blocks(TYPES), "mul (Money 1) (Money 2)")},
     ("REJECT", "NAMING ERROR", "I cannot find a `mul` variable"), None),
    ("a5b-not-named", "D5: a type whose members only travel in another interface (Lib passes on Lib2.Money) is not a candidate",
     {"Lib2.elm": LIB2, "Lib.elm": LIB_VIA, "Main.elm": main_of("", "add (mk 1) (mk 2)", imports="import Lib exposing (mk)")},
     ("REJECT", "NAMING ERROR", "I cannot find a `add` variable"), None),
    ("a5b-elm-naming", "an Elm program (no where block) keeps Elm's NAMING ERROR for an unbound add",
     {"Main.elm": main_of("total xs =\n    List.foldl add 0 xs", "total [ 1, 2 ]")},
     ("REJECT", "NAMING ERROR", "I cannot find a `add` variable"), None),
    # ---- imports (D5: any import form, opaque types count)
    ("a5b-import-exposing", "D5: types imported with exposing (Money(..), Vec(..)): bare add and zero",
     {"Lib.elm": LIB_TYPES, "Main.elm": main_of("", "( add (Money 1) zero, add zero (Vec 1 2) )", imports="import Lib exposing (Money(..), Vec(..))")},
     RUN,
     ("oldc", {"Lib.elm": LIB_TYPES, "Main.elm": main_of("", "( Money.add (Money 1) Money.zero, Vec.add Vec.zero (Vec 1 2) )", imports="import Lib exposing (Money(..), Vec(..))")})),
    ("a5b-import-qualified", "D5: a type imported qualified only (import Lib): bare add and zero",
     {"Lib.elm": LIB_TYPES, "Main.elm": main_of("", "add (Lib.Money 1) zero", imports="import Lib")},
     RUN,
     ("oldc", {"Lib.elm": LIB_TYPES, "Main.elm": main_of("", "Lib.Money.add (Lib.Money 1) Lib.Money.zero", imports="import Lib")})),
    ("a5b-import-opaque", "D5: an opaque type (exposing (Money)): bare add and zero",
     {"Lib.elm": LIB_OPAQUE, "Main.elm": main_of("", "add (mk 1) zero", imports="import Lib exposing (Money, mk)")},
     RUN,
     ("oldc", {"Lib.elm": LIB_OPAQUE, "Main.elm": main_of("", "Money.add (mk 1) Money.zero", imports="import Lib exposing (Money, mk)")})),
    ("a5b-cross-module", "an inferred function with selectors in Lib (total xs = List.foldl add zero xs), used from Main at Money and Vec",
     {"Lib.elm": "module Lib exposing (Money(..), Vec(..), total)\n\n\n" + blocks(TYPES, "total xs =\n    List.foldl add zero xs"),
      "Main.elm": main_of("", "( total [ Money 1, Money 2 ], total [ Vec 1 2, Vec 3 4 ] )", imports="import Lib exposing (Money(..), Vec(..), total)")},
     RUN,
     ("oldc", {"Lib.elm": "module Lib exposing (Money(..), Vec(..), total)\n\n\n" + blocks(TYPES, TOTAL_SIG),
      "Main.elm": main_of("", "( total [ Money 1, Money 2 ], total [ Vec 1 2, Vec 3 4 ] )", imports="import Lib exposing (Money(..), Vec(..), total)")})),
    ("a5b-sized", "a sized type is a candidate when imported: bare add at Float32",
     {"Main.elm": main_of("", "Float32.toString (add (Float32.fromFloat 1.5) (Float32.fromFloat 2))", imports="import Float32 exposing (Float32)")},
     RUN,
     ("oldc", {"Main.elm": main_of("", "Float32.toString (Float32.fromFloat 1.5 + Float32.fromFloat 2)", imports="import Float32 exposing (Float32)")})),
    # ---- shadowing: any binding wins
    ("a5b-shadow-top", "a top level add hides the selector in the whole module",
     {"Main.elm": main_of(blocks(TYPES, "add x y =\n    x ++ y"), "add \"a\" \"b\"")},
     RUN,
     ("elm", {"Main.elm": main_of("add x y =\n    x ++ y", "add \"a\" \"b\"")})),
    ("a5b-shadow-local", "a let-bound zero wins over the selector (add stays one)",
     {"Main.elm": main_of(blocks(TYPES, "f n =\n    let\n        zero =\n            n\n    in\n    add zero zero"), "f (Money 2)")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(TYPES), "Money.add (Money 2) (Money 2)")})),
    # ---- JavaScript
    ("a5b-js-refused", "the JavaScript output refuses a selector like a constrained function",
     {"Main.elm": main_of(blocks(TYPES, "two : Money\ntwo =\n    add (Money 1) (Money 1)"), "two")},
     ("REJECT", "CONSTRAINED FUNCTIONS", "the attached function `add` by its bare name"), None),
]


# the G71 cases whose outcome changes in A5b: id -> (row, twin)
CASES_CONVERTED = {
    "g71-q1-nosig-bare-member": (RUN, ("oldc", {"Main.elm": None, "edit": [("\ntotal xs =", "\n" + TOTAL_SIG.split("\ntotal xs =")[0] + "\ntotal xs =")]})),
    "g71-q2-missing-all": (("REJECTC", "MISSING CONSTRAINT", "a has add : a -> a -> a"), None),
    "g71-q2-missing-one": (("REJECTC", "MISSING CONSTRAINT", "a has zero : a"), None),
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
        if "import Float32" in files.get("Main.elm", ""): meta["c_only"] = True
        json.dump(meta, open(os.path.join(d, "case.json"), "w"))
        rows[cid] = row
        if twin: a5agen.put_twin(cid, twin)
        elif os.path.exists(os.path.join(d, "expected.out")): os.remove(os.path.join(d, "expected.out"))
    for cid, (row, twin) in CASES_CONVERTED.items():
        rows[cid] = row
        if twin: a5agen.put_twin(cid, twin)
        elif os.path.exists(os.path.join(CASES, cid, "expected.out")) and row[0] != "RUN":
            os.remove(os.path.join(CASES, cid, "expected.out"))
    path = os.path.join(HERE, "expected.tsv")
    out, seen = [], set()
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if not line.startswith("#") and f[0] in rows:
            out.append("\t".join((f[0],) + tuple(rows[f[0]])) + "\n"); seen.add(f[0])
        else:
            out.append(line)
    new = [cid for cid, _, _, _, _ in CASES_NEW if cid not in seen]
    if new and not any(l.startswith("# A5b") for l in out):
        out.append("# A5b (a5bgen.py): bare names of attached functions (selectors)\n")
    for cid in new:
        out.append("\t".join((cid,) + tuple(rows[cid])) + "\n")
    open(path, "w", encoding="utf-8").writelines(out)
    print("wrote %d new cases, %d converted rows" % (len(CASES_NEW), len(CASES_CONVERTED)))


def expect(only):
    a5agen.TWINS = TWINS
    root = attach.ROOT
    elm0193 = os.path.join(root, "bin", "elm0193")
    old = os.path.join(root, "bin", "elmficA5a")
    home = tempfile.mkdtemp(prefix="a5btwin-home-")
    mkhome.make(home)
    g71 = {}
    with contextlib.redirect_stdout(io.StringIO()):
        exec(open(os.path.join(HERE, "g71expect.py")).read(), {"EXPECT": g71})
    try:
        ids = sorted(os.listdir(TWINS))
        if only: ids = [i for i in ids if i in only.split(",")]
        for cid in ids:
            out = a5agen.run_twin(cid, elm0193, old, home)
            open(os.path.join(CASES, cid, "expected.out"), "w", encoding="utf-8").write(out)
            note = ""
            if cid in g71 and (g71[cid][0] != "RUN" or g71[cid][1] != out): note = "   g71expect.py differs: %r" % (g71[cid],)
            print("%-28s %r%s" % (cid, out, note))
    finally:
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true"); ap.add_argument("--expect", action="store_true"); ap.add_argument("--only")
    a = ap.parse_args()
    if a.write: write()
    if a.expect: expect(a.only)
