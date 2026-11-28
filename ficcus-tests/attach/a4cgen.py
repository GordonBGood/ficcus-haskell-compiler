#!/usr/bin/env python3
"""a4cgen.py -- the A4c cases of the attach suite: derived `toString` (docs/A4-DERIVE-DESIGN.md section 2: exactly Elm's
Debug.toString, structural all the way down), the derived enumeration members `minValue`, `maxValue`, `succ`, `pred`, `enumerate`,
the built-in members (`toString` of every type Debug.toString shows; the five enumeration members of Bool and Order; `minValue`,
`maxValue` of Int and the sized integers), and the A4b review's F4 and F6.  Standard library only.  Standalone: it imports only
attach and mkhome (the helpers are those of a4bgen.py / a4bfgen.py).
  python3 ficcus-tests/attach/a4cgen.py --write                 # write cases/a4c-*/, a4c-twins/ and the rows of expected.tsv
  python3 ficcus-tests/attach/a4cgen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case
The expected output of a RUN case is never written by hand.  An `elm` twin is plain Elm on bin/elm0193 + node: the same program
with `Debug.toString` for each derived or built-in `toString`, and hand-written lists for the enumeration members.  An `oldc`
twin (the types Elm cannot show: Vector, the sized types) is the same program with `Debug.toString`, on bin/elmficT1c."""
import argparse, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a4c-twins")
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
# original positions), Dict and Set keys, the position of the maximum.  The same text in the Ficcus program and in its twin.
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


import re

# ---------------------------------------------------------------------------------------------------------------- the two sides
# A source with markers becomes the Ficcus program (fic=True) or its plain Elm twin (fic=False):
#   @D{m1, m2}   the derive line of the type above (Elm: nothing)
#   @TS{T}       `T.toString` (Elm: `Debug.toString`)
#   @{key}       the entry `key` of the side's table (FICX / ELMX of the case)

def side(src, fic, table=None):
    table = table or {}
    src = re.sub(r"@D\{([^}]*)\}", (lambda m: "\n    where\n        derive " + m.group(1)) if fic else (lambda m: ""), src)
    src = re.sub(r"@TS\{([^}]*)\}", (lambda m: m.group(1) + ".toString") if fic else (lambda m: "Debug.toString"), src)
    src = re.sub(r"@\{([^}]*)\}", lambda m: table[m.group(1)], src)
    return src


def pair(cid, desc, imports, src, ficx=None, elmx=None, kind="elm", files_fic=None, files_twin=None, twin_imports=None):
    fic = {"Main.elm": mod(imports, side(src, True, ficx))}
    fic.update(files_fic or {})
    twin = {"Main.elm": mod(imports if twin_imports is None else twin_imports, side(src, False, elmx))}
    twin.update(files_twin or {})
    case(cid, desc, fic, (kind, twin))


SHOW_FIC = """

showIt : a -> String
    where
        a has toString : a -> String
showIt x =
    toString x
"""
SHOW_ELM = """

showIt : a -> String
showIt x =
    Debug.toString x
"""

# ---------------------------------------------------------------------------------------------------------------- a4c-format

FORMAT = r'''

type alias Person =
    { name : String, age : Int, zeta : Float, aB : Int, ab : Int, m : Int, arr : Int }


type P
    = P Person
    | Q {}
    | E { b : Int, a : ( Int, Float ), c : { z : Int, y : String } }@D{toString}


type Shape
    = Circle Float
    | Rect Float Float
    | Named String Shape
    | Pt { x : Int, y : Int }
    | Unit
    | Many (List Shape) (Maybe Shape) ( Int, Char )
    | Res (Result String (Maybe Int)) (Result (List Int) ())
    | Box (Dict.Dict Int String) (Set.Set Char) (Array.Array Float)
    | Flags Bool Order ()
    | Deep (Maybe (Maybe (Maybe Int))) (List (List Shape))@D{toString}


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)@D{toString}


type Ext r
    = Ext { r | x : Int }@D{toString}


type Txt
    = Txt String Char
    | Cs (List Char)@D{toString}


bump : Person -> Person
bump p =
    { p | age = p.age + 1 }


floats : List Float
floats =
    [ 1.0, -0.0, 0.1, 1.0e21, 1.0e-7, 123456789012345678, 0 / 0, 1 / 0, -1 / 0, -2.5, 5.0e-324, 1.7976931348623157e308, 100, 1.0e20, 0.000001 ]


shapes : List Shape
shapes =
    List.map Circle floats
        ++ [ Rect -1 2
           , Named "a b" (Circle 0)
           , Named "x" (Named "y" (Rect 1 2))
           , Pt { x = -1, y = 2 }
           , Unit
           , Many [ Unit, Circle -3 ] (Just (Named "" Unit)) ( -9007199254740991, '\'' )
           , Many [] Nothing ( 0, ' ' )
           , Res (Ok (Just -1)) (Err [ -1, 2 ])
           , Res (Err "e r") (Ok ())
           , Box (Dict.fromList [ ( 2, "b" ), ( 1, "a" ) ]) (Set.fromList [ 'z', 'a' ]) (Array.fromList [ 1.5, -0 ])
           , Box Dict.empty Set.empty Array.empty
           , Flags True LT ()
           , Flags False GT ()
           , Deep (Just (Just Nothing)) [ [ Unit ], [] ]
           , Deep (Just (Just (Just -7))) []
           ]


txts : List Txt
txts =
    [ Txt "a\"b\\c\nd\te'f\r\u{000B}\u{0000}é😀\u{007F}\u{0001}" '"'
    , Txt "" '\\'
    , Txt "hello world" '\n'
    , Cs [ 'a', '\'', '"', '\\', '\n', '\t', '\u{0000}', '\u{000D}', '\u{000B}', 'é', '😀', '\u{007F}', '\u{0001}', '\u{001F}', '中' ]
    ]


lines : List String
lines =
    [ @TS{P} (P { name = "Bo", age = 3, zeta = 1.5, aB = 1, ab = 2, m = 4, arr = 5 })
    , @TS{P} (P (Person "Al" -4 -0.5 7 8 9 10))
    , @TS{P} (P (bump (Person "Al" 4 -0.5 7 8 9 10)))
    , @TS{P} (Q {})
    , @TS{P} (E { b = 1, a = ( -1, 0 / 0 ), c = { z = 1, y = "s t" } })
    , @TS{Tree} (Node (Node Leaf 1 Leaf) 2 Leaf)
    , @TS{Tree} (Node Leaf -2 (Node Leaf 3 Leaf))
    , @TS{Tree} (Node Leaf "s t" Leaf)
    , @TS{Tree} (Node Leaf -1.5 (Node Leaf (0 / 0) Leaf))
    , @TS{Tree} (Node Leaf (Just -1) Leaf)
    , @TS{Tree} (Node Leaf (Node Leaf 'c' Leaf) Leaf)
    , @TS{Tree} (Node Leaf { a = -1, b = [ "x" ] } Leaf)
    , @TS{Tree} (Node Leaf ( 1, "a", 'c' ) Leaf)
    , @TS{Tree} (Node Leaf Unit (Node Leaf (Circle -1) Leaf))
    , @TS{Tree} (Node Leaf [ Ok 1, Err "e" ] Leaf)
    , @TS{Tree} (Leaf |> always (Node Leaf () Leaf))
    , @TS{Ext} (Ext { x = 1, y = 2 })
    , @TS{Ext} (Ext { x = -1, w = "s", aa = [ 1.5 ] })
    , @TS{Ext} (Ext { x = 3 })
    ]
        ++ List.map @TS{Shape} shapes
        ++ List.map @TS{Txt} txts
        ++ [ Debug.toString (List.map (\s -> ( s, Unit )) shapes) ]
'''

pair("a4c-format", "derived toString equals Elm's Debug.toString: records (Name order, alias constructor, update, empty, nested), "
     "custom types (parentheses, negatives, records and strings as arguments), Maybe, Result, lists, tuples, unit, Bool, Order, "
     "Dict, Set, Array, strings and chars with every escape and Unicode, floats (NaN, Infinity, -0, exponents), an extensible "
     "record in a custom type (P1 row)", ["Array", "Dict", "Set"], FORMAT)

# ---------------------------------------------------------------------------------------------------------------- a4c-cycles

CYCLES = r'''

type Expr
    = Num Int
    | Add Expr Expr
    | Neg Expr
    | Block (List Stmt)@D{toString}


type Stmt
    = Let String Expr
    | Print Expr
    | Nest (Maybe Stmt)@D{toString}


type A
    = A1 B
    | AEnd@D{toString}


type B
    = B1 C@D{toString}


type C
    = C1 A
    | CStop Int@D{toString}


negs : Int -> Expr -> Expr
negs n e =
    if n <= 0 then
        e

    else
        negs (n - 1) (Neg e)


chain : Int -> A
chain n =
    if n <= 0 then
        AEnd

    else
        A1 (B1 (C1 (chain (n - 1))))


sum : Int -> Expr
sum n =
    List.foldl (\i acc -> Add acc (Num i)) (Num 0) (List.range 1 n)


prog : Stmt
prog =
    Nest (Just (Let "x" (Block [ Print (Num -1), Nest Nothing, Let "y z" (Add (Num 1) (Neg (Num 2))) ])))


lines : List String
lines =
    [ @TS{Stmt} prog
    , @TS{Expr} (Block [ prog, Print (Block []) ])
    , @TS{Expr} (negs 3 (Num 7))
    , @TS{Expr} (negs 400 (Num -7))
    , @TS{Expr} (sum 300)
    , @TS{A} (chain 3)
    , @TS{A} (chain 300)
    , @TS{B} (B1 (CStop -1))
    , @TS{C} (C1 (A1 (B1 (CStop 2))))
    ]
'''

pair("a4c-cycles", "derived toString over types that refer to each other (Expr/Stmt, a cycle A -> B -> C -> A), deep nesting "
     "(400 Neg, a chain of 900 constructors), a left-nested sum of 300", [], CYCLES)

# ---------------------------------------------------------------------------------------------------------------- a4c-long

LONG = r'''

type Big
    = Big (List Int) String (List String)
    | Chars (List Char)@D{toString}


big : Big
big =
    Big (List.range -5000 5000)
        (String.repeat 700 "a\"\\\n\t é😀\u{0001}中")
        (List.map (\i -> String.fromInt i ++ "\u{000B}" ++ String.repeat (modBy 7 i) "ü") (List.range 1 1000))


lines : List String
lines =
    [ @TS{Big} big
    , @TS{Big} (Chars (String.toList (String.repeat 300 "x'\"\\\r😀")))
    , String.fromInt (List.length (String.toList (@TS{Big} big)))
    ]
'''

pair("a4c-long", "derived toString of a long list (10001 Ints), a long string with escapes and Unicode (700 repeats), 1000 "
     "strings, a long list of chars; the length of the text in code points (`String.length` counts UTF-16 units in Elm, L11)", [], LONG)

# ---------------------------------------------------------------------------------------------------------------- a4c-has-tostring

HAS = r'''

type Color
    = Red
    | Green
    | Blue@D{toString}


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)@D{toString}


type Name
    = Name String@{nameWhere}


type Wrap
    = Wrap Name (List Name)@D{toString}
@{show}@{nameFun}

results : ( Result String Int, Result Char Int )
results =
    ( Ok 1, Err 'e' )


showAll : List a -> List String@{allWhere}
showAll xs =
    List.map @{showOne} xs


lines : List String
lines =
    [ showIt 1
    , showIt -9007199254740991
    , showIt 1.5
    , showIt (0 / 0)
    , showIt "s \"q\"\n"
    , showIt 'c'
    , showIt [ Just 1.5, Nothing ]
    , showIt { b = 1, a = "x" }
    , showIt ( True, LT )
    , showIt ( (), 1 )
    , showIt results
    , showIt (Dict.fromList [ ( 1, Red ) ])
    , showIt (Set.fromList [ "b", "a" ])
    , showIt (Array.fromList [ Red, Blue ])
    , showIt Red
    , showIt (Node Leaf Red Leaf)
    , showIt { c = Red, t = Node Leaf ( Blue, [ Green ] ) Leaf }
    , showIt (Just (Node Leaf (Just Red) Leaf))
    , showIt (Wrap (Name "bob") [ Name "al", Name "" ])
    , @{nameShow} (Name "bob")
    , @TS{Wrap} (Wrap (Name "x y") [])
    , String.join "|" (showAll [ Red, Green, Blue ])
    , String.join "|" (showAll [ [ 1 ], [] ])
    ]
'''

pair("a4c-has-tostring", "`a has toString` at the built-in types (Int, Float, String quoted, Char, List, Maybe, records, tuples, "
     "Bool, Order, (), Result, Dict, Set, Array) and derived ones inside them; structural all the way down: a written "
     "`Name.toString` inside a derived type is not called, but `a has toString` at `Name` itself calls it",
     ["Array", "Dict", "Set"], HAS,
     ficx={"nameWhere": "\n    where\n        toString : Name -> String\n        toString (Name s) =\n            s", "show": SHOW_FIC,
           "nameFun": "", "nameShow": "showIt", "allWhere": "\n    where\n        a has toString : a -> String", "showOne": "toString"},
     elmx={"nameWhere": "", "show": SHOW_ELM,
           "nameFun": "\n\nnameToString : Name -> String\nnameToString (Name s) =\n    s\n", "nameShow": "nameToString",
           "allWhere": "", "showOne": "Debug.toString"})

# ---------------------------------------------------------------------------------------------------------------- a4c-unshowable

UNSHOW = r'''

type Holder
    = H (Vector Int) (Vector (Maybe String))
    | S Int8 Int16 Int32
    | U Word8 Word16 Word32 Word64
    | F Float32
    | Nested (List Holder) (Vector Holder)@D{toString}
@{show}

lines : List String
lines =
    [ @TS{Holder} (H (Vector.fromList [ 1, -2 ]) (Vector.fromList [ Just "a b", Nothing ]))
    , @TS{Holder} (H (Vector.fromList []) (Vector.fromList []))
    , @TS{Holder} (S (Int8.fromInt -128) (Int16.fromInt 32767) (Int32.fromInt -5))
    , @TS{Holder} (U (Word8.fromInt 255) (Word16.fromInt -1) (Word32.fromInt 7) (Word64.shiftLeftBy 63 (Word64.fromInt 1)))
    , @TS{Holder} (F (Float32.fromFloat 0.1))
    , @TS{Holder} (F (Float32.fromFloat -1.5))
    , @TS{Holder} (Nested [ F (Float32.fromFloat 2) ] (Vector.fromList [ S (Int8.fromInt 1) (Int16.fromInt 2) (Int32.fromInt 3) ]))
    , showIt (Vector.fromList [ Word64.fromInt -1 ])
    , showIt ( Int8.fromInt -1, Float32.fromFloat 3 )
    ]
'''

UNSHOW_IMPORTS = ["Vector exposing (Vector)", "Int8 exposing (Int8)", "Int16 exposing (Int16)", "Int32 exposing (Int32)",
                  "Word8 exposing (Word8)", "Word16 exposing (Word16)", "Word32 exposing (Word32)", "Word64 exposing (Word64)",
                  "Float32 exposing (Float32)"]
pair("a4c-unshowable", "derived and built-in toString of the types Elm cannot show (Vector, the sized integers, Float32): the "
     "format of Debug.toString in C (oldc twin: the same program with Debug.toString on elmficT1c)", UNSHOW_IMPORTS, UNSHOW,
     ficx={"show": SHOW_FIC}, elmx={"show": SHOW_ELM}, kind="oldc")

# ---------------------------------------------------------------------------------------------------------------- a4c-cross-module

SHAPES_FIC = """module Shapes exposing (Shape(..), Secret, secret)


type Shape
    = Dot
    | Circle Float
    where
        derive toString, compare


type Secret
    = Secret Int String
    where
        derive toString


secret : Int -> Secret
secret n =
    Secret n "hidden"
"""
SHAPES_ELM = SHAPES_FIC.replace("\n    where\n        derive toString, compare", "").replace("\n    where\n        derive toString", "")

CROSS = r'''

type Local
    = Local Shape (List Shapes.Secret)@D{toString}


lines : List String
lines =
    [ @{shapeTs} (Circle 1.5)
    , @{shapeTs2} Dot
    , @{secretTs} (Shapes.secret 3)
    , @TS{Local} (Local Dot [ Shapes.secret -1 ])
    ]
'''
pair("a4c-cross-module", "derived toString of an exposed union and an opaque type of another module (G70: members follow the "
     "type name), inside a derived type of Main", ["Shapes exposing (Shape(..))"], CROSS,
     ficx={"shapeTs": "Shapes.Shape.toString", "shapeTs2": "Shapes.Shape.toString", "secretTs": "Shapes.Secret.toString"},
     elmx={"shapeTs": "Debug.toString", "shapeTs2": "Debug.toString", "secretTs": "Debug.toString"},
     files_fic={"Shapes.elm": SHAPES_FIC}, files_twin={"Shapes.elm": SHAPES_ELM})

# ---------------------------------------------------------------------------------------------------------------- a4c-enum

ENUM = r'''

type Color
    = Red
    | Green
    | Blue@D{minValue, maxValue, succ, pred, enumerate, toString, compare}


type Phantom a
    = P1
    | P2
    | P3@D{minValue, maxValue, succ, pred, enumerate}


type One
    = One@D{minValue, maxValue, succ, pred, enumerate}


type Big
    = B0 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | B8 | B9 | B10 | B11 | B12 | B13 | B14 | B15 | B16 | B17 | B18 | B19
    | B20 | B21 | B22 | B23 | B24 | B25 | B26 | B27 | B28 | B29 | B30 | B31 | B32 | B33 | B34 | B35 | B36 | B37 | B38 | B39@D{succ, pred, enumerate, minValue, maxValue}
@{defs}

walkWith : (a -> Maybe a) -> a -> List a
walkWith step x =
    case step x of
        Just y ->
            x :: walkWith step y

        Nothing ->
            [ x ]


phantomEnum : List (Phantom Int)
phantomEnum =
    @{enumP}


phantomStart : Phantom String
phantomStart =
    @{minP}


lines : List String
lines =
    [ Debug.toString ( @{enumC}, List.map @{succC} @{enumC}, List.map @{predC} @{enumC} )
    , Debug.toString ( ( @{minC}, @{maxC} ), walkWith @{succC} @{minC} == @{enumC}, List.reverse (walkWith @{predC} @{maxC}) == @{enumC} )
    , Debug.toString ( List.sortWith @{cmpC} (List.reverse @{enumC}) == @{enumC}, List.map (\c -> ( c, @{succC} c )) [ Blue, Red ] )
    , Debug.toString ( phantomEnum, ( @{succP} phantomStart, @{predP} phantomStart ), walkWith @{succP} phantomStart )
    , Debug.toString ( ( @{enumO}, @{succO} One, @{predO} One ), ( @{minO}, @{maxO} ) )
    , Debug.toString ( List.length @{enumB}, walkWith @{succB} @{minB} == @{enumB}, ( @{maxB}, @{predB} @{maxB}, @{succB} @{maxB} ) )
    , Debug.toString ( ( @{walkBool}, @{walkOrder}, @{walkColor} ), ( @{countBool}, @{countOrder}, @{countColor} ) )
    , Debug.toString ( @{boundsBool}, @{boundsOrder}, @{boundsColor} )
    , Debug.toString ( @{backBool}, @{backOrder} )
    , String.join " " [ @{textInt}, @{textInt8}, @{textInt16}, @{textInt32}, @{textWord8}, @{textWord16}, @{textWord32}, @{textWord64} ]
    ]
'''

ENUM_FIC_DEFS = """

walk : a -> List a
    where
        a has succ : a -> Maybe a
walk x =
    walkWith succ x


walkBack : a -> List a
    where
        a has maxValue : a
        a has pred : a -> Maybe a
walkBack _ =
    walkWith pred maxValue


count : a -> Int
    where
        a has enumerate : List a
count _ =
    List.length enumerate


bounds : a -> ( a, a )
    where
        a has minValue : a
        a has maxValue : a
bounds _ =
    ( minValue, maxValue )


boundsText : a -> String
    where
        a has minValue : a
        a has maxValue : a
        a has toString : a -> String
boundsText _ =
    toString minValue ++ ".." ++ toString maxValue
"""

ENUM_ELM_DEFS = """

colorAll : List Color
colorAll =
    [ Red, Green, Blue ]


phantomAll : List (Phantom a)
phantomAll =
    [ P1, P2, P3 ]


bigAll : List Big
bigAll =
    [ B0, B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15, B16, B17, B18, B19
    , B20, B21, B22, B23, B24, B25, B26, B27, B28, B29, B30, B31, B32, B33, B34, B35, B36, B37, B38, B39 ]


-- the next element of the declaration order (hand-written: the list, then the element after the given one)
nextIn : List a -> a -> Maybe a
nextIn all x =
    case all of
        a :: b :: rest ->
            if a == x then
                Just b

            else
                nextIn (b :: rest) x

        _ ->
            Nothing


prevIn : List a -> a -> Maybe a
prevIn all x =
    nextIn (List.reverse all) x


firstIn : List a -> a -> a
firstIn all d =
    Maybe.withDefault d (List.head all)


lastIn : List a -> a -> a
lastIn all d =
    firstIn (List.reverse all) d


colorCompare : Color -> Color -> Order
colorCompare a b =
    compare (indexOf a colorAll) (indexOf b colorAll)


indexOf : a -> List a -> Int
indexOf x all =
    case all of
        [] ->
            0

        y :: rest ->
            if y == x then
                0

            else
                1 + indexOf x rest
"""

ENUM_FIC = {
    "defs": ENUM_FIC_DEFS,
    "enumC": "Color.enumerate", "succC": "Color.succ", "predC": "Color.pred", "minC": "Color.minValue", "maxC": "Color.maxValue",
    "cmpC": "Color.compare",
    "enumP": "Phantom.enumerate", "minP": "Phantom.minValue", "succP": "Phantom.succ", "predP": "Phantom.pred",
    "enumO": "One.enumerate", "succO": "One.succ", "predO": "One.pred", "minO": "One.minValue", "maxO": "One.maxValue",
    "enumB": "Big.enumerate", "succB": "Big.succ", "predB": "Big.pred", "minB": "Big.minValue", "maxB": "Big.maxValue",
    "walkBool": "walk False", "walkOrder": "walk LT", "walkColor": "walk Red",
    "countBool": "count True", "countOrder": "count EQ", "countColor": "count Red",
    "boundsBool": "bounds True", "boundsOrder": "bounds GT", "boundsColor": "bounds Green",
    "backBool": "walkBack True", "backOrder": "walkBack GT",
    "textInt": "boundsText 0", "textInt8": "boundsText (Int8.fromInt 0)", "textInt16": "boundsText (Int16.fromInt 0)",
    "textInt32": "boundsText (Int32.fromInt 0)", "textWord8": "boundsText (Word8.fromInt 0)",
    "textWord16": "boundsText (Word16.fromInt 0)", "textWord32": "boundsText (Word32.fromInt 0)",
    "textWord64": "boundsText (Word64.fromInt 0)",
}
ENUM_ELM = {
    "defs": ENUM_ELM_DEFS,
    "enumC": "colorAll", "succC": "(nextIn colorAll)", "predC": "(prevIn colorAll)", "minC": "(firstIn colorAll Blue)",
    "maxC": "(lastIn colorAll Red)", "cmpC": "colorCompare",
    "enumP": "phantomAll", "minP": "(firstIn phantomAll P3)", "succP": "(nextIn phantomAll)", "predP": "(prevIn phantomAll)",
    "enumO": "[ One ]", "succO": "(nextIn [ One ])", "predO": "(prevIn [ One ])", "minO": "(firstIn [ One ] One)",
    "maxO": "(lastIn [ One ] One)",
    "enumB": "bigAll", "succB": "(nextIn bigAll)", "predB": "(prevIn bigAll)", "minB": "(firstIn bigAll B39)",
    "maxB": "(lastIn bigAll B0)",
    # Bool and Order: declaration order False < True (A4b's compare), LT < EQ < GT
    "walkBool": "walkWith (nextIn [ False, True ]) False", "walkOrder": "walkWith (nextIn [ LT, EQ, GT ]) LT",
    "walkColor": "walkWith (nextIn colorAll) Red",
    "countBool": "List.length [ False, True ]", "countOrder": "List.length [ LT, EQ, GT ]", "countColor": "List.length colorAll",
    "boundsBool": "( firstIn [ False, True ] True, lastIn [ False, True ] False )",
    "boundsOrder": "( firstIn [ LT, EQ, GT ] GT, lastIn [ LT, EQ, GT ] LT )",
    "boundsColor": "( firstIn colorAll Blue, lastIn colorAll Red )",
    "backBool": "walkWith (prevIn [ False, True ]) True", "backOrder": "walkWith (prevIn [ LT, EQ, GT ]) GT",
    # the 64 bit bounds are beyond JavaScript's 2^53: the twin writes their decimal text (Debug.toString of the number)
    "textInt": '"-9223372036854775808..9223372036854775807"', "textInt8": '"-128..127"', "textInt16": '"-32768..32767"',
    "textInt32": '"-2147483648..2147483647"', "textWord8": '"0..255"', "textWord16": '"0..65535"',
    "textWord32": '"0..4294967295"', "textWord64": '"0..18446744073709551615"',
}
pair("a4c-enum", "derived minValue, maxValue, succ, pred, enumerate (declaration order, total succ/pred, phantom parameter, one "
     "constructor, 40 constructors, enumerate == iterate succ minValue, consistent with compare); the built-in members of Bool "
     "and Order (all five) and the bounds of Int and the sized integers through `a has`",
     ["Int8", "Int16", "Int32", "Word8", "Word16", "Word32", "Word64"], ENUM, ficx=ENUM_FIC, elmx=ENUM_ELM, twin_imports=[])

# ---------------------------------------------------------------------------------------------------------------- the A4b review: F4, F6

OWNVEC_FIC = """module Vector exposing (Vector(..), fromList)


type Vector a
    = Vector (List a) Int
    where
        compare : Vector a -> Vector a -> Order
        compare (Vector _ m) (Vector _ n) =
            Basics.compare m n


fromList : List a -> Vector a
fromList xs =
    Vector xs (List.length xs)
"""
OWNVEC_ELM = """module Vector exposing (Vector(..), fromList, compareV)


type Vector a
    = Vector (List a) Int


compareV : Vector a -> Vector a -> Order
compareV (Vector _ m) (Vector _ n) =
    Basics.compare m n


fromList : List a -> Vector a
fromList xs =
    Vector xs (List.length xs)
"""
OWNVEC = r'''
@{sortW}

len : Vector a -> Int
len (Vector.Vector _ n) =
    n


lines : List String
lines =
    [ Debug.toString ( @{cmp} (Vector.fromList [ 1, 2 ]) (Vector.fromList [ 3 ]), @{cmp} (Vector.fromList [ \x -> x ]) (Vector.fromList []) )
    , Debug.toString (List.map len (@{sort} [ Vector.fromList [ 5, 5 ], Vector.fromList [ 9 ], Vector.fromList [] ]))
    ]
'''
pair("a4c-f4-own-vector-fn", "A4b review F4: a project's own module `Vector` with a written `compare` (no constraint) is compared "
     "by it at `Vector (a -> a)` (was TYPE MISMATCH: the core container rule came first)", ["Vector exposing (Vector)"], OWNVEC,
     ficx={"sortW": "\n\nsortW : List a -> List a\n    where\n        a has compare : a -> a -> Order\nsortW xs =\n    List.sortWith compare xs\n",
           "cmp": "compare", "sort": "sortW"},
     elmx={"sortW": "", "cmp": "Vector.compareV", "sort": "List.sortWith Vector.compareV"},
     files_fic={"Vector.elm": OWNVEC_FIC}, files_twin={"Vector.elm": OWNVEC_ELM})

F6 = r'''

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare, hash


sortTrees : List (Tree comparable) -> List (Tree comparable)@{where}
sortTrees =
    List.sortWith Tree.compare


lines : List String
lines =
    [ Debug.toString ( sortTrees [ Node Leaf "b" Leaf, Leaf, Node (Node Leaf "a" Leaf) "a" Leaf, Node Leaf "a" Leaf ], sortTrees [ Node Leaf 3 Leaf, Leaf ] )
    ]
'''
pair("a4c-f6-value-at-comparable", "A4b review F6: `List.sortWith Tree.compare` at `Tree comparable` needs no `where` line: the "
     "super type `comparable` gives `compare` (oldc twin: the same with the line, on elmficT1c)", [], F6,
     ficx={"where": ""}, elmx={"where": "\n    where\n        comparable has compare : comparable -> comparable -> Order"}, kind="oldc")

# ---------------------------------------------------------------------------------------------------------------- errors

def worker1(body):
    return {"Main.elm": mod([], body)}

TREE_TS = """

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive toString
"""

bad("a4c-err-tostring-function-arg", "Tree.toString at `Tree (Int -> Int)`: a function has no toString",
    worker1(TREE_TS + "\n\nlines : List String\nlines =\n    [ Tree.toString (Node Leaf (\\x -> x + 1) Leaf) ]\n"), "NO ATTACHED FUNCTION", "toString")
bad("a4c-err-has-tostring-function", "`a has toString` at a function",
    worker1(SHOW_FIC + "\n\nlines : List String\nlines =\n    [ showIt (\\x -> x + 1) ]\n"), "NO ATTACHED FUNCTION", "toString")
bad("a4c-err-has-tostring-open-record", "`a has toString` at an extensible record: closed records only (A4bf F1)",
    worker1(SHOW_FIC + "\n\nf : { r | x : Int } -> String\nf r =\n    showIt r\n\n\nlines : List String\nlines =\n    [ f { x = 1 } ]\n"),
    "NO ATTACHED FUNCTION", "closed record")
bad("a4c-err-succ-int", "`a has succ` at Int: Int has only minValue and maxValue",
    worker1("\n\nnext : a -> Maybe a\n    where\n        a has succ : a -> Maybe a\nnext x =\n    succ x\n\n\nlines : List String\nlines =\n    [ Debug.toString (next one) ]\n\n\none : Int\none =\n    1\n"),
    "NO ATTACHED FUNCTION", "succ")
bad("a4c-err-min-float", "`a has minValue` at Float: Float has no bounds",
    worker1("\n\nlow : a -> a\n    where\n        a has minValue : a\nlow _ =\n    minValue\n\n\nlines : List String\nlines =\n    [ Debug.toString (low 1.5) ]\n"),
    "NO ATTACHED FUNCTION", "minValue")
bad("a4c-err-define-tostring", "toString both derived and written",
    worker1("\n\ntype Color\n    = Red\n    where\n        derive toString\n\n        toString : Color -> String\n        toString _ =\n            \"r\"\n\n\nlines : List String\nlines =\n    [ Color.toString Red ]\n"),
    "DERIVE AND DEFINE", "toString")
bad("a4c-err-enum-fields", "succ on a type with a constructor that has fields",
    worker1("\n\ntype Color\n    = Red\n    | Mix Int\n    where\n        derive succ\n\n\nlines : List String\nlines =\n    [ \"\" ]\n"),
    "DERIVE ON NON-ENUMERATION", "Mix")
bad("a4c-js-tostring", "derived toString in a JavaScript build: refused",
    worker1(TREE_TS + "\n\nlines : List String\nlines =\n    [ Tree.toString (Node Leaf 1 Leaf) ]\n"), "DERIVED MEMBERS", "derives toString")

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
    work = tempfile.mkdtemp(prefix="a4ctwin-")
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
    old = os.path.join(root, "bin", "elmficT1c")
    home = tempfile.mkdtemp(prefix="a4ctwin-home-")
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
