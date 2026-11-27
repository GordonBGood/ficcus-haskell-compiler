module Main exposing (main)

type T r
    = T { r | x : Int }
    | U Int


sumT : T { y : Int, s : String } -> String
sumT t =
    case t of
        T r ->
            String.fromInt (r.x + r.y) ++ r.s

        U n ->
            String.fromInt n


destr : T { y : Int } -> Int
destr t =
    case t of
        T { x, y } ->
            x * 10 + y

        U _ ->
            0


getX : T { w : String } -> Int
getX t =
    case t of
        T r ->
            r.x

        U n ->
            n


lines : List String
lines =
    [ sumT (T { x = 1, y = 2, s = "!" })
    , sumT (U 9)
    , String.fromInt (destr (T { x = 4, y = 5 }))
    , String.fromInt (getX (T { x = 7, w = "w" }) + getX (U 1))
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
