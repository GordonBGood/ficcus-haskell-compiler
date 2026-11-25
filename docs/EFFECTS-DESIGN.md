# Effects run time design (checklist G17), draft for the user and a Fable review

EFFECTS session, 17 Nov 2026. Design note only: no code, no edit of the decisions file or the checklist. Proposed entries for those are in section 6.

**Marks.** **[S]** read in the source (file named). **[T]** run on `bin/elm0193` under node (test in section 1.8). **[A]** assumption or inference, not checked. A sentence without a mark is argument, not a claim about Elm.

Sources read: `elm/core 1.0.5` `Elm/Kernel/{Scheduler,Platform,Process,Process.server}.js`, `Platform.elm`, `Platform/{Cmd,Sub}.elm`, `Process.elm`, `Task.elm`; `elm/time 1.0.0` `Time.elm`, `Kernel/Time.js`; `elm/random 1.0.0` `Random.elm` (manager part); `elm/http 2.0.0` `Http.elm` (manager) and `Kernel/Http.js`; `elm/browser 1.0.2` `AnimationManager.elm`, `Kernel/Browser.js` (animator only). `elm/core 1.0.5` is byte-identical in the 0.19.1 and 0.19.3 package directories [S: `diff -r`], so what follows holds for both. In the compiler: `Generate/JavaScript.hs`, `Optimize/Module.hs`, `AST/Optimized.hs`, `Ficcus/Mono/{CGen,Spec,Kernel}.hs`, `runtime/fic_rt.h`, `fic_debug.h`. Docs: `COMPILER-HANDOFF.md`, `STAGE3-PLAN.md` R9, `STAGE4-PLAN.md`, `STAGE4-S6.md`, the decisions file (rev 135).

---

## 1. How Elm 0.19.3 runs effects

### 1.1 Layers

Three layers, all in `elm/core` JavaScript plus ordinary Elm code:

1. **Scheduler** (`Scheduler.js`): tasks (descriptions) and processes (running tasks), one FIFO run queue.
2. **Platform** (`Platform.js`): the program loop (`init`, `update`, `subscriptions`), bags (`Cmd`/`Sub` trees), effect managers, ports.
3. **Effect managers**: Elm modules declared `effect module X where { command = MyCmd, subscription = MySub }` (`Task`, `Time`, `Random`, `Http`, `Browser.AnimationManager`, `Browser.Events`, `Browser.Navigation`, `File`...). Each is a state machine in a process. The compiler turns the module into `Opt.Manager` nodes and the JS generator emits `_Platform_effectManagers["Time"] = _Platform_createManager(init, onEffects, onSelfMsg, cmdMap, subMap)` plus `command`/`subscription` as `_Platform_leaf("Time")` [S: `Optimize/Module.hs addEffects`, `Generate/JavaScript.hs generateManager/generateManagerHelp`]. A command-only manager passes `0` as `subMap`, a subscription-only manager passes `0` as `cmdMap` [S]; the manager loop tests `cmdMap && subMap` to choose the `onEffects` arity [S: `_Platform_instantiateManager`].

User code never sees processes except through `Process.spawn`, `sleep`, `kill` and `Task`; `Scheduler.receive`, `send` and the mailbox are used only by managers [S: `Process.elm` exports `Id, spawn, sleep, kill`].

### 1.2 Tasks

A task is an immutable description with six forms [S: `Scheduler.js`]: `SUCCEED v`, `FAIL e`, `BINDING callback`, `AND_THEN callback task`, `ON_ERROR callback task`, `RECEIVE callback`. `Task.map`, `map2..5`, `sequence`, `mapError` are Elm code over `andThen`/`onError`/`succeed`/`fail` [S: `Task.elm`]. `map2` runs its tasks in sequence, not concurrently [S]. A `BINDING` is the only form that touches the outside world: `callback(resume)` starts the operation, calls `resume(task)` later (or at once), and may return a cancel function stored in the binding as `__kill`.

Nothing runs until a process steps it. `Task.perform f task` is `command (Perform (map f task))` for the `Task` manager; `attempt` wraps `Ok`/`Err` and cannot fail [S: `Task.elm`].

### 1.3 Processes and the scheduler loop

A process is `{id, root, stack, mailbox}` [S]. The loop [S: `_Scheduler_enqueue`, `_Scheduler_step`]:

- `enqueue(proc)` pushes on a global FIFO. If the loop is already running it returns; otherwise it drains the queue calling `step`. So every entry into the scheduler from outside (a timer, an XHR, a port) runs everything it makes runnable before returning, and a re-entrant call from inside a step only queues.
- `step(proc)` loops while `root` is non-null:
  - `SUCCEED`/`FAIL`: pop the stack to the first frame of the matching kind (`AND_THEN` frames catch success, `ON_ERROR` frames catch failure; the others are discarded), apply its callback to the value, the result becomes the new root. If the stack is empty the process ends **silently**: a failure of a spawned task is dropped.
  - `AND_THEN`/`ON_ERROR`: push a frame, root becomes the inner task.
  - `BINDING`: call the callback with a `resume` that sets `proc.root = newRoot` and enqueues `proc`; store the returned cancel function; stop stepping this process.
  - `RECEIVE`: if the mailbox is empty stop, else apply the callback to the oldest message.
- A process therefore runs without interruption until it blocks on a binding or an empty mailbox. There is no preemption and no fairness beyond FIFO order of the queue.

Consequences that a port must keep (all [S] by reading, the first two also [T]):

1. **Spawn order.** `rawSpawn` enqueues the child; the `spawn` binding then calls its resume, which enqueues the parent behind it. So the child runs first, up to its first block; then the parent continues.
2. **A synchronous binding does not yield.** `Time.now` calls `resume` inside its callback; the process continues in the same drain.
3. **`sleep 0` yields to the host event loop** (`setTimeout`) [S: `Process.js`]. The only other way to let other host events in is a real asynchronous binding.
4. **A message sent to a process blocked on a binding re-runs the binding.** `rawSend` pushes to the mailbox and enqueues; `step` sees root `BINDING` and calls its callback again (a second `setTimeout` for `sleep`) and overwrites `__kill`; the first and second `resume` both fire later. [S: `_Scheduler_rawSend` + `_Scheduler_step`; not run.] This is reachable only through a manager process that is blocked inside `onEffects` or `init`, and it is harmless for the shipped managers (the outgoing port is the one that blocks, section 1.7). I recommend **not** reproducing it (decision D-fx-6); a stale resume after it would otherwise need care.
5. **`kill`** [S: `_Scheduler_kill`]: if root is a `BINDING` with a cancel function, call it; set root to null; the stack is dropped, no finalizer runs. A binding without a cancel function (`Time.now`, `spawn`, the `sendToApp` binding) cannot be cancelled, and if its `resume` fires later it **sets root and re-enqueues the killed process**: the callback does not test for death. Only bindings that are never pending (synchronous ones) or that cancel properly (`sleep`, `setInterval`, Http abort) occur in the shipped libraries, so this does not show up; a Ficcus binding API must say "a cancel function is mandatory for a pending binding, and `resume` after cancel is ignored" (stricter than Elm, no observable difference for Elm programs).
6. **Self kill** is a no-op in effect [A, derived from the code of 5; not run].
7. **Process ids** are a counter `guid++` and unobservable from Elm [S: `Process.Id` is opaque].

### 1.4 Bags, managers and the dispatch of effects

`Cmd a` and `Sub a` are one structure [S: `Platform.js`]: `LEAF home value`, `NODE [bags]` (`batch`), `MAP tagger bag` (`map`). `Cmd.none = batch []`.

`_Platform_initialize` [S] does, in order: decode flags; `init flags` giving `(model, cmd)`; build the stepper (a no-op for `worker`); `setupEffects`; `enqueueEffects(managers, cmd, subscriptions model)`.

- `setupEffects` walks `_Platform_effectManagers` (JS object, so insertion order: the order of the manager definitions in the generated file, which is dependency order of globals [A]) and for each manager spawns its process `rawSpawn (andThen loop init)`. `loop state = andThen loop (receive (msg -> ...))`: a message `SELF x` calls `onSelfMsg router x state`; any other message is `{cmds, subs}` and calls `onEffects` with the cmd list, the sub list or both. The new state is the task's result. Since the scheduler is idle at this point, the spawn runs `init` immediately; a manager whose `init` blocks (the outgoing port: `sleep 0`) is not ready until later. **E2 (24 Nov 2026, checked):** that order is the post order of the JS generator's dependency walk from `main` (`Generate.JavaScript.addGlobal`: the dependency sets in `Opt.Global` order, a manager after its `init`, `onEffects`, `onSelfMsg`, `cmdMap`, `subMap`), not the order of the homes' names that E1 used: a worker with `Time.every` in `subscriptions` and `Random.generate` in `init` registers Time before Random [T]. The C program uses the same walk (`Ficcus.Mono.ManagerOrder`, over the optimized graph that Make loads only for programs with managers).
- `sendToApp msg` [S]: `pair = update msg model; stepper(model = pair.a); enqueueEffects(managers, pair.b, subscriptions(model))`. The runtime variable `model` is replaced by the new model **after** `update` returns, so during `update` the runtime still holds the old model. (This is the sentence of STAGE4-S6 and rev 122 that Ficcus must change: section 3.4.)
- `enqueueEffects` [S]: pushes `{cmdBag, subBag}` on a queue and, unless already dispatching, drains it (a flag, with a long comment on why: effects from a synchronous command executed inside a dispatch must wait for the batch in progress).
- `dispatchEffects` [S]: `gatherEffects` flattens the cmd bag and the sub bag into a map home → `{cmds, subs}`, applying the `Map` taggers on the way down with the manager's own `cmdMap`/`subMap`; then **every manager, including those with nothing to do, gets one `fx` message** (`effectsDict[home] || {Nil, Nil}`), through `rawSend`. So `onEffects` of every manager runs after every `update`, with the complete current subscription list: diffing subscriptions is the manager's job (Time keys its timers by interval, Http compares trackers).
- **Order of the lists is reversed** relative to the bag: `_Platform_insert` conses each new effect on the front [S]. `Cmd.batch [a, b]` to one manager delivers `[b, a]`. [T: see 1.8.] The workertests README records the same ("a new compiler must keep"). For `Sub` the same reversal applies [S].
- Subscriptions are re-evaluated by calling `subscriptions model` after **every** update and once after `init` [S], and the result is retained by the managers only through their own state.

### 1.5 The shipped managers (how they use the scheduler)

- **Task** [S: `Task.elm`]: state `()`. `onEffects` is `sequence (map (spawnCmd router) cmds)`; `spawnCmd` is `Scheduler.spawn (task |> andThen (Platform.sendToApp router))`. So each `Task.perform` is a fresh process that, when its task finishes, calls `update` **synchronously inside the scheduler** (the `sendToApp` binding calls `router.sendToApp msg` and resumes with unit).
- **Time** [S: `Time.elm`, `Kernel/Time.js`]: state `{taggers : Dict interval (List tagger), processes : Dict interval Process.Id}`. `onEffects` merges the new interval set with the old, kills processes of removed intervals, spawns `setInterval interval (sendToSelf router interval)` for new ones. `setInterval` is a binding whose cancel is `clearInterval`; each tick runs `rawSpawn task` (a new process per tick). `onSelfMsg` reads `Time.now` and calls `sendToApp (tagger time)` for every tagger of that interval. `Time.now`, `here`, `getZoneName` are synchronous bindings (`Date.now()`, timezone offset).
- **Random** [S: `Random.elm`]: `init = Time.now |> map (initialSeed . posixToMillis)`; state is the seed; `onEffects` runs each `Generate` command on the seed and `sendToApp`s the value, in list order.
- **Http** [S]: state `{reqs : Dict tracker Process.Id, subs}`. `Request` spawns a process of a binding (an XMLHttpRequest, cancel = `abort`); `Cancel tracker` kills it; progress events go through `sendToSelf` to `onSelfMsg`, which filters the stored subs by tracker.
- **Browser.AnimationManager** [S, partly]: same pattern with `requestAnimationFrame`. For `Browser.element/document/application` the `view` is not an effect: `_Browser_makeAnimator` calls `draw(model)` at most once per animation frame and keeps `model = nextModel` between frames [S: `Kernel/Browser.js`]. So the **browser stepper holds the model between update and the next frame**, which matters for uniqueness (3.4).

### 1.6 Pure parts

`update`, `subscriptions`, `view`, `onEffects`'s Elm code, `cmdMap`, taggers are pure Elm. The impurity is exactly: the bindings, the timers, the port sides, and the order in which the scheduler picks processes.

### 1.7 Ports

[S: `Platform.js`, `Generate/JavaScript.hs generatePort`.] A port is a pseudo effect manager registered by name; `port out : T -> Cmd msg` is `outgoingPort(name, encoder)` and `port inn : (T -> msg) -> Sub msg` is `incomingPort(name, decoder)`; the compiler checks the payload type (`Canonicalize.Effects.checkPayload`).

- **Outgoing:** the manager's `init` is `Process.sleep 0`; `onEffects` converts each command with the encoder and calls every current JS subscriber synchronously, in list order (so in the reversed order of 1.4), then returns `init` again (**another `sleep 0`**). JS subscribers are copied before the loop so `unsubscribe` inside a callback is safe. A command with no subscriber is dropped.
- **Incoming:** `onEffects` just stores the sub list; `send(value)` decodes with the decoder, **crashes on a decode failure** (`Debug.crash 4`) and calls `sendToApp (tagger value)` for each current sub, synchronously, each producing a full `update`.
- Port names share the namespace of manager names (`checkPortName` crashes on clash).
- Flags are decoded at `init`; a failure crashes (`Debug.crash 2`).

### 1.8 What I ran (Elm 0.19.3, node 21.5)

A worker with `Cmd.batch [perform A (succeed ()), perform B (succeed ()), out "port1", perform C (sleep 0), perform D (succeed ())]` and an `update` that logs and answers `out "port-from-A"` on `A`. Output:

```
update: (D,0)   update: (B,1)   update: (A,2)      <- inside init(), before init() returned
init returned
subscribed                                          <- JS subscribed to the port after init()
PORT port1                                          <- outgoing port: delivered later, asynchronously
update: (C,3)
PORT port-from-A
```

[T] confirms: (a) the manager's list is the reversal of the batch order (D, B, A; `out` is a different manager and `C` is delayed); (b) a `Task.perform` of a pure task calls `update` before `init()` returns (nested in the dispatch); (c) outgoing port messages are delivered asynchronously after a timer tick, also those produced during `init`, and a message from `update` after the `sleep 0` of the same tick comes after `C`. The test is in `scratchpad/fx` (`Main.elm`, `run.js`) and can be added to `targets` as a Platform case (D-fx-9).

---

## 2. What the C path supports today

All [S] unless marked.

- **`main` must be** `Platform.worker { init = \flags -> ..., ... }` with a literal record and a lambda for `init` (`Spec.specWorker`; otherwise the error "Platform.worker without a literal record with an `init` lambda"; `CGen.workerInit`: "the only program shape supported in slice 1"). `Platform.Program` of `Browser.*` is rejected.
- **`update` and `subscriptions` are never compiled or run** (`specWorker` comment; STAGE3-PLAN R9). `init` runs, the model is dropped, **every `Cmd` is ignored** (`Cmd` is the unit class, `Spec` `"elm/core:Platform.Cmd.Cmd" -> CUnit`; `Cmd.none` and `Sub.none` are `0`; `Kernel.hs` lines 69-70, 193). The 16 suite programs print through `Debug.log` in `init` [A: not re-read for this note].
- **Everything else of Platform, Task, Process, Time, Http, ports, `Random.generate`** fails to compile with "the kernel function/value `...` is not supported by the C generator yet" (`CGen` kernel dispatch). `Random.step`, the pure part, compiles.
- **I/O:** `Debug.log` writes `tag: value` plus newline to **stdout** (`fic_debug.h`), `Debug.todo` writes to stderr and aborts. There is no stdin, no file access, no clock, no environment, no arguments, no exit code (C `main` returns 0, or 3 under the leak checks; `fic_main`). `Debug.log` is the only output of a program, so the differential tests compare stdout.
- **Threads:** one. `main` runs the whole program on a pthread with a 1 GB stack (`fic_run_main`, S6 decision (a)); the original thread only joins. Counts are non-atomic (`STAGE4-PLAN` section 3). A global size class pool serves all allocation (`fic_pool_*`, `fic_rt.h`) [S, not read in detail].
- **Ownership facts the effects design builds on:** header `{rc:u32, tag:u16, nptr:u8, cls:u8}`; static objects start at `FIC_IMMORTAL` = 2^30; `fic_is_unique` is `rc == 1`; an updated parameter is owned (`Borrow.updateParams`, "update rule"); a top level value is never unique when read (STAGE4-S6 section 6); `FIC_CHECK` aborts at 0xF0000000.
- **Closures:** a closure is `{header, code, captured}`, `fic_ap<n>` application, PAPs (`fic_rt.h`). How uniform the call ABI is over value classes (Int, Float, struct, reference) is something I have not read; section 3.2 depends on it [A].

So the effects work starts from nothing: no scheduler, no event loop, no I/O primitive, and no program shape beyond `init`.

---

## 3. Design for the C run time

### 3.1 Principle: port the semantics, not the implementation

Port `Scheduler.js` and `Platform.js` **line for line** into C kernels, and compile the effect managers (`Task`, `Time`, `Random`, `Http`, ...) **from their Elm source** as the compiler already does for the JS output (`Opt.Manager` nodes). Then the observable behaviour (spawn order, one `fx` message per manager after every update, the reversed lists, synchronous `update` inside `Task.perform`, silent death of failed spawned tasks) follows from the code instead of from a re-specification. The kernel set that must be written in C is small:

| Kernel | What |
|---|---|
| Scheduler | `succeed, fail, binding, andThen, onError, receive, rawSpawn, spawn, rawSend, send, kill`, the queue and `step` |
| Platform | `worker`, `leaf, batch, map`, `sendToApp, sendToSelf`, `createManager`, dispatch, ports (outgoing, incoming) |
| Process | `sleep` (a timer binding) |
| Time | `now, here, getZoneName, setInterval` |
| Per package | Http (`toTask` over a socket library or libcurl), File, Browser (platform specific, 3.7) |

### 3.2 Representation

- A **Task** is a counted heap object with the six tags of 1.2, a **Process** a heap object `{id, root, stack, mailbox}`, a **bag** a heap object with the three tags of 1.4. The scheduler queue and the manager table are runtime globals, not Elm values.
- **Boxing at the kernel boundary (the real design risk).** The scheduler and the bags are polymorphic in `a`, `x`, `msg` and they mix instances: a process stack holds callbacks of different result types, `Cmd.map` nests bags with different `a`. Whole program specialization cannot clone these per type without an explosion, and the closure/object layout depends on the class (Int, Float, struct, reference). I recommend: **a value that enters or leaves a Task, a bag leaf, a mailbox or a port converter is a boxed word** (`Scheduler.succeed @a` boxes by the class known at the call site, which the kernel key mechanism of Spec already supplies; `andThen`'s callback is wrapped in an adapter that unboxes), and the manager functions (`init`, `onEffects`, `onSelfMsg`, `cmdMap`, `subMap`) are compiled as ordinary clones at the single `msg` instance of the program. Only one `msg` instance exists per manager, because by the time effects reach a manager all `Cmd.map` taggers have been applied (`gatherEffects`). The cost is one allocation per `succeed` (small, the effect path is not the hot path) [A: depends on the closure ABI and on the "kernel key" machinery; needs a short check by the compiler session before the decision].
- **A cancel function** is `{void (*cancel)(void *env); env}` stored in the binding; **`resume`** is a runtime function `fic_resume(proc, task)` that is a no-op on a dead process (the strict rule of 1.3.5).

### 3.3 The single threaded event loop

Elm's JS host gives the scheduler three event sources: timers (`setTimeout/Interval`), I/O completions (XHR, ports) and animation frames. The C loop supplies the same by **one poll-based loop**:

```
run(): fic_init(); init program; dispatch initial effects;
       while (sources alive) {
           run timers whose deadline passed, in (deadline, creation order);   // each: resume(...) and drain
           wait: poll(fds, timeout = next deadline or infinite);
           for each ready fd: its handler (read stdin, accept, socket)         // each ends in resume(...) and drain
           drain the wake-up queue (completions posted by helper threads, ports from other threads)
       }
```

- **Drain** is the scheduler's own `enqueue` loop, unchanged: every handler ends in `resume`, which enqueues and drains. So one event is processed to completion before the next, as in a JS turn [S for JS; A for the port]. Between events the stack is empty, so it is the natural place for the leak-check and for dropping temporary state.
- **Timers:** a binary heap keyed `(deadline, sequence)`. `sleep t` and `setInterval` are bindings with a cancel that removes the entry (O(log n) with an index in the entry, or a tombstone). `sleep 0` runs after everything already ready, like `setTimeout 0` [S for JS; node clamps 0 to 1 ms, which is not reproduced and which no deterministic test can depend on [A]]. An interval re-arms from the previous deadline (no drift): JS `setInterval` drifts, and a test cannot depend on either.
- **Clock:** `Time.now` is `clock_gettime(CLOCK_REALTIME)` in ms (`Date.now`); timers use `CLOCK_MONOTONIC`. `Time.here` needs a zone: Elm gives only the fixed current offset (`new Date().getTimezoneOffset()`, no DST rules) [S]; the C version should do the same for equality with Elm, with the real zone as a later extension (D-fx-7).
- **stdin, stdout, files:** not part of Elm's core, so these are **new effect managers written in Ficcus** over C bindings, designed with the decided "Console and FileIO library modules" (decisions line 56): `Console.putStr : String -> Cmd msg`, `Console.readLine : Task x (Maybe String)` (a binding on the stdin fd, non-blocking), `Console.lines : (String -> msg) -> Sub msg`, `File.read/write` as tasks. stdout is buffered and flushed at exit and when the loop waits (so interleaving with `Debug.log`, which writes the same `FILE*`, stays in order). Files are synchronous POSIX calls in the first version (a regular file read does not wait for I/O in any way the loop could use; `poll` does not work on regular files), moved to a worker thread later (3.5 option B).
- **Random:** `Random.generate` is the Elm manager unchanged; its seed comes from `Time.now` at `init` like Elm's. For tests, a flag/env var fixes the seed [A: not in Elm; D-fx-7].
- **Http:** a binding per request. libcurl's multi interface integrates into `poll` and keeps the loop single threaded; a hand-written HTTP/1.1 client over `poll` is possible but TLS makes libcurl (or the host's webview networking) the sensible choice; a dependency decision, and the lowest priority (D-fx-8). Cancel = remove the easy handle; progress events via `sendToSelf` as Elm.
- **Exit.** A worker never ends in Elm; node ends when no event source is left. The same rule: the loop ends when there are no timers, no watched fds, no pending bindings and the queue is empty. A program with a live `Time.every` runs for ever. A new `Platform.exit : Int -> Cmd msg` (or a task) sets the exit code (D-fx-5). `Debug.todo` and crashes keep aborting.
- **Embedding:** the loop is a function `fic_run(timeout)`/`fic_poll_once` as well as `fic_run_main`, so a host (3.7) can drive it.

### 3.4 Keeping the model unique

Goal (rev 122, checklist G17): `update msg model` mutates the model in place.

Protocol: the runtime owns **one slot** `model`. `sendToApp`:

```
msg   = owned
m     = slot; slot = NULL               // the runtime drops its reference BEFORE the call (move, no dup)
(m2, cmd) = update(msg, m)              // update takes m owned: the update rule already makes such a parameter owned
slot  = m2
sub   = subscriptions(borrow slot)      // pure, borrows
enqueueEffects(cmd, sub)                // owned; released after the dispatch
```

The take/restore wraps only the pure call, so it is not re-entrant: nested `sendToApp` calls come later, from the scheduler, after `slot` is restored (1.4: the dispatch is after `update`). `update` is pure and cannot reach the scheduler.

What can still hold a second reference to the model, so that `rc > 1` and the update copies (never wrongly updates: the count is the truth, decisions line 352):

1. **The tuple of `init`/`update`**: the pair is a struct; the runtime moves both parts out. No problem.
2. **The `Cmd` returned by `update`** if a command or tagger captures the model or a large part of it (`Task.perform Done (Task.succeed model)`). It is released after dispatch, but a spawned `Task.perform` process keeps its closure until the task finishes, so the model stays shared **until then**. Correct, slower.
3. **The `Sub` bag and the manager state.** Managers keep the taggers of the last subscription list (Time's `taggers`, Http's `subs`) until the next `onEffects`. A tagger `\t -> Tick t model` captures the whole model, so the model is shared at the next `update`; a tagger that captures only the needed fields shares only those. **Cost: one copy of the shared part per update for such programs.** Mitigations: the manager state can be released **before** calling `update` only by changing Elm's order, which I do not recommend; instead provide the counter (`FIC_STATS`, "model copies") and a lint hint that names the capture [A].
4. **The browser/GUI stepper and `Html.Lazy`.** The view is a borrow of the slot at frame time and must not retain the model; a lazy node that stores its arguments for comparison holds a reference (the case of decisions line 352). Under the GUI, the loop calls `view` **borrowing** the slot and drops the result's references to the model parts after it has produced the patch.
5. **Debug history / time travel** would retain every model; not planned for C.

In debug builds, `FIC_CHECK_UNIQUE` can assert at the `update` call that the model has count 1, with a stat of how often it does not (checklist G17 test: counters in the rc runtime, a `Dict`/`Array` model updated 10^5 times, 0 copies).

### 3.5 Process, Task and Cmd on the loop

- `Task.perform`/`attempt`: unchanged (Elm code over the Task manager).
- **Process.spawn** is `rawSpawn`; **kill** is the algorithm of 1.3.5; **sleep** a timer binding. These are the whole of Process.
- **Task.perform of a task that never blocks** runs `update` inside `init`'s dispatch, as in Elm [T]. That order (D before B before A) is part of the contract and gets differential tests with Elm output (D-fx-9).
- **Outgoing ports** are delivered by `sleep 0`'s mechanism, i.e. from the loop, after the current turn [T].
- **Non-blocking by construction.** One long pure computation in `update` stops the loop (also in Elm: it stops the JS thread). No change.

### 3.6 Ports, the host API and the C FFI

**Ports.** Keep the Elm surface (`port module`, `port out : T -> Cmd msg`, `port inn : (T -> msg) -> Sub msg`, payload types checked by `Canonicalize.Effects`) and give it a **C host API** instead of the JS one:

```c
fic_port_subscribe("out", fn(void *env, fic_json v), env);   // called on the loop thread, asynchronously (1.7, T)
fic_port_send("inn", fic_json v);                            // loop thread only; from another thread: fic_post_port(...)
```

Values cross as `Json.Value` (the existing `fic_json.h` tree), which is what Elm's ports carry: converter = the Elm encoder/decoder. A decode failure of an incoming port crashes with Elm's message (D-fx-4). A **headless program with ports is also the way a C host or a test harness talks to a program**, and it is what the existing JS differential tests use (workertests, `Harness.elm`): the C test runner can print every outgoing port message to stdout in a fixed format, and read incoming messages from a script, giving a differential test of the whole effect path against node [A].

**C FFI** (checklist: `ficcus.json` carries link settings, decisions line 136). Two kinds:

1. **Pure FFI:** `foreign` declarations typed as ordinary functions over primitive and string types; the user asserts purity. No runtime support beyond the existing value layout.
2. **Effectful FFI is a Task binding.** Its C ABI is the runtime's own: `fic_cancel *start(void *env, fic_resume r)`; the function calls `r(proc, boxed_result)` on the loop thread, now or later. A library author wraps it in an Elm-level `Task x a` and optionally an effect manager (in Ficcus, the same `init/onEffects/onSelfMsg` form). So there is no separate FFI effect concept. A **blocking** C call goes to the worker pool (3.5 B, section 4). C code that wants to call back into Ficcus (a toolkit callback) must call `fic_post(...)`, which queues a completion for the loop thread (a lock free queue + an eventfd/self pipe woken in `poll`); it must never call `fic_resume` from another thread.

### 3.7 What a GUI platform needs from the run time

The decided design: a custom virtual DOM and an HTML GUI hosted in a Tauri-like webview, or in a browser (decisions line 55). From the run time it needs:

1. **`Browser.element/document/application`-shaped programs**: `view : model -> Html msg` plus `update`; the platform's stepper replaces the no-op stepper of `worker` (Elm's `_Platform_initialize` takes a `stepperBuilder` for exactly this [S]). `view` runs at most once per frame, from a **frame source** that is an event source of the loop (timer driven at 60 Hz when the host has no vsync callback; the webview's `requestAnimationFrame` when it has) [S for the coalescing in `_Browser_makeAnimator`].
2. **An outgoing channel for patches and an incoming channel for DOM events**, both as `Json.Value` or `Bytes`: this is a port with a fixed name, so the GUI platform = ports + a vdom kernel (diff in C, patch in the webview's JS) [A: design choice].
3. **A thread/event loop arrangement with the host.** Webview toolkits want the UI on the main thread and own the loop (Tauri/wry: Rust, `tao`; GTK/Qt: their main loops; macOS: AppKit main thread). Three ways, in order of my preference: **(a)** the Ficcus program as a **separate process** talking to the webview over a pipe or local socket (a port in disguise: no shared memory at all, so no thread safety question; one more process and IPC latency of the order of 0.1 ms); **(b)** the Ficcus loop on a **second thread** with a post queue in both directions, values crossing as serialised JSON/Bytes (never as shared Ficcus objects); **(c)** the Ficcus loop driven **by the host loop** through `fic_poll_once` from an idle/fd callback (works for GLib/GTK and libuv hosts; not for hosts that own an opaque loop). (a) and (b) need only the thread-safe `fic_post` of 3.6.
4. **Browser tasks and subscriptions** (`Browser.Dom.focus`, `getViewport`, `Browser.Events.onResize/onKeyDown`, `Browser.Navigation`, `File.Select`): each is a binding or manager whose implementation is on the host side; the run time only provides the generic "ask the host, resume later" binding (3.6.2) and event subscriptions fed by incoming messages.
5. A native toolkit instead of a webview has the same needs; only the vdom kernel (2) differs.

---

## 4. Threading kept in mind

Today counts are non-atomic and there is one thread (2). The question is what we may promise now so that threads can come later, and what each model costs and does to `Process`.

**The hazard.** `dup/drop` are plain `rc++`/`--rc`; two threads touching one object corrupt the count. Also the allocator pool is global [S: `fic_pool_*`] and would need one pool per thread (a free from another thread goes to the owner's remote list, or the block is freed with `free`): this is a second cost besides counts and belongs in any estimate. Immortal statics are counted too (2^30) so concurrent `++/--` on them is a data race that cannot overflow in practice but is formally undefined and will upset ThreadSanitizer [A].

**Options for making values cross a thread boundary:**

| Mechanism | How | Cost | Fits |
|---|---|---|---|
| **Move a unique value** | `rc == 1` at every level: transfer pointer, no sharing afterwards | Zero on the fast path, but "unique at every level" is a walk of the object, i.e. as costly as a copy, except for leaves (`String`, `Bytes`, raw `Vector`: O(1) check) | messages made of such leaves |
| **Deep copy at the boundary** (Erlang) | copy the reachable graph on send | O(size) per message, no cost anywhere else, no atomics, no flag | small messages, plain-data boundaries |
| **Shared flag, atomic counts** (Koka) | at the boundary mark every reachable object shared; `dup/drop` test the flag and use atomic ops on shared objects | O(size) once per crossing, **a branch in every dup/drop** (unmeasured for Ficcus [A]: the borrow inference and reuse keep most dup/drop out of hot loops, STAGE4-PLAN 12; benchmark on the 16 programs before choosing), the "never unique" test for in place update must also check the flag | large shared read-only data (a big `Vector` many workers read) |
| **No sharing, plain data only** | binding arguments/results are copied to/from C structs on the loop thread | The cost of the copy, only for I/O sized data | the worker pool for blocking I/O |

A compatible reservation that costs nothing now: **define bit 31 of `rc` as reserved for the shared flag** (Koka keeps the flag as the sign of the count). `FIC_IMMORTAL` is 2^30 and `FIC_CHECK` aborts at 0xF0000000, so the field has room; nothing in the runtime may use it for another purpose.

**Models of concurrency and what each does to `Process`:**

- **(0) Single thread plus the async I/O loop (section 3).** Process semantics are exactly Elm's: cooperative, deterministic, atomic between blocks. No count change. I/O that blocks the loop (regular files, a blocking FFI call) blocks everything.
- **(B) Worker pool for blocking bindings.** The binding's native part (a file read, a blocking C call, a DNS lookup) runs on a pool thread; the completion is posted to the loop, which calls `resume`. Values do not cross: arguments are extracted to plain C data on the loop thread, results are plain C data turned into Ficcus values on the loop thread ("no sharing, plain data only"). **Process semantics are unchanged** (all Elm-level code, `update`, managers still run on one thread, one at a time); `kill` of a process blocked in such a binding becomes "request cancel, and drop the result when it arrives" (a started file read cannot be recalled), observable only as a late side effect, as with an XHR that already reached the server. No atomics, no per-thread pool needed for Ficcus values; only the pool's own queue is concurrent. **This is the cheap, high value step.**
- **(A) Erlang-like processes with message passing.** Several threads each running a scheduler, `Process.spawn` placing the new process on any of them, an actor-style `Pid msg` with `send`/`receive` that copies or moves messages. Changes `Process` fundamentally: (1) a process is no longer atomic until its next binding relative to others; (2) `kill` becomes asynchronous (a running process stops at its next yield point); (3) ordering guarantees (the spawn-order of 1.3.1) hold only inside one scheduler; (4) managers must stay on the app scheduler with `update`, or `sendToApp` from several threads would race (so "the app actor" owns the model: TEA stays single writer, which is also what keeps 3.4 true). This is a new feature (Elm has no user `send/receive`) that can sit beside the Elm semantics as a separate module if all values cross by copy or move. It needs per thread pools and run time support (scheduler per thread, mailbox queue). Large.
- **(C) Parallel map / fork-join of pure functions** (`List.pmap`, `Task.parallel` over pure work, parallel `Vector` operations). Semantically invisible (results equal the sequential ones, the functions being pure) except `Debug.log` interleaving and which crash is reported first. This is the option that needs **shared objects with atomic counts** (the function's captured data is shared by the workers), or deep copies of the inputs. It does not change `Process` at all: a parallel map is one binding that completes when all parts are done (cancel = a flag the workers poll). Medium to large; the shared flag is the real cost, and it is the case Ficcus benefits most from (vectors).

**My recommendation.** Build (0) now, with (B) as a later step; reserve the flag bit (free); decide on (C) with the shared flag only after measuring the dup/drop branch; treat (A) as a separate library project on top of copy or move, not as a change to `Process`. All of them keep the Elm semantics of `Process.spawn/sleep/kill` as long as Elm-level code (`update`, managers, tasks) runs on the app scheduler. The only observable change in any option is: after `kill`, a native operation already started may finish (its result is discarded).

---

## 5. Open points and risks

1. Boxing at the kernel boundary (3.2) depends on the closure ABI and on how the specializer keys kernels by type. A half page check by the compiler session before the implementation.
2. Elm quirks that a port should keep, each with a differential test (D-fx-9): reversed order of lists to a manager (1.4 [T]); `update` called synchronously inside `init`'s dispatch for synchronous tasks (1.5, [T]); one `fx` message to every manager after every update (1.4 [S]); outgoing ports asynchronous (1.7 [T]); a failed spawned task is silent (1.3 [S]); `sleep 0` yields (1.3 [S]).
3. Stack: a chain of synchronous `andThen` is iterative in `step` [S]; any worker thread (B, C) needs a configured stack size like the main run thread.
4. Leak checks under `--rc`: at exit the effect state (managers, the bags, process stacks) must be freed or counted as static roots so that `fic_shutdown` still reports zero live objects: a runtime teardown function (the "dropped only by test builds" mechanism of globals).

---

## 6. Decisions for the user, in the order that blocks

Each: recommendation and cost. "Blocks" means what cannot start until it is answered.

**D-fx-1. What does the first effects version support, and in what order?** *Blocks everything.* Recommend: (1) `Platform.worker` with `update`, `subscriptions`, `Cmd`, `Sub`, `Task`, `Process.sleep/spawn/kill`, `Time`, `Random`, outgoing and incoming ports, a single thread and the poll loop; (2) `Console` stdin/stdout and `File` modules; (3) the GUI platform (`Browser.*`); (4) Http. Cost: step (1) is the scheduler and platform ports in C (about 700 lines of C if the JS is any guide: `Scheduler.js` 195 lines, `Platform.js` 521 [S: line counts]) plus compiling the manager modules, plus the boxing change in Spec/CGen, which is the larger part.

**D-fx-2. Boxed values at the kernel boundary (3.2) or something else.** *Blocks the scheduler and every manager.* **Amended 24 Nov 2026** (compiler check `ficcus-haskell-compiler` branch design/fx-check, `docs/EFFECTS-CHECK.md` section 2; implemented by effects slice E1, branch feat/effects-e1): values crossing the Task, bag, mailbox and port kernels use **the closure word ABI** (a `fic_word`; a struct as its existing `FIC_TAG_BOX`), no new box kind: the premise that the object layout depends on the class held only for structs, which the ABI already boxes. Kernel objects (Task nodes, processes, bags) follow the header convention (references first, `nptr` counts them). The class comes from the kernel key, which the specializer computes at the instantiated type. Callbacks (`andThen`, `onError`, taggers, `cmdMap`/`subMap`) are ordinary closures applied with `fic_ap1`, no adapter. Manager functions are ordinary clones from their Elm source: `init`, `onEffects`, `onSelfMsg` at the class of the program's `msg`, `cmdMap`/`subMap` at each class pair of the program's `Cmd.map`/`Sub.map`; `command`/`subscription` are the leaf kernel keyed by the manager's home. `Cmd`, `Sub`, `Program`, `Task`, `ProcessId`, `Router` are references; `Cmd.none`/`Sub.none` are one static immortal empty bag. Cost: an allocation only for a struct payload. E1 status: the classes, the kernel table and the manager clones (steps 1 and 2); the scheduler kernels in C are E2 (step 4). **E2 step 4 (24 Nov 2026, branch feat/effects-e2):** `runtime/fic_sched.h` ports `Scheduler.js` and the dispatch of `Platform.js`: tasks, processes, the run queue, the mailbox, bags, the manager table (`fic_mgr_def`, one router and one process per manager, its loop and receive in the runtime), `enqueueEffects`/`dispatchEffects`/`gatherEffects`. "None" is a static object, so every reference field is an object. Two points where the port differs from a literal translation: (1) `Elm.Kernel.Scheduler.spawn` in `Task.spawnCmd` (annotated `Task x ()`) yields `()`, not the process, because a reference typed `()` would never be released (unobservable: JavaScript never reads it); `Process.spawn` still yields the id. (2) A `Cmd.map`/`Sub.map` node applies its tagger with the manager's map function at that node's class pair, one node at a time, innermost first, where Elm composes the taggers and calls the map function once: equal for every map function with `map f << map g = map (f << g)` (Task, Time, Random; ports are handled by the runtime). The rule 2 check (`FICCUS_UNBOX_CHECK=1`) also fails the compile if a worker's result is a kernel type; rule 2 already refuses such clones (their leaves are kernel calls).

**D-fx-3. Model ownership protocol (3.4).** *Blocks G17 itself.* **Amended 24 Nov 2026** (EFFECTS-CHECK section 3; implemented by effects slice E1 step 3): the platform does **not** call `update` through a closure. The specializer clones `init`, `update` and `subscriptions` (later `view`) at the program's types, and the C generator emits a **typed stepper** that calls them directly, the model in a slot of its own class (a record is a struct by value, no box on the way in). **The model is passed owned and returned owned, and the stepper never copies it:** it moves the model out of the slot into `update`, stores the model `update` returns (one owned value), and then calls `subscriptions` with the slot **borrowed**, as a direct call; no uncounted pointer to the model survives a call, so every in-place write in `update` tests the true count. `subscriptions` is called after `init` and after every `update`, as Elm does. Two compiler rules make the ownership hold: (1) the borrow inference **seeds** `update`'s model parameter as owned (an extra root of the update rule), since the ordinary rules borrow a model whose fields are only read; (2) the fields that `update` reads from the model are bound at its entry (`Ficcus.Mono.ModelUnpack`), because the Rc pass reads a field of an owned struct as a view plus a count and drops the struct only after its last use, so an `Array.set k v m.a` next to an `m.n` would see two counts and copy. The record update `{ m | a = e }` (Spec's `let _upK = m in { a = e, d = _upK.d }`) is read as `m` itself where `_upK` is only read field by field (review fix 1, `docs/E1-REVIEW.md` Q1; 70% of the two-argument `update`s in `corpus/` use this form). **What is guaranteed (narrowed 24 Nov 2026 after the E1 review):** no copy of the model by the protocol when `update` is a lambda or a top-level function of two arguments whose body reads the model's fields directly or through `{ m | .. }` (writing all fields, or some and keeping the rest), including fields read under a lambda or on one branch only. Not guaranteed, correct but copying: a helper that receives the whole model (and a nested record `{ m | inner = { i | .. } }`) copies the leaf it writes, until a per-leaf move in the Rc pass; the closure fallback (`update = f config`, a curried or wrong-arity `update`, about 4% of `corpus/`) puts the seed and the unpack on the wrapper, not on the real function, and copies. A model leaf with a second owner (another field, a list of old models, a closure or a command that captured it) is decided by the reference count: copied when shared, written in place when unique. Measured (test G17b, 100,000 steps over a record of a `Dict` and an `Array`): 0 model copies, 199,200 updates in place, 0 reuse misses; without the unpack, or without the seed when `update` only reads fields, 199,200 copies. Review tests (`ficcus-tests/e1_review.py`): R1Partial (partial update, 1,000 steps) 1,960 copies before fix 1, 5 after (the first writes to the immortal `init` literal); R2Alias 10 in 30 steps (exactly the steps that share the array), R3History 6, R4Lambda 0, R5Capture 12 (one per step: required). The protocol never asserts uniqueness: a model also held by a command, a subscription's tagger, a manager's state or an immortal `init` literal is copied once at its next update, never written in place. Kernels must never keep an uncounted pointer to the model across `update`. `FIC_STATS` prints a `model` line (in place, copied, vector copies, reuse misses between the stepper's entry and exit; `model_copies` = copied + vector copies). The dispatch keeps Elm 1.0.5's re-entrancy order (E2). Limits: a helper that `update` passes the whole model to is not unpacked (the same Rc limitation; the general fix is a per-leaf move in the Rc pass); an `update` that is not a lambda or top level function of two arguments (`update = f config`) is called through its closure (correct, without the guarantee). The guidance "do not capture the whole model in a tagger" is a performance rule for the docs. **Compile regression until E2 (recorded 24 Nov 2026, E1 review Q5):** since E1 always clones `update` and `subscriptions`, a worker whose `init`, `update` or `subscriptions` mentions a manager (`Task.perform`, `Time.every`) no longer compiles, even if no message ever reaches that code; `bin/elmficW7a` compiled it (it never cloned `update`) and its output equalled Elm's. The C generator stops with one message, "the effect managers elm/core:Task need the scheduler, which the C generator does not have yet (effects slice E2): the program uses them ...", in both modes (test S2Perform in `ficcus-tests/effects_e1.py`). No program in `targets/` or `ElmFiccusSamples/` is affected. It ends with the scheduler (E2 step 4). **Ended by E2 step 4 (24 Nov 2026):** such a worker compiles in both modes and its output equals Elm 0.19.3's (`ficcus-tests/effects_e2.py`: S2Perform, E2Perform). G17 proper (100,000 `Task.perform` steps on the scheduler, `ficcus-tests/effects2/src/G17.fic`): output = Elm, 0 model copies, 199,200 updates in place, 0 reuse misses; companion (c) (a closed literal `init` model): exactly 1 copy in 50 steps. The stepper's `FIC_STATS` bracket now ends before the dispatch, because a step can run inside the dispatch of another (a `Task.perform` answered synchronously), and the brackets must not nest.

**D-fx-4. Port surface in C (3.6).** *Blocks ports and the differential test of the effect path.* Recommend: keep Elm's `port` declarations and JSON payloads; host API `fic_port_subscribe/send`; delivery asynchronous on the loop thread; for the test runner print outgoing messages to stdout in the harness format of `workertests`. Cost: small. Alternative: ports only through the Console module (no host API): cheaper, but no embedding.

**D-fx-5. Program shape and exit.** *Blocks the driver.* Recommend: the loop exits when no event source is left; add `Platform.exit : Int -> Cmd msg` (or a `Task`), exit code 0 otherwise; unhandled crash 1 or abort; `main` stays `Platform.worker` in a `.fic` application, a different `main` type for the GUI later. Cost: one library function and one kernel; a new name in the Platform module is an extension to the Elm API and needs the user's yes (`.fic` only, as the dialect gating decision says). **E2 step 5 (24 Nov 2026):** the loop part is implemented: `fic_sched_run` (runtime/fic_sched.h) runs the timers until none is left, then the program ends (exit 0); a program with a live `Time.every` runs for ever, as under node. `Platform.exit` is not done (it needs the user's yes on the Elm API extension).

**D-fx-6. Elm quirks to keep or drop (1.3.4, 1.3.5).** *Blocks the scheduler details.* Recommend: keep everything that is observable by Elm programs (list 5.2); drop the re-run of a blocked binding on `rawSend`, and make `resume` after `kill` a no-op: record both as decisions. Cost: none now; tiny risk of a difference for an unusual package manager, caught by the corpus. **E2 (24 Nov 2026):** implemented as recommended. A message to a process that waits in a binding does not run the binding again; `kill` cancels the pending timer (`clearTimeout`/`clearInterval`) and a resume can no longer reach the process (the timer is gone, and the loop resumes only a process whose root is still that binding). A process killed while it sleeps never runs its continuation (test E2Sleep). A synchronous self kill continues, as in Elm (the binding's own resume is not a late one).

**D-fx-7. Time and Random for deterministic tests.** *Blocks tests of `Time`/`Random` against Elm.* Recommend: `Time.here` = fixed offset as Elm; an environment variable `FIC_TIME`/`FIC_SEED` (or a runtime flag) fixing the clock and the seed in test runs; document that wall clock output cannot be compared with Elm. Cost: small; extension to Elm. **E2 step 5 (24 Nov 2026):** `FIC_TIME=<ms since the epoch>` makes the C clock virtual: `Time.now` starts there and the loop never sleeps, it moves the clock to the next deadline, so a program with timers gives the same output and values on every run (the effects tests use it; the Elm side runs in real time and is compared by output, which the tests keep independent of the clock). Without it: `Time.now` is `CLOCK_REALTIME` in ms, the timers `CLOCK_MONOTONIC`, and the loop sleeps (stdout is flushed first). As in node, a delay below 1 ms is 1 ms (so `sleep 0` and `sleep 1` fire in the order they were made); an interval re-arms from its previous deadline. `Time.here` is the offset of the local zone now (no rules) and `Time.getZoneName` the zone's name (TZ, else the link /etc/localtime, else `Offset` of the offset), through `overlay/FicOverlayTime.elm` on two kernels; Elm builds the same values in its kernel. The zone data is the system's tz database, node's is ICU's: on the development machine they disagree for America/Edmonton (system -06:00, node -07:00), so the tests run with TZ=UTC on both sides. **E2 step 6 (24 Nov 2026):** `Random.generate` runs elm/random's manager unchanged (compiled from Elm), seeded from `Time.now` at its `init`. `FIC_SEED=<n>` replaces the time that this one `Time.now` (the one run by the Random manager's own process) reads, so the seed is `initialSeed n` and nothing else changes. With the clock fixed the values equal Elm's: the effects tests pin node's `Date.now` to `FIC_TIME` (effects2/ref/run.js), and `FIC_SEED=7` gives what Elm gives for `Date.now = 7` (tests E2Random, E2Seed). This also gives an observable case of the manager order of 1.4: in E2Random Elm registers Random before Task, so the `Task.perform` of the batch reaches `update` after the five `Random.generate`s; E1's order of names would have put it first.

**D-fx-8. Http and the libcurl dependency.** *Blocks Http only.* Recommend: last; libcurl multi in the loop for the C target, the webview's `fetch` for the GUI target; no hand written TLS. Cost: an external dependency (or none if Http is left out of the first release, which I recommend: the user's own list does not need it for the headless programs).

**D-fx-9. Differential tests.** *Blocks the confidence in any of the above.* Recommend: add `targets` Platform cases (the test of 1.8 plus Time/Random/ports from `workertests` T12) whose golden output comes from node with the port messages and `Debug.log` lines interleaved; a runner that prints outgoing ports in the same format. Cost: a day; high value since the order is the whole risk.

**D-fx-10. Threading promises (section 4).** *Does not block 1 to 9.* Recommend: (a) now: reserve bit 31 of `rc` for the shared flag and write "single threaded run time, no atomics" in the plan; (b) after D-fx-1 step 2: worker pool for blocking bindings, plain data across, Process semantics unchanged; (c) measure the dup/drop branch before deciding on parallel map; (d) actors as a library, later. Cost now: one line in the header comment; later steps as in section 4. If instead the user wants threads from the start, option (C) with atomics changes `fic_rt.h`, the allocator and every kernel's FIC_RC_DUP/DROP: weeks, not days.

**D-fx-11. GUI host arrangement (3.7).** *Blocks the GUI platform only.* Recommend: the Ficcus program as a separate process or second thread, talking to the webview by serialised messages (3.7 a/b); not sharing Ficcus values with the host. Cost: IPC latency; independent of threading decisions.

---

## 7. Proposed entries for the shared files (not applied)

Decisions file: a DONE entry for this note and one DECIDED entry per answer D-fx-1 to 11; the OPEN item on thread safety of counts (line 50) becomes "answered by D-fx-10"; the quirks of D-fx-6 join the Elm quirks list. Checklist: G17 gets sub items (a) boxing check, (b) scheduler and platform kernels, (c) model protocol and counters, (d) Platform differential cases, (e) Console/File modules, (f) ports host API.
