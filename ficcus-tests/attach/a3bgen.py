#!/usr/bin/env python3
"""a3bgen.py -- the A3b cases of the attach suite (members inside containers, Word64 in compared containers, the
`fromFloat` literal; docs/A3B-PLAN.md).  Standard library only.

  python3 ficcus-tests/attach/a3bgen.py --write                 # write cases/a3b-*/ and the rows of expected.tsv
  python3 ficcus-tests/attach/a3bgen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case

The expected output of a RUN case is never written by hand: it is the output of a *twin* program.
  elm   the twin is plain Elm, compiled by bin/elm0193 and run by node.  The member types of the Ficcus program are
        replaced by a normalized representation for which Elm's structural `==`/`compare` IS the member
        (`type alias Ci = String`, `ci = String.toLower`; `Desc n` -> `negate n`; Word64 -> `(hi, lo)` with hi, lo < 2^32).
  oldc  the twin is a Ficcus program that the reference binary (bin/elmficA4b) already compiles to C: the literal written
        as `Float32.fromFloat 0.1`; run with gcc.
The converted A3 cases (a3-c-holds-*, sized-err-word64-tuple, sized-err-float-literal) keep their sources; only their twin
and their row are here."""
import argparse, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a3b-twins")
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

NAME_FIC = """
type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


name : String -> Name
name s =
    Name s
"""

NAME_ELM = """
type Name
    = Name String


name : String -> Name
name s =
    Name (String.toLower s)
"""

CI_FIC = """
type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b

        compare : Ci -> Ci -> Order
        compare (Ci a) (Ci b) =
            Basics.compare (String.toLower a) (String.toLower b)


ci : String -> Ci
ci s =
    Ci s


showCi : Ci -> String
showCi (Ci s) =
    String.toLower s
"""

CI_ELM = """
type alias Ci =
    String


ci : String -> Ci
ci s =
    String.toLower s


showCi : Ci -> String
showCi s =
    s
"""

DESC_FIC = """
type Desc
    = Desc Int
    where
        compare : Desc -> Desc -> Order
        compare (Desc a) (Desc b) =
            Basics.compare b a


desc : Int -> Desc
desc n =
    Desc n


showDesc : Desc -> String
showDesc (Desc n) =
    String.fromInt n


type Pt
    = Pt Int Int
    where
        compare : Pt -> Pt -> Order
        compare (Pt a b) (Pt c d) =
            Basics.compare ( b, a ) ( d, c )


pt : Int -> Int -> Pt
pt a b =
    Pt a b


showPt : Pt -> String
showPt (Pt a b) =
    String.fromInt a ++ "." ++ String.fromInt b
"""

DESC_ELM = """
type alias Desc =
    Int


desc : Int -> Desc
desc n =
    negate n


showDesc : Desc -> String
showDesc n =
    String.fromInt (negate n)


type alias Pt =
    ( Int, Int )


pt : Int -> Int -> Pt
pt a b =
    ( b, a )


showPt : Pt -> String
showPt ( b, a ) =
    String.fromInt a ++ "." ++ String.fromInt b
"""

WORD_FIC = """
import Word64 exposing (Word64)


w : Int -> Int -> Word64
w hi lo =
    Word64.or (Word64.shiftLeftBy 32 (Word64.fromInt hi)) (Word64.fromInt lo)


showW : Word64 -> String
showW x =
    String.fromInt (Word64.toInt (Word64.shiftRightBy 32 x)) ++ ":" ++ String.fromInt (Word64.toInt (Word64.and x (Word64.fromInt 4294967295)))
"""

WORD_ELM = """
type alias Word64 =
    ( Int, Int )


w : Int -> Int -> Word64
w hi lo =
    ( hi, lo )


showW : Word64 -> String
showW ( hi, lo ) =
    String.fromInt hi ++ ":" ++ String.fromInt lo
"""


def prog(imports, prologue, body, module="Main", exposing="main"):
    head = "module %s exposing (%s)\n\n" % (module, exposing)
    imps = "".join("import %s\n" % i for i in imports)
    # an import inside a prologue (Word64) goes up with the others
    pro_imports = [l for l in prologue.splitlines() if l.startswith("import ")]
    pro_rest = "\n".join(l for l in prologue.splitlines() if not l.startswith("import "))
    imps += "".join(l + "\n" for l in pro_imports)
    return head + imps + "\n" + pro_rest + "\n\n" + body.strip("\n") + "\n" + (MAIN if module == "Main" else "")


BODY_EQ_BUILTIN = """
same : a -> a -> Bool
same x y =
    x == y


okName : Name -> Result String Name
okName =
    Ok


names : Int -> List Name
names n =
    List.map (\\i -> name ("n" ++ String.fromInt i)) (List.range 1 n)


lines : List String
lines =
    List.map Debug.toString
        [ [ name "a", name "B" ] == [ name "A", name "b" ]
        , [ name "a" ] == [ name "a", name "b" ]
        , [ name "a", name "c" ] == [ name "A", name "b" ]
        , ( name "x", 1 ) == ( name "X", 1 )
        , ( name "x", 1 ) == ( name "X", 2 )
        , ( name "x", name "y", "z" ) == ( name "X", name "Y", "z" )
        , { n = name "q", k = 3 } == { n = name "Q", k = 3 }
        , { n = name "q", k = 3 } == { n = name "R", k = 3 }
        , Just (name "m") == Just (name "M")
        , Just (name "m") == Nothing
        , okName (name "e") == okName (name "E")
        , okName (name "e") == Err "e"
        , Dict.fromList [ ( 1, name "d" ), ( 2, name "e" ) ] == Dict.fromList [ ( 2, name "E" ), ( 1, name "D" ) ]
        , Dict.fromList [ ( 1, name "d" ) ] == Dict.fromList [ ( 1, name "x" ) ]
        , Array.fromList [ name "a", name "b" ] == Array.fromList [ name "A", name "B" ]
        , Array.fromList (names 40) == Array.push (name "N40") (Array.fromList (names 39))
        , Array.fromList (names 40) == Array.fromList (names 41)
        , [ Just ( name "n", 1 ) ] /= [ Just ( name "N", 1 ) ]
        , [ Just ( name "n", 1 ) ] /= [ Just ( name "N", 2 ) ]
        , List.member (name "Z") [ name "y", name "z" ]
        , List.member (Just (name "Z")) [ Nothing, Just (name "z") ]
        , List.member ( name "Z", 1 ) [ ( name "z", 2 ) ]
        , same ( name "g", 2 ) ( name "G", 2 )
        , same [ [ name "g" ] ] [ [ name "G" ] ]
        , [ { a = Just [ ( name "deep", 1 ) ] } ] == [ { a = Just [ ( name "DEEP", 1 ) ] } ]
        , List.filter (\\x -> x == ( name "K", [ name "l" ] )) [ ( name "k", [ name "L" ] ), ( name "k", [] ) ] == [ ( name "K", [ name "l" ] ) ]
        ]
"""

BODY_EQ_UNIONS = """
type Shape
    = Circle Name Int
    | Pair ( Name, Name )
    | Rec { n : Name, k : Int }
    | Empty


type Tree
    = Leaf
    | Node Tree Name Tree


type A
    = A (List B)
    | AEnd


type B
    = B Name A


type Box a
    = Box a (Maybe (Box a))


lines : List String
lines =
    List.map Debug.toString
        [ Circle (name "c") 1 == Circle (name "C") 1
        , Circle (name "c") 1 == Circle (name "C") 2
        , Pair ( name "a", name "b" ) == Pair ( name "A", name "B" )
        , Rec { n = name "r", k = 1 } == Rec { n = name "R", k = 1 }
        , Empty == Circle (name "c") 1
        , Empty == Empty
        , Node Leaf (name "t") (Node Leaf (name "u") Leaf) == Node Leaf (name "T") (Node Leaf (name "U") Leaf)
        , Node Leaf (name "t") Leaf == Node Leaf (name "T") (Node Leaf (name "U") Leaf)
        , A [ B (name "m") AEnd, B (name "n") (A []) ] == A [ B (name "M") AEnd, B (name "N") (A []) ]
        , A [ B (name "m") AEnd ] == A [ B (name "m") (A []) ]
        , Box (name "x") (Just (Box (name "y") Nothing)) == Box (name "X") (Just (Box (name "Y") Nothing))
        , Box ( name "x", 1 ) Nothing == Box ( name "X", 1 ) Nothing
        , Box 1 Nothing == Box 1 (Just (Box 1 Nothing))
        , [ Node Leaf (name "a") Leaf ] == [ Node Leaf (name "A") Leaf ]
        , Just (Pair ( name "p", name "q" )) /= Just (Pair ( name "P", name "Q" ))
        ]
"""

BODY_EQ_VECTOR = """
lines : List String
lines =
    List.map Debug.toString
        [ Vector.fromList [ name "a", name "b" ] == Vector.fromList [ name "A", name "B" ]
        , Vector.fromList [ name "a" ] == Vector.fromList [ name "A", name "B" ]
        , Vector.fromList [ ( name "a", 1 ) ] == Vector.fromList [ ( name "A", 1 ) ]
        , [ Vector.fromList [ Just (name "v") ] ] == [ Vector.fromList [ Just (name "V") ] ]
        , Vector.fromList [ name "a" ] /= Vector.fromList [ name "b" ]
        ]
"""

BODY_CI = """
showPairs : List ( Ci, Int ) -> String
showPairs ps =
    String.join "," (List.map (\\( c, i ) -> showCi c ++ "/" ++ String.fromInt i) ps)


lines : List String
lines =
    [ Debug.toString (Set.fromList [ ci "a", ci "B" ] == Set.fromList [ ci "A", ci "b" ])
    , Debug.toString (Set.fromList [ ( ci "a", 1 ) ] == Set.fromList [ ( ci "A", 1 ) ])
    , Debug.toString (Set.member ( ci "X", 2 ) (Set.fromList [ ( ci "x", 2 ), ( ci "y", 1 ) ]))
    , Debug.toString (Set.size (Set.fromList [ ( ci "x", 2 ), ( ci "X", 2 ), ( ci "x", 3 ) ]))
    , Debug.toString (Dict.get ( ci "K", [ ci "l" ] ) (Dict.fromList [ ( ( ci "k", [ ci "L" ] ), "found" ) ]))
    , showPairs (Dict.keys (Dict.fromList [ ( ( ci "b", 1 ), () ), ( ( ci "A", 2 ), () ), ( ( ci "a", 1 ), () ) ]))
    , Debug.toString (Dict.fromList [ ( ( ci "a", 1 ), "x" ) ] == Dict.fromList [ ( ( ci "A", 1 ), "x" ) ])
    , Debug.toString (Dict.member [ ci "Q", ci "r" ] (Dict.fromList [ ( [ ci "q", ci "R" ], 1 ) ]))
    , Debug.toString (compare [ ci "a", ci "b" ] [ ci "A", ci "C" ])
    , Debug.toString ([ ci "a" ] < [ ci "A", ci "a" ])
    , showPairs (List.sort [ ( ci "b", 2 ), ( ci "A", 3 ), ( ci "a", 1 ) ])
    , Debug.toString (List.member [ ci "Q" ] [ [ ci "q" ] ])
    , Debug.toString (( ci "m", 1 ) == ( ci "M", 1 ))
    ]
"""

BODY_CMP = """
sd : List Desc -> String
sd ds =
    String.join "," (List.map showDesc ds)


sdp : List ( Desc, String ) -> String
sdp ps =
    String.join "," (List.map (\\( d, s ) -> showDesc d ++ s) ps)


lines : List String
lines =
    [ Debug.toString (compare ( desc 1, "a" ) ( desc 2, "a" ))
    , Debug.toString (( desc 1, "a" ) < ( desc 2, "a" ))
    , Debug.toString (( desc 1, "a" ) <= ( desc 1, "b" ))
    , Debug.toString (( desc 3, "a" ) > ( desc 2, "z" ))
    , Debug.toString (( desc 3, "a" ) >= ( desc 3, "a" ))
    , sdp [ max ( desc 1, "a" ) ( desc 2, "b" ), min ( desc 1, "a" ) ( desc 2, "b" ) ]
    , Debug.toString (compare [ desc 1, desc 2 ] [ desc 1, desc 3 ])
    , Debug.toString ([ desc 5 ] < [ desc 5, desc 1 ])
    , sdp (List.sort [ ( desc 1, "x" ), ( desc 3, "y" ), ( desc 2, "z" ), ( desc 3, "a" ) ])
    , sdp (List.sortBy (\\( d, s ) -> ( s, d )) [ ( desc 1, "x" ), ( desc 3, "x" ), ( desc 2, "a" ) ])
    , String.join ";" (List.map sd (List.sort [ [ desc 1 ], [ desc 2, desc 1 ], [], [ desc 2 ] ]))
    , Maybe.withDefault "none" (Maybe.map sd (List.maximum [ [ desc 1 ], [ desc 2, desc 1 ], [ desc 2 ] ]))
    , Maybe.withDefault "none" (Maybe.map (\\( d, s ) -> showDesc d ++ s) (List.minimum [ ( desc 1, "x" ), ( desc 3, "y" ) ]))
    , String.join "," (List.map (\\( ( d, n ), v ) -> showDesc d ++ String.fromInt n ++ v) (Dict.toList (Dict.fromList [ ( ( desc 1, 1 ), "a" ), ( ( desc 2, 1 ), "b" ), ( ( desc 2, 0 ), "c" ) ])))
    , Debug.toString (Dict.get ( desc 2, 1 ) (Dict.fromList [ ( ( desc 1, 1 ), "a" ), ( ( desc 2, 1 ), "b" ) ]))
    , String.join ";" (List.map sd (Set.toList (Set.fromList [ [ desc 1 ], [ desc 2 ], [ desc 1, desc 1 ] ])))
    , String.join "," (List.map (\\( p, _ ) -> showPt p) (List.sort [ ( pt 1 2, 0 ), ( pt 2 1, 0 ), ( pt 0 2, 0 ) ]))
    , Debug.toString (compare ( ( desc 1, "a" ), [ ( desc 2, 3 ) ] ) ( ( desc 1, "a" ), [ ( desc 3, 3 ) ] ))
    , Debug.toString (List.map (\\( p, q ) -> compare p q) [ ( ( desc 1, desc 2 ), ( desc 1, desc 1 ) ), ( ( desc 2, desc 2 ), ( desc 2, desc 2 ) ) ])
    ]
"""

RANK_FIC = """
type Rank
    = Rank Int
    where
        compare : Rank -> Rank -> Order
        compare =
            byNegated


byNegated : Rank -> Rank -> Order
byNegated (Rank a) (Rank b) =
    Basics.compare b a


rank : Int -> Rank
rank n =
    Rank n


showRank : Rank -> String
showRank (Rank n) =
    String.fromInt n


type Digit
    = Digit Int
    where
        eq : Digit -> Digit -> Bool
        eq =
            \\(Digit a) (Digit b) -> modBy 10 a == modBy 10 b


digit : Int -> Digit
digit n =
    Digit n


type Half
    = Half Int
    where
        compare : Half -> Half -> Order
        compare (Half a) =
            \\(Half b) -> Basics.compare (a // 2) (b // 2)


half : Int -> Half
half n =
    Half n
"""

RANK_ELM = """
type alias Rank =
    Int


rank : Int -> Rank
rank n =
    negate n


showRank : Rank -> String
showRank n =
    String.fromInt (negate n)


type Digit
    = Digit Int


digit : Int -> Digit
digit n =
    Digit (modBy 10 n)


type alias Half =
    Int


half : Int -> Half
half n =
    n // 2
"""

BODY_RANK = """
lines : List String
lines =
    [ Debug.toString (( rank 1, 0 ) < ( rank 2, 0 ))
    , String.join "," (List.map (\\( r, _ ) -> showRank r) (List.sort [ ( rank 1, 0 ), ( rank 3, 0 ), ( rank 2, 0 ) ]))
    , Debug.toString (compare [ rank 1 ] [ rank 1, rank 0 ])
    , Debug.toString ([ digit 13 ] == [ digit 3 ])
    , Debug.toString (( digit 13, 1 ) == ( digit 4, 1 ))
    , Debug.toString (Just (digit 21) == Just (digit 1))
    , Debug.toString (compare ( half 4, 1 ) ( half 5, 1 ))
    , Debug.toString (( half 4, 1 ) < ( half 6, 0 ))
    ]
"""

NAMES_FIC = """
type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


name : String -> Name
name s =
    Name s


type Desc
    = Desc Int
    where
        compare : Desc -> Desc -> Order
        compare (Desc a) (Desc b) =
            Basics.compare b a


desc : Int -> Desc
desc n =
    Desc n


showDesc : Desc -> String
showDesc (Desc n) =
    String.fromInt n
"""

NAMES_ELM = """
type Name
    = Name String


name : String -> Name
name s =
    Name (String.toLower s)


type alias Desc =
    Int


desc : Int -> Desc
desc n =
    negate n


showDesc : Desc -> String
showDesc n =
    String.fromInt (negate n)
"""

HOLDER = """
type Holder
    = Holder (List Name) (Maybe Holder)


type alias Key =
    ( Desc, Int )


key : Int -> Int -> Key
key d n =
    ( desc d, n )


sameHolder : Holder -> Holder -> Bool
sameHolder a b =
    a == b
"""

BODY_IMPORTED = """
lines : List String
lines =
    [ Debug.toString (Holder.Holder [ Names.name "a" ] Nothing == Holder.Holder [ Names.name "A" ] Nothing)
    , Debug.toString (Holder.sameHolder (Holder.Holder [] (Just (Holder.Holder [ Names.name "x" ] Nothing))) (Holder.Holder [] (Just (Holder.Holder [ Names.name "X" ] Nothing))))
    , Debug.toString (Holder.Holder [ Names.name "a" ] Nothing == Holder.Holder [ Names.name "b" ] Nothing)
    , String.join "," (List.map (\\( d, n ) -> Names.showDesc d ++ "/" ++ String.fromInt n) (Dict.keys (Dict.fromList [ ( Holder.key 1 1, () ), ( Holder.key 3 1, () ), ( Holder.key 2 0, () ) ])))
    , Debug.toString (Holder.key 1 0 < Holder.key 2 0)
    ]
"""

BODY_WORD = """
big : Word64
big =
    w 4294967295 5


small : Word64
small =
    w 1 0


mid : Word64
mid =
    w 2147483648 0


sw : List Word64 -> String
sw xs =
    String.join "," (List.map showW xs)


lines : List String
lines =
    [ Debug.toString (( big, 1 ) < ( small, 1 ))
    , Debug.toString (compare ( mid, "a" ) ( small, "a" ))
    , Debug.toString ([ small, big ] < [ small, mid ])
    , sw (List.map Tuple.first (List.sort [ ( big, 0 ), ( small, 0 ), ( mid, 0 ), ( w 0 7, 0 ) ]))
    , sw (List.map Tuple.first (List.sortBy (\\( a, b ) -> ( b, a )) [ ( big, 0 ), ( small, 0 ), ( mid, 0 ) ]))
    , sw (List.map Tuple.first (Dict.keys (Dict.fromList [ ( ( big, 1 ), () ), ( ( small, 1 ), () ), ( ( mid, 1 ), () ) ])))
    , String.join ";" (List.map sw (Set.toList (Set.fromList [ [ big ], [ small, big ], [ mid ] ])))
    , sw (List.map Tuple.first [ max ( big, 0 ) ( small, 0 ), min ( big, 0 ) ( small, 0 ) ])
    , Maybe.withDefault "none" (Maybe.map sw (List.maximum [ [ small ], [ big ], [ mid, big ] ]))
    , Debug.toString (Dict.get ( mid, 1 ) (Dict.fromList [ ( ( big, 1 ), "big" ), ( ( mid, 1 ), "mid" ) ]))
    , Debug.toString (( big, 1 ) == ( w 4294967295 5, 1 ))
    , Debug.toString (compare ( ( small, big ), 1 ) ( ( small, mid ), 1 ))
    , sw (List.sort [ big, small, mid ])
    ]
"""

METERS_FIC = """
type Meters
    = Meters Float
    where
        fromFloat : Float -> Meters
        fromFloat x =
            Meters (x * 2)


raw : Meters -> Float
raw (Meters m) =
    m


half : Meters
half =
    0.25


scaled : Float -> Float
scaled f =
    f * 1.5
"""

BODY_METERS_FIC = """
lines : List String
lines =
    [ String.fromFloat (raw half)
    , String.fromFloat (raw 1.5)
    , String.fromFloat (List.sum (List.map raw [ 0.5, 2.25 ]))
    , String.fromFloat (let m = 4.5 in raw m)
    , String.fromFloat (scaled 2.5)
    , String.fromFloat (0.1 + 0.2)
    , String.fromFloat (let f = 2.5 in f * 2)
    , Debug.toString (Meters 1.0 == 0.5)
    , Debug.toString (List.map raw (Maybe.withDefault [] (Just [ 1.25 ])))
    ]
"""

METERS_ELM = """
type Meters
    = Meters Float


fromFloat : Float -> Meters
fromFloat x =
    Meters (x * 2)


raw : Meters -> Float
raw (Meters m) =
    m


half : Meters
half =
    fromFloat 0.25


scaled : Float -> Float
scaled f =
    f * 1.5
"""

BODY_METERS_ELM = """
lines : List String
lines =
    [ String.fromFloat (raw half)
    , String.fromFloat (raw (fromFloat 1.5))
    , String.fromFloat (List.sum (List.map raw [ fromFloat 0.5, fromFloat 2.25 ]))
    , String.fromFloat (let m = fromFloat 4.5 in raw m)
    , String.fromFloat (scaled 2.5)
    , String.fromFloat (0.1 + 0.2)
    , String.fromFloat (let f = 2.5 in f * 2)
    , Debug.toString (Meters 1.0 == fromFloat 0.5)
    , Debug.toString (List.map raw (Maybe.withDefault [] (Just [ fromFloat 1.25 ])))
    ]
"""

METERS_TYPE = """
type Meters
    = Meters Float
    where
        fromFloat : Float -> Meters
        fromFloat x =
            Meters (x * 2)
"""

BODY_DEFAULTS = """
area : Float -> Float
area r =
    3.14159 * r * r


lines : List String
lines =
    [ String.fromFloat (area 2.5)
    , String.fromFloat (let k = 0.1 in k + 0.2)
    , String.fromFloat (List.sum [ 0.5, 1.25, 1.0e-3 ])
    , Debug.toString ( 1.5, [ 2.5 ] )
    , String.fromFloat (max 1.5 2.5)
    , String.fromFloat (toFloat 3 / 2.0)
    ]
"""

F32_FIC = """
import Float32 exposing (Float32)


x : Float32
x =
    0.1


scale : Float32 -> Float32
scale v =
    v * 2.5


lines : List String
lines =
    [ Float32.toString x
    , Float32.toString (x + 0.2)
    , Float32.toString -0.5
    , Float32.toString (List.sum [ 0.1, 0.2, 0.3 ])
    , Debug.toString (x == Float32.fromFloat 0.1)
    , Float32.toString (let y = 1.1 in y * y)
    , String.fromFloat (0.1 + 0.2)
    , Float32.toString (scale 3.3)
    , Debug.toString (( x, 1 ) < ( 0.2, 1 ))
    , Float32.toString 16777217.0
    , Float32.toString 3.4028235e38
    ]
"""

F32_OLD = """
import Float32 exposing (Float32)


x : Float32
x =
    Float32.fromFloat 0.1


scale : Float32 -> Float32
scale v =
    v * Float32.fromFloat 2.5


lines : List String
lines =
    [ Float32.toString x
    , Float32.toString (x + Float32.fromFloat 0.2)
    , Float32.toString (negate (Float32.fromFloat 0.5))
    , Float32.toString (List.sum [ Float32.fromFloat 0.1, Float32.fromFloat 0.2, Float32.fromFloat 0.3 ])
    , Debug.toString (x == Float32.fromFloat 0.1)
    , Float32.toString (let y = Float32.fromFloat 1.1 in y * y)
    , String.fromFloat (0.1 + 0.2)
    , Float32.toString (scale (Float32.fromFloat 3.3))
    , Debug.toString (x < Float32.fromFloat 0.2)
    , Float32.toString (Float32.fromFloat 16777217.0)
    , Float32.toString (Float32.fromFloat 3.4028235e38)
    ]
"""

ERR_MISSING = """
type Meters
    = Meters Float
    where
        fromFloat : Float -> Meters
        fromFloat x =
            Meters x


type Feet
    = Feet Float


f : Feet
f =
    0.5


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
"""

ERR_SHAPE = """
type Meters
    = Meters Float
    where
        fromFloat : Int -> Meters
        fromFloat x =
            Meters (toFloat x)


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
"""

ERR_ELM_LITERAL = """
type Meters
    = Meters Float


f : Meters
f =
    0.5


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
"""

JS_FROMFLOAT = """
type Meters
    = Meters Float
    where
        fromFloat : Float -> Meters
        fromFloat x =
            Meters x


raw : Meters -> Float
raw (Meters m) =
    m


lines : List String
lines =
    [ String.fromFloat (raw 0.5) ]
"""


def case(cid, desc, files, twin, row, c_only=False):
    return dict(id=cid, desc=desc, files=files, twin=twin, row=row, c_only=c_only)


ELM_IMPORTS = ["Array", "Dict", "Set"]

CASES_NEW = [
    case("a3b-eq-builtin", "eq member inside lists, tuples, records, Maybe, Result, Dict values, Array (tail and tree), nested; List.member, /=, generic, filter",
         {"Main.elm": prog(ELM_IMPORTS, NAME_FIC, BODY_EQ_BUILTIN)},
         ("elm", {"Main.elm": prog(ELM_IMPORTS, NAME_ELM, BODY_EQ_BUILTIN)}), ("RUN", "c", "")),
    case("a3b-eq-unions", "eq member inside user unions: fields, tuple and record fields, recursive, mutually recursive, parameterized (at Name, at a tuple, at Int)",
         {"Main.elm": prog([], NAME_FIC, BODY_EQ_UNIONS)},
         ("elm", {"Main.elm": prog([], NAME_ELM, BODY_EQ_UNIONS)}), ("RUN", "c", "")),
    case("a3b-eq-vector", "eq member inside Vector (twin: Array as Vector)",
         {"Main.elm": prog(["Vector"], NAME_FIC, BODY_EQ_VECTOR)},
         ("elm", {"Main.elm": prog(["Array as Vector"], NAME_ELM, BODY_EQ_VECTOR)}), ("RUN", "c", ""), c_only=True),
    case("a3b-ci-keys", "a type with eq and compare: Set and Dict equality, tuple and list keys of Dict and Set, sort, member",
         {"Main.elm": prog(ELM_IMPORTS, CI_FIC, BODY_CI)},
         ("elm", {"Main.elm": prog(ELM_IMPORTS, CI_ELM, BODY_CI)}), ("RUN", "c", "")),
    case("a3b-cmp", "compare member inside tuples and lists: compare < <= > >= max min, sort, sortBy, maximum, minimum, Dict and Set keys, nested",
         {"Main.elm": prog(ELM_IMPORTS, DESC_FIC, BODY_CMP)},
         ("elm", {"Main.elm": prog(ELM_IMPORTS, DESC_ELM, BODY_CMP)}), ("RUN", "c", "")),
    case("a3b-member-forms", "members written point free (compare = byNegated), as a lambda (eq), with one parameter (compare (Half a) = \\(Half b) -> ...)",
         {"Main.elm": prog([], RANK_FIC, BODY_RANK)},
         ("elm", {"Main.elm": prog([], RANK_ELM, BODY_RANK)}), ("RUN", "c", "")),
    case("a3b-imported", "the member types in one module, the holder and the key alias in another, used from Main",
         {"Names.elm": prog([], NAMES_FIC, "", "Names", "Name, Desc, name, desc, showDesc"),
          "Holder.elm": prog([], "import Names exposing (Name, Desc, desc)", HOLDER, "Holder", "Holder(..), Key, key, sameHolder"),
          "Main.elm": prog(["Dict", "Holder", "Names"], "", BODY_IMPORTED)},
         ("elm", {"Names.elm": prog([], NAMES_ELM, "", "Names", "Name, Desc, name, desc, showDesc"),
                  "Holder.elm": prog([], "import Names exposing (Name, Desc, desc)", HOLDER, "Holder", "Holder(..), Key, key, sameHolder"),
                  "Main.elm": prog(["Dict", "Holder", "Names"], "", BODY_IMPORTED)}), ("RUN", "c", "")),
    case("a3b-word64", "Word64 (unsigned order) inside tuples, lists, nested tuples; sort, sortBy, Dict and Set keys, max, min, maximum",
         {"Main.elm": prog(["Dict", "Set"], WORD_FIC, BODY_WORD)},
         ("elm", {"Main.elm": prog(["Dict", "Set"], WORD_ELM, BODY_WORD)}), ("RUN", "c", ""), c_only=True),
    case("a3b-fromfloat-user", "Float literals at a user type with fromFloat: annotated value, argument, list, let (held), ==; Float uses in the same module",
         {"Main.elm": prog([], METERS_FIC, BODY_METERS_FIC)},
         ("elm", {"Main.elm": prog([], METERS_ELM, BODY_METERS_ELM)}), ("RUN", "c", "")),
    case("a3b-fromfloat-defaults", "a type with fromFloat in sight, every Float literal used at Float: JS and C as Elm (twin: no such type)",
         {"Main.elm": prog([], METERS_TYPE, BODY_DEFAULTS)},
         ("elm", {"Main.elm": prog([], "", BODY_DEFAULTS)}), ("RUN", "js+c", "")),
    case("a3b-fromfloat-float32", "Float literals at Float32 (rounded to float as Float32.fromFloat): value, operand, negative, list, let, tuple key; twin: explicit Float32.fromFloat on elmficA4b",
         {"Main.elm": prog([], F32_FIC, "")},
         ("oldc", {"Main.elm": prog([], F32_OLD, "")}), ("RUN", "c", ""), c_only=True),
    case("a3b-err-fromfloat-missing", "a Float literal at a type without fromFloat while another type has it: NO MEMBER",
         {"Main.elm": "module Main exposing (main)\n\n" + ERR_MISSING}, None, ("REJECT", "NO ATTACHED FUNCTION", "fromFloat")),
    case("a3b-err-fromfloat-shape", "fromFloat with the wrong type",
         {"Main.elm": "module Main exposing (main)\n\n" + ERR_SHAPE}, None, ("REJECT", "OPERATOR FUNCTION WITH THE WRONG TYPE", "fromFloat : Float -> Meters")),
    case("a3b-err-float-literal-elm", "no fromFloat in sight: a Float literal at a user type is Elm's TYPE MISMATCH, as before",
         {"Main.elm": "module Main exposing (main)\n\n" + ERR_ELM_LITERAL}, None, ("REJECT", "TYPE MISMATCH", "")),
    case("a3b-js-fromfloat", "--output=out.js of a program with a Float literal at a type with fromFloat: refused",
         {"Main.elm": prog([], JS_FROMFLOAT, "")}, None, ("REJECT", "NOT AVAILABLE IN JAVASCRIPT YET", "operators on custom types")),
]


# the A3 cases that the A3b lifts: their sources stay, the twin gives expected.out
def holds_twin(body_lines, prologue="", imports=()):
    lines = "lines : List String\nlines =\n    [ " + "\n    , ".join(body_lines) + "\n    ]\n"
    return {"Main.elm": prog(list(imports), prologue, lines)}

NAME_PLAIN = "type Name\n    = Name String\n"
VER_PLAIN = "type Ver\n    = Ver Int\n\n\nverKey : Ver -> Int\nverKey (Ver n) =\n    negate n\n"

CASES_CONVERTED = [
    ("a3-c-holds-union", None),
    ("a3-c-holds-recursive", None), ("a3-c-holds-mutual", None), ("a3-c-holds-alias", None), ("a3-c-holds-generic", None),
    ("a3-c-holds-member", None), ("a3-c-holds-tuple", None), ("a3-c-holds-record", None), ("a3-c-holds-imported", None),
    ("a3-c-holds-imported-both", None),
    ("a3-c-holds-dictkey", holds_twin(['Debug.toString (Dict.get ( verKey (Ver 1), 2 ) (Dict.fromList [ ( ( verKey (Ver 1), 2 ), "x" ) ]))'], VER_PLAIN, ["Dict"])),
    ("a3-c-holds-sortby", holds_twin(['Debug.toString (List.map .k (List.sortBy (\\r -> Tuple.mapFirst verKey r.k) [ { k = ( Ver 2, 1 ) }, { k = ( Ver 1, 1 ) } ]))'], VER_PLAIN)),
    ("a3-c-holds-set", holds_twin(['Debug.toString (Set.size (Set.fromList [ List.map verKey [ Ver 1 ], List.map verKey [ Ver 2 ] ]))'], VER_PLAIN, ["Set"])),
    ("sized-err-word64-tuple", ("empty", None)),
    ("sized-err-float-literal", ("empty", None)),
]


def lowered_twin(cid):
    """the twin of an `eq` holds case: the same sources with every string literal lowered (Name's eq is case-insensitive,
    so structural == on lowered strings is the member) and the `where` block removed"""
    out = {}
    d = os.path.join(CASES, cid)
    for fn in os.listdir(d):
        if not fn.endswith(".elm"): continue
        src = open(os.path.join(d, fn), encoding="utf-8").read()
        keep, skip = [], False
        for line in src.splitlines():
            if line.strip() == "where": skip = True; continue
            if skip and (line.startswith("        ") or line.strip() == ""):
                if line.strip() == "": keep.append(line)
                continue
            skip = False
            keep.append(line)
        src = "\n".join(keep) + "\n"
        # lower the contents of the "..." literals that are arguments of Name (Name "A", Names.Name "A")
        import re
        src = re.sub(r'(Name\s+)"([^"]*)"', lambda m: m.group(1) + '"' + m.group(2).lower() + '"', src)
        out[fn] = src
    return out


def write():
    rows = {}
    for c in CASES_NEW:
        d = os.path.join(CASES, c["id"])
        os.makedirs(d, exist_ok=True)          # expected.out (written by --expect) stays
        for fn, src in c["files"].items():
            open(os.path.join(d, fn), "w", encoding="utf-8").write(src)
        meta = {"desc": c["desc"]}
        if c["c_only"]: meta["c_only"] = True
        json.dump(meta, open(os.path.join(d, "case.json"), "w"))
        rows[c["id"]] = c["row"]
        if c["twin"]:
            td = os.path.join(TWINS, c["id"])
            if os.path.isdir(td): shutil.rmtree(td)
            os.makedirs(td)
            open(os.path.join(td, "kind"), "w").write(c["twin"][0] + "\n")
            for fn, src in c["twin"][1].items():
                open(os.path.join(td, fn), "w", encoding="utf-8").write(src)
    for cid, twin in CASES_CONVERTED:
        rows[cid] = ("RUN", "c", "")
        td = os.path.join(TWINS, cid)
        if os.path.isdir(td): shutil.rmtree(td)
        os.makedirs(td)
        if twin is None: twin = ("elm", lowered_twin(cid))
        elif isinstance(twin, dict): twin = ("elm", twin)
        open(os.path.join(td, "kind"), "w").write(twin[0] + "\n")
        for fn, src in (twin[1] or {}).items():
            open(os.path.join(td, fn), "w", encoding="utf-8").write(src)
    # expected.tsv: replace the rows of these ids, append the new ones
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
    print("wrote %d new cases, %d converted rows" % (len(CASES_NEW), len(CASES_CONVERTED)))


def run_twin(cid, elm0193, old, home):
    td = os.path.join(TWINS, cid)
    kind = open(os.path.join(td, "kind")).read().strip()
    if kind == "empty": return ""
    work = tempfile.mkdtemp(prefix="a3btwin-")
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
    old = os.path.join(root, "bin", "elmficA4b")
    home = tempfile.mkdtemp(prefix="a3btwin-home-")
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
