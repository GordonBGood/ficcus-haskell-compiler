module JsonTreeV exposing (Json(..), Summary, report, summarize)

{-| The value tree of the P1 benchmark, version A2: strings are byte vectors (UTF-8), arrays and objects are Vectors (as the Roc
version: List U8, List JSON). The checksum is the one of JsonTree: node count, sum of the numbers, total string length (code points,
keys included: the bytes that are not continuation bytes), maximum depth.
-}

import Vector exposing (Vector)


type Json
    = JNull
    | JBool Bool
    | JNum Float
    | JStr (Vector Int)
    | JArr (Vector Json)
    | JObj (Vector ( Vector Int, Json ))


type alias Summary =
    { nodes : Int, sum : Float, strlen : Int, depth : Int }


codePoints : Vector Int -> Int
codePoints bytes =
    Vector.foldl (\b n -> if b >= 128 && b < 192 then n else n + 1) 0 bytes


summarize : Json -> Summary
summarize j =
    fold 1 j { nodes = 0, sum = 0, strlen = 0, depth = 0 }


fold : Int -> Json -> Summary -> Summary
fold d j acc =
    let
        a1 =
            { acc | nodes = acc.nodes + 1, depth = max acc.depth d }
    in
    case j of
        JNull ->
            a1

        JBool _ ->
            a1

        JNum x ->
            { a1 | sum = a1.sum + x }

        JStr s ->
            { a1 | strlen = a1.strlen + codePoints s }

        JArr xs ->
            Vector.foldl (fold (d + 1)) a1 xs

        JObj ps ->
            Vector.foldl (\( k, v ) a -> fold (d + 1) v { a | strlen = a.strlen + codePoints k }) a1 ps


report : Summary -> String
report s =
    "nodes=" ++ String.fromInt s.nodes ++ " sum64=" ++ String.fromInt (floor (s.sum * 64)) ++ " strlen=" ++ String.fromInt s.strlen ++ " depth=" ++ String.fromInt s.depth
