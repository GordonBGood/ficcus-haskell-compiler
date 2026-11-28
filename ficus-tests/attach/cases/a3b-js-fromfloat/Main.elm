module Main exposing (main)



type Meters
    = Meters Float
    where
        fromFloat : Float -> Meters
        fromFloat x =
            Meters x


raw : Meters -> Float
raw (Meters m) =
    m


lines : List String
lines =
    [ String.fromFloat (raw 0.5) ]




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
