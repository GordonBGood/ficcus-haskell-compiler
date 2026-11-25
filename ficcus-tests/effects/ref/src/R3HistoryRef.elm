module R3HistoryRef exposing (main)

-- snapshots of a field kept in another field (a list of old arrays), and the whole model kept in a field of a record that is the model

import Array exposing (Array)


type alias Model =
    { a : Array Int, hist : List (Array Int), n : Int }


type Msg
    = Step


initModel : Model
initModel =
    { a = Array.repeat 8 0, hist = [], n = 40 }


update : Msg -> Model -> ( Model, Cmd Msg )
update _ m =
    let
        h =
            if modBy 7 m.n == 0 then
                m.a :: m.hist

            else
                m.hist

        m2 =
            { a = Array.set (modBy 8 m.n) m.n m.a, hist = h, n = m.n - 1 }
    in
    if m2.n == 0 then
        ( Debug.log "final" m2, Cmd.none )

    else
        ( m2, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( List.foldl (\_ mm -> Tuple.first (update Step mm)) initModel (List.range 1 40), Cmd.none )
        , update = update
        , subscriptions = \_ -> Sub.none
        }
