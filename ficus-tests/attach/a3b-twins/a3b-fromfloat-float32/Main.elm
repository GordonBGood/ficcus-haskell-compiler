module Main exposing (main)

import Float32 exposing (Float32)




x : Float32
x =
    Float32.fromFloat 0.1


scale : Float32 -> Float32
scale v =
    v * Float32.fromFloat 2.5


lines : List String
lines =
    [ Float32.toString x
    , Float32.toString (x + Float32.fromFloat 0.2)
    , Float32.toString (negate (Float32.fromFloat 0.5))
    , Float32.toString (List.sum [ Float32.fromFloat 0.1, Float32.fromFloat 0.2, Float32.fromFloat 0.3 ])
    , Debug.toString (x == Float32.fromFloat 0.1)
    , Float32.toString (let y = Float32.fromFloat 1.1 in y * y)
    , String.fromFloat (0.1 + 0.2)
    , Float32.toString (scale (Float32.fromFloat 3.3))
    , Debug.toString (x < Float32.fromFloat 0.2)
    , Float32.toString (Float32.fromFloat 16777217.0)
    , Float32.toString (Float32.fromFloat 3.4028235e38)
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
