#!/usr/bin/env python3
"""a5agen.py -- the A5a cases of the attach suite (inference of requirements, let generalization, defaulting, the
monomorphism restriction; docs/A5-INFERENCE-DESIGN.md sections 1 and 3, decisions D1 to D4, D6, D9).
Standard library only.

  python3 ficcus-tests/attach/a5agen.py --write                 # write cases/a5a-*/, the twins, the rows of expected.tsv
  python3 ficcus-tests/attach/a5agen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case

The expected output of a RUN case is never written by hand: it is the output of a *twin* program (in a5a-twins/<id>/).
  elm   plain Elm, compiled by bin/elm0193 and run by node
  oldc  a Ficcus program that the previous binary (bin/elmficA3b) compiles to C: the same program with the requirements
        written as `where` lines (a lifted let function with a signature, a typed value for a literal), run with gcc
The converted cases (section 3 of the note: rejections that now run) keep their sources; only their twin and their row
are here.  For the g71-* ones, g71expect.py holds the same outputs (its A5a block); --expect says when they disagree."""
import argparse, contextlib, io, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a5a-twins")
sys.path.insert(0, HERE)
import attach, mkhome

with contextlib.redirect_stdout(io.StringIO()):      # g71gen prints its rows when loaded
    import g71gen

TYPES, HELPERS, CASH, B3_TYPES, B4_TYPES = g71gen.TYPES, g71gen.HELPERS, g71gen.CASH, g71gen.B3_TYPES, g71gen.B4_TYPES


def main_of(decls, out, imports=""):
    return g71gen.MAIN.format(imports=imports, decls=decls.strip("\n") + "\n\n\nout =\n    " + out + "\n\n")


def blocks(*parts):
    return "\n\n".join(p.strip("\n") for p in parts if p) + "\n"


RUN = ("RUN", "c", "")


# id, desc, files, row, twin (kind, files) or None
CASES_NEW = [
    # ---- D1: unannotated top level functions infer their requirements
    ("a5a-top-infer-two-types", "D1: unannotated twice m = plus m m, and quad calling twice (inferred through an inferred scheme), at Money and Vec",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "twice m =\n    plus m m", "quad m =\n    twice (twice m)"),
                          "( quad (Money 2), quad (Vec 1 2), twice (Money 5) )")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS,
        "twice : a -> a\n    where\n        a has add : a -> a -> a\ntwice m =\n    plus m m",
        "quad : a -> a\n    where\n        a has add : a -> a -> a\nquad m =\n    twice (twice m)"),
        "( quad (Money 2), quad (Vec 1 2), twice (Money 5) )")})),
    ("a5a-top-infer-recursive", "D1: an unannotated recursive function whose requirement is inferred (rep n x doubles x n times)",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "rep n x =\n    if n <= 0 then\n        x\n\n    else\n        rep (n - 1) (plus x x)"),
                          "( rep 2 (Money 1), rep 1 (Vec 1 2) )")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS,
        "rep : Int -> a -> a\n    where\n        a has add : a -> a -> a\nrep n x =\n    if n <= 0 then\n        x\n\n    else\n        rep (n - 1) (plus x x)"),
        "( rep 2 (Money 1), rep 1 (Vec 1 2) )")})),
    ("a5a-cross-module", "D1: an inferred constrained function in module Lib (its scheme in the interface), used from Main at Money and Vec",
     {"Lib.elm": "module Lib exposing (Money(..), Vec(..), plus, twice)\n\n\n" + blocks(TYPES, HELPERS, "twice m =\n    plus m m"),
      "Main.elm": main_of("", "( twice (Money 2), twice (Vec 1 2) )", imports="import Lib exposing (Money(..), Vec(..), twice)")},
     RUN,
     ("oldc", {"Lib.elm": "module Lib exposing (Money(..), Vec(..), plus, twice)\n\n\n" + blocks(TYPES, HELPERS,
        "twice : a -> a\n    where\n        a has add : a -> a -> a\ntwice m =\n    plus m m"),
      "Main.elm": main_of("", "( twice (Money 2), twice (Vec 1 2) )", imports="import Lib exposing (Money(..), Vec(..), twice)")})),
    ("a5a-js-inferred", "D6: the JavaScript output refuses an inferred constrained function (half x = x / 2 with Cash in sight) and suggests a type annotation",
     {"Main.elm": main_of(blocks(CASH, "half x =\n    x / 2"), "half 3")},
     ("REJECT", "CONSTRAINED FUNCTIONS", "Main.half (no type annotation"), None),
    # ---- the subject decides (rules 2 and 3), D2, B4
    ("a5a-subject-decides", "rules 2 and 3: unannotated get1 t = get t and get2 w = get (get w): the member of the subject's type decides the result type",
     {"Main.elm": main_of(blocks(B4_TYPES, "get1 t =\n    get t", "get2 w =\n    get (get w)"),
                          "( get2 (W (T 41)) + 1, get1 (W (T 5)), get1 (T 3) )")},
     RUN,
     ("elm", {"Main.elm": main_of("type T\n    = T Int\n\n\ntype W\n    = W T", "( 41 + 1, T 5, 3 )")})),
    ("a5a-b2-chain", "D2: a written where whose second subject is decided by the first member (a has f : a -> b, b has g : b -> String)",
     {"Main.elm": main_of(blocks(
        "type T = T Int\n    where\n        g : T -> String\n        g (T n) = \"T\" ++ String.fromInt n",
        "type W = W T\n    where\n        f : W -> T\n        f (W t) = t\n\n        g : W -> String\n        g _ = \"W\"",
        "describe : a -> String\n    where\n        a has f : a -> b\n        b has g : b -> String\ndescribe x =\n    g (f x)"),
        "describe (W (T 7))")},
     RUN,
     ("elm", {"Main.elm": main_of("", "\"T7\"")})),
    ("a5a-b4-held-generic", "B4 inside an inferred function: pair w = let y = get w in ( y, y ) (y is held: the outer w decides it), at T and W",
     {"Main.elm": main_of(blocks(B4_TYPES, "pair w =\n    let\n        y =\n            get w\n    in\n    ( y, y )"),
                          "( pair (T 1), pair (W (T 2)) )")},
     RUN,
     ("elm", {"Main.elm": main_of("type T\n    = T Int", "( ( 1, 1 ), ( T 2, T 2 ) )")})),
    # ---- let generalization (L2), hold by determination
    ("a5a-let-two-types", "L2: a let function with its own requirement (plus x x) and a held one decided by the outer m (plus m m), used at Money and Vec",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "f m v =\n    let\n        g x =\n            ( plus x x, plus m m )\n    in\n    ( g m, g v )"),
                          "f (Money 1) (Vec 1 2)")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS,
        "g : b -> a -> ( a, b )\n    where\n        a has add : a -> a -> a\n        b has add as addB : b -> b -> b\ng m x =\n    ( plus x x, plus m m )",
        "f : Money -> Vec -> ( ( Money, Money ), ( Vec, Money ) )\nf m v =\n    ( g m m, g m v )"),
        "f (Money 1) (Vec 1 2)")})),
    ("a5a-let-outer-determined", "hold by determination: let g x = ( get w, plus x x ): the get w requirement is the outer w's, plus x x is g's own",
     {"Main.elm": main_of(blocks(B4_TYPES, TYPES, HELPERS, "k w =\n    let\n        g x =\n            ( get w, plus x x )\n    in\n    ( g (Money 1), g (Vec 1 1) )"),
                          "k (T 5)")},
     RUN,
     ("elm", {"Main.elm": main_of("type Money\n    = Money Int\n\n\ntype Vec\n    = Vec Int Int", "( ( 5, Money 2 ), ( 5, Vec 2 2 ) )")})),
    ("a5a-let-lambda", "D4: a let definition whose body is a lambda (g = \\x -> plus x x) is a function: generalized, used at Money and Vec",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "f m v =\n    let\n        g =\n            \\x -> plus x x\n    in\n    ( g m, g v )"),
                          "f (Money 2) (Vec 1 2)")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS), "( plus (Money 2) (Money 2), plus (Vec 1 2) (Vec 1 2) )")})),
    ("a5a-let-rem-two", "L3: a let function using remainderBy at Int and at Cash (generalized over `has rem`)",
     {"Main.elm": main_of(blocks(CASH), "let\n        h y =\n            remainderBy 4 y\n    in\n    ( h 9, h (Cash 900) )")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks(CASH), "( remainderBy 4 9, remainderBy (Cash 400) (Cash 900) )")})),
    ("a5a-div-two-customs", "a relaxed / in a top level and a let function at two custom types with div, and at a literal (Float by D3)",
     {"Main.elm": main_of(blocks(
        "type Cash\n    = Cash Int\n    where\n        div : Cash -> Cash -> Cash\n        div (Cash a) (Cash b) =\n            Cash (a // b)",
        "type Ratio\n    = Ratio Int Int\n    where\n        div : Ratio -> Ratio -> Ratio\n        div (Ratio a b) (Ratio c d) =\n            Ratio (a * d) (b * c)",
        "half x y =\n    x / y"),
        "let\n        q a b =\n            a / b\n    in\n    ( ( half (Cash 800) (Cash 4), half (Ratio 1 2) (Ratio 3 4) ), ( q (Cash 9) (Cash 3), q (Ratio 1 1) (Ratio 2 1) ), half 3 2 )")},
     RUN,
     ("elm", {"Main.elm": main_of("type Cash\n    = Cash Int\n\n\ntype Ratio\n    = Ratio Int Int",
        "( ( Cash 200, Ratio 4 6 ), ( Cash 3, Ratio 1 2 ), 3 / 2 )")})),
    # ---- the monomorphism restriction (D4)
    ("a5a-mr-let-value", "D4 (MR): a let value g = plus is not a function: not generalized, so its use at Money and Vec is a type mismatch",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "f m v =\n    let\n        g =\n            plus\n    in\n    ( g m m, g v v )"),
                          "f (Money 2) (Vec 1 2)")},
     ("REJECTC", "TYPE MISMATCH", "But `f` needs the 2nd argument to be:"), None),
    ("a5a-mr-top-value", "D4 (MR): a top level value pl = plus keeps its requirement on a type variable: reported, not inferred",
     {"Main.elm": main_of(blocks(TYPES, HELPERS, "pl =\n    plus"), "pl (Money 1) (Money 2)")},
     ("REJECTC", "MISSING CONSTRAINT", "pl : a -> a -> a"), None),
    # ---- defaulting (D3)
    ("a5a-default-top-value", "D3: top level values with literals at constrained functions: Int for add, Float for div",
     {"Main.elm": main_of(blocks(CASH, HELPERS, "halve : a -> a -> a\n    where\n        a has div : a -> a -> a\nhalve x y =\n    x / y",
                                 "three =\n    plus 1 2", "oneHalf =\n    halve 3 2"),
                          "( three, oneHalf, ( 7 / 2, 7 // 2, modBy 3 7 ) )")},
     RUN,
     ("elm", {"Main.elm": main_of("", "( 1 + 2, 3 / 2, ( 7 / 2, 7 // 2, modBy 3 7 ) )")})),
    ("a5a-undetermined-error", "D3: an undetermined subject that is not a number (zeroOf u : a with a has zero) is an error",
     {"Main.elm": main_of(blocks(TYPES, "zeroOf : () -> a\n    where\n        a has zero : a\nzeroOf _ =\n    zero",
                                 "f u =\n    Debug.toString (zeroOf u)"), "f ()")},
     ("REJECTC", "UNKNOWN MEMBER TYPE", "zero"), None),
    ("a5a-float-literal", "D3 and the A3b literal: unannotated scale x = x * 0.5 with Float32 in sight infers `has fromFloat`; at Float32 and Float",
     {"Main.elm": main_of(blocks("scale x =\n    x * 0.5"), "( Float32.toString (scale (Float32.fromFloat 3)), scale 3 )",
                          imports="import Float32 exposing (Float32)")},
     RUN,
     ("oldc", {"Main.elm": main_of(blocks("scale : number -> number\n    where\n        number has fromFloat : Float -> number\nscale x =\n    x * 0.5",
        "f3 : Float32\nf3 =\n    Float32.fromFloat 3", "t3 : Float\nt3 =\n    3"),
        "( Float32.toString (scale f3), scale t3 )", imports="import Float32 exposing (Float32)")})),
    # ---- rule 1 (D9)
    ("a5a-rule1-poly-member", "D9 (rule 1): a polymorphic member used at Int and String through one inferred requirement is one type per name: rejected",
     {"Main.elm": main_of(blocks(B3_TYPES, "both q =\n    ( choose q 1, choose q \"s\" )"), "both (Q 1)")},
     ("REJECTC", "MEMBER TYPE MISMATCH", "pick"), None),
]


CASH_ELM = "type Cash\n    = Cash Int"
CASH_OUT = lambda out: ("oldc", {"Main.elm": main_of(blocks(CASH), out)})
TWICE_SIG = "twice : a -> a\n    where\n        a has add : a -> a -> a\ntwice m =\n    plus m m"

# the section 3 cases whose outcome changes in A5a: id -> (row, twin)
CASES_CONVERTED = {
    "a3-err-ambiguous-literal": (RUN, ("oldc", {"Main.elm": None, "edit": [("Debug.log \"r\" (total [ 1, 2, 3 ])", "Debug.log \"r\" (total ints)"),
                                                                           ("\nmain :", "\nints : List Int\nints =\n    [ 1, 2, 3 ]\n\n\nmain :")]})),
    "a3-f7-err-literal-obligation": (RUN, ("oldc", {"Main.elm": None, "edit": [("smallest 3 2", "smallest three 2"),
                                                                               ("\nmain :", "\nthree : Int\nthree =\n    3\n\n\nmain :")]})),
    "a3-f8-err-let-div-two-types": (("REJECT", "NO MEMBER", "div : Int -> Int -> Int"), None),
    "constraint-ambiguous": (RUN, ("elm", {"Main.elm": main_of("", "Debug.toString 1")})),
    "constraint-let-fun-mono": (RUN, ("elm", {"Main.elm": main_of("type T\n    = T Int", "( 1, T 2 )")})),
    "constraint-no-signature": (RUN, ("oldc", {"Main.elm": None, "edit": [("\ntotal xs =", "\ntotal : List a -> a\n    where\n        a has zero : a\n        a has add : a -> a -> a\ntotal xs =")]})),
    "constraint-top-nosig-hidden": (RUN, ("elm", {"Main.elm": main_of("", "1")})),
    "constraint-top-nosig-type": (RUN, ("elm", {"Main.elm": main_of("", "1")})),
    "g71-q1-nosig-call": (RUN, ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS, TWICE_SIG), "( twice (Money 2), twice (Vec 1 2) )")})),
    "g71-q1-nosig-call-one-use": (RUN, ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS, TWICE_SIG), "twice (Money 2)")})),
    "g71-q3-let-two-types": (RUN, ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS, "g : a -> a\n    where\n        a has add : a -> a -> a\ng x =\n    plus x x"),
                                                                 "( g (Money 2), g (Vec 1 2) )")})),
    "g71-q3-lifted-nosig": (RUN, ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS, "g : a -> a\n    where\n        a has add : a -> a -> a\ng x =\n    plus x x"),
                                                                "( g (Money 2), g (Vec 1 2) )")})),
    "g71-q4-two-locals-nosig": (RUN, ("oldc", {"Main.elm": main_of(blocks(TYPES, HELPERS,
        "stats : List a -> a -> ( a, Order )\n    where\n        a has zero : a\n        a has add : a -> a -> a\n        a has compare : a -> a -> Order\n"
        "stats xs limit =\n    ( sum xs, cmp (sum xs) limit )"), "stats [ Money 1, Money 2 ] (Money 2)")})),
    "g71-q7-div-two": (RUN, CASH_OUT("( 3.5 / 4, Cash 800 / Cash 400 )")),
    "g71-q7-idiv-two": (RUN, CASH_OUT("( 9 // 4, Cash 800 // Cash 400 )")),
    "g71-q7-idiv-typed-int": (RUN, CASH_OUT("( 9 // 4, Cash 800 // Cash 400 )")),
    "g71-q7-modby-two": (RUN, CASH_OUT("( modBy 4 9, modBy (Cash 400) (Cash 900) )")),
    "g71-q7-idiv-lifted-sig": (RUN, CASH_OUT("( 9 // 4, Cash 800 // Cash 400 )")),
    "g71-q7-idiv-lifted-nosig": (RUN, CASH_OUT("( 9 // 4, Cash 800 // Cash 400 )")),
}


def twin_files(cid, twin):
    kind, files = twin
    if files.get("edit") is not None:       # the case's own sources with textual edits (the requirement written out)
        src = open(os.path.join(CASES, cid, "Main.elm"), encoding="utf-8").read()
        for old, new in files["edit"]:
            if old not in src: raise SystemExit("twin %s: %r not in Main.elm" % (cid, old))
            src = src.replace(old, new, 1)
        return kind, {"Main.elm": src}
    return kind, files


def put_twin(cid, twin):
    td = os.path.join(TWINS, cid)
    if os.path.isdir(td): shutil.rmtree(td)
    os.makedirs(td)
    kind, files = twin_files(cid, twin)
    open(os.path.join(td, "kind"), "w").write(kind + "\n")
    for fn, src in files.items():
        open(os.path.join(td, fn), "w", encoding="utf-8").write(src)


def write():
    rows = {}
    for cid, desc, files, row, twin in CASES_NEW:
        d = os.path.join(CASES, cid)
        os.makedirs(d, exist_ok=True)          # expected.out (written by --expect) stays
        for fn, src in files.items():
            open(os.path.join(d, fn), "w", encoding="utf-8").write(src)
        meta = {"desc": desc}
        if "import Float32" in files.get("Main.elm", ""): meta["c_only"] = True     # the overlay module exists only for the C output
        json.dump(meta, open(os.path.join(d, "case.json"), "w"))
        rows[cid] = row
        if twin: put_twin(cid, twin)
    for cid, (row, twin) in CASES_CONVERTED.items():
        rows[cid] = row
        if twin: put_twin(cid, twin)
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
    if new and not any(l.startswith("# A5a") for l in out):
        out.append("# A5a (a5agen.py): inference of requirements, let generalization, defaulting, the monomorphism restriction\n")
    for cid in new:
        out.append("\t".join((cid,) + tuple(rows[cid])) + "\n")
    open(path, "w", encoding="utf-8").writelines(out)
    print("wrote %d new cases, %d converted rows" % (len(CASES_NEW), len(CASES_CONVERTED)))


def run_twin(cid, elm0193, old, home):
    td = os.path.join(TWINS, cid)
    kind = open(os.path.join(td, "kind")).read().strip()
    work = tempfile.mkdtemp(prefix="a5atwin-")
    try:
        os.makedirs(os.path.join(work, "src"))
        for fn in os.listdir(td):
            if fn.endswith(".elm"): shutil.copy(os.path.join(td, fn), os.path.join(work, "src", fn))
        json.dump(attach.elm_json([]), open(os.path.join(work, "elm.json"), "w"))
        env = dict(os.environ, ELM_HOME=home)
        if kind == "elm":
            rc, out = attach.run([elm0193, "make", "src/Main.elm", "--output=out.js"], work, env)
            if rc != 0: raise SystemExit("twin %s: %s" % (cid, out))
            p = subprocess.run(["node", "-e", "require('./out.js').Elm.Main.init()"], cwd=work, capture_output=True, text=True, timeout=60)
            if p.returncode != 0: raise SystemExit("twin %s: node: %s" % (cid, p.stderr))
            return p.stdout
        rc, out = attach.run([old, "make", "src/Main.elm", "--output=x.c", "--no-rc"], work, env)
        if rc != 0: raise SystemExit("twin %s: %s" % (cid, out))
        b = subprocess.run(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-I", attach.RT, "x.c", "-o", "x", "-lm"], cwd=work, capture_output=True, text=True)
        if b.returncode != 0: raise SystemExit("twin %s: gcc: %s" % (cid, b.stderr))
        p = subprocess.run(["./x"], cwd=work, capture_output=True, text=True, timeout=60)
        if p.returncode != 0: raise SystemExit("twin %s: run: %s" % (cid, p.stderr))
        return p.stdout
    finally:
        shutil.rmtree(work, ignore_errors=True)


def expect(only):
    root = attach.ROOT
    elm0193 = os.path.join(root, "bin", "elm0193")
    old = os.path.join(root, "bin", "elmficA3b")
    home = tempfile.mkdtemp(prefix="a5atwin-home-")
    mkhome.make(home)
    g71 = {}
    with contextlib.redirect_stdout(io.StringIO()):
        exec(open(os.path.join(HERE, "g71expect.py")).read(), {"EXPECT": g71})
    try:
        ids = sorted(os.listdir(TWINS))
        if only: ids = [i for i in ids if i in only.split(",")]
        for cid in ids:
            out = run_twin(cid, elm0193, old, home)
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
