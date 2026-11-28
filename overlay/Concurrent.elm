effect module Concurrent where { command = MyCmd, subscription = MySub } exposing
    ( Pid, Address, Mailbox, Channel, Exit(..)
    , spawn, spawnWith, address, self, send, receive, receiveWithin, await, kill
    , channel, toAddress, listen, sendCmd
    )

{-| Ficus T1a (docs/T1-THREADING-DESIGN.md T1-D2 to T1-D6; docs/attach/T1A-NOTES.md): green processes with typed mailboxes on the
scheduler of the run time, one thread. Every operation is a `Task`; run them with `Task.perform` / `Task.attempt` from `init` or
`update`, or inside a process. Importable from `.fic` modules only.

    spawn         : run a task as a process; its result is `Done a`, its failure `Failed err`, a kill `Killed`
    spawnWith     : the same, the body gets its own `Mailbox` (only the body may receive from it)
    send          : append a message to the mailbox of an address (never blocks; a message to an ended process is dropped)
    receive       : the oldest message of the own mailbox, waiting for one when it is empty
    receiveWithin : the same, `Nothing` after the given milliseconds
    await         : the exit value of a process, waiting for its end
    kill          : stop a process now (its `await` then gives `Killed`; its `Process.spawn` children go on)
    channel       : an address whose messages reach `update` through `listen`
    listen        : a subscription to a channel (a message nobody listens to is dropped)
    sendCmd       : `send` as a command of `update`

Order: messages from one sender to one address arrive in the order they were sent. `spawn`, `send` and `kill` never yield: a spawned
process starts when the current one waits or ends. A process runs until it waits (receive, await, a `Process.sleep` or another task of
the run time) or ends. A process that waits forever does not keep the program alive. Messages of channels reach `update` only through
this module's effect manager, so the model keeps one writer.

The module is added to the source directories of every build (Ficus.Mono.Concurrent); a module `Concurrent` of the project wins. The
types are run time objects (the constructors below are never built: they mark the types as built-ins). The functions of the section
KERNELS are the kernels `elm/core:Concurrent.<name>` (runtime/fic_conc.h; in JavaScript runtime/fic_conc.js); their bodies only give
the types (and, for JavaScript, the dependency on the scheduler).

-}

import Platform
import Task exposing (Task)


{-| a spawned process: await it, kill it, send to it
-}
type Pid exit msg
    = FicConcPidBuiltin


{-| the right to send to a process or a channel
-}
type Address msg
    = FicConcAddressBuiltin


{-| the right to receive; only the body given to `spawnWith` gets it
-}
type Mailbox msg
    = FicConcMailboxBuiltin


{-| an address whose messages reach `update` through `listen`
-}
type Channel msg
    = FicConcChannelBuiltin


{-| a channel seen by the effect manager (any message type)
-}
type ChanRef
    = FicConcChanRefBuiltin


{-| how a process ended
-}
type Exit err a
    = Done a
    | Failed err
    | Killed


spawn : Task err a -> Task x (Pid (Exit err a) Never)
spawn task =
    spawnRaw Killed (\_ -> finish task)


spawnWith : (Mailbox msg -> Task err a) -> Task x (Pid (Exit err a) msg)
spawnWith body =
    spawnRaw Killed (\box -> finish (body box))


finish : Task err a -> Task Never (Exit err a)
finish task =
    Task.onError (\e -> Task.succeed (Failed e)) (Task.map Done task)


receiveWithin : Float -> Mailbox msg -> Task x (Maybe msg)
receiveWithin ms box =
    receiveWithinRaw ms box Just Nothing


channel : Task x (Channel msg)
channel =
    newChannel ()


listen : Channel a -> (a -> msg) -> Sub msg
listen ch tagger =
    subscription (Listen (channelId ch) (\toApp -> current ch |> Task.andThen (\v -> toApp (tagger v))))


sendCmd : Address a -> a -> Cmd msg
sendCmd to v =
    command (SendCmd (send to v))



-- THE EFFECT MANAGER
--
-- A listen keeps its message type inside a closure: given the manager's `sendToApp`, it reads the channel's current message and sends
-- the tagged message to the app. A message sent to a channel is queued in the channel and the manager gets the channel as a self message
-- (only after its first onEffects, which gives the run time the router; before that a channel message is dropped); onSelfMsg runs every
-- current listen of that channel in the order of the subscriptions, then drops the message (counted as dropped when nobody listens).
-- O9: a message that finds no listen while an effects dispatch of this manager is under way (the turn that subscribes) is kept by
-- `advance ref 0`; the next onEffects takes the kept channels (`held`) and delivers them with the new subscriptions (`-1`: dropped
-- when there is still no listen), before its commands.


type MyCmd msg
    = SendCmd (Task Never ())


type MySub msg
    = Listen Int ((msg -> Task Never ()) -> Task Never ())


cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ (SendCmd t) =
    SendCmd t


subMap : (a -> b) -> MySub a -> MySub b
subMap f (Listen id deliver) =
    Listen id (\toApp -> deliver (\a -> toApp (f a)))


init : Task Never (List (MySub msg))
init =
    Task.succeed []


onEffects : Platform.Router msg ChanRef -> List (MyCmd msg) -> List (MySub msg) -> List (MySub msg) -> Task Never (List (MySub msg))
onEffects router cmds subs _ =
    attach router
        |> Task.andThen (\_ -> held ())
        |> Task.andThen (\refs -> Task.sequence (List.map (deliverChan router subs (-1)) refs))
        |> Task.andThen (\_ -> Task.sequence (List.map (\(SendCmd t) -> t) cmds))
        |> Task.map (\_ -> subs)


onSelfMsg : Platform.Router msg ChanRef -> ChanRef -> List (MySub msg) -> Task Never (List (MySub msg))
onSelfMsg router ref subs =
    deliverChan router subs 0 ref
        |> Task.map (\_ -> subs)


{-| the oldest message of the channel to every listen of it; `none` is what `advance` gets when there is no listen (0 or -1)
-}
deliverChan : Platform.Router msg ChanRef -> List (MySub msg) -> Int -> ChanRef -> Task Never ()
deliverChan router subs none ref =
    let
        id =
            chanRefId ref

        hits =
            List.filter (\(Listen i _) -> i == id) subs
    in
    Task.sequence (List.map (\(Listen _ toApp) -> toApp (Platform.sendToApp router)) hits)
        |> Task.andThen (\_ -> advance ref (if List.isEmpty hits then none else List.length hits))



-- KERNELS (runtime/fic_conc.h, runtime/fic_conc.js)


{-| kernel: a new process running the body on its own mailbox; `killed` is its exit value when it is killed
-}
spawnRaw : exit -> (Mailbox msg -> Task Never exit) -> Task x (Pid exit msg)
spawnRaw killed body =
    Task.andThen (\_ -> spawnRaw killed body) (Task.succeed ())


{-| kernel
-}
address : Pid exit msg -> Address msg
address pid =
    address pid


{-| kernel
-}
self : Mailbox msg -> Address msg
self box =
    self box


{-| kernel
-}
send : Address msg -> msg -> Task x ()
send to msg =
    Task.andThen (\_ -> send to msg) (Task.succeed ())


{-| kernel: only the owner of the mailbox may receive
-}
receive : Mailbox msg -> Task x msg
receive box =
    Task.andThen (\_ -> receive box) (Task.succeed ())


{-| kernel: `just m` for a message, `nothing` after `ms` milliseconds (a timer of the run time)
-}
receiveWithinRaw : Float -> Mailbox msg -> (msg -> r) -> r -> Task x r
receiveWithinRaw ms box just nothing =
    Task.andThen (\_ -> receiveWithinRaw ms box just nothing) (Task.succeed ())


{-| kernel
-}
await : Pid exit msg -> Task x exit
await pid =
    Task.andThen (\_ -> await pid) (Task.succeed ())


{-| kernel
-}
kill : Pid exit msg -> Task x ()
kill pid =
    Task.andThen (\_ -> kill pid) (Task.succeed ())


{-| kernel
-}
newChannel : () -> Task x (Channel msg)
newChannel u =
    Task.andThen (\_ -> newChannel u) (Task.succeed ())


{-| kernel
-}
toAddress : Channel msg -> Address msg
toAddress ch =
    toAddress ch


{-| kernel: the id of a channel (equal ids, the same channel)
-}
channelId : Channel msg -> Int
channelId ch =
    channelId ch


{-| kernel
-}
chanRefId : ChanRef -> Int
chanRefId ref =
    chanRefId ref


{-| kernel: the oldest message of the channel (it stays until `advance`)
-}
current : Channel msg -> Task x msg
current ch =
    Task.andThen (\_ -> current ch) (Task.succeed ())


{-| kernel: drop the oldest message of the channel; `listeners` 0 counts it as dropped, or keeps it while an effects dispatch of this
manager is under way (O9); -1 counts it as dropped
-}
advance : ChanRef -> Int -> Task x ()
advance ref listeners =
    Task.andThen (\_ -> advance ref listeners) (Task.succeed ())


{-| kernel: the channels whose oldest message was kept by `advance ref 0` (O9), oldest first; the run time forgets them
-}
held : () -> Task x (List ChanRef)
held u =
    Task.andThen (\_ -> held u) (Task.succeed ())


{-| kernel: give the run time the router of this manager (the first time)
-}
attach : Platform.Router msg ChanRef -> Task x ()
attach router =
    Task.andThen (\_ -> attach router) (Task.succeed ())
