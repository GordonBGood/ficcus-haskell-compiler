module Main exposing (main)

type U r
    = U (List { r | x : Int }) (Maybe { r | x : Int })


type T r
    = T { r | x : Int }


u1 =
    U [ { x = 1, s = "a" }, { x = 2, s = "b" } ] (Just { x = 3, s = "c" })


lines : List String
lines =
    [ Debug.toString u1
    , Debug.toString ( u1 == U [ { x = 1, s = "a" }, { x = 2, s = "b" } ] (Just { x = 3, s = "c" }), u1 == U [ { x = 1, s = "a" }, { x = 2, s = "B" } ] (Just { x = 3, s = "c" }) )
    , Debug.toString ( u1 == U [ { x = 1, s = "a" }, { x = 2, s = "b" } ] Nothing, U [] Nothing == U [ { x = 1 } ] Nothing )
    , Debug.toString [ Just (T { x = 1, y = "q" }), Nothing ]
    , Debug.toString ( [ T { x = 1, y = "q" } ] == [ T { x = 1, y = "r" } ], Just (T { x = 1, y = 2 }) == Just (T { x = 1, y = 2 }) )
    , Debug.toString (List.map (\(T r) -> T { r | x = r.x * 2 }) [ T { x = 1, y = "a" }, T { x = 2, y = "b" } ])
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
