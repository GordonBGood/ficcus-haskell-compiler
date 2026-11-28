module Int8 exposing (Int8, fromInt, toString)

-- a project module Int8: an opaque wrapper of Int (no range)


type Int8
    = Int8 Int


fromInt : Int -> Int8
fromInt =
    Int8


toString : Int8 -> String
toString (Int8 i) =
    String.fromInt i
