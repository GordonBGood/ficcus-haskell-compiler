module Int64 exposing (Int64, fromParts, hi, lo, add)

{-| two 32 bit halves, as the packages elm-int64 do -}


type Int64
    = Int64 Int Int


fromParts : Int -> Int -> Int64
fromParts h l =
    Int64 h l


hi : Int64 -> Int
hi (Int64 h _) =
    h


lo : Int64 -> Int
lo (Int64 _ l) =
    l


add : Int64 -> Int64 -> Int64
add (Int64 h1 l1) (Int64 h2 l2) =
    let
        l =
            l1 + l2
    in
    Int64 (h1 + h2 + l // 4294967296) (modBy 4294967296 l)
