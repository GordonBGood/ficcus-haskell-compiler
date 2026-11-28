module Int8 exposing (Int8, fromInt, toInt, add, toString)

-- a project module Int8 (not the overlay): an opaque wrapper of Int that wraps like a signed byte


type Int8
    = Int8 Int


fromInt : Int -> Int8
fromInt i =
    Int8 (modBy 256 (i + 128) - 128)


toInt : Int8 -> Int
toInt (Int8 i) =
    i


add : Int8 -> Int8 -> Int8
add (Int8 a) (Int8 b) =
    fromInt (a + b)


toString : Int8 -> String
toString (Int8 i) =
    "i8:" ++ String.fromInt i
