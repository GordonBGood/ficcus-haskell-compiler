module Main exposing (main)

-- MARK: Float literals in the plain Elm style; the Ficus copy adds `import Float32` (a type with fromFloat in sight)


half =
    0.5


scale x =
    x * 0.25


pair =
    let
        h = 0.5
    in
    ( h * 2, String.fromFloat h )


lines : List String
lines =
    [ Debug.toString [ 0.5, 1 ]
    , Debug.toString (0.5 + 1)
    , Debug.toString (round 2.5)
    , Debug.toString 0.1
    , Debug.toString (half * 3)
    , Debug.toString (scale 3)
    , Debug.toString pair
    , Debug.toString (List.map (\x -> x / 2) [ 1.5, 2 ])
    , Debug.toString (max 0.5 (toFloat 2))
    , Debug.toString (1.0e300 * 1.0e10)
    , Debug.toString (compare 0.5 1)
    , Debug.toString (-0.0)
    , Debug.toString (0 / 0 == 0 / 0)
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
