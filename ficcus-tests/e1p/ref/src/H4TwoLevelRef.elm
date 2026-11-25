module H4TwoLevelRef exposing (main)

import Array exposing (Array)
import Dict exposing (Dict)


type alias Model =
    { a : Array Int, d : Dict Int Int, n : Int }


type Msg
    = Step


initModel : Model
initModel =
    { a = Array.repeat 100 0, d = Dict.singleton 1 1, n = 1000 }


final : Model -> Model
final m =
    if m.n == 0 then
        Debug.log "final" { m | a = Array.slice 0 5 m.a }

    else
        m


update : Msg -> Model -> ( Model, Cmd Msg )
update _ m =
    ( final (step m), Cmd.none )


step : Model -> Model
step m =
    setA (modBy 100 m.n) { m | n = m.n - 1 }


setA : Int -> Model -> Model
setA i m =
    { m | a = Array.set i m.n m.a }


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( List.foldl (\_ mm -> Tuple.first (update Step mm)) initModel (List.range 1 1000), Cmd.none )
        , update = update
        , subscriptions = \_ -> Sub.none
        }
