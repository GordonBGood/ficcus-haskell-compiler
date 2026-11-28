module Main exposing (main)

import Float32 exposing (Float32)
import Dict


nan : Float32
nan =
    Float32.fromFloat (0 / 0)


one : Float32
one =
    1.0


nz : Float32
nz =
    -0.0


lines : List String
lines =
    [ "top compare nan one " ++ Debug.toString (compare nan one)
    , "tup compare nan one " ++ Debug.toString (compare ( nan, 0 ) ( one, 0 ))
    , "top compare one nan " ++ Debug.toString (compare one nan)
    , "tup compare one nan " ++ Debug.toString (compare ( one, 0 ) ( one, 0 ) |> always (compare ( one, 0 ) ( nan, 0 )))
    , "top nan == nan " ++ Debug.toString (nan == nan)
    , "tup nan == nan " ++ Debug.toString (( nan, 0 ) == ( nan, 0 ))
    , "lst nan == nan " ++ Debug.toString ([ nan ] == [ nan ])
    , "top 0 == -0 " ++ Debug.toString (nz == 0)
    , "tup 0 == -0 " ++ Debug.toString (( nz, 1 ) == ( 0, 1 ))
    , "top nan < one " ++ Debug.toString (nan < one)
    , "tup nan < one " ++ Debug.toString (( nan, 0 ) < ( one, 0 ))
    , "lit " ++ Debug.toString (Float32.toFloat 0.1 == Float32.toFloat (Float32.fromFloat 0.1))
    , "neg lit " ++ Debug.toString (Float32.toFloat -0.1)
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
