module Names exposing (Name, Desc, name, desc, showDesc)



type Name
    = Name String


name : String -> Name
name s =
    Name (String.toLower s)


type alias Desc =
    Int


desc : Int -> Desc
desc n =
    negate n


showDesc : Desc -> String
showDesc n =
    String.fromInt (negate n)


