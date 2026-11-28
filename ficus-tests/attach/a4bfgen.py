#!/usr/bin/env python3
"""a4bfgen.py -- the A4bf cases of the attach suite: the fixes of the A4b review (docs/A4B-REVIEW.md) M1 (derived compare/hash
over types that refer to each other at growing arguments), M2 (a derived member over an extensible-record field), F1
(`a has compare`/`a has hash` at an open record), F2 (a written `hash` of another type inside a derived one), F3 (`derive
compare`/`hash` beside a written `eq`).  Each reproducer of the review is an expected rejection; the RUN cases show what must
still work beside them (a regular group of types that refer to each other; a record whose row is closed later).
Standard library only.  Standalone: it imports only attach and mkhome, so a `--write` cannot rewrite the rows or files of
another generator.  The helpers (MAIN, GROUP, TWINLIB, the writer, the twins) are those of a4bgen.py.

  python3 ficus-tests/attach/a4bfgen.py --write                 # write cases/a4bf-*/, a4bf-twins/ and the rows of expected.tsv
  python3 ficus-tests/attach/a4bfgen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case

The expected output of a RUN case is never written by hand: it is the output of its twin, plain Elm compiled by bin/elm0193
and run by node (see a4bgen.py for the representations)."""
import argparse, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a4bf-twins")
sys.path.insert(0, HERE)
import attach, mkhome

MAIN = """

logAll : List String -> ()
logAll items =
    List.foldl (\\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
"""

# the generic report of a list of values of one comparable type: the compare matrix, the operators, the stable sort (as the
# original positions), Dict and Set keys, the position of the maximum.  The same text in the Ficus program and in its twin.
GROUP = """

indexed : List a -> List ( a, Int )
indexed xs =
    List.indexedMap (\\i x -> ( x, i )) xs


group : String -> List comparable -> String
group label xs =
    label
        ++ " "
        ++ Debug.toString
            ( ( List.map (\\a -> List.map (\\b -> compare a b) xs) xs
              , List.map (\\a -> List.map (\\b -> ( a < b, a >= b )) xs) xs
              )
            , ( List.map Tuple.second (List.sortBy Tuple.first (indexed xs))
              , Dict.values (Dict.fromList (indexed xs))
              , Set.size (Set.fromList xs)
              )
            , Maybe.map (\\m -> List.map Tuple.second (List.filter (\\( x, _ ) -> compare x m == EQ) (indexed xs))) (List.maximum xs)
            )


orders : String -> List comparable -> String
orders label xs =
    label
        ++ " "
        ++ Debug.toString
            ( List.map (\\a -> List.map (\\b -> compare a b) xs) xs
            , List.map (\\a -> List.map (\\b -> ( a < b, a > b )) xs) xs
            )
"""

# the twin's Dict and Set by a comparison function: Dict.fromList then toList (a later equal key replaces the earlier entry,
# key and value, as Dict.insert does), Set.fromList then toList, List.maximum (the first of the greatest)
TWINLIB = """

assoc : (k -> k -> Order) -> List ( k, v ) -> List ( k, v )
assoc cmp kvs =
    List.foldl (\\( k, v ) acc -> insertA cmp k v acc) [] kvs


insertA : (k -> k -> Order) -> k -> v -> List ( k, v ) -> List ( k, v )
insertA cmp k v acc =
    case acc of
        [] ->
            [ ( k, v ) ]

        ( k2, v2 ) :: rest ->
            case cmp k k2 of
                LT ->
                    ( k, v ) :: acc

                EQ ->
                    ( k, v ) :: rest

                GT ->
                    ( k2, v2 ) :: insertA cmp k v rest


setA : (k -> k -> Order) -> List k -> List k
setA cmp xs =
    List.map Tuple.first (assoc cmp (List.map (\\x -> ( x, () )) xs))


maxA : (a -> a -> Order) -> List a -> Maybe a
maxA cmp xs =
    List.foldl (\\x m -> case m of
                            Nothing -> Just x
                            Just y -> if cmp x y == GT then Just x else Just y) Nothing xs


groupW : String -> (a -> a -> Order) -> List a -> String
groupW label cmp xs =
    label
        ++ " "
        ++ Debug.toString
            ( ( List.map (\\a -> List.map (\\b -> cmp a b) xs) xs
              , List.map (\\a -> List.map (\\b -> ( cmp a b == LT, cmp a b /= LT )) xs) xs
              )
            , ( List.map Tuple.second (List.sortWith (\\( a, _ ) ( b, _ ) -> cmp a b) (indexed xs))
              , List.map Tuple.second (assoc cmp (indexed xs))
              , List.length (setA cmp xs)
              )
            , Maybe.map (\\m -> List.map Tuple.second (List.filter (\\( x, _ ) -> cmp x m == EQ) (indexed xs))) (maxA cmp xs)
            )
"""


def mod(imports, body, header="module Main exposing (main)"):
    return header + "\n\n" + "".join("import %s\n" % i for i in imports) + body.rstrip() + "\n" + MAIN


CASES_NEW = []


def case(cid, desc, files, twin, row=("RUN", "c", ""), c_only=True):
    CASES_NEW.append({"id": cid, "desc": desc, "files": files, "twin": twin, "row": row, "c_only": c_only})


def bad(cid, desc, files, title, text, outcome="REJECT", c_only=False, deps=None):
    CASES_NEW.append({"id": cid, "desc": desc, "files": files, "twin": None, "row": (outcome, title, text), "c_only": c_only, "deps": deps})


# ---------------------------------------------------------------------------------------------------------------- M1: the mutual group

NONREG_MUTUAL = """

type A a
    = A a (B (List a))
    | AN
    where
        derive {m}


type B a
    = B (A a)
    | BN
    where
        derive {m}


lines : List String
lines =
    [ Debug.toString ({use}) ]
"""

bad("a4bf-err-nonregular-mutual", "M1: derived compare over two types that refer to each other at a growing argument "
    "(A a = A a (B (List a)), B a = B (A a)): CANNOT DERIVE at once (elmficA4bb did not stop)",
    {"Main.elm": mod([], NONREG_MUTUAL.replace("{m}", "compare").replace("{use}", "compare (A 1 BN) (A 1 (B AN))"))},
    "CANNOT DERIVE", "refer to each other")
bad("a4bf-err-nonregular-mutual-hash", "M1: the same with derived hash",
    {"Main.elm": mod([], NONREG_MUTUAL.replace("{m}", "hash").replace("{use}", "A.hash (A 1 (B AN))"))},
    "CANNOT DERIVE", "keep growing")
bad("a4bf-err-nonregular-three", "M1: a group of three types, the growth in the third (A a -> B a -> C (Maybe a) -> A (Maybe a))",
    {"Main.elm": mod([], """

type A a
    = A a (B a)
    | AN
    where
        derive compare


type B a
    = B (C (Maybe a))


type C a
    = C (A a)
    | CN


lines : List String
lines =
    [ "x" ]
""")}, "CANNOT DERIVE", "A (Maybe a)")

# a regular group: the same shapes without growth must keep working (compare and hash, at a parameter and without one)
MUTUAL_TYPES_FIC = """

type Expr
    = Num Int
    | Neg Expr
    | Blk (List Stmt)
    where
        derive compare, hash


type Stmt
    = Let String Expr
    | Ret Expr
    where
        derive compare, hash


type A a
    = A a (B a)
    | AN
    where
        derive compare, hash


type B a
    = B (A a)
    | BN
    where
        derive compare, hash
"""

MUTUAL_TYPES_ELM = """

type Expr
    = Num Int
    | Neg Expr
    | Blk (List Stmt)


type Stmt
    = Let String Expr
    | Ret Expr


type A a
    = A a (B a)
    | AN


type B a
    = B (A a)
    | BN


cmpList : (x -> x -> Order) -> List x -> List x -> Order
cmpList cmp xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            EQ

        ( [], _ ) ->
            LT

        ( _, [] ) ->
            GT

        ( x :: xr, y :: yr ) ->
            case cmp x y of
                EQ ->
                    cmpList cmp xr yr

                o ->
                    o


rank : Int -> Int -> Order -> Order
rank i j inner =
    if i /= j then
        compare i j

    else
        inner


cmpExpr : Expr -> Expr -> Order
cmpExpr x y =
    case ( x, y ) of
        ( Num a, Num b ) ->
            compare a b

        ( Neg a, Neg b ) ->
            cmpExpr a b

        ( Blk a, Blk b ) ->
            cmpList cmpStmt a b

        _ ->
            rank (exprTag x) (exprTag y) EQ


exprTag : Expr -> Int
exprTag e =
    case e of
        Num _ ->
            0

        Neg _ ->
            1

        Blk _ ->
            2


cmpStmt : Stmt -> Stmt -> Order
cmpStmt x y =
    case ( x, y ) of
        ( Let n a, Let m b ) ->
            case compare n m of
                EQ ->
                    cmpExpr a b

                o ->
                    o

        ( Ret a, Ret b ) ->
            cmpExpr a b

        ( Let _ _, Ret _ ) ->
            LT

        ( Ret _, Let _ _ ) ->
            GT


cmpA : A Int -> A Int -> Order
cmpA x y =
    case ( x, y ) of
        ( A i b, A j c ) ->
            case compare i j of
                EQ ->
                    cmpB b c

                o ->
                    o

        ( A _ _, AN ) ->
            LT

        ( AN, A _ _ ) ->
            GT

        ( AN, AN ) ->
            EQ


cmpB : B Int -> B Int -> Order
cmpB x y =
    case ( x, y ) of
        ( B a, B b ) ->
            cmpA a b

        ( B _, BN ) ->
            LT

        ( BN, B _ ) ->
            GT

        ( BN, BN ) ->
            EQ
"""

MUTUAL_VALUES = """

exprs : List Expr
exprs =
    [ Num 2, Neg (Num 1), Blk [], Blk [ Ret (Num 1) ], Blk [ Let "x" (Num 1) ], Num 1, Blk [ Let "x" (Num 1), Ret (Neg (Num 0)) ], Neg (Num 1), Blk [ Let "w" (Blk [ Ret (Num 3) ]) ] ]


as_ : List (A Int)
as_ =
    [ AN, A 1 BN, A 1 (B AN), A 0 (B (A 2 BN)), A 1 (B AN), A 0 (B (A 2 (B AN))) ]


pairsE : List ( Expr, Expr )
pairsE =
    List.concatMap (\\x -> List.map (\\y -> ( x, y )) exprs) exprs


pairsA : List ( A Int, A Int )
pairsA =
    List.concatMap (\\x -> List.map (\\y -> ( x, y )) as_) as_
"""

case("a4bf-mutual-regular", "M1: a regular group of types that refer to each other (Expr/Stmt; A a = A a (B a), B a = B (A a)) "
     "still derives compare and hash: the group report, Dict and Set keys, the hash law over all pairs",
     {"Main.elm": mod(["Dict", "Set"], GROUP + MUTUAL_TYPES_FIC + MUTUAL_VALUES + """

lines : List String
lines =
    [ group "expr" exprs
    , group "a" as_
    , "hash expr " ++ Debug.toString (List.map (\\( x, y ) -> Expr.hash x == Expr.hash y) pairsE)
    , "hash a " ++ Debug.toString (List.map (\\( x, y ) -> A.hash x == A.hash y) pairsA)
    , "stmt " ++ Debug.toString ( Stmt.compare (Let "a" (Num 1)) (Ret (Num 0)), Stmt.hash (Ret (Num 0)) == Stmt.hash (Ret (Num 0)) )
    , "keys " ++ Debug.toString ( Dict.toList (Dict.fromList (List.map (\\e -> ( e, 1 )) exprs)) |> List.length, Set.toList (Set.fromList as_) |> List.length )
    ]
""")},
     ("elm", {"Main.elm": mod(["Dict", "Set"], GROUP + TWINLIB + MUTUAL_TYPES_ELM + MUTUAL_VALUES + """

lines : List String
lines =
    [ groupW "expr" cmpExpr exprs
    , groupW "a" cmpA as_
    , "hash expr " ++ Debug.toString (List.map (\\( x, y ) -> x == y) pairsE)
    , "hash a " ++ Debug.toString (List.map (\\( x, y ) -> x == y) pairsA)
    , "stmt " ++ Debug.toString ( cmpStmt (Let "a" (Num 1)) (Ret (Num 0)), True )
    , "keys " ++ Debug.toString ( List.length (assoc cmpExpr (List.map (\\e -> ( e, 1 )) exprs)), List.length (setA cmpA as_) )
    ]
""")}))


# ---------------------------------------------------------------------------------------------------------------- M2: an extensible-record field

# (P1) lifted: the row is filled at the exact type (fix/p1). The ids keep their old names; both now RUN against Elm twins
# (the derived order is Elm's Name order of the fields, the twins compare the same fields as tuples).
case("a4bf-err-row-field", "M2 lifted (P1): derive compare, hash over a field { r | x : Int }; the row's fields take part",
     {"Main.elm": mod([], """

type T r
    = T { r | x : Int }
    where
        derive compare, hash


lines : List String
lines =
    [ Debug.toString ( T { x = 1, y = 2 } < T { x = 1, y = 3 }, compare (T { x = 2, a = 9 }) (T { x = 1, a = 10 }) )
    , Debug.toString ( T.hash (T { x = 1, y = 2 }) == T.hash (T { x = 1, y = 3 }), T.hash (T { x = 1, y = 2 }) == T.hash (T { x = 1, y = 2 }) )
    ]
""")},
     ("elm", {"Main.elm": mod([], """

lines : List String
lines =
    [ Debug.toString ( ( 1, 2 ) < ( 1, 3 ), compare ( 9, 2 ) ( 10, 1 ) )
    , Debug.toString ( ( 1, 2 ) == ( 1, 3 ), ( 1, 2 ) == ( 1, 2 ) )
    ]
""")}))
case("a4bf-err-row-field-hash", "M2 lifted (P1): derive hash alone, the extensible record behind an alias inside a list",
     {"Main.elm": mod([], """

type alias Named r =
    { r | name : String }


type T r
    = T Int (List (Named r))
    where
        derive hash


lines : List String
lines =
    [ Debug.toString ( T.hash (T 1 [ { name = "a", age = 3 } ]) == T.hash (T 1 [ { name = "a", age = 4 } ]), T.hash (T 1 [ { name = "a", age = 3 } ]) == T.hash (T 1 [ { name = "a", age = 3 } ]) ) ]
""")},
     ("elm", {"Main.elm": mod([], """

lines : List String
lines =
    [ Debug.toString ( ( 1, [ ( 3, "a" ) ] ) == ( 1, [ ( 4, "a" ) ] ), ( 1, [ ( 3, "a" ) ] ) == ( 1, [ ( 3, "a" ) ] ) ) ]
""")}))


# ---------------------------------------------------------------------------------------------------------------- F1: an open record at `a has compare/hash`

HAS = """

type Color
    = Red
    | Green
    where
        derive compare


cmpG : a -> a -> Order
    where
        a has compare : a -> a -> Order
cmpG x y =
    compare x y


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x
"""

bad("a4bf-err-open-record-compare", "F1: a has compare at an annotated { r | x : Int }: NO ATTACHED FUNCTION, a closed record only "
    "(elmficA4bb accepted it, and the C generator stopped it)", {"Main.elm": mod([], HAS + """

cmpRec : { r | x : Int } -> { r | x : Int } -> Order
cmpRec a b =
    cmpG a b


lines : List String
lines =
    [ Debug.toString (cmpRec { x = 1, f = \\n -> n + 1 } { x = 1, f = \\n -> n }) ]
""")}, "NO ATTACHED FUNCTION", "Only a closed record")
bad("a4bf-err-open-record-hash", "F1: a has hash at an annotated open record", {"Main.elm": mod([], HAS + """

hashRec : { r | x : Int } -> Int
hashRec a =
    hashOf a


lines : List String
lines =
    [ Debug.toString (hashRec { x = 1, y = 2 }) ]
""")}, "NO ATTACHED FUNCTION", "has `hash`")
bad("a4bf-err-open-record-inferred", "F1: an unannotated function whose record stays open (not AMBIGUOUS TYPE)", {"Main.elm": mod([], HAS + """

cmpRec a b =
    if a.x > 0 then cmpG a b else EQ


lines : List String
lines =
    [ Debug.toString (cmpRec { x = 1, y = 2 } { x = 1, y = 3 }) ]
""")}, "NO ATTACHED FUNCTION", "Only a closed record")
bad("a4bf-err-open-record-let", "F1: the open record in a let", {"Main.elm": mod([], HAS + """

outer : { r | x : Int } -> { r | x : Int } -> Order
outer a b =
    let
        inner () =
            cmpG a b
    in
    inner ()


lines : List String
lines =
    [ Debug.toString (outer { x = 1, y = 2 } { x = 1, y = 3 }) ]
""")}, "NO ATTACHED FUNCTION", "Only a closed record")

case("a4bf-closed-record-later", "F1: a record whose row is still open when the obligation is met (a lambda reads a.x first) and "
     "closed later by the list; a let function; an annotated closed record: all still have compare and hash",
     {"Main.elm": mod([], HAS + """

cmpC : { x : Int, y : String } -> { x : Int, y : String } -> Order
cmpC a b =
    cmpG a b


recs : List { x : Int, y : String }
recs =
    [ { x = 2, y = "b" }, { x = 1, y = "z" }, { x = 2, y = "a" }, { x = 0, y = "q" } ]


lines : List String
lines =
    let
        f a b =
            cmpG a b
    in
    [ Debug.toString (List.sortWith (\\a b -> if a.x >= 0 then cmpG a b else EQ) recs)
    , Debug.toString (List.map (\\r -> hashOf r == hashOf { x = 2, y = "a" }) recs)
    , Debug.toString (List.map (\\r -> f r { y = "b", x = 2 }) recs)
    , Debug.toString (List.map (\\r -> cmpC r { x = 1, y = "z" }) recs)
    ]
""")},
     ("elm", {"Main.elm": mod([], """

recs : List { x : Int, y : String }
recs =
    [ { x = 2, y = "b" }, { x = 1, y = "z" }, { x = 2, y = "a" }, { x = 0, y = "q" } ]


key : { x : Int, y : String } -> ( Int, String )
key r =
    ( r.x, r.y )


lines : List String
lines =
    [ Debug.toString (List.sortWith (\\a b -> if a.x >= 0 then compare (key a) (key b) else EQ) recs)
    , Debug.toString (List.map (\\r -> r == { x = 2, y = "a" }) recs)
    , Debug.toString (List.map (\\r -> compare (key r) ( 2, "b" )) recs)
    , Debug.toString (List.map (\\r -> compare (key r) ( 1, "z" )) recs)
    ]
""")}))


# ---------------------------------------------------------------------------------------------------------------- F2: the shape of a written hash

HASH_SHAPE = """

type T
    = T Int
    where
        hash : {sig}
        hash {body}


type Outer
    = Outer T
    where
        derive hash


lines : List String
lines =
    [ Debug.toString (Outer.hash (Outer (T 1))) ]
"""

bad("a4bf-err-hash-shape", "F2: a written hash : T -> String inside a derived hash: CANNOT DERIVE with both types (elmficA4bb: the C "
    "generator failed)", {"Main.elm": mod([], HASH_SHAPE.replace("{sig}", "T -> String").replace("{body}", "(T n) =\n            String.fromInt n"))},
    "CANNOT DERIVE", "    T -> String")
bad("a4bf-err-hash-shape-arity2", "F2: a written hash : T -> Int -> Int", {"Main.elm": mod([], HASH_SHAPE.replace("{sig}", "T -> Int -> Int").replace("{body}", "(T n) k =\n            n + k"))},
    "CANNOT DERIVE", "T -> Int -> Int")


# ---------------------------------------------------------------------------------------------------------------- F3: beside a written eq

BESIDE_EQ = """

type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b

        derive {m}


lines : List String
lines =
    [ Debug.toString ( Ci "A" == Ci "a", Ci "A" /= Ci "b" ) ]
"""

bad("a4bf-err-beside-eq", "F3: derive compare, hash beside a written eq: CANNOT DERIVE (Ci 'A' == Ci 'a' but compare LT and "
    "the hashes differ)", {"Main.elm": mod([], BESIDE_EQ.replace("{m}", "compare, hash"))}, "CANNOT DERIVE", "its own `eq`")
bad("a4bf-err-beside-eq-hash", "F3: derive hash alone beside a written eq", {"Main.elm": mod([], BESIDE_EQ.replace("{m}", "hash"))},
    "CANNOT DERIVE", "get different hashes")

# ---------------------------------------------------------------------------------------------------------------- writing and twins

def write():
    rows = {}
    for c in CASES_NEW:
        d = os.path.join(CASES, c["id"])
        os.makedirs(d, exist_ok=True)          # expected.out (written by --expect) stays
        for fn, src in c["files"].items():
            open(os.path.join(d, fn), "w", encoding="utf-8").write(src)
        meta = {"desc": c["desc"]}
        if c["c_only"]: meta["c_only"] = True
        if c.get("deps"): meta["deps"] = c["deps"]
        json.dump(meta, open(os.path.join(d, "case.json"), "w"))
        rows[c["id"]] = c["row"]
        if c["twin"]:
            td = os.path.join(TWINS, c["id"])
            if os.path.isdir(td): shutil.rmtree(td)
            os.makedirs(td)
            open(os.path.join(td, "kind"), "w").write(c["twin"][0] + "\n")
            for fn, src in c["twin"][1].items():
                open(os.path.join(td, fn), "w", encoding="utf-8").write(src)
    path = os.path.join(HERE, "expected.tsv")
    out, seen = [], set()
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if not line.startswith("#") and f[0] in rows:
            out.append("\t".join((f[0],) + tuple(rows[f[0]])) + "\n"); seen.add(f[0])
        else:
            out.append(line)
    for cid in [c["id"] for c in CASES_NEW]:
        if cid not in seen: out.append("\t".join((cid,) + tuple(rows[cid])) + "\n")
    open(path, "w", encoding="utf-8").writelines(out)
    print("wrote %d cases" % len(CASES_NEW))


def run_twin(cid, elm0193, old, home):
    td = os.path.join(TWINS, cid)
    kind = open(os.path.join(td, "kind")).read().strip()
    work = tempfile.mkdtemp(prefix="a4bftwin-")
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
    old = os.path.join(root, "bin", "elmficA5c")
    home = tempfile.mkdtemp(prefix="a4bftwin-home-")
    mkhome.make(home)
    try:
        ids = sorted(os.listdir(TWINS))
        if only: ids = [i for i in ids if i in only.split(",")]
        for cid in ids:
            out = run_twin(cid, elm0193, old, home)
            open(os.path.join(CASES, cid, "expected.out"), "w", encoding="utf-8").write(out)
            print("%-28s %d lines" % (cid, out.count("\n")))
    finally:
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true"); ap.add_argument("--expect", action="store_true"); ap.add_argument("--only")
    a = ap.parse_args()
    if a.write: write()
    if a.expect: expect(a.only)
