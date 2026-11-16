module Main exposing (main)



type Temp = Temp Float
    where
        {-| a documentation comment before a member is accepted -}
        celsius : Float -> Temp
        celsius c =
            Temp c

        -- a line comment between members
        fahrenheit : Temp -> Float
        fahrenheit (Temp c) =
            let
                k =
                    9 / 5
            in
            c * k + 32


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Temp.fahrenheit (Temp.celsius 100), Temp.fahrenheit (Temp 0) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
