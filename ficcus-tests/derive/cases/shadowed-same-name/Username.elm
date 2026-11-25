module Username exposing (Username, make)


type Username = Username String where derive compare, toString


make : String -> Username
make =
    Username


toString : Username -> String
toString (Username s) =
    s
