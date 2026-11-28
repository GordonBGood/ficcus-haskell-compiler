module Main exposing (main)



type alias Rank =
    Int


rank : Int -> Rank
rank n =
    negate n


showRank : Rank -> String
showRank n =
    String.fromInt (negate n)


type Digit
    = Digit Int


digit : Int -> Digit
digit n =
    Digit (modBy 10 n)


type alias Half =
    Int


half : Int -> Half
half n =
    n // 2

lines : List String
lines =
    [ Debug.toString (( rank 1, 0 ) < ( rank 2, 0 ))
    , String.join "," (List.map (\( r, _ ) -> showRank r) (List.sort [ ( rank 1, 0 ), ( rank 3, 0 ), ( rank 2, 0 ) ]))
    , Debug.toString (compare [ rank 1 ] [ rank 1, rank 0 ])
    , Debug.toString ([ digit 13 ] == [ digit 3 ])
    , Debug.toString (( digit 13, 1 ) == ( digit 4, 1 ))
    , Debug.toString (Just (digit 21) == Just (digit 1))
    , Debug.toString (compare ( half 4, 1 ) ( half 5, 1 ))
    , Debug.toString (( half 4, 1 ) < ( half 6, 0 ))
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
