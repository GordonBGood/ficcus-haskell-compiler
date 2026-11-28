module Main exposing (main)



type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


type Tree
    = Leaf
    | Node Tree Int Tree

type A
    = AEnd
    | A B

type B
    = B A Int

type W
    = W Name

type alias Ids =
    List Int

type Z
    = Z Ids (Maybe Float)

type P a
    = P a

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ Debug.toString (Node Leaf 1 Leaf == Node Leaf 1 Leaf)
                            , Debug.toString (A (B AEnd 2) == A (B AEnd 3))
                            , Debug.toString (Z [ 1, 2 ] (Just 1.5) == Z [ 1, 2 ] (Just 1.5))
                            , Debug.toString (P 3 == P 3)
                            , Debug.toString (Name "a" == Name "A")
                            , Debug.toString ((\(W _) -> 1) (W (Name "x")))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

