module G17bRef exposing (main)

-- The reference of ../src/G17b.fic under Elm 0.19.3: the same model and update, the N steps run by a fold in init (no scheduler
-- needed). Generates ../../expected/g17b.out (node).

import Array exposing (Array)
import Dict exposing (Dict)


type alias Model =
    { a : Array Int, d : Dict Int Int, n : Int }


type Msg
    = Step


size : Int
size =
    100000


update : Msg -> Model -> ( Model, Cmd Msg )
update _ m =
    if m.n <= 0 then
        ( m, Cmd.none )

    else
        let
            k =
                modBy 1000 m.n

            m2 =
                { m | d = Dict.insert k m.n m.d, a = Array.set k m.n m.a, n = m.n - 1 }
        in
        if m2.n == 0 then
            ( logSum m2, Cmd.none )

        else
            ( m2, Cmd.none )


logSum : Model -> Model
logSum m =
    let
        s =
            Dict.foldl (\k v acc -> acc + k * v) 0 m.d + Array.foldl (+) 0 m.a

        _ =
            Debug.log "checksum" ( s, Dict.size m.d, Array.length m.a )
    in
    m


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( List.foldl (\_ m -> Tuple.first (update Step m)) { a = Array.repeat 1000 0, d = Dict.empty, n = size } (List.range 1 size), Cmd.none )
        , update = update
        , subscriptions = \_ -> Sub.none
        }
