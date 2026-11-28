module Int8 exposing (Int8, fromInt)

-- the Elm twin's stand in for the overlay's Int8 (a custom type, as the overlay's)


type Int8
    = FicInt8Builtin


fromInt : Int -> Int8
fromInt _ =
    FicInt8Builtin
