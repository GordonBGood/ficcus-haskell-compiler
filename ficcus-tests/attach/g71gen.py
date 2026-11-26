#!/usr/bin/env python3
"""g71gen.py -- writes the G71 inference cases (cases/g71-*) and prints their expected.tsv lines.

G71 records what the compiler does today (no change) with the inference of member constraints and local definitions:
unannotated top level functions, missing constraints, unannotated let functions, two let functions on one outer variable,
captures, the review 1 findings B3 and B4, and which let definitions using `/`, `//`, `modBy`, `+`, `compare`, `<` are
generalized.  Every case is checked in C mode (RUN c, or REJECTC with the report title: `--output=x.c`).
The report is docs/attach/G71-INFERENCE.md.  Run from this directory: python3 g71gen.py [--write]"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

# the two types of G70's shape (members zero, add, compare) and the constrained helpers the cases call
TYPES = """type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b


type Vec = Vec Int Int
    where
        zero : Vec
        zero = Vec 0 0

        add : Vec -> Vec -> Vec
        add (Vec a b) (Vec c d) = Vec (a + c) (b + d)

        compare : Vec -> Vec -> Order
        compare (Vec a b) (Vec c d) = Basics.compare ( a, b ) ( c, d )
"""

HELPERS = """sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs


plus : a -> a -> a
    where
        a has add : a -> a -> a
plus x y =
    add x y


cmp : a -> a -> Order
    where
        a has compare : a -> a -> Order
cmp x y =
    compare x y
"""

# every well known number member (A3), so `+`, `-`, `*`, `/`, `//`, `modBy`, `compare`, `<` all work on Cash
CASH = """type Cash
    = Cash Int
    where
        add : Cash -> Cash -> Cash
        add (Cash a) (Cash b) = Cash (a + b)

        sub : Cash -> Cash -> Cash
        sub (Cash a) (Cash b) = Cash (a - b)

        mul : Cash -> Cash -> Cash
        mul (Cash a) (Cash b) = Cash (a * b // 100)

        pow : Cash -> Cash -> Cash
        pow (Cash a) (Cash b) = Cash (a ^ (b // 100))

        neg : Cash -> Cash
        neg (Cash a) = Cash (negate a)

        abs : Cash -> Cash
        abs (Cash a) = Cash (Basics.abs a)

        fromInt : Int -> Cash
        fromInt n = Cash (n * 100)

        compare : Cash -> Cash -> Order
        compare (Cash a) (Cash b) = Basics.compare a b

        eq : Cash -> Cash -> Bool
        eq (Cash a) (Cash b) = a == b

        div : Cash -> Cash -> Cash
        div (Cash a) (Cash b) = Cash (a * 100 // b)

        idiv : Cash -> Cash -> Cash
        idiv (Cash a) (Cash b) = Cash ((a // b) * 100)

        mod : Cash -> Cash -> Cash
        mod (Cash m) (Cash x) = Cash (modBy m x)

        rem : Cash -> Cash -> Cash
        rem (Cash m) (Cash x) = Cash (remainderBy m x)
"""

MAIN = """module Main exposing (main)

{imports}

{decls}

main : Program () () ()
main =
    Platform.worker
        {{ init =
            \\_ ->
                let
                    _ =
                        Debug.log "r" out
                in
                ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }}
"""

# B3/B4 (docs/review/repros): their own types
B3_TYPES = """type Q = Q Int
    where
        pick : Q -> c -> c
        pick _ x = x

        idq : Q -> Q
        idq q = q


choose : a -> c -> c
    where
        a has pick : a -> c -> c
choose x y =
    pick x y
"""

B4_TYPES = """type T = T Int
    where
        f : T -> Int
        f (T n) = n


type W = W T
    where
        f : W -> T
        f (W t) = t


get : a -> b
    where
        a has f : a -> b
get x =
    f x
"""

K_MODULE = """module K exposing (Q(..), k{extra_exp})


{types}

k t =
    let
        y =
            choose t
    in
    ( y, Q.idq t )
{extra}"""

MV = "( Money 1, Money 2 )"


def h(body):
    return body.strip("\n") + "\n\n"


# id: (question, desc, prelude parts, declarations, out expression, expectation, expected output or None, extra modules)
# expectation: ("RUN",) or ("REJECTC", title, text)
CASES = [
    # ---- 1: unannotated top level functions
    ("q1-nosig-qualified", "1", "control: unannotated top level function calling members on a known type (Money.add m m)", "TH",
     "twice m =\n    Money.add m m\n",
     "twice (Money 2)", ("RUN",), "r: Money 4\n"),
    ("q1-nosig-bare-member", "1", "unannotated top level function naming a member bare (`add`, `zero`) outside any constraint", "T",
     "total xs =\n    List.foldl add zero xs\n",
     "total [ Money 1, Money 2 ]", None, None),
    ("q1-nosig-call", "1", "unannotated top level function calling a constrained function generically (plus m m): is `a has add` inferred?", "TH",
     "twice m =\n    plus m m\n",
     "( twice (Money 2), twice (Vec 1 2) )", None, None),
    ("q1-nosig-call-one-use", "1", "as q1-nosig-call, used at one type only (Money): still not inferred?", "TH",
     "twice m =\n    plus m m\n",
     "twice (Money 2)", None, None),
    ("q1-nosig-lt", "1", "unannotated top level function using `<` (comparable bundle) at Money, Vec, Int, String", "T",
     "smaller a b =\n    if a < b then\n        a\n\n    else\n        b\n",
     "( ( smaller (Money 3) (Money 2), smaller (Vec 1 2) (Vec 1 1) ), ( smaller 3 2, smaller \"b\" \"a\" ) )", None, None),
    ("q1-nosig-compare", "1", "unannotated top level function using Basics.compare at Money, Vec, Int, String", "T",
     "order a b =\n    compare a b\n",
     "( ( order (Money 3) (Money 2), order (Vec 1 2) (Vec 1 3) ), ( order 3 2, order \"a\" \"b\" ) )", None, None),
    ("q1-nosig-eq", "1", "unannotated top level function using `==` at Money (no eq member), Vec, Int", "T",
     "same a b =\n    a == b\n",
     "( same (Money 3) (Money 3), same (Vec 1 2) (Vec 1 3), same 3 2 )", None, None),
    ("q1-nosig-plus", "1", "unannotated top level function using `+` (number bundle) at Cash (every number member), Int, Float", "C",
     "dbl x =\n    x + x\n",
     "( dbl (Cash 2), dbl 3, dbl 1.5 )", None, None),
    ("q1-nosig-plus-money", "1", "unannotated top level function using `+` at Money (only add, zero, compare): the number bundle is not complete", "T",
     "dbl x =\n    x + x\n",
     "dbl (Money 2)", None, None),
    # ---- 2: annotated, missing constraints
    ("q2-missing-all", "2", "annotated `List a -> a` using the members add, zero with no constraint (MISSING CONSTRAINT)", "T",
     "total : List a -> a\ntotal xs =\n    List.foldl add zero xs\n",
     "total [ Money 1 ]", None, None),
    ("q2-missing-all-call", "2", "annotated `a -> a` calling the constrained `plus` with no constraint", "TH",
     "twice : a -> a\ntwice m =\n    plus m m\n",
     "twice (Money 2)", None, None),
    ("q2-missing-one", "2", "annotated with `a has add` but uses `zero` too", "T",
     "total : List a -> a\n    where\n        a has add : a -> a -> a\ntotal xs =\n    List.foldl add zero xs\n",
     "total [ Money 1 ]", None, None),
    ("q2-missing-compare", "2", "annotated with add and zero, calls the constrained `cmp` (needs `a has compare`)", "TH",
     "check : List a -> a -> Order\n    where\n        a has zero : a\n        a has add : a -> a -> a\ncheck xs limit =\n    cmp (sum xs) limit\n",
     "check [ Money 1 ] (Money 3)", None, None),
    ("q2-lt-plain-var", "2", "annotated `a -> a -> a` using `<` (needs comparable or `a has compare`)", "T",
     "smaller : a -> a -> a\nsmaller a b =\n    if a < b then\n        a\n\n    else\n        b\n",
     "smaller (Money 3) (Money 2)", None, None),
    # ---- 3: unannotated local functions
    ("q3-let-once", "3", "unannotated let function calling `plus` generically, used once (outer annotated Money -> Money)", "TH",
     "f : Money -> Money\nf m =\n    let\n        g x =\n            plus x x\n    in\n    g m\n",
     "f (Money 2)", None, None),
    ("q3-let-twice-one-type", "3", "unannotated let function calling `plus`, used twice at Money", "TH",
     "f : Money -> Money\nf m =\n    let\n        g x =\n            plus x x\n    in\n    g (g m)\n",
     "f (Money 2)", None, None),
    ("q3-let-two-types", "3", "unannotated let function calling `plus`, used at Money and at Vec", "TH",
     "f : Money -> Vec -> ( Money, Vec )\nf m v =\n    let\n        g x =\n            plus x x\n    in\n    ( g m, g v )\n",
     "f (Money 2) (Vec 1 2)", None, None),
    ("q3-let-two-types-elm", "3", "Elm without members: unannotated let function using `+`, used at Int and Float (Elm generalizes number)", "",
     "f : Int -> Float -> ( Int, Float )\nf m v =\n    let\n        g x =\n            x + x\n    in\n    ( g m, g v )\n",
     "f 2 1.5", None, None),
    ("q3-lifted-two-types", "3", "q3-let-two-types with g lifted to top level with a signature (a has add)", "TH",
     "g : a -> a\n    where\n        a has add : a -> a -> a\ng x =\n    plus x x\n\n\nf : Money -> Vec -> ( Money, Vec )\nf m v =\n    ( g m, g v )\n",
     "f (Money 2) (Vec 1 2)", None, None),
    ("q3-lifted-nosig", "3", "q3-let-two-types with g lifted to top level without a signature", "TH",
     "g x =\n    plus x x\n\n\nf : Money -> Vec -> ( Money, Vec )\nf m v =\n    ( g m, g v )\n",
     "f (Money 2) (Vec 1 2)", None, None),
    # ---- 4: two local functions needing different members of the outer variable
    ("q4-two-locals-bare", "4", "outer `a has zero, add, compare`; let total (bare add, zero) and check (bare compare); used at Money and Vec", "T",
     "stats : List a -> a -> ( a, Order )\n    where\n        a has zero : a\n        a has add : a -> a -> a\n        a has compare : a -> a -> Order\n"
     "stats xs limit =\n    let\n        total ys =\n            List.foldl add zero ys\n\n        check y =\n            compare y limit\n    in\n    ( total xs, check (total xs) )\n",
     "( stats [ Money 1, Money 2 ] (Money 2), stats [ Vec 1 2, Vec 3 4 ] (Vec 9 0) )", None, None),
    ("q4-two-locals-call", "4", "as q4-two-locals-bare, the locals call the constrained `sum` and `cmp`", "TH",
     "stats : List a -> a -> ( a, Order )\n    where\n        a has zero : a\n        a has add : a -> a -> a\n        a has compare : a -> a -> Order\n"
     "stats xs limit =\n    let\n        total ys =\n            sum ys\n\n        check y =\n            cmp y limit\n    in\n    ( total xs, check (total xs) )\n",
     "( stats [ Money 1, Money 2 ] (Money 2), stats [ Vec 1 2, Vec 3 4 ] (Vec 9 0) )", None, None),
    ("q4-two-locals-concrete", "4", "outer annotated at Money; locals call `sum` and `cmp` (the outer type settles both)", "TH",
     "stats : List Money -> Money -> ( Money, Order )\n"
     "stats xs limit =\n    let\n        total ys =\n            sum ys\n\n        check y =\n            cmp y limit\n    in\n    ( total xs, check (total xs) )\n",
     "stats [ Money 1, Money 2 ] (Money 2)", None, None),
    ("q4-two-locals-nosig", "4", "outer unannotated; locals call `sum` and `cmp`; outer used at Money", "TH",
     "stats xs limit =\n    let\n        total ys =\n            sum ys\n\n        check y =\n            cmp y limit\n    in\n    ( total xs, check (total xs) )\n",
     "stats [ Money 1, Money 2 ] (Money 2)", None, None),
    ("q4-two-locals-nosig-pinned", "4", "outer unannotated; locals call `sum` and `cmp`; the body also calls Money.compare, which pins the outer variable to Money", "TH",
     "stats xs limit =\n    let\n        total ys =\n            sum ys\n\n        check y =\n            cmp y limit\n    in\n    ( total xs, check (total xs), Money.compare limit limit )\n",
     "stats [ Money 1, Money 2 ] (Money 2)", None, None),
    ("q4-lifted-one", "4", "q4-two-locals-call with check lifted to top level (signature a has compare, limit a parameter)", "TH",
     "check : a -> a -> Order\n    where\n        a has compare : a -> a -> Order\ncheck limit y =\n    cmp y limit\n\n\n"
     "stats : List a -> a -> ( a, Order )\n    where\n        a has zero : a\n        a has add : a -> a -> a\n        a has compare : a -> a -> Order\n"
     "stats xs limit =\n    let\n        total ys =\n            sum ys\n    in\n    ( total xs, check limit (total xs) )\n",
     "( stats [ Money 1, Money 2 ] (Money 2), stats [ Vec 1 2, Vec 3 4 ] (Vec 9 0) )", None, None),
    # ---- 5: captures
    ("q5-capture", "5", "outer `a has add`; let move captures the parameter base and uses bare add; at Money and Vec", "T",
     "shift : a -> List a -> List a\n    where\n        a has add : a -> a -> a\nshift base xs =\n    let\n        move y =\n            add y base\n    in\n    List.map move xs\n",
     "( shift (Money 10) [ Money 1, Money 2 ], shift (Vec 10 20) [ Vec 1 2 ] )", None, None),
    ("q5-capture-call", "5", "as q5-capture, move calls the constrained `plus`", "TH",
     "shift : a -> List a -> List a\n    where\n        a has add : a -> a -> a\nshift base xs =\n    let\n        move y =\n            plus y base\n    in\n    List.map move xs\n",
     "( shift (Money 10) [ Money 1, Money 2 ], shift (Vec 10 20) [ Vec 1 2 ] )", None, None),
    ("q5-capture-concrete", "5", "outer annotated at Money; let move captures base and calls `plus`", "TH",
     "shift : Money -> List Money -> List Money\nshift base xs =\n    let\n        move y =\n            plus y base\n    in\n    List.map move xs\n",
     "shift (Money 10) [ Money 1, Money 2 ]", None, None),
    ("q5-lifted", "5", "q5-capture with move lifted to top level, base a parameter, signature a has add; partially applied", "TH",
     "move : a -> a -> a\n    where\n        a has add : a -> a -> a\nmove base y =\n    plus y base\n\n\n"
     "shift : a -> List a -> List a\n    where\n        a has add : a -> a -> a\nshift base xs =\n    List.map (move base) xs\n",
     "( shift (Money 10) [ Money 1, Money 2 ], shift (Vec 10 20) [ Vec 1 2 ] )", None, None),
    # ---- 7: let generalization of the relaxed operators and bundles (Cash has every number member)
    ("q7-div-float", "7", "let h y = y / 4 at two Float values, Cash in sight", "C",
     "out =\n    let\n        h y =\n            y / 4\n    in\n    ( h 3, h 2.5 )\n", None, None, None),
    ("q7-div-two", "7", "let h y = y / 4 at Float and at Cash", "C",
     "out =\n    let\n        h y =\n            y / 4\n    in\n    ( h 3.5, h (Cash 800) )\n", None, None, None),
    ("q7-idiv-two", "7", "let h y = y // 4 at Int and at Cash", "C",
     "out =\n    let\n        h y =\n            y // 4\n    in\n    ( h 9, h (Cash 800) )\n", None, None, None),
    ("q7-modby-two", "7", "let h y = modBy 4 y at Int and at Cash", "C",
     "out =\n    let\n        h y =\n            modBy 4 y\n    in\n    ( h 9, h (Cash 900) )\n", None, None, None),
    ("q7-plus-two", "7", "let h y = y + y at Int, Float and Cash", "C",
     "out =\n    let\n        h y =\n            y + y\n    in\n    ( h 1, h 1.5, h (Cash 2) )\n", None, None, None),
    ("q7-compare-two", "7", "let c a b = compare a b at Int, String and Cash", "C",
     "out =\n    let\n        c a b =\n            compare a b\n    in\n    ( c 1 2, c \"b\" \"a\", c (Cash 1) (Cash 1) )\n", None, None, None),
    ("q7-lt-two", "7", "let l a b = a < b at Int, String and Cash", "C",
     "out =\n    let\n        l a b =\n            a < b\n    in\n    ( l 1 2, l \"b\" \"a\", l (Cash 1) (Cash 2) )\n", None, None, None),
    ("q7-idiv-int", "7", "let h y = y // 4 at Int only, Cash in sight (Elm's type kept?)", "C",
     "out =\n    let\n        h y =\n            y // 4\n    in\n    ( h 9, h 10 )\n", None, None, None),
    ("q7-idiv-typed-int", "7", "let h y = y // 4 at a typed Int (nine : Int) and at Cash", "C",
     "nine : Int\nnine =\n    9\n\n\nout =\n    let\n        h y =\n            y // 4\n    in\n    ( h nine, h (Cash 800) )\n", None, None, None),
    ("q7-modby-int", "7", "let h y = modBy 4 y at Int only, Cash in sight", "C",
     "out =\n    let\n        h y =\n            modBy 4 y\n    in\n    ( h 9, h 10 )\n", None, None, None),
    ("q7-idiv-lifted-sig", "7", "q7-idiv-two lifted: top level h : number -> number with number has idiv, used at 9 and at Cash", "C",
     "h : number -> number\n    where\n        number has idiv : number -> number -> number\nh y =\n    y // 4\n\n\nout =\n    ( h 9, h (Cash 800) )\n", None, None, None),
    ("q7-idiv-lifted-sig-typed", "7", "as q7-idiv-lifted-sig, the Int use is a typed value (nine : Int), not a literal", "C",
     "h : number -> number\n    where\n        number has idiv : number -> number -> number\nh y =\n    y // 4\n\n\nnine : Int\nnine =\n    9\n\n\nout =\n    ( h nine, h (Cash 800) )\n", None, None, None),
    ("q7-idiv-lifted-nosig", "7", "q7-idiv-two lifted without a signature: top level h y = y // 4 at 9 and at Cash", "C",
     "h y =\n    y // 4\n\n\nout =\n    ( h 9, h (Cash 800) )\n", None, None, None),
    ("q7-div-cash-only", "7", "let h y = y / 4 at Cash only (F4: held, settled by its use)", "C",
     "out =\n    let\n        h y =\n            y / 4\n    in\n    ( h (Cash 300), h (Cash 800) )\n", None, None, None),
]

# ---- 8: pure Elm (no members), run as JS and C; expected.out is elm0193's output
ELM_CASES = [
    ("elm-nosig-bundles", "8", "pure Elm: unannotated top level functions with <, compare, ==, + at Int, Float, String",
     "smaller a b =\n    if a < b then\n        a\n\n    else\n        b\n\n\norder a b =\n    compare a b\n\n\nsame a b =\n    a == b\n\n\ndbl x =\n    x + x\n",
     "( ( smaller 3 2, smaller \"b\" \"a\", order 3 2 ), ( same 3 3, dbl 3, dbl 1.5 ) )"),
    ("elm-let-ops", "8", "pure Elm: let functions with /, //, modBy at one type each, and +, compare, < at two types each",
     "", "let\n        hd y =\n            y / 4\n\n        hi y =\n            y // 4\n\n        hm y =\n            modBy 4 y\n\n        hp y =\n            y + y\n\n        hc a b =\n            compare a b\n\n        hl a b =\n            a < b\n    in\n    ( ( hd 3, hd 2.5, hi 9 ), ( hi 10, hm 9, hm 10 ), ( ( hp 1, hp 1.5 ), ( hc 1 2, hc \"b\" \"a\" ), ( hl 1 2, hl \"b\" \"a\" ) ) )"),
    ("elm-lt-plain-var", "8", "pure Elm: annotated a -> a -> a using < (Elm's TYPE MISMATCH)",
     "smaller : a -> a -> a\nsmaller a b =\n    if a < b then\n        a\n\n    else\n        b\n", "smaller 3 2"),
]

# ---- 6: B3 and B4 of review 1
B_CASES = [
    ("b3-repro", "6", "review 1 B3 repro: let y = choose t in k, k used at Int and String", B3_TYPES,
     "k t =\n    let\n        y =\n            choose t\n    in\n    ( y, Q.idq t )\n",
     "( Tuple.first (k (Q 1)) 1, Tuple.first (k (Q 1)) \"s\" )"),
    ("b3-nolet", "6", "B3 control: k t = ( choose t, Q.idq t ) without the let", B3_TYPES,
     "k t =\n    ( choose t, Q.idq t )\n",
     "( Tuple.first (k (Q 1)) 1, Tuple.first (k (Q 1)) \"s\" )"),
    ("b3-same-type", "6", "B3 control: k used at Int twice", B3_TYPES,
     "k t =\n    let\n        y =\n            choose t\n    in\n    ( y, Q.idq t )\n",
     "( Tuple.first (k (Q 1)) 1, Tuple.first (k (Q 1)) 2 )"),
    ("b4-let", "6", "review 1 B4 repro: let y = get (get w)", B4_TYPES,
     "h w =\n    let\n        y =\n            get (get w)\n    in\n    ( y + 1, W.f w )\n", "h (W (T 41))"),
    ("b4-pipe", "6", "B4 as a pipeline: let y = w |> get |> get", B4_TYPES,
     "h w =\n    let\n        y =\n            w |> get |> get\n    in\n    ( y + 1, W.f w )\n", "h (W (T 41))"),
    ("b4-two-bindings", "6", "B4 as two bindings: m = get w, y = get m", B4_TYPES,
     "h w =\n    let\n        m =\n            get w\n\n        y =\n            get m\n    in\n    ( y + 1, W.f w )\n", "h (W (T 41))"),
    ("b4-nolet", "6", "B4 without the let: ( get (get w) + 1, W.f w )", B4_TYPES,
     "h w =\n    ( get (get w) + 1, W.f w )\n", "h (W (T 41))"),
]

# B3 across a module: k's exported type depends on a use inside K
B3_MODULE = [
    ("b3-module-use", "6", "B3 across modules: K has a use of k at Float; Main uses k at String",
     "\n\nkf : Float\nkf =\n    Tuple.first (k (Q 1)) 1.5\n", ", kf", "Tuple.first (K.k (K.Q 1)) \"s\""),
    ("b3-module-nouse", "6", "B3 across modules: no use of k inside K; Main uses k at Int and String",
     "", "", "( Tuple.first (K.k (K.Q 1)) 1, Tuple.first (K.k (K.Q 1)) \"s\" )"),
]

# observed results, filled in from the runs (see G71-INFERENCE.md); id -> ("RUN", output) or ("REJECTC", title, text)
EXPECT = {}
try:
    exec(open(os.path.join(HERE, "g71expect.py")).read())
except FileNotFoundError:
    pass


def prelude(parts):
    s = ""
    if "T" in parts: s += h(TYPES) + "\n"
    if "H" in parts: s += h(HELPERS) + "\n"
    if "C" in parts: s += h(CASH) + "\n"
    return s


def all_cases():
    """yields (cid, desc, files)"""
    for (name, q, desc, parts, decls, out, _w, _o) in CASES:
        d = prelude(parts) + decls.rstrip("\n") + "\n\n\n"
        if out is not None: d += "out =\n    " + out + "\n\n\n"
        yield "g71-" + name, "G71 question %s: %s" % (q, desc), {"Main.elm": MAIN.format(imports="", decls=d.rstrip("\n") + "\n\n")}
    for (name, q, desc, decls, out) in ELM_CASES:
        d = (decls.rstrip("\n") + "\n\n\n" if decls else "") + "out =\n    " + out + "\n\n"
        yield "g71-" + name, "G71 question %s: %s" % (q, desc), {"Main.elm": MAIN.format(imports="", decls=d)}
    for (name, q, desc, types, decls, out) in B_CASES:
        d = h(types) + "\n" + decls.rstrip("\n") + "\n\n\nout =\n    " + out + "\n\n"
        yield "g71-" + name, "G71 question %s: %s" % (q, desc), {"Main.elm": MAIN.format(imports="", decls=d)}
    for (name, q, desc, extra, extra_exp, out) in B3_MODULE:
        k = K_MODULE.format(types=h(B3_TYPES), extra=extra, extra_exp=extra_exp)
        yield "g71-" + name, "G71 question %s: %s" % (q, desc), {"K.elm": k, "Main.elm": MAIN.format(imports="import K", decls="out =\n    " + out + "\n\n")}


def write(cid, desc, files, out):
    d = os.path.join(HERE, "cases", cid)
    os.makedirs(d, exist_ok=True)
    for name, text in files.items():
        open(os.path.join(d, name), "w").write(text)
    json.dump({"desc": desc}, open(os.path.join(d, "case.json"), "w"), indent=1)
    p = os.path.join(d, "expected.out")
    if out is not None: open(p, "w").write(out)
    elif os.path.exists(p): os.remove(p)


def main():
    do = "--write" in sys.argv
    lines = []
    for cid, desc, files in all_cases():
        want = EXPECT.get(cid)
        if want is None: lines.append("# %s\t(not yet observed)" % cid); out = None
        elif want[0] == "RUN": lines.append("%s\tRUN\t%s\t" % (cid, want[2] if len(want) > 2 else "c")); out = want[1]
        else: lines.append("%s\tREJECTC\t%s\t%s" % (cid, want[1], want[2])); out = None
        if do: write(cid, desc, files, out)
    print("\n".join(lines))


main()
