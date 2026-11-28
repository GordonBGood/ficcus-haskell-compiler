module Main exposing (main)


type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b

        compare : Ci -> Ci -> Order
        compare (Ci a) (Ci b) =
            Basics.compare (String.toLower a) (String.toLower b)


ci : String -> Ci
ci s =
    Ci s


nan : Float
nan =
    0 / 0


lines : List String
lines =
    [ Debug.toString (( ci "a", nan ) == ( ci "A", nan ))
    , Debug.toString (( ci "a", -0.0 ) == ( ci "A", 0.0 ))
    , Debug.toString (compare ( ci "a", nan ) ( ci "A", 1 ))
    , Debug.toString (compare ( ci "a", 1 ) ( ci "A", nan ))
    , Debug.toString (( ci "a", nan ) < ( ci "A", 1 ))
    , Debug.toString (( ci "a", nan ) > ( ci "A", 1 ))
    , Debug.toString ([ ( ci "b", nan ) ] == [ ( ci "B", nan ) ])
    , Debug.toString (compare [ ( ci "a", -0.0 ) ] [ ( ci "A", 0.0 ) ])
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
