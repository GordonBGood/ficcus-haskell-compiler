module Shapes exposing (Shape(..), Secret, secret)


type Shape
    = Dot
    | Circle Float


type Secret
    = Secret Int String


secret : Int -> Secret
secret n =
    Secret n "hidden"
