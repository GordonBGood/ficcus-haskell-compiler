module Main exposing (main)


type L
    = Cons Int L
    | Nil
    where
        derive compare, hash


build : Int -> L -> L
build n acc =
    if n <= 0 then
        acc

    else
        build (n - 1) (Cons n acc)


lines : List String
lines =
    let
        a =
            build 1000000 Nil

        b =
            build 1000000 (Cons 0 Nil)
    in
    [ Debug.toString ( compare a b, L.hash a == L.hash b ) ]


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
