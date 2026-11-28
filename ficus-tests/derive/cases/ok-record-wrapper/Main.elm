module Main exposing (main)



type Email = Email String where derive compare, hash, toString, encode, decoder

type User
    = User { name : String, email : Email, bio : Maybe String }
    where
        derive compare, hash, toString, encode, decoder


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ((\(User u) -> u.name) (User { name = "Bo", email = Email "b@o", bio = Nothing }))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
