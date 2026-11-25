module Email exposing (Email, make)


type Email = Email String where derive compare


make : String -> Email
make =
    Email
