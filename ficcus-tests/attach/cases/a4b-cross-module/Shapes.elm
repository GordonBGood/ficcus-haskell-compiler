module Shapes exposing (Email, Shape(..), email, show)


type Shape
    = Circle Float
    | Square Int
    | Dot
    where
        derive compare, hash


type Email
    = Email String
    where
        derive compare


email : String -> Email
email =
    Email


show : Email -> String
show (Email s) =
    s
