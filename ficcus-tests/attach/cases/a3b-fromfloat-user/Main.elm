module Main exposing (main)



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
