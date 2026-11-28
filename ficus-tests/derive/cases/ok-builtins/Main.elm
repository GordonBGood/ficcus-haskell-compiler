module Main exposing (main)
import Array
import Dict
import Set



type Mixed
    = Mixed Int Float String Char Bool () ( Int, String ) (List Int) (Maybe Order) (Result String Int)
    | Other (Array.Array Int) (Dict.Dict String Int) (Set.Set Int) { x : Int, y : ( Bool, Char, Float ) }
    where
        derive compare, hash, toString, fromString, encode, decoder


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (1)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
