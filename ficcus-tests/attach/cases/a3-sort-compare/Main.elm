module Main exposing (main)


{-| A version number with its own `compare`. -}
type Version
    = Version Int Int Int
    where
        compare : Version -> Version -> Order
        compare (Version a b c) (Version x y z) =
            case Basics.compare a x of
                EQ ->
                    case Basics.compare b y of
                        EQ ->
                            Basics.compare c z

                        o ->
                            o

                o ->
                    o


{-| The reverse order for the same data (a wrapper with its own `compare`). -}
type Desc
    = Desc Int
    where
        compare : Desc -> Desc -> Order
        compare (Desc a) (Desc b) =
            Basics.compare b a


v : Version -> String
v (Version a b c) =
    String.fromInt a ++ "." ++ String.fromInt b ++ "." ++ String.fromInt c


d : Desc -> String
d (Desc n) =
    String.fromInt n


{-| A reference sort that only uses `compare` (insertion sort, stable). -}
insertBy : (a -> a -> Order) -> a -> List a -> List a
insertBy cmp x sorted =
    case sorted of
        [] ->
            [ x ]

        y :: ys ->
            if cmp x y == LT then
                x :: y :: ys

            else
                y :: insertBy cmp x ys


refSort : (a -> a -> Order) -> List a -> List a
refSort cmp xs =
    List.foldl (insertBy cmp) [] xs


{-| 300 pseudo random versions with many duplicates and some sorted runs (so that the run detection of the merge sort is used). -}
many : List Version
many =
    let
        step n =
            modBy 2147483629 (n * 48271 + 11)

        go k n acc =
            if k <= 0 then
                List.reverse acc

            else
                let
                    m =
                        step n
                in
                go (k - 1) m (Version (modBy 4 (m // 7)) (modBy 5 (m // 31)) (modBy 3 (m // 101)) :: acc)
    in
    go 300 7 [] ++ List.map (\i -> Version (i // 50) (i // 10) i) (List.range 0 99)


logAll : List String -> ()
logAll ls =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () ls


noVersions : List Version
noVersions =
    []


lines : List String
lines =
        [ "sort " ++ String.join " " (List.map v (List.sort [ Version 3 0 0, Version 1 0 5, Version 1 10 0, Version 1 2 0, Version 1 0 4 ]))
        , "desc " ++ String.join " " (List.map d (List.sort [ Desc 1, Desc 3, Desc 2, Desc 3 ]))
        , "empty " ++ Debug.toString (List.length (List.sort noVersions))
        , "many " ++ Debug.toString (List.map v (List.sort many) == List.map v (refSort compare many))
        , "many len " ++ String.fromInt (List.length (List.sort many))
        , "descmany " ++ Debug.toString (List.map d (List.sort (List.map (\(Version a b _) -> Desc (a * 10 + b)) many)) == List.map d (refSort compare (List.map (\(Version a b _) -> Desc (a * 10 + b)) many)))
        ]


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
