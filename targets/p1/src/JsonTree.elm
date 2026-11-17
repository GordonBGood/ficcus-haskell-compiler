module JsonTree exposing (Json(..), Summary, report, summarize)

{-| The value tree of the P1 benchmark and the checksum fold: node count, sum of the numbers, total string length (code points,
keys included), maximum depth (the document array is depth 1). All versions share this module.
-}


type Json
    = JNull
    | JBool Bool
    | JNum Float
    | JStr String
    | JArr (List Json)
    | JObj (List ( String, Json ))


type alias Summary =
    { nodes : Int, sum : Float, strlen : Int, depth : Int }


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
            { a1 | strlen = a1.strlen + String.length s }

        JArr xs ->
            List.foldl (fold (d + 1)) a1 xs

        JObj ps ->
            List.foldl (\( k, v ) a -> fold (d + 1) v { a | strlen = a.strlen + String.length k }) a1 ps


report : Summary -> String
report s =
    "nodes=" ++ String.fromInt s.nodes ++ " sum64=" ++ String.fromInt (floor (s.sum * 64)) ++ " strlen=" ++ String.fromInt s.strlen ++ " depth=" ++ String.fromInt s.depth
