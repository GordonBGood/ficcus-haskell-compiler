module SubsOrder exposing (main)

-- E1 step 3: Elm calls `subscriptions model` once after `init` (Platform.js _Platform_initialize); the stepper does the same, so a
-- Debug.log in subscriptions prints after the lines of init. The model is a record with a list (a reference leaf), borrowed by
-- subscriptions. Golden: expected/subsorder.out from Elm 0.19.3 (ref/src/SubsOrder.elm is the same module).


type alias Model =
    { xs : List Int, n : Int }


type Msg
    = Tick


main : Program () Model Msg
main =
    Platform.worker
        { init = \_ -> ( Debug.log "init" { xs = [ 1, 2, 3 ], n = 3 }, Cmd.none )
        , update = \_ m -> ( Debug.log "update" { m | n = m.n + 1 }, Cmd.none )
        , subscriptions = \m -> always Sub.none (Debug.log "subscriptions" (List.sum m.xs + m.n))
        }
