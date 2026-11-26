module Main exposing (main)

-- a plain Elm program (no member anywhere): `==` on a non-regular recursive type


type Nest a
    = Nil
    | Cons a (Nest (List a))


lines : List String
lines =
    [ Debug.toString (Cons 1 (Cons [ 2 ] Nil) == Cons 1 (Cons [ 2 ] Nil))
    , Debug.toString (Cons 1 Nil == Cons 2 Nil)
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
