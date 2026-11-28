module Shapes exposing (Shape(..), Secret, secret)


type Shape
    = Dot
    | Circle Float
    where
        derive toString, compare


type Secret
    = Secret Int String
    where
        derive toString


secret : Int -> Secret
secret n =
    Secret n "hidden"
