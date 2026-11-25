module Money exposing (Money, make)


type Money = Money Int where derive compare


make : Int -> Money
make =
    Money
