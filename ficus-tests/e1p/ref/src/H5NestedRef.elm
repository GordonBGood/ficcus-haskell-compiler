module H5NestedRef exposing (main)

import Array exposing (Array)


type alias Inner =
    { a : Array Int, k : Int }


type alias Model =
    { inner : Inner, n : Int }


type Msg
    = Step


initModel : Model
initModel =
    { inner = { a = Array.repeat 100 0, k = 0 }, n = 1000 }


update : Msg -> Model -> ( Model, Cmd Msg )
update _ m =
    let
        i =
            m.inner

        m2 =
            { m | inner = { i | a = Array.set (modBy 100 m.n) m.n i.a, k = i.k + 1 }, n = m.n - 1 }
    in
    if m2.n == 0 then
        ( Debug.log "final" (Array.slice 0 5 m2.inner.a) |> (\_ -> m2), Cmd.none )

    else
        ( m2, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( List.foldl (\_ mm -> Tuple.first (update Step mm)) initModel (List.range 1 1000), Cmd.none )
        , update = update
        , subscriptions = \_ -> Sub.none
        }
