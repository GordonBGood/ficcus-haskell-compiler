module Names exposing (Name, Desc, name, desc, showDesc)



type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


name : String -> Name
name s =
    Name s


type Desc
    = Desc Int
    where
        compare : Desc -> Desc -> Order
        compare (Desc a) (Desc b) =
            Basics.compare b a


desc : Int -> Desc
desc n =
    Desc n


showDesc : Desc -> String
showDesc (Desc n) =
    String.fromInt n


