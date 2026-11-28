module Main exposing (main)


type W a
    = W (List a)
    where
        append : W a -> W a -> W a
            where
                a has append as app : a -> a -> a
        append (W x) (W y) =
            W (x ++ y)


unW : W a -> List a
unW (W xs) =
    xs


lines : List String
lines =
    [ Debug.toString (List.length (unW (W [ [ \n -> n ] ] ++ W [ [] ]))) ]


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
