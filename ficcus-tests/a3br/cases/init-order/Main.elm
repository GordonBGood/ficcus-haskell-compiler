module Main exposing (main)


type Part
    = Part Int String
    where
        eq : Part -> Part -> Bool
        eq =
            eqBy partKey

        compare : Part -> Part -> Order
        compare =
            byKey partKey


partKey : Part -> Int
partKey (Part n _) =
    n + offset


offset : Int
offset =
    List.length [ 'a', 'b' ] - 2


table : List ( Part, Int )
table =
    List.sort [ ( Part 3 "c", 0 ), ( Part 1 "a", 0 ) ]


eqBy : (a -> Int) -> a -> a -> Bool
eqBy f =
    \x y -> f x == f y


byKey : (a -> Int) -> a -> a -> Order
byKey f =
    \x y -> Basics.compare (f x) (f y)


early : Bool
early =
    [ ( Part 1 "x", 0 ) ] == [ ( Part 1 "y", 0 ) ]


lines : List String
lines =
    [ Debug.toString early
    , Debug.toString (List.map (\( Part n _, _ ) -> n) table)
    ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
