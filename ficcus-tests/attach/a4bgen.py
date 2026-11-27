#!/usr/bin/env python3
"""a4bgen.py -- the A4b cases of the attach suite (derived `compare` and `hash`; `compare` on records, Maybe, Result, Array,
Vector, Dict and Set; docs/attach/A4B-NOTES.md).  Standard library only.  Standalone: it imports only attach and mkhome
(not g71gen or a5agen), so a `--write` cannot rewrite the rows or files of another generator.

  python3 ficcus-tests/attach/a4bgen.py --write                 # write cases/a4b-*/, a4b-twins/ and the rows of expected.tsv
  python3 ficcus-tests/attach/a4bgen.py --expect [--only ids]   # build the twins, write expected.out of every RUN case

The expected output of a RUN case is never written by hand: it is the output of a *twin* program.
  elm   plain Elm, compiled by bin/elm0193 and run by node.  A derived type is replaced by a representation whose structural
        `compare` IS the derived order (an enumeration by `Int`; `Maybe a` by `List a`, Nothing = [] < [x]; a record by the tuple
        of its fields in alphabetical order; `Result e a` by `( tag, [a], [e] )`; `Array`, `Vector`, `Set` by their lists, `Dict`
        by its `toList`; Word64 by `( hi, lo )`), or by a hand-written comparison function (the recursive `Tree`) with the
        `Dict`/`Set` results computed from it; `hash` by the identity (so `hash a == hash b` prints `a == b`, the law).
  oldc  a Ficcus program that the reference binary (bin/elmficA5c) compiles to C: the documented hash (splitmix64 finalizer,
        FNV-1a 64) written out with Word64 arithmetic, for the stable hash values."""
import argparse, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
TWINS = os.path.join(HERE, "a4b-twins")
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


# ---------------------------------------------------------------------------------------------------------------- enumeration

ENUM_LINES = """

names : List Color -> String
names cs =
    String.join "," (List.map name cs)


colors : List Color
colors =
    [ Blue, Red, Green, Red ]


lines : List String
lines =
    [ Debug.toString (List.map (\\a -> List.map (\\b -> CMP a b) colors) colors)
    , Debug.toString (List.map (\\a -> List.map (\\b -> compare a b) colors) colors)
    , Debug.toString (List.map (\\a -> List.map (\\b -> ( a < b, a <= b, ( a > b, a >= b ) )) colors) colors)
    , names (List.sort colors)
    , names (List.sortWith CMP colors)
    , names (List.reverse (List.sortBy identity colors))
    , names [ max Red Blue, min Green Blue, max Green Green ]
    , Debug.toString ( Maybe.map name (List.maximum colors), Maybe.map name (List.minimum colors) )
    , String.join ";" (List.map (\\( c, i ) -> name c ++ String.fromInt i) (Dict.toList (Dict.fromList (List.indexedMap (\\i c -> ( c, i )) colors))))
    , names (Set.toList (Set.fromList colors))
    , Debug.toString (Dict.values (Dict.fromList [ ( ( Green, 1 ), "a" ), ( ( Red, 2 ), "b" ), ( ( Green, 0 ), "c" ), ( ( Blue, -1 ), "d" ) ]))
    , Debug.toString ( compare [ Red, Blue ] [ Red, Green ], compare [ Blue ] [ Blue, Red ], [ Green ] < [ Blue ] )
    , Debug.toString ( Dict.get Green (Dict.fromList [ ( Red, 1 ), ( Green, 2 ) ]), Set.member Blue (Set.fromList [ Red ]) )
    , Debug.toString (List.map (\\c -> CMP c Green) [ Red, Green, Blue ])
    ]
"""

ENUM_FIC = """

type Color
    = Red
    | Green
    | Blue
    where
        derive compare


name : Color -> String
name c =
    case c of
        Red ->
            "Red"

        Green ->
            "Green"

        Blue ->
            "Blue"
""" + ENUM_LINES.replace("CMP", "Color.compare")

ENUM_ELM = """

type alias Color =
    Int


red : Color
red =
    0


green : Color
green =
    1


blue : Color
blue =
    2


name : Color -> String
name c =
    if c == 0 then
        "Red"

    else if c == 1 then
        "Green"

    else
        "Blue"
""" + ENUM_LINES.replace("CMP", "compare").replace("Red", "red").replace("Green", "green").replace("Blue", "blue")

case("a4b-enum", "derived compare of an enumeration: Color.compare, compare, the operators, sort, sortWith Color.compare, sortBy, "
     "max, min, clamp, maximum, minimum, Dict and Set keys, tuple keys, lists of the type",
     {"Main.elm": mod(["Dict", "Set"], ENUM_FIC)}, ("elm", {"Main.elm": mod(["Dict", "Set"], ENUM_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- recursive, parametric

TREE_COMMON = """

insert : comparable -> Tree comparable -> Tree comparable
insert x t =
    case t of
        Leaf ->
            Node Leaf x Leaf

        Node l v r ->
            if x < v then
                Node (insert x l) v r

            else
                Node l v (insert x r)


fromList : List comparable -> Tree comparable
fromList xs =
    List.foldl insert Leaf xs


trees : List (Tree Int)
trees =
    [ Leaf, fromList [ 2, 1, 3 ], fromList [ 1, 2, 3 ], fromList [ 2, 1 ], fromList [ 2, 1, 3 ], Node Leaf 5 Leaf, fromList [ 3 ], fromList [ 2, 3 ] ]


strees : List (Tree String)
strees =
    [ fromList [ "b", "a" ], fromList [ "a" ], Leaf, fromList [ "b" ], fromList [ "b", "c" ] ]
"""

TREE_FIC = """

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare
""" + TREE_COMMON + GROUP + """

lines : List String
lines =
    [ group "int" trees
    , group "string" strees
    , Debug.toString (List.map (\\a -> List.map (\\b -> Tree.compare a b) trees) trees)
    , Debug.toString ( List.maximum trees, List.minimum strees )
    , Debug.toString ( List.sort (List.take 4 trees), max (fromList [ 1 ]) Leaf )
    , Debug.toString ( compare (Just (fromList [ 1 ])) Nothing, compare [ Leaf, fromList [ 1 ] ] [ Leaf, Leaf ], ( fromList [ 2 ], 1 ) < ( fromList [ 2 ], 0 ) )
    , Debug.toString (Dict.values (Dict.fromList [ ( ( fromList [ 1 ], 2 ), "x" ), ( ( Leaf, 5 ), "y" ), ( ( fromList [ 1 ], 1 ), "z" ) ]))
    , Debug.toString (Node Leaf 1 Leaf < Leaf)
    ]
"""

TREE_ELM = """

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)


cmpTree : Tree comparable -> Tree comparable -> Order
cmpTree a b =
    case ( a, b ) of
        ( Leaf, Leaf ) ->
            EQ

        ( Leaf, _ ) ->
            LT

        ( _, Leaf ) ->
            GT

        ( Node l1 v1 r1, Node l2 v2 r2 ) ->
            case cmpTree l1 l2 of
                EQ ->
                    case compare v1 v2 of
                        EQ ->
                            cmpTree r1 r2

                        o ->
                            o

                o ->
                    o


cmpList : (a -> a -> Order) -> List a -> List a -> Order
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
""" + TREE_COMMON + GROUP + TWINLIB + """

lines : List String
lines =
    [ groupW "int" cmpTree trees
    , groupW "string" cmpTree strees
    , Debug.toString (List.map (\\a -> List.map (\\b -> cmpTree a b) trees) trees)
    , Debug.toString ( maxA cmpTree trees, maxA (\\a b -> cmpTree b a) strees )
    , Debug.toString ( List.sortWith cmpTree (List.take 4 trees), Maybe.withDefault Leaf (maxA cmpTree [ fromList [ 1 ], Leaf ]) )
    , Debug.toString ( cmpList cmpTree [ fromList [ 1 ] ] [], cmpList cmpTree [ Leaf, fromList [ 1 ] ] [ Leaf, Leaf ], (case cmpTree (fromList [ 2 ]) (fromList [ 2 ]) of
                                                                                                                          EQ -> compare 1 0
                                                                                                                          o -> o) == LT )
    , Debug.toString (List.map Tuple.second (assoc (\\( t1, n1 ) ( t2, n2 ) -> case cmpTree t1 t2 of
                                                                                EQ -> compare n1 n2
                                                                                o -> o) [ ( ( fromList [ 1 ], 2 ), "x" ), ( ( Leaf, 5 ), "y" ), ( ( fromList [ 1 ], 1 ), "z" ) ]))
    , Debug.toString (cmpTree (Node Leaf 1 Leaf) Leaf == LT)
    ]
"""

case("a4b-tree", "derived compare of a recursive parametric type at Tree Int and Tree String: the group report (compare, <, >=, "
     "sortBy, Dict and Set keys, maximum), Tree.compare, maximum and minimum, sort, max, Maybe and list and tuple of trees, `<` "
     "(the A4a case operator-param-not-yet)", {"Main.elm": mod(["Dict", "Set"], TREE_FIC)},
     ("elm", {"Main.elm": mod(["Dict", "Set"], TREE_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- the built-in containers

CONT_VALUES = """

maybes : List (Maybe Int)
maybes =
    [ Just 3, Nothing, Just -1, Just 3, Nothing, Just 0 ]


records : List { b : String, a : Int }
records =
    [ { a = 2, b = "x" }, { a = 1, b = "z" }, { b = "a", a = 2 }, { a = 1, b = "z" } ]


results : List (Result String Int)
results =
    [ Err "b", Ok 5, Err "a", Ok -2, Ok 5 ]


arrays : List (Array Int)
arrays =
    [ Array.fromList [ 1, 2 ]
    , Array.empty
    , Array.fromList [ 1 ]
    , Array.fromList (List.range 1 40)
    , Array.fromList (List.range 1 39 ++ [ 0 ])
    , Array.initialize 70 identity
    , Array.push 7 (Array.fromList (List.range 0 68))
    , Array.fromList (List.range 1 40)
    , Array.fromList (List.range 0 1100)
    , Array.set 1099 5 (Array.fromList (List.range 0 1100))
    ]


vectors : List (Vector Int)
vectors =
    [ Vector.fromList [ 1, 2 ], Vector.fromList [], Vector.fromList [ 1 ], Vector.fromList [ 1, 2, 0 ], Vector.fromList [ 1, 2 ], Vector.fromList [ 0, 9, 9 ] ]


dicts : List (Dict String Int)
dicts =
    [ Dict.fromList [ ( "a", 1 ) ], Dict.empty, Dict.fromList [ ( "b", 0 ), ( "a", 1 ) ], Dict.fromList [ ( "a", 2 ) ], Dict.fromList [ ( "a", 1 ), ( "b", 0 ) ], Dict.fromList [ ( "a", 1 ), ( "b", -1 ) ] ]


sets : List (Set Int)
sets =
    [ Set.fromList [ 3, 1 ], Set.fromList [ 1 ], Set.empty, Set.fromList [ 1, 2, 3 ], Set.fromList [ 1, 3 ] ]


nested : List (Maybe (List ( Int, Maybe String )))
nested =
    [ Just [ ( 1, Nothing ) ], Nothing, Just [ ( 1, Just "a" ) ], Just [], Just [ ( 0, Just "z" ), ( 9, Nothing ) ], Just [ ( 1, Nothing ) ] ]


recs2 : List { arr : Array Int, m : Maybe { k : String } }
recs2 =
    [ { arr = Array.fromList [ 1 ], m = Nothing }, { arr = Array.fromList [ 1 ], m = Just { k = "b" } }, { arr = Array.empty, m = Just { k = "a" } } ]


floatsM : List (Maybe Float)
floatsM =
    [ Just (0 / 0), Just 0, Just -0.0, Nothing, Just 1, Just (1 / 0) ]


floatsR : List { x : Float, y : Int }
floatsR =
    [ { x = 0, y = 1 }, { x = -0.0, y = 1 }, { x = 0 / 0, y = 0 }, { x = -1 / 0, y = 2 } ]
"""

CONT_FIC = """

type Tag
    = Tag Int
    where
        derive compare


dictsOfSets : List (Dict (Maybe Int) (Set String))
dictsOfSets =
    [ Dict.fromList [ ( Just 1, Set.fromList [ "x" ] ) ], Dict.fromList [ ( Nothing, Set.empty ) ], Dict.fromList [ ( Just 1, Set.fromList [ "w", "x" ] ), ( Nothing, Set.empty ) ], Dict.fromList [ ( Just -1, Set.fromList [ "x" ] ) ] ]
""" + CONT_VALUES + GROUP + """

lines : List String
lines =
    [ group "maybe" maybes
    , group "record" records
    , group "result" results
    , group "array" arrays
    , group "vector" vectors
    , group "dict" dicts
    , group "set" sets
    , group "nested" nested
    , group "recs2" recs2
    , group "dictsOfSets" dictsOfSets
    , orders "floatsM" floatsM
    , orders "floatsR" floatsR
    , Debug.toString ( compare (Just 1) Nothing, Just 2 < Just 10, max Nothing (Just -5) == Just -5 )
    , Debug.toString ( compare { a = 1, b = "x" } { a = 1, b = "y" }, { b = "z", a = 0 } < { a = 1, b = "a" } )
    , Debug.toString ( compare (Ok 1) (Err 0), compare (Err "a") (Err "b"), Ok 3 > Ok 2 )
    , Debug.toString ( Dict.get (Just 2) (Dict.fromList [ ( Just 2, "two" ), ( Nothing, "none" ) ]), List.map (Maybe.withDefault 99) (Dict.keys (Dict.fromList [ ( Just 2, "two" ), ( Nothing, "none" ), ( Just -1, "m" ) ])) )
    , Debug.toString ( Vector.fromList [ 1, 2 ] < Vector.fromList [ 1, 3 ], compare (Array.fromList [ 5 ]) (Array.fromList [ 4, 9 ]), compare (Set.fromList [ 2 ]) (Set.fromList [ 1, 3 ]) )
    , Debug.toString ( List.map (Maybe.withDefault -9) (List.sort maybes), List.map .a (List.sortBy identity records) )
    ]
"""

CONT_ELM = """

mb : Maybe a -> List a
mb m =
    case m of
        Nothing ->
            []

        Just x ->
            [ x ]


res : Result e a -> ( Int, List a, List e )
res r =
    case r of
        Ok v ->
            ( 0, [ v ], [] )

        Err e ->
            ( 1, [], [ e ] )


dictsOfSets : List (List ( List Int, List String ))
dictsOfSets =
    List.map (\\kvs -> Dict.toList (Dict.fromList (List.map (\\( k, v ) -> ( mb k, Set.toList v )) kvs)))
        [ [ ( Just 1, Set.fromList [ "x" ] ) ], [ ( Nothing, Set.empty ) ], [ ( Just 1, Set.fromList [ "w", "x" ] ), ( Nothing, Set.empty ) ], [ ( Just -1, Set.fromList [ "x" ] ) ] ]
""" + (CONT_VALUES
       .replace("List (Maybe Int)\nmaybes =\n    [", "List (List Int)\nmaybes =\n    List.map mb [")
       .replace("List { b : String, a : Int }\nrecords =\n    [", "List ( Int, String )\nrecords =\n    List.map (\\r -> ( r.a, r.b )) [")
       .replace("List (Result String Int)\nresults =\n    [", "List ( Int, List Int, List String )\nresults =\n    List.map res [")
       .replace("List (Array Int)\narrays =\n    [", "List (List Int)\narrays =\n    List.map Array.toList\n    [")
       .replace("List (Vector Int)", "List (List Int)").replace("Vector.fromList ", "")
       .replace("List (Dict String Int)\ndicts =\n    [", "List (List ( String, Int ))\ndicts =\n    List.map Dict.toList [")
       .replace("List (Set Int)\nsets =\n    [", "List (List Int)\nsets =\n    List.map Set.toList [")
       .replace("List (Maybe (List ( Int, Maybe String )))\nnested =\n    [", "List (List (List ( Int, List String )))\nnested =\n    List.map (\\m -> mb (Maybe.map (List.map (\\( i, s ) -> ( i, mb s ))) m)) [")
       .replace("List { arr : Array Int, m : Maybe { k : String } }\nrecs2 =\n    [", "List ( List Int, List String )\nrecs2 =\n    List.map (\\r -> ( Array.toList r.arr, mb (Maybe.map .k r.m) )) [")
       .replace("List (Maybe Float)\nfloatsM =\n    [", "List (List Float)\nfloatsM =\n    List.map mb [")
       .replace("List { x : Float, y : Int }\nfloatsR =\n    [", "List ( Float, Int )\nfloatsR =\n    List.map (\\r -> ( r.x, r.y )) [")
       ) + GROUP + """

lines : List String
lines =
    [ group "maybe" maybes
    , group "record" records
    , group "result" results
    , group "array" arrays
    , group "vector" vectors
    , group "dict" dicts
    , group "set" sets
    , group "nested" nested
    , group "recs2" recs2
    , group "dictsOfSets" dictsOfSets
    , orders "floatsM" floatsM
    , orders "floatsR" floatsR
    , Debug.toString ( compare [ 1 ] [], [ 2 ] < [ 10 ], max [] [ -5 ] == [ -5 ] )
    , Debug.toString ( compare ( 1, "x" ) ( 1, "y" ), ( 0, "z" ) < ( 1, "a" ) )
    , Debug.toString ( compare ( 0, [ 1 ], [] ) ( 1, [], [ 0 ] ), compare ( 1, [], [ "a" ] ) ( 1, [], [ "b" ] ), ( 0, [ 3 ], [] ) > ( 0, [ 2 ], [] ) )
    , Debug.toString ( Maybe.map List.head (Dict.get [ 2 ] (Dict.fromList [ ( [ 2 ], [ "two" ] ), ( [], [ "none" ] ) ])) |> Maybe.andThen identity, List.map (\\k -> Maybe.withDefault 99 (List.head k)) (Dict.keys (Dict.fromList [ ( [ 2 ], "two" ), ( [], "none" ), ( [ -1 ], "m" ) ])) )
    , Debug.toString ( [ 1, 2 ] < [ 1, 3 ], compare [ 5 ] [ 4, 9 ], compare [ 2 ] [ 1, 3 ] )
    , Debug.toString ( List.map (\\l -> Maybe.withDefault -9 (List.head l)) (List.sort maybes), List.map Tuple.first (List.sortBy identity records) )
    ]
"""

case("a4b-containers", "compare on records (alphabetical fields), Maybe (Nothing first), Result (Ok first), Array (lengths around 32 "
     "and 1100: the tree), Vector, Dict (as toList), Set, nested ones, NaN and -0.0 inside: the group report, direct uses, "
     "Dict keys of Maybe; the module sees a type with attached functions (the gate)",
     {"Main.elm": mod(["Array exposing (Array)", "Dict exposing (Dict)", "Set exposing (Set)", "Vector exposing (Vector)"], CONT_FIC)},
     ("elm", {"Main.elm": mod(["Array", "Dict", "Set"], CONT_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- Word64 above 2^63

W64_COMMON = """

big : Word64
big =
    w 4294967295 5


top : Word64
top =
    w 2147483648 0


small : Word64
small =
    w 1 0
"""

W64_FIC = """

type Big
    = Big Word64 String
    where
        derive compare, hash


w : Int -> Int -> Word64
w hi lo =
    Word64.or (Word64.shiftLeftBy 32 (Word64.fromInt hi)) (Word64.fromInt lo)
""" + W64_COMMON + GROUP + """

bigs : List Big
bigs =
    [ Big big "a", Big small "z", Big top "a", Big big "0", Big (w 0 7) "q" ]


lines : List String
lines =
    [ group "big" bigs
    , group "maybe" [ Just big, Nothing, Just small, Just top ]
    , group "record" [ { w = big, n = 1 }, { w = small, n = 2 }, { w = top, n = 0 }, { w = small, n = 1 } ]
    , group "array" [ Array.fromList [ big ], Array.fromList [ small, big ], Array.fromList [ top ] ]
    , Debug.toString ( Big big "a" < Big small "a", compare (Just top) (Just big), Big.compare (Big top "x") (Big top "y") )
    , Debug.toString ( Big.hash (Big big "a") == Big.hash (Big big "a"), Big.hash (Big big "a") == Big.hash (Big top "a") )
    ]
"""

W64_ELM = """

type alias Word64 =
    ( Int, Int )


w : Int -> Int -> Word64
w hi lo =
    ( hi, lo )
""" + W64_COMMON + GROUP + """

bigs : List ( Word64, String )
bigs =
    [ ( big, "a" ), ( small, "z" ), ( top, "a" ), ( big, "0" ), ( w 0 7, "q" ) ]


lines : List String
lines =
    [ group "big" bigs
    , group "maybe" [ [ big ], [], [ small ], [ top ] ]
    , group "record" [ ( 1, big ), ( 2, small ), ( 0, top ), ( 1, small ) ]
    , group "array" [ [ big ], [ small, big ], [ top ] ]
    , Debug.toString ( ( big, "a" ) < ( small, "a" ), compare [ top ] [ big ], compare ( top, "x" ) ( top, "y" ) )
    , Debug.toString ( ( big, "a" ) == ( big, "a" ), ( big, "a" ) == ( top, "a" ) )
    ]
"""

case("a4b-word64", "Word64 above 2^63 (unsigned order) in a derived type, Maybe, a record and an Array; Big.hash",
     {"Main.elm": mod(["Array", "Dict", "Set", "Word64 exposing (Word64)"], W64_FIC)},
     ("elm", {"Main.elm": mod(["Dict", "Set"], W64_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- nested members

NEST_FIC = """

type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b

        compare : Ci -> Ci -> Order
        compare (Ci a) (Ci b) =
            Basics.compare (String.toLower a) (String.toLower b)


type Color
    = Red
    | Green
    | Blue
    where
        derive compare


type Contact
    = Contact { name : Ci, color : Color, tags : List Ci, age : Maybe Int }
    where
        derive compare


contact : String -> Color -> List String -> Maybe Int -> Contact
contact n c ts a =
    Contact { name = Ci n, color = c, tags = List.map Ci ts, age = a }
""" + GROUP + """

contacts : List Contact
contacts =
    [ contact "Bo" Red [ "x" ] (Just 3)
    , contact "bo" Red [ "X" ] (Just 3)
    , contact "Al" Blue [] Nothing
    , contact "al" Green [ "a", "b" ] Nothing
    , contact "Cy" Red [ "x" ] (Just 2)
    , contact "BO" Red [ "x", "y" ] (Just 3)
    ]


lines : List String
lines =
    [ group "contact" contacts
    , group "maybe" (List.map Just contacts ++ [ Nothing ])
    , group "pair" (List.map (\\c -> ( c, Ci "k" )) contacts)
    , Debug.toString (Dict.values (Dict.fromList (List.indexedMap (\\i c -> ( ( Ci (if modBy 2 i == 0 then "K" else "k"), c ), i )) contacts)))
    , Debug.toString ( Contact.compare (contact "a" Red [] Nothing) (contact "A" Red [] Nothing), contact "a" Red [] Nothing == contact "A" Red [] Nothing )
    ]
"""

NEST_ELM = """

type alias Ci =
    String


ci : String -> Ci
ci =
    String.toLower


red : Int
red =
    0


green : Int
green =
    1


blue : Int
blue =
    2


type alias Contact =
    ( List Int, Int, ( Ci, List Ci ) )


contact : String -> Int -> List String -> Maybe Int -> Contact
contact n c ts a =
    ( Maybe.withDefault [] (Maybe.map List.singleton a), c, ( ci n, List.map ci ts ) )
""" + GROUP + """

contacts : List Contact
contacts =
    [ contact "Bo" red [ "x" ] (Just 3)
    , contact "bo" red [ "X" ] (Just 3)
    , contact "Al" blue [] Nothing
    , contact "al" green [ "a", "b" ] Nothing
    , contact "Cy" red [ "x" ] (Just 2)
    , contact "BO" red [ "x", "y" ] (Just 3)
    ]


lines : List String
lines =
    [ group "contact" contacts
    , group "maybe" (List.map List.singleton contacts ++ [ [] ])
    , group "pair" (List.map (\\c -> ( c, ci "k" )) contacts)
    , Debug.toString (Dict.values (Dict.fromList (List.indexedMap (\\i c -> ( ( ci (if modBy 2 i == 0 then "K" else "k"), c ), i )) contacts)))
    , Debug.toString ( compare (contact "a" red [] Nothing) (contact "A" red [] Nothing), contact "a" red [] Nothing == contact "A" red [] Nothing )
    ]
"""

case("a4b-nested", "a derived compare over a record with a written compare (Ci, case insensitive), a derived enumeration, a list and a "
     "Maybe of them (record fields in alphabetical order: age, color, name, tags); Maybe and tuples of it; Dict keys",
     {"Main.elm": mod(["Dict", "Set"], NEST_FIC)}, ("elm", {"Main.elm": mod(["Dict", "Set"], NEST_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- sorts (A3b review A2)

SORT_COMMON = """

seq : List Int
seq =
    List.map (\\i -> modBy 3 (i * 7 + i // 5)) (List.range 0 99)
"""

SORT_FIC = """

type Color
    = Red
    | Green
    | Blue
    where
        derive compare


type Ci
    = Ci String
    where
        compare : Ci -> Ci -> Order
        compare (Ci a) (Ci b) =
            Basics.compare (String.toLower a) (String.toLower b)


color : Int -> Color
color i =
    case i of
        0 ->
            Red

        1 ->
            Green

        _ ->
            Blue


rank : Color -> Int
rank c =
    case c of
        Red ->
            0

        Green ->
            1

        Blue ->
            2
""" + SORT_COMMON + """

lines : List String
lines =
    [ Debug.toString (List.map rank (List.sort (List.map color seq)))
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.indexedMap (\\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map Tuple.second (List.sortWith (\\( a, _ ) ( b, _ ) -> Color.compare a b) (List.indexedMap (\\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map (\\( c, i ) -> rank c * 1000 + i) (List.sort (List.indexedMap (\\i k -> ( color k, modBy 4 i )) seq)))
    , Debug.toString (Vector.toList (Vector.map rank (Vector.sort (Vector.fromList (List.map color seq)))))
    , Debug.toString (List.map (\\( c, Ci s ) -> String.fromInt (rank c) ++ s) (List.sort [ ( Blue, Ci "b" ), ( Red, Ci "B" ), ( Red, Ci "a" ), ( Blue, Ci "A" ) ]))
    , Debug.toString (List.map (Maybe.map rank) (List.sort [ Just Blue, Nothing, Just Red, Nothing ]))
    ]
"""

SORT_ELM = """

color : Int -> Int
color i =
    i


rank : Int -> Int
rank c =
    c
""" + SORT_COMMON + """

lines : List String
lines =
    [ Debug.toString (List.map rank (List.sort (List.map color seq)))
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.indexedMap (\\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map Tuple.second (List.sortWith (\\( a, _ ) ( b, _ ) -> compare a b) (List.indexedMap (\\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map (\\( c, i ) -> rank c * 1000 + i) (List.sort (List.indexedMap (\\i k -> ( color k, modBy 4 i )) seq)))
    , Debug.toString (List.map rank (List.sort (List.map color seq)))
    , Debug.toString (List.map (\\( c, s ) -> String.fromInt (rank c) ++ s) (List.sortWith (\\( c1, s1 ) ( c2, s2 ) -> case compare c1 c2 of
                                                                                                                EQ -> compare (String.toLower s1) (String.toLower s2)
                                                                                                                o -> o) [ ( 2, "b" ), ( 0, "B" ), ( 0, "a" ), ( 2, "A" ) ]))
    , Debug.toString (List.map (\\l -> List.head l) (List.sort [ [ 2 ], [], [ 0 ], [] ]))
    ]
"""

case("a4b-sort", "sorts of derived elements by the kernel comparator (List.sort, sortBy, sortWith, Vector.sort; stable ties, 100 "
     "elements) and of an element that also holds a written compare (the overlay's sortMember)",
     {"Main.elm": mod(["Vector"], SORT_FIC)}, ("elm", {"Main.elm": mod([], SORT_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- cross module, opaque

SHAPES = """module Shapes exposing (Email, Shape(..), email, show)


type Shape
    = Circle Float
    | Square Int
    | Dot
    where
        derive compare, hash


type Email
    = Email String
    where
        derive compare


email : String -> Email
email =
    Email


show : Email -> String
show (Email s) =
    s
"""

CROSS_FIC = """

shapes : List Shape
shapes =
    [ Square 2, Circle 1.5, Dot, Circle -0.0, Square 1, Circle 0, Dot ]
""" + GROUP + """

lines : List String
lines =
    [ group "shape" shapes
    , Debug.toString (List.map Shapes.show (Set.toList (Set.fromList (List.map Shapes.email [ "c@x", "a@x", "b@x", "a@x" ]))))
    , Debug.toString (Dict.toList (Dict.fromList (List.map (\\s -> ( s, 1 )) shapes)))
    , Debug.toString ( Shape.compare Dot (Square 9), Shapes.Shape.compare (Circle 2) (Circle 1), Shape.hash (Circle 0) == Shape.hash (Circle -0.0) )
    ]
"""

CROSS_ELM = """

type Shape
    = Circle Float
    | Square Int
    | Dot


enc : Shape -> ( Int, Float, Int )
enc s =
    case s of
        Circle r ->
            ( 0, r, 0 )

        Square n ->
            ( 1, 0, n )

        Dot ->
            ( 2, 0, 0 )


shapes : List Shape
shapes =
    [ Square 2, Circle 1.5, Dot, Circle -0.0, Square 1, Circle 0, Dot ]
""" + GROUP + TWINLIB + """

cmpS : Shape -> Shape -> Order
cmpS a b =
    compare (enc a) (enc b)


lines : List String
lines =
    [ groupW "shape" cmpS shapes
    , Debug.toString (Set.toList (Set.fromList [ "c@x", "a@x", "b@x", "a@x" ]))
    , Debug.toString (assoc cmpS (List.map (\\s -> ( s, 1 )) shapes))
    , Debug.toString ( cmpS Dot (Square 9), cmpS (Circle 2) (Circle 1), Circle 0 == Circle -0.0 )
    ]
"""

case("a4b-cross-module", "derived compare and hash of types of another module (an exposed union, an opaque type): Set and Dict keys, "
     "Shape.compare and Shapes.Shape.compare; Circle -0.0 and Circle 0 are equal, Dict keeps the later key (Elm's Dict.insert)",
     {"Shapes.elm": SHAPES, "Main.elm": mod(["Dict", "Set", "Shapes exposing (Shape(..))"], CROSS_FIC)},
     ("elm", {"Main.elm": mod(["Dict", "Set"], CROSS_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- hash: the law

HASH_TYPES = """

type Shape
    = Circle Float
    | Rect Int Int
    | None_
    WHERE_SHAPE


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    WHERE_TREE
"""

HASH_PAIRS = """

pairs : String -> List ( a, a ) -> String
PAIRS_WHERE
pairs label ps =
    label ++ " " ++ Debug.toString (List.map (\\( x, y ) -> ( x == y, hashOf x == hashOf y )) ps)


lines : List String
lines =
    [ pairs "int" [ ( 1, 1 ), ( 1, 2 ), ( -1, 1 ), ( 0, 0 ), ( 123456789012, 123456789012 ) ]
    , pairs "float" [ ( 0, -0.0 ), ( 1.5, 1.5 ), ( 1.5, 2.5 ), ( 1 / 0, 1 / 0 ), ( 1 / 0, -1 / 0 ) ]
    , pairs "string" [ ( "", "" ), ( "a", "a" ), ( "a", "b" ), ( "héllo", "héllo" ), ( "ab", "ba" ) ]
    , pairs "char" [ ( 'a', 'a' ), ( 'a', 'b' ) ]
    , pairs "bool" [ ( True, True ), ( True, False ) ]
    , pairs "unit" [ ( (), () ) ]
    , pairs "tuple" [ ( ( 1, "a" ), ( 1, "a" ) ), ( ( 1, "a" ), ( 1, "b" ) ) ]
    , pairs "tuplef" [ ( ( 0, -0.0 ), ( 0, 0 ) ), ( ( 1, 2.5 ), ( 1, 2 ) ) ]
    , pairs "list" [ ( [ 1, 2 ], [ 1, 2 ] ), ( [ 1, 2 ], [ 2, 1 ] ), ( [], [] ), ( [ 1 ], [ 1, 1 ] ) ]
    , pairs "record" [ ( { a = 1, b = "x" }, { b = "x", a = 1 } ), ( { a = 1, b = "x" }, { a = 1, b = "y" } ) ]
    , pairs "maybe" [ ( Just 1, Just 1 ), ( Just 1, Nothing ), ( Nothing, Nothing ), ( Just 0, Nothing ) ]
    , pairs "result" [ ( Ok 1, Ok 1 ), ( Ok 1, Err "1" ), ( Err "e", Err "e" ) ]
    , pairs "array" [ ( Array.fromList [ 1, 2 ], Array.fromList [ 1, 2 ] ), ( Array.fromList (List.range 1 50), Array.fromList (List.range 1 50) ), ( Array.fromList [ 1 ], Array.fromList [ 2 ] ) ]
    , pairs "vector" [ ( VEC [ 1, 2 ], VEC [ 1, 2 ] ), ( VEC [ 1, 2 ], VEC [ 1 ] ) ]
    , pairs "dict" [ ( Dict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ], Dict.fromList [ ( 3, "c" ), ( 1, "a" ), ( 2, "b" ) ] ), ( Dict.fromList [ ( 1, "a" ) ], Dict.fromList [ ( 1, "b" ) ] ) ]
    , pairs "set" [ ( Set.fromList [ 5, 1, 3, 2, 4 ], Set.fromList [ 1, 2, 3, 4, 5 ] ), ( Set.fromList [ 1 ], Set.fromList [ 1, 2 ] ) ]
    , pairs "shape" [ ( Circle 0, Circle -0.0 ), ( Rect 1 2, Rect 1 2 ), ( Rect 1 2, Rect 2 1 ), ( None_, None_ ), ( None_, Circle 0 ) ]
    , pairs "tree" [ ( Node Leaf "a" Leaf, Node Leaf "a" Leaf ), ( Node Leaf "a" Leaf, Node (Node Leaf "a" Leaf) "a" Leaf ), ( Leaf, Leaf ) ]
    , pairs "nested" [ ( [ Just { s = Circle 1, t = Dict.fromList [ ( "k", [ 1 ] ) ] } ], [ Just { s = Circle 1, t = Dict.fromList [ ( "k", [ 1 ] ) ] } ] ), ( [ Just { s = Circle 1, t = Dict.empty } ], [ Nothing ] ) ]
    , pairs "word64" [ ( W64HI, W64HI ), ( W64HI, W64LO ) ]
    , pairs "float32" [ ( F32Z, F32NZ ), ( F32Z, F32ONE ) ]
    ]
"""

HASH_FIC = (HASH_TYPES.replace("WHERE_SHAPE", "where\n        derive hash").replace("WHERE_TREE", "where\n        derive hash") + """

hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x
""" + HASH_PAIRS.replace("PAIRS_WHERE", "    where\n        a has hash : a -> Int").replace("VEC", "Vector.fromList")
            .replace("W64HI", "Word64.shiftLeftBy 63 (Word64.fromInt 1)").replace("W64LO", "Word64.fromInt 1")
            .replace("F32Z", "Float32.fromFloat 0").replace("F32NZ", "Float32.fromFloat -0.0").replace("F32ONE", "Float32.fromFloat 1"))

HASH_ELM = (HASH_TYPES.replace("WHERE_SHAPE", "").replace("WHERE_TREE", "") + """

hashOf : a -> a
hashOf x =
    x
""" + HASH_PAIRS.replace("PAIRS_WHERE\n", "").replace("VEC ", "")
            .replace("W64HI", "( 2147483648, 0 )").replace("W64LO", "( 0, 1 )")
            .replace("F32Z", "0").replace("F32NZ", "-0.0").replace("F32ONE", "1"))

case("a4b-hash", "the law of hash: equal values (==) have equal hashes, here also -0.0 and 0, a Dict and a Set built in other orders, "
     "a record written in another field order; the distinct values of the cases have distinct hashes.  Through a constrained "
     "function `hashOf` at the built-in types, records, the containers, Word64, Float32 and derived types",
     {"Main.elm": mod(["Array", "Dict", "Set", "Vector", "Word64", "Float32"], HASH_FIC)},
     ("elm", {"Main.elm": mod(["Array", "Dict", "Set"], HASH_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- hash: stable values

HASHV_FIC = """

type Color
    = Red
    | Green
    | Blue
    where
        derive hash


type Shape
    = Circle Int
    | Dot
    where
        derive hash


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x


nothing : Maybe Int
nothing =
    Nothing


ok2 : Result String Int
ok2 =
    Ok 2


errE : Result String Int
errE =
    Err "e"


lines : List String
lines =
    List.map String.fromInt
        [ hashOf 0, hashOf 1, hashOf -1, hashOf 123456789, hashOf 'a', hashOf True, hashOf False, hashOf ()
        , hashOf "", hashOf "a", hashOf "hello, world"
        , hashOf ( 1, 2 ), hashOf ( 1, "x", 'c' ), hashOf [ 1, 2, 3 ], hashOf { a = 1, b = "x" }
        , Color.hash Red, Color.hash Blue, Shape.hash Dot, Shape.hash (Circle 7)
        , hashOf (Just 1), hashOf nothing, hashOf ok2, hashOf errE
        , hashOf [ Just Green ]
        ]
"""

HASHV_OLD = """

c1 : Word64
c1 =
    Word64.fromInt -4658895280553007687


c2 : Word64
c2 =
    Word64.fromInt -7723592293110705685


golden : Word64
golden =
    Word64.fromInt -7046029254386353131


mix : Word64 -> Word64
mix z0 =
    let
        z1 =
            Word64.xor z0 (Word64.shiftRightBy 30 z0) * c1

        z2 =
            Word64.xor z1 (Word64.shiftRightBy 27 z1) * c2
    in
    Word64.xor z2 (Word64.shiftRightBy 31 z2)


combine : Word64 -> Word64 -> Word64
combine h x =
    mix (h * golden + x)


int : Int -> Word64
int n =
    mix (Word64.fromInt n)


str : String -> Word64
str s =
    mix (List.foldl (\\c h -> Word64.xor h (Word64.fromInt (Char.toCode c)) * Word64.fromInt 1099511628211) (Word64.fromInt -3750763034362895579) (String.toList s))


fields : List Word64 -> Word64
fields hs =
    List.foldl (\\x h -> combine h x) (Word64.fromInt (List.length hs)) hs


list : List Word64 -> Word64
list hs =
    List.foldl (\\x h -> combine h x) (Word64.fromInt 5506058962772521844) hs


ctor : Int -> List Word64 -> Word64
ctor rank hs =
    List.foldl (\\x h -> combine h x) (mix (Word64.fromInt rank)) hs


lines : List String
lines =
    List.map (\\h -> String.fromInt (Word64.toInt h))
        [ int 0, int 1, int -1, int 123456789, int 97, int 1, int 0, int 0
        , str "", str "a", str "hello, world"
        , fields [ int 1, int 2 ], fields [ int 1, str "x", int 99 ], list [ int 1, int 2, int 3 ], fields [ int 1, str "x" ]
        , int 0, int 2, ctor 1 [], ctor 0 [ int 7 ]
        , ctor 1 [ int 1 ], ctor 0 [], ctor 0 [ int 2 ], ctor 1 [ str "e" ]
        , list [ ctor 1 [ int 1 ] ]
        ]
"""

case("a4b-hash-values", "the hash is stable: fixed values for Int, Char, Bool, (), String (FNV-1a 64), tuples, a list, a record, derived "
     "enumeration and union, Maybe (Nothing has rank 0), Result; the twin computes the documented algorithm with Word64 on elmficA5c",
     {"Main.elm": mod([], HASHV_FIC)}, ("oldc", {"Main.elm": mod(["Word64 exposing (Word64)"], HASHV_OLD)}))


# ---------------------------------------------------------------------------------------------------------------- `a has compare`

HAS_FIC = """

type Color
    = Red
    | Green
    | Blue
    where
        derive compare


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare


sortW : List a -> List a
    where
        a has compare : a -> a -> Order
sortW xs =
    List.sortWith compare xs


rank : Color -> Int
rank c =
    case c of
        Red ->
            0

        Green ->
            1

        Blue ->
            2


lines : List String
lines =
    [ Debug.toString (List.map (Maybe.withDefault -1) (sortW [ Just 3, Nothing, Just 1, Nothing ]))
    , Debug.toString (List.map .a (sortW [ { a = 2, b = "x" }, { a = 1, b = "z" }, { a = 2, b = "a" } ]))
    , Debug.toString (List.map rank (sortW [ Blue, Red, Green ]))
    , Debug.toString (sortW [ Node Leaf 2 Leaf, Leaf, Node (Node Leaf 1 Leaf) 0 Leaf ])
    , Debug.toString (List.map (List.map rank) (sortW [ [ Blue ], [], [ Red, Blue ] ]))
    , Debug.toString (List.map (Result.withDefault 0) (sortW [ Err "b", Ok 5, Ok 1 ]))
    ]
"""

HAS_ELM = """

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)


cmpTree : Tree comparable -> Tree comparable -> Order
cmpTree a b =
    case ( a, b ) of
        ( Leaf, Leaf ) ->
            EQ

        ( Leaf, _ ) ->
            LT

        ( _, Leaf ) ->
            GT

        ( Node l1 v1 r1, Node l2 v2 r2 ) ->
            case cmpTree l1 l2 of
                EQ ->
                    case compare v1 v2 of
                        EQ ->
                            cmpTree r1 r2

                        o ->
                            o

                o ->
                    o


lines : List String
lines =
    [ Debug.toString (List.map (\\l -> Maybe.withDefault -1 (List.head l)) (List.sort [ [ 3 ], [], [ 1 ], [] ]))
    , Debug.toString (List.map Tuple.first (List.sort [ ( 2, "x" ), ( 1, "z" ), ( 2, "a" ) ]))
    , Debug.toString (List.sort [ 2, 0, 1 ])
    , Debug.toString (List.sortWith cmpTree [ Node Leaf 2 Leaf, Leaf, Node (Node Leaf 1 Leaf) 0 Leaf ])
    , Debug.toString (List.sort [ [ 2 ], [], [ 0, 2 ] ])
    , Debug.toString (List.map (\\( _, v, _ ) -> Maybe.withDefault 0 (List.head v)) (List.sort [ ( 1, [], [ "b" ] ), ( 0, [ 5 ], [] ), ( 0, [ 1 ], [] ) ]))
    ]
"""

case("a4b-has-compare", "a constrained function (`a has compare`) at Maybe, a record, a derived enumeration and recursive type, a "
     "list of the enumeration and Result (the obligation path of the solver and the specializer's built-in members)",
     {"Main.elm": mod([], HAS_FIC)}, ("elm", {"Main.elm": mod([], HAS_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- written hash inside

HW_FIC = """

ciHash : Ci -> Int
ciHash (Ci s) =
    String.length s * 1000 + Char.toCode (Maybe.withDefault 'z' (List.head (String.toList (String.toLower s))))


type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b

        hash : Ci -> Int
        hash =
            ciHash


type Key
    = Key Ci Int
    | Many (List Ci)
    where
        derive hash


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x


pairs : String -> List ( a, a ) -> String
    where
        a has hash : a -> Int
pairs label ps =
    label ++ " " ++ Debug.toString (List.map (\\( x, y ) -> ( x == y, hashOf x == hashOf y )) ps)


lines : List String
lines =
    [ pairs "key" [ ( Key (Ci "Ab") 1, Key (Ci "aB") 1 ), ( Key (Ci "Ab") 1, Key (Ci "Ab") 2 ), ( Many [ Ci "X", Ci "y" ], Many [ Ci "x", Ci "Y" ] ), ( Many [], Many [ Ci "" ] ) ]
    , pairs "nested" [ ( ( Just (Ci "Q"), 1 ), ( Just (Ci "q"), 1 ) ), ( ( Just (Ci "Q"), 1 ), ( Nothing, 1 ) ) ]
    , Debug.toString ( Key.hash (Key (Ci "A") 0) == Key.hash (Key (Ci "a") 0), Ci.hash (Ci "Abc") )
    ]
"""

HW_ELM = """

type alias Ci =
    String


ciHash : Ci -> Int
ciHash s =
    String.length s * 1000 + Char.toCode (Maybe.withDefault 'z' (List.head (String.toList (String.toLower s))))


type Key
    = Key Ci Int
    | Many (List Ci)


hashOf : a -> a
hashOf x =
    x


pairs : String -> List ( a, a ) -> String
pairs label ps =
    label ++ " " ++ Debug.toString (List.map (\\( x, y ) -> ( x == y, hashOf x == hashOf y )) ps)


lines : List String
lines =
    [ pairs "key" [ ( Key "ab" 1, Key "ab" 1 ), ( Key "ab" 1, Key "ab" 2 ), ( Many [ "x", "y" ], Many [ "x", "y" ] ), ( Many [], Many [ "" ] ) ]
    , pairs "nested" [ ( ( Just "q", 1 ), ( Just "q", 1 ) ), ( ( Just "q", 1 ), ( Nothing, 1 ) ) ]
    , Debug.toString ( Key "a" 0 == Key "a" 0, ciHash "Abc" )
    ]
"""

case("a4b-hash-written", "a derived hash over a type with a written eq and a point-free written hash (an eta clone of one parameter), in "
     "a list and in a Maybe inside a tuple: the law holds through the written members",
     {"Main.elm": mod([], HW_FIC)}, ("elm", {"Main.elm": mod([], HW_ELM)}))


# ---------------------------------------------------------------------------------------------------------------- errors

MONEY = """

type Money
    = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)
"""

ELM_GATE = """

lines : List String
lines =
    [ Debug.toString (compare (Just 1) Nothing) ]
"""

bad("a4b-err-gate-maybe", "plain Elm: compare on Maybe stays Elm's TYPE MISMATCH (no type with attached functions in sight: the gate)",
    {"Main.elm": mod([], ELM_GATE)}, "TYPE MISMATCH", "comparable")
bad("a4b-err-gate-record-key", "plain Elm: a record as a Dict key stays Elm's TYPE MISMATCH",
    {"Main.elm": mod(["Dict"], """

lines : List String
lines =
    [ Debug.toString (Dict.size (Dict.fromList [ ( { a = 1 }, 2 ) ])) ]
""")}, "TYPE MISMATCH", "comparable")
bad("a4b-js-container", "compare on Maybe in a module that sees a type with attached functions: accepted, so the JavaScript output "
    "refuses it", {"Main.elm": mod([], MONEY + ELM_GATE)}, "NOT AVAILABLE IN JAVASCRIPT YET", "")
bad("a4b-err-fun-in-tree", "a derived compare at Tree (Int -> Int): the argument must be comparable (TYPE MISMATCH)", {"Main.elm": mod([], """

type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare


lines : List String
lines =
    [ Debug.toString (Node Leaf (\\x -> x + 1) Leaf < Leaf) ]
""")}, "TYPE MISMATCH", "comparable", outcome="REJECTC", c_only=True)
bad("a4b-err-fun-in-record", "compare on a record with a function field (gate open): TYPE MISMATCH", {"Main.elm": mod([], MONEY + """

lines : List String
lines =
    [ Debug.toString (compare { f = identity, n = 1 } { f = identity, n = 2 }) ]
""")}, "TYPE MISMATCH", "comparable", outcome="REJECTC", c_only=True)
bad("a4b-err-cannot-hash-function", "derive hash with a function field: CANNOT DERIVE with the path", {"Main.elm": mod([], """

type Handler
    = Handler String (Int -> Int)
    where
        derive hash


lines : List String
lines =
    [ "x" ]
""")}, "CANNOT DERIVE", "Handler > argument 2")
bad("a4b-err-cannot-compare-inner", "derive compare with a field of a custom type without compare: CANNOT DERIVE", {"Main.elm": mod([], """

type Inner
    = Inner Int


type Outer
    = Outer (List Inner)
    where
        derive compare


lines : List String
lines =
    [ "x" ]
""")}, "CANNOT DERIVE", "Inner")
bad("a4b-err-define-hash", "derive hash and a written hash: DERIVE AND DEFINE", {"Main.elm": mod([], """

type Id
    = Id Int
    where
        derive hash

        hash : Id -> Int
        hash (Id n) =
            n


lines : List String
lines =
    [ "x" ]
""")}, "DERIVE AND DEFINE", "")
bad("a4b-err-nonregular-hash", "derive hash on a non-regular type: CANNOT DERIVE", {"Main.elm": mod([], """

type Nest a
    = Nil
    | Cons a (Nest (List a))
    where
        derive hash


lines : List String
lines =
    [ "x" ]
""")}, "CANNOT DERIVE", "inside itself")

NONREG = """

type Nest a
    = Nil
    | Cons a (Nest (List a))
"""

bad("a4b-nonregular-eq-elm", "plain Elm: == on a non-regular type is refused by the C generator, once, with the type in source form "
    "(A3b review A3)", {"Main.elm": mod([], NONREG + """

lines : List String
lines =
    [ Debug.toString (Cons 1 (Cons [ 2 ] Nil) == Cons 1 (Cons [ 2 ] Nil), Cons 1 Nil == Nil) ]
""")}, "", "`==` on the type `Nest Int`, which is used at another argument inside itself (non-regular recursion), is not supported by the C generator",
    outcome="REJECTC")
bad("a4b-nonregular-member", "a non-regular type holding a type with a written eq: the same report", {"Main.elm": mod([], NONREG + """

type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b


lines : List String
lines =
    [ Debug.toString (Cons (Ci "a") Nil == Nil, Cons (Ci "b") Nil == Nil) ]
""")}, "", "`==` on the type `Nest Ci`, which is used at another argument inside itself (non-regular recursion), is not supported by the C generator",
    outcome="REJECTC", c_only=True)


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
    work = tempfile.mkdtemp(prefix="a4btwin-")
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
    home = tempfile.mkdtemp(prefix="a4btwin-home-")
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
