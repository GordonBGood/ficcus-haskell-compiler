module Main exposing (main)

type T r
    = T { r | x : Int }


type W a r
    = W a { r | m : a }


lines : List String
lines =
    [ Debug.toString (T { x = 1, zeta = "z", alpha = 'c', mid = ( 1, "t" ) })
    , Debug.toString (T { x = -3 })
    , Debug.toString [ T { x = 1, y = { q = [ "a" ] } } ]
    , Debug.toString (W "a" { m = "b", k = 2 })
    , Debug.toString (W 1.5 { m = 2.5, b = True, z = Nothing })
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
