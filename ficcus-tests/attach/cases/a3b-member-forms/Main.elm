module Main exposing (main)



type Rank
    = Rank Int
    where
        compare : Rank -> Rank -> Order
        compare =
            byNegated


byNegated : Rank -> Rank -> Order
byNegated (Rank a) (Rank b) =
    Basics.compare b a


rank : Int -> Rank
rank n =
    Rank n


showRank : Rank -> String
showRank (Rank n) =
    String.fromInt n


type Digit
    = Digit Int
    where
        eq : Digit -> Digit -> Bool
        eq =
            \(Digit a) (Digit b) -> modBy 10 a == modBy 10 b


digit : Int -> Digit
digit n =
    Digit n


type Half
    = Half Int
    where
        compare : Half -> Half -> Order
        compare (Half a) =
            \(Half b) -> Basics.compare (a // 2) (b // 2)


half : Int -> Half
half n =
    Half n

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
