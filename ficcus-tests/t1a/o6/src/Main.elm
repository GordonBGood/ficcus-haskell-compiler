module Main exposing (main)

-- T1a-2 (O6): an Elm module may not import the Ficcus module Concurrent

import Concurrent
import Task


main : Program () Int ()
main =
    Platform.worker { init = \_ -> ( 0, Task.perform (\_ -> ()) (Concurrent.spawn (Task.succeed 1)) ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }
