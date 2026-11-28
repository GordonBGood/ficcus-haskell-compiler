module Main exposing (main)



type Meters
    = Meters Float
    where
        fromFloat : Float -> Meters
        fromFloat x =
            Meters (x * 2)

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
