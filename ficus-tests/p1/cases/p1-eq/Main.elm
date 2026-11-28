module Main exposing (main)

type T r
    = T { r | x : Int }
    | E


type C
    = Red
    | Blue String


a =
    T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 1.5 }, c = Blue "q" }


lines : List String
lines =
    [ Debug.toString ( a == T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 1.5 }, c = Blue "q" }, a /= a )
    , Debug.toString ( a == T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 1.5 }, c = Blue "z" }, a == E )
    , Debug.toString ( a == T { x = 1, s = "ab", l = [ 1 ], n = { p = 1.5 }, c = Blue "q" } )
    , Debug.toString ( a == T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 2.5 }, c = Blue "q" } )
    , Debug.toString ( a == T { x = 1, s = String.fromInt 7, l = [ 1, 2 ], n = { p = 1.5 }, c = Red } )
    , Debug.toString ( T { x = 1 } == T { x = 1 }, T { x = 1 } == T { x = 2 } )
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
