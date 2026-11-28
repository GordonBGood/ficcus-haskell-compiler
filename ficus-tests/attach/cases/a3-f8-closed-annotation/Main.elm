module Main exposing (main)


type D
    = D Float
    where
        div : D -> D -> D
        div (D a) (D b) =
            D (a / b)


direct : String
direct =
    Debug.toString (3 / 4)


inLet : String
inLet =
    let
        h y =
            y / 4
    in
    Debug.toString (h 3)


withArgs : Int -> String
withArgs n =
    let
        h y =
            y / 8
    in
    Debug.toString (h (toFloat n), 1 / 2)


halve : Int -> Float -> Float
halve n x =
    if n <= 0 then
        x

    else
        halve (n - 1) (x / 2)


untyped =
    Debug.toString (5 / 2)


untypedLet =
    let
        h y =
            y / 10
    in
    Debug.toString (h 1)


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
                        logAll [ direct, inLet, withArgs 3, Debug.toString (halve 3 1), untyped, untypedLet ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
