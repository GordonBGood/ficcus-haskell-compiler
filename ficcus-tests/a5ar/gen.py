#!/usr/bin/env python3
"""gen.py -- writes the A5a review cases (ficcus-tests/a5ar/cases/<id>/Main.elm, twin/Main.elm, expected.out).
Run from the worktree root: python3 ficcus-tests/a5ar/gen.py"""
import os, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")

MAIN = '''

main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
                    _ =
                        Debug.log "r" out
                in
                ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
'''

MONEY = '''
type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b

        addTo : Money -> Int -> Money
        addTo (Money a) n = Money (a + n)


type Vec = Vec Int Int
    where
        zero : Vec
        zero = Vec 0 0

        add : Vec -> Vec -> Vec
        add (Vec a b) (Vec c d) = Vec (a + c) (b + d)

        compare : Vec -> Vec -> Order
        compare (Vec a b) (Vec c d) = Basics.compare ( a, b ) ( c, d )

        addTo : Vec -> Int -> Vec
        addTo (Vec a b) n = Vec (a + n) (b + n)


sum : List a -> a
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


addN : a -> b -> a
    where
        a has addTo : a -> b -> a
addN x n =
    addTo x n
'''

CASH = '''
type Cash = Cash Int
    where
        add : Cash -> Cash -> Cash
        add (Cash a) (Cash b) = Cash (a + b)

        sub : Cash -> Cash -> Cash
        sub (Cash a) (Cash b) = Cash (a - b)

        mul : Cash -> Cash -> Cash
        mul (Cash a) (Cash b) = Cash (a * b)

        pow : Cash -> Cash -> Cash
        pow (Cash a) (Cash b) = Cash (a ^ b)

        neg : Cash -> Cash
        neg (Cash a) = Cash (negate a)

        abs : Cash -> Cash
        abs (Cash a) = Cash (Basics.abs a)

        fromInt : Int -> Cash
        fromInt n = Cash (n * 100)

        compare : Cash -> Cash -> Order
        compare (Cash a) (Cash b) = Basics.compare a b

        div : Cash -> Cash -> Cash
        div (Cash a) (Cash b) = Cash ((a * 100) // b)

        idiv : Cash -> Cash -> Cash
        idiv (Cash a) (Cash b) = Cash ((a * 100) // b)

        mod : Cash -> Cash -> Cash
        mod (Cash a) (Cash b) = Cash (modBy b a)

        rem : Cash -> Cash -> Cash
        rem (Cash a) (Cash b) = Cash (remainderBy b a)


type Ratio = Ratio Int Int
    where
        div : Ratio -> Ratio -> Ratio
        div (Ratio a b) (Ratio c d) = Ratio (a * d) (b * c)
'''

TW = '''
type T = T Int
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
'''

CASES_ = {}


def case(cid, body, twin=None, expected=None, header="module Main exposing (main)\n", extra=None):
    CASES_[cid] = (header + body + MAIN, twin and (header + twin + MAIN), expected, extra or {})


# ---- 1. sharing --------------------------------------------------------------------------------------------------------

# a scheme requirement whose type mentions an outer variable: the carrier copy must keep it shared, so `f "s"` is a type error
case("share-outer-reject", MONEY + '''
f n =
    let
        g x =
            addN x n
    in
    ( g (Money 1), g (Vec 1 2) )


out =
    f "s"
''')

# the accepted version of the same (n := Int through both members)
case("share-outer-ok", MONEY + '''
f n =
    let
        g x =
            addN x n
    in
    ( g (Money 1), g (Vec 1 2) )


out =
    f 5
''', expected="r: (Money 6,Vec 6 7)\n")

# nested lets: an inner local function uses a variable of the outer local function
case("share-nested", MONEY + '''
f m v =
    let
        g x =
            let
                h y =
                    plus y x
            in
            ( h x, h (h x) )
    in
    ( g m, g v )


out =
    f (Money 1) (Vec 1 2)
''', expected="r: ((Money 2,Money 3),(Vec 2 4,Vec 3 6))\n")

# nested: the inner function is generalized on its own and used at two types inside one use of the outer one
case("share-nested-two", MONEY + '''
f m v =
    let
        g x =
            let
                h y =
                    plus y y
            in
            ( h x, h m, h v )
    in
    ( g m, g v )


out =
    f (Money 1) (Vec 1 2)
''', expected="r: ((Money 2,Money 2,Vec 2 4),(Vec 2 4,Money 2,Vec 2 4))\n")

# mutually recursive let functions with a requirement
case("share-recursive-let", MONEY + '''
f m v =
    let
        ev n x =
            if n == 0 then x else od (n - 1) (plus x x)

        od n x =
            if n == 0 then x else ev (n - 1) x
    in
    ( ev 3 m, od 3 v )


out =
    f (Money 1) (Vec 1 2)
''', expected="r: (Money 4,Vec 2 4)\n")

# mutually recursive top level functions: one name's type does not mention the requirement's subject (deviation 3)
case("share-recursive-top", MONEY + '''
fa x n =
    if n <= 0 then ( plus x x, gb n ) else fa x (n - 1)


gb n =
    if n <= 0 then 0 else Tuple.second ( fa (Debug.todo "never") 0, gb (n - 1) )


out =
    ( fa (Vec 1 2) 2, gb 0, fa (Money 1) 0 )
''', expected="r: ((Vec 2 4,0),0,(Money 2,0))\n")

# the same without Debug.todo, and gb's call of fa evaluated: gb's body needs `a has zero, add` at a variable no type decides
case("share-recursive-ambiguous", MONEY + '''
fa x n =
    if n <= 0 then ( plus x x, gb n ) else fa x (n - 1)


gb n =
    if n <= 0 then 0 else Tuple.second ( fa (sum []) 0, gb (n - 1) )


out =
    ( fa (Vec 1 2) 2, gb 2 )
''')

# the same ambiguity without recursion: rejected (control)
case("share-nonrec-ambiguous", MONEY + '''
fa x n =
    ( plus x x, n )


gb n =
    Tuple.second ( fa (sum []) 0, n )


out =
    ( fa (Vec 1 2) 2, gb 2 )
''')

# ---- 2. holding --------------------------------------------------------------------------------------------------------

# the requirement of the let function is decided by the outer variable through a structure (List)
case("hold-structure", MONEY + '''
f ms =
    let
        g x =
            plus x (sum ms)
    in
    g (Money 5)


out =
    f [ Money 1, Money 2 ]
''', expected="r: Money 8\n")

# same, but used at a second type: must be rejected (g is monomorphic in x because sum ms decides it)
case("hold-structure-reject", MONEY + '''
f ms =
    let
        g x =
            plus x (sum ms)
    in
    ( g (Money 5), g (Vec 1 1) )


out =
    f [ Money 1, Money 2 ]
''')

# eta-reduced let function: a value under D4 (MR), used at two types
case("hold-eta-value", MONEY + '''
f m v =
    let
        g =
            plus
    in
    ( g m m, g v v )


out =
    f (Money 1) (Vec 1 2)
''')

# a let function defined by case returning lambdas (a value under D4)
case("hold-case-lambda", MONEY + '''
f b m =
    let
        g =
            if b then \\x -> plus x x else \\x -> x
    in
    g m


out =
    f True (Money 2)
''', expected="r: Money 4\n")

# the B4 shape inside a let function used at two types: the subject decides the member type
case("hold-b4-let-fun", TW + '''
ff w =
    let
        g x =
            ( get x, get w )
    in
    ( g (T 1), g (W (T 2)) )


out =
    ff (W (T 9))
''', expected="r: ((1,T 9),(T 2,T 9))\n")

# a let function inside the body of a member (are member bodies in Type.Requirements.kindsOf?)
case("hold-member-body-let", MONEY + '''
type Pair = Pair Money Vec
    where
        double : Pair -> Pair
        double (Pair m v) =
            let
                g x =
                    plus x x
            in
            Pair (g m) (g v)


show : Pair -> ( Money, Vec )
show (Pair m v) =
    ( m, v )


out =
    show (Pair.double (Pair (Money 1) (Vec 1 2)))
''', expected="r: (Money 2,Vec 2 4)\n")

# a typed member of a top level recursive group with an undetermined `//` (its body is solved at the outermost rank)
case("hold-rec-typed-literal", CASH + '''
ev : Int -> String
ev n =
    if n <= 0 then Debug.toString (7 // 2) else od (n - 1)


od n =
    if n <= 0 then "o" else ev (n - 1)


out =
    ( ev 2, od 2 )
''', expected='r: ("3","o")\n')

# control: the same without the recursion
case("hold-nonrec-typed-literal", CASH + '''
ev : Int -> String
ev n =
    if n <= 0 then Debug.toString (7 // 2) else "e"


out =
    ev 0
''', expected='r: "3"\n')

# an inferred function exported and used by another module at two types, and inside a let there
case("cross-module-let", '''
import Helper exposing (Money(..), Vec(..), twice)


out =
    let
        g x =
            twice (twice x)
    in
    ( g (Money 1), g (Vec 1 2) )
''', extra={"Helper.elm": "module Helper exposing (Money(..), Vec(..), plus, twice)\n" + MONEY.replace("type Money", "type Money", 1) + '''

twice m =
    plus m m
'''}, expected="r: (Money 4,Vec 4 8)\n")

# ---- 3. order ----------------------------------------------------------------------------------------------------------

QP = '''
type Q = Q Int
    where
        pick : Q -> c -> c
        pick _ x = x


choose : a -> c -> c
    where
        a has pick : a -> c -> c
choose x y =
    pick x y
'''

# rule 1 with a subject that is concrete later in the same body: no let in between
case("order-rule1-nolet", QP + '''
both q =
    ( ( choose q 1, choose q "s" ), q == Q 1 )


out =
    both (Q 1)
''', expected='r: ((1,"s"),True)\n')

# the same with the two uses in a let value: the subject is still a variable at the let
case("order-rule1-let", QP + '''
both q =
    let
        p =
            ( choose q 1, choose q "s" )
    in
    ( p, q == Q 1 )


out =
    both (Q 1)
''', expected='r: ((1,"s"),True)\n')

# the same with the subject made concrete before the let
case("order-rule1-let-after", QP + '''
both q =
    let
        k =
            q == Q 1

        p =
            ( choose q 1, choose q "s" )
    in
    ( p, k )


out =
    both (Q 1)
''', expected='r: ((1,"s"),True)\n')

# the same with the two let definitions in the other source order
case("order-rule1-let-swapped", QP + '''
both q =
    let
        p =
            ( choose q 1, choose q "s" )

        k =
            q == Q 1
    in
    ( p, k )


out =
    both (Q 1)
''', expected='r: ((1,"s"),True)\n')

# the same with the settling definition renamed (k -> zk): does the let order depend on names?
case("order-rule1-let-renamed", QP + '''
both q =
    let
        zk =
            q == Q 1

        p =
            ( choose q 1, choose q "s" )
    in
    ( p, zk )


out =
    both (Q 1)
''', expected='r: ((1,"s"),True)\n')

# ---- 4. demotion / subjects in various positions ----------------------------------------------------------------------

case("subj-record", MONEY + '''
g r =
    plus r.a r.a


h r =
    { r | a = plus r.a r.a }


out =
    ( g { a = Money 2 }, h { a = Vec 1 2, b = 3 } )
''', expected="r: (Money 4,{ a = Vec 2 4, b = 3 })\n")

case("subj-lambda-case", MONEY + '''
g mx =
    case mx of
        Just x ->
            \\y -> plus x y

        Nothing ->
            \\y -> y


out =
    ( g (Just (Money 1)) (Money 2), g Nothing (Vec 1 1) )
''', expected="r: (Money 3,Vec 1 1)\n")

# an undetermined subject inside a let function (deviation 2: held, then reported or defaulted at the top level)
case("subj-undetermined-let", MONEY + '''
f m =
    let
        g x =
            ( x, sum [] )
    in
    ( g m, 1 )


out =
    f (Money 1)
''')

# undetermined in the let, settled later in the enclosing body
case("subj-later-settled", MONEY + '''
f m =
    let
        z =
            sum []

        g x =
            plus x z
    in
    g m


out =
    f (Money 3)
''', expected="r: Money 3\n")

# a literal subject in a let, settled to Int at the top level (D3), with Cash in sight
case("subj-let-literal", CASH + '''
f s =
    let
        k =
            7 // 2

        g y =
            y // 2
    in
    ( k, g s, g (Cash 900) )


out =
    f 9
''', expected="r: (3,4,Cash 450)\n")

# ---- 5. built-in subjects decide a variable (D2 in the specializer) ---------------------------------------------------

case("builtin-decides-compare", '''
type Box = Box Int
    where
        compare : Box -> Box -> Order
        compare (Box a) (Box b) = Basics.compare a b


cmpz : a -> a -> String
    where
        a has compare : a -> a -> z
cmpz x y =
    Debug.toString (compare x y)


out =
    ( cmpz 1 2, cmpz "b" "a", cmpz (Box 1) (Box 1) )
''', expected='r: ("LT","GT","EQ")\n')

case("builtin-decides-inferred", '''
type Box = Box Int
    where
        compare : Box -> Box -> Order
        compare (Box a) (Box b) = Basics.compare a b


cmpz : a -> a -> z
    where
        a has compare : a -> a -> z
cmpz x y =
    compare x y


cmp2 x y =
    Debug.toString (cmpz x y)


out =
    ( cmp2 1 2, cmp2 "b" "a", cmp2 (Box 1) (Box 1) )
''', expected='r: ("LT","GT","EQ")\n')

case("builtin-decides-float32", '''
import Float32 exposing (Float32)


conv : a -> z
    where
        a has fromInt : Int -> z
conv _ =
    fromInt 3


show : Float32 -> String
show x =
    Float32.toString x


out =
    show (conv (Float32.fromFloat 1))
''', header="module Main exposing (main)\n", expected='r: "3"\n')

case("builtin-decides-written", '''
type Box = Box Int
    where
        compare : Box -> Box -> Order
        compare (Box a) (Box b) = Basics.compare a b


cmpz : a -> a -> z
    where
        a has compare : a -> a -> z
cmpz x y =
    compare x y


cmp2 : a -> a -> String
    where
        a has compare : a -> a -> z
cmp2 x y =
    Debug.toString (cmpz x y)


out =
    ( cmp2 1 2, cmp2 "b" "a", cmp2 (Box 1) (Box 1) )
''', expected='r: ("LT","GT","EQ")\n')

# the same with only the custom type (control: D2 through a custom member)
case("builtin-decides-custom-only", '''
type Box = Box Int
    where
        compare : Box -> Box -> Order
        compare (Box a) (Box b) = Basics.compare a b


cmpz : a -> a -> z
    where
        a has compare : a -> a -> z
cmpz x y =
    compare x y


cmp2 x y =
    Debug.toString (cmpz x y)


out =
    cmp2 (Box 1) (Box 2)
''', expected='r: "LT"\n')

# a built-in member that decides a boxed type (String, List): does the wrong key compile and print something else?
case("builtin-decides-append", '''
appz : a -> a -> z
    where
        a has append : a -> a -> z
appz x y =
    append x y


app2 x y =
    Debug.toString (appz x y)


lenOf x y =
    String.length (app2 x y)


out =
    ( app2 "a" "b", app2 [ 1 ] [ 2 ], lenOf "ab" "cd" )
''', twin='''
app2 x y =
    Debug.toString (x ++ y)


lenOf x y =
    String.length (app2 x y)


out =
    ( app2 "a" "b", app2 [ 1 ] [ 2 ], lenOf "ab" "cd" )
''')


# ---- 7. specializer -------------------------------------------------------------------------------------------------

case("spec-div-chain", CASH + '''
half x y =
    x / y


quarter y z =
    half (half y z) z


out =
    ( quarter 3 2, quarter (Cash 800) (Cash 200), quarter (Ratio 1 1) (Ratio 1 2) )
''', expected="r: (0.75,Cash 200,Ratio 4 1)\n")

case("spec-modby-two", CASH + '''
m3 x =
    modBy 3 x


twice x =
    m3 (m3 x)


out =
    ( twice 10, twice (Cash 1000), m3 7 )
''', expected="r: (1,Cash 0,1)\n")

case("spec-lambda-top", CASH + '''
half =
    \\x -> x / 2


out =
    ( half 3, half (Cash 900) )
''', expected="r: (1.5,Cash 450)\n")

case("spec-outer-relaxed", CASH + '''
f x =
    let
        g y =
            ( x / 2, y )
    in
    ( g 1, g "s" )


out =
    ( f 3, f (Cash 900) )
''', expected='r: (((1.5,1),(1.5,"s")),((Cash 450,1),(Cash 450,"s")))\n')


case("spec-div-structures", CASH + '''
halfAll xs =
    List.map (\\x -> x / 2) xs


halfLet xs =
    let
        h x =
            x / 2
    in
    List.map h xs


halfRec r =
    { r | v = r.v / 2 }


halfMaybe m =
    Maybe.map (\\x -> x / 4) m


out =
    ( ( halfAll [ 3, 5 ], halfAll [ Cash 300 ], List.map Float32.toString (halfAll [ Float32.fromFloat 3 ]) )
    , ( halfLet [ 1 ], halfLet [ Cash 100 ], List.map Float32.toString (halfLet [ Float32.fromFloat 1 ]) )
    , ( ( halfRec { v = 9, w = 1 }, halfRec { v = Cash 900, w = "x" } ), ( halfMaybe (Just (Cash 800)), halfMaybe (Just 2) ) )
    )
''', header="module Main exposing (main)\nimport Float32 exposing (Float32)\n", expected='r: (([1.5,2.5],[Cash 150],["1.5"]),([0.5],[Cash 50],["0.5"]),(({ v = 4.5, w = 1 },{ v = Cash 450, w = "x" }),(Just (Cash 200),Just 0.5)))\n')


def chain(n, inferred):
    lines = []
    for i in range(n + 1):
        if i == 0:
            lines.append("type T0 = T0 Int\n    where\n        f : T0 -> Int\n        f (T0 k) = k\n")
        else:
            lines.append("type T%d = T%d T%d\n    where\n        f : T%d -> T%d\n        f (T%d t) = t\n" % (i, i, i - 1, i, i - 1, i))
    lines.append(TW.split("\n\nget :")[0].split("type T = T Int")[0])
    lines.append("get : a -> b\n    where\n        a has f : a -> b\nget x =\n    f x\n")
    call = "w"
    for _ in range(n + 1):
        call = "get (%s)" % call
    if inferred:
        lines.append("deep w =\n    %s\n" % call)
    else:
        vs = ["a%d" % i for i in range(n + 2)]
        wh = ["        %s has f as f%d : %s -> %s" % (vs[i], i, vs[i], vs[i + 1]) for i in range(n + 1)]
        wh.reverse()
        lines.append("deep : a0 -> a%d\n    where\n%s\ndeep w =\n    %s\n" % (n + 1, "\n".join(wh), call))
    v = "T0 42"
    for i in range(1, n + 1):
        v = "T%d (%s)" % (i, v)
    lines.append("out =\n    deep (%s) + 1\n" % v)
    return "\n\n".join(lines)


for n in (7, 8, 9, 12):
    case("spec-deep-inferred-%d" % n, chain(n, True), expected="r: 43\n")
    case("spec-deep-written-%d" % n, chain(n, False), expected="r: 43\n")

# ---- 8. D6 ---------------------------------------------------------------------------------------------------------

case("d6-import-only", '''
import Helper


out =
    Helper.used 3
''', extra={"Helper.elm": '''module Helper exposing (half, used)


type Cash = Cash Int
    where
        div : Cash -> Cash -> Cash
        div (Cash a) (Cash b) = Cash (a // b)


half x =
    x / 2


used : Int -> Int
used n =
    n + 1
'''}, expected="r: 4\n")

case("d6-unused-local", CASH + '''
half x =
    x / 2


out =
    3 + 1
''', expected="r: 4\n")

case("d6-mutual", CASH + '''
ev n x =
    if n <= 0 then x else od (n - 1) (x / 2)


od n x =
    if n <= 0 then x else ev (n - 1) x


out =
    ev 2 8
''', expected="r: 4\n")

# D6: an inferred let function inside an annotated top level function, only used at Float and Int (no marker): JavaScript
D6LET = '''
f : Float -> Int -> ( Float, Int )
f x n =
    let
        g y =
            y / 2

        h y =
            y // 2
    in
    ( g x, h n )


out =
    f 3 7
'''
case("d6-let-js", CASH + D6LET, twin=D6LET)

# ---- 6/9. Elm programs and defaulting ------------------------------------------------------------------------------

ELMPROG = '''
f x =
    let
        k =
            9

        g y =
            y / 2

        h y =
            y // 2
    in
    ( ( k + 1, toFloat k / 2 ), ( g x, h 9, modBy 4 9 ) )


out =
    f 3
'''
case("elm-let-numbers", ELMPROG, twin=ELMPROG)

# deviation 2: an inner let value whose literal is decided later by the body (must not default early)
case("dev2-let-literal-later", CASH + '''
f c =
    let
        k =
            8 // 2
    in
    ( k, c )


g c =
    let
        k =
            8 // 2
    in
    k + c


out =
    ( f 1, g (Cash 300) )
''', expected="r: ((4,1),Cash 700)\n")

case("dev2-let-float-later", CASH + '''
g c =
    let
        k =
            9 / 2
    in
    k + c


out =
    ( g (Cash 300), g 0.5 )
''', expected="r: (Cash 750,5)\n")


# an Elm program with Cash in sight (the relaxed operators are inferred, held, defaulted): must print what Elm prints
ELMREL = '''
f x =
    let
        g y =
            Debug.toString ( y, 7 // 2, 7 / 2 )
    in
    g x


h y =
    y // 4


k =
    modBy 3 10


mm =
    let
        q z =
            z / 2
    in
    ( q 3, q 4.5 )


r a b =
    ( remainderBy a b, modBy a b )


v =
    7 / 2


out =
    ( ( f 1, h 9, k ), ( mm, r 3 -7, v ) )
'''
case("dev2-elm-semantics", CASH + ELMREL, twin=ELMREL)


def write():
    if os.path.isdir(CASES):
        shutil.rmtree(CASES)
    for cid, (main, twin, expected, extra) in CASES_.items():
        d = os.path.join(CASES, cid)
        os.makedirs(d)
        open(os.path.join(d, "Main.elm"), "w").write(main)
        for name, text in extra.items():
            open(os.path.join(d, name), "w").write(text)
        if twin:
            os.makedirs(os.path.join(d, "twin"))
            open(os.path.join(d, "twin", "Main.elm"), "w").write(twin)
        if expected:
            open(os.path.join(d, "expected.out"), "w").write(expected)
    print(len(os.listdir(CASES)), "cases")


if __name__ == "__main__":
    write()
