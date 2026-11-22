module Word16 exposing (Word16, make, value)


type Word16
    = Word16 Int


make : Int -> Word16
make n =
    Word16 (modBy 65536 n)


value : Word16 -> Int
value (Word16 n) =
    n
