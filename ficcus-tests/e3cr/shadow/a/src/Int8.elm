module Int8 exposing (Int8(..), toString)

-- a project module Int8 (not the overlay): a custom type holding a String


type Int8
    = Int8 String


toString : Int8 -> String
toString (Int8 s) =
    s
