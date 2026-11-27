module Main exposing (main)


type Money
    = Money Int
    where
        toInt : Money -> Int
        toInt (Money n) =
            n


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x


lines : List String
lines =
    [ Debug.toString ( hashOf 5, hashOf "x" ) ]


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
