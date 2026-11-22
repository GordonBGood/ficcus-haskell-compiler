module Main exposing (main)

-- a type of the project named like a sized type: ordinary code (the module rule), with and without members


type Word8
    = Word8 Int
    where
        add : Word8 -> Word8 -> Word8
        add (Word8 a) (Word8 b) =
            Word8 (a + b)

        sub : Word8 -> Word8 -> Word8
        sub (Word8 a) (Word8 b) =
            Word8 (a - b)

        mul : Word8 -> Word8 -> Word8
        mul (Word8 a) (Word8 b) =
            Word8 (a * b)

        pow : Word8 -> Word8 -> Word8
        pow (Word8 a) (Word8 b) =
            Word8 (a ^ b)

        neg : Word8 -> Word8
        neg (Word8 a) =
            Word8 (negate a)

        abs : Word8 -> Word8
        abs (Word8 a) =
            Word8 (Basics.abs a)

        fromInt : Int -> Word8
        fromInt n =
            Word8 n

        compare : Word8 -> Word8 -> Order
        compare (Word8 a) (Word8 b) =
            Basics.compare a b


type Int16
    = Int16 Int


show : Word8 -> String
show (Word8 n) =
    String.fromInt n


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    a : Word8
                    a =
                        200

                    _ =
                        logAll
                            [ show (a + 100)
                            , show (a - 300)
                            , show (-a)
                            , show (max a 3)
                            , case Int16 5 of
                                Int16 n ->
                                    String.fromInt n
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
