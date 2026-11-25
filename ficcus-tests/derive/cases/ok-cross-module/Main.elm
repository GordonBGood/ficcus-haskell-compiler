module Main exposing (main)
import Email exposing (Email)



type Contact = Contact { email : Email, tags : List String } where derive compare, hash, encode, decoder


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (1)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
