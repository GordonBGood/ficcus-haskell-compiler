module Main exposing (main)

import Dict
import Holder
import Names



lines : List String
lines =
    [ Debug.toString (Holder.Holder [ Names.name "a" ] Nothing == Holder.Holder [ Names.name "A" ] Nothing)
    , Debug.toString (Holder.sameHolder (Holder.Holder [] (Just (Holder.Holder [ Names.name "x" ] Nothing))) (Holder.Holder [] (Just (Holder.Holder [ Names.name "X" ] Nothing))))
    , Debug.toString (Holder.Holder [ Names.name "a" ] Nothing == Holder.Holder [ Names.name "b" ] Nothing)
    , String.join "," (List.map (\( d, n ) -> Names.showDesc d ++ "/" ++ String.fromInt n) (Dict.keys (Dict.fromList [ ( Holder.key 1 1, () ), ( Holder.key 3 1, () ), ( Holder.key 2 0, () ) ])))
    , Debug.toString (Holder.key 1 0 < Holder.key 2 0)
    ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
