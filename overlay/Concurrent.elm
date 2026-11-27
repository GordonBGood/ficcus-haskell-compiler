module Concurrent exposing
    ( Pid, Address, Mailbox, Exit(..)
    , spawn, spawnWith, address, self, send, receive, await, kill
    )

{-| Ficcus T1a (docs/T1-THREADING-DESIGN.md T1-D2 to T1-D5; docs/attach/T1A-NOTES.md): green processes with typed mailboxes on the
scheduler of the C run time, one thread. Every operation is a `Task`; run them with `Task.perform` / `Task.attempt` from `init` or
`update`, or inside a process.

    spawn     : run a task as a process; its result is `Done a`, its failure `Failed err`, a kill `Killed`
    spawnWith : the same, the body gets its own `Mailbox`
    send      : append a message to the mailbox of an address (never blocks; a message to an ended process is dropped)
    receive   : the oldest message of a mailbox, waiting for one when it is empty
    await     : the exit value of a process, waiting for its end
    kill      : stop a process now (its `await` then gives `Killed`; its `Process.spawn` children go on)

Messages from one sender to one address arrive in the order they were sent. A process runs until it waits (receive, await, a
`Process.sleep` or another task of the run time) or ends. A process that waits forever does not keep the program alive.

The module is added to the source directories of `.c` and `.mono` builds (Ficcus.Mono.Overlay), like `Vector`; a module `Concurrent` of
the project wins. The types are run time objects (the constructors below are never built: they mark the types as built-ins), and the
functions of the last section are replaced by the kernels `elm/core:Concurrent.<name>` (runtime/fic_conc.h); their bodies only give the
types. Not yet (T1a-2): `receiveWithin`, channels, `listen`, `sendCmd`.

-}

import Task exposing (Task)


{-| a spawned process: await it, kill it, send to it
-}
type Pid exit msg
    = FicConcPidBuiltin


{-| the right to send to a process
-}
type Address msg
    = FicConcAddressBuiltin


{-| the right to receive; only the body given to `spawnWith` gets it
-}
type Mailbox msg
    = FicConcMailboxBuiltin


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



-- KERNELS (runtime/fic_conc.h)


{-| kernel: a new process running the body on its own mailbox; `killed` is its exit value when it is killed
-}
spawnRaw : exit -> (Mailbox msg -> Task Never exit) -> Task x (Pid exit msg)
spawnRaw killed body =
    spawnRaw killed body


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
    send to msg


{-| kernel
-}
receive : Mailbox msg -> Task x msg
receive box =
    receive box


{-| kernel
-}
await : Pid exit msg -> Task x exit
await pid =
    await pid


{-| kernel
-}
kill : Pid exit msg -> Task x ()
kill pid =
    kill pid
