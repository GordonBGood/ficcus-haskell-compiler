module Email exposing (Email, make)


type Email = Email String where derive compare, hash, toString, encode, decoder


make : String -> Email
make =
    Email
