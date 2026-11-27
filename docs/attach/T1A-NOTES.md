# T1a-1 notes: Concurrent on the E2 scheduler

27 Nov 2026, worktree `ficcus-haskell-compiler-t1a`, branch `feat/t1a` from `ficcus` 89e215a2 (P1b). Binary `bin/elmficT1a`. Identity
reference `bin/elmficP1b`. Design: `docs/T1-THREADING-DESIGN.md` on `design/t1`. The user's scope cut: green processes only, one thread,
no real threads, no parallel pure work, no shared flag bit, no atomics (parallel work is future package work); the thread-safe post
queue stays E3e.

## 1. The sixteen decisions under the scope cut

| # | Decision | Under the cut |
|---|---|---|
| 1 | D1 `Concurrent`, `Process` untouched | kept (gated like `Vector`, not `.fic` only: O6) |
| 2 | D12 two runtime modes | **reduced**: one runtime; `fic_conc.h` and the patched scheduler only when reached; identity gate kept |
| 3 | D7 green, M:N, fork-join | **green only**; M:N, fork-join, posting to the loop thread drop; domains only as the shuffle's unit |
| 4 | D2 types and functions | kept; `channel`, `listen`, `sendCmd`, `receiveWithin` in T1a-2 |
| 5 | D3 mailboxes | kept |
| 6 | D6 effect module, channels | kept, T1a-2 |
| 7 | D4 results, crash ends all | kept |
| 8 | D5 kill | **reduced**: one scheduler; asynchronous cross-thread kill drops |
| 9 | D13 shutdown | kept for one thread; worker join drops |
| 10 | D14 determinism | deterministic and seeded shuffle kept; N-run parallel mode drops; JS kernel deferred (hand-reasoned outputs) |
| 11 | D15 sanitizers | ASan, UBSan, DROP_ALL kept; TSan, owner check drop |
| 12 | D8 crossing rule | **drops** (one heap: plain counts) |
| 13 | D9 bit 31, sticky immortals | **drops** (bit 31 stays reserved, D-fx-10 a) |
| 14 | D11 per-thread pools, TLS | **drops**; tcc needs nothing special |
| 15 | D10 exclusive rule | **drops** |
| 16 | staged plan | T1a only (T1a-1, T1a-2); T1b stays E3e; T1m, T1c, T1d leave Phase 1 |

## 2. What was built

- `overlay/Concurrent.elm`: types `Pid exit msg`, `Address msg`, `Mailbox msg` (one marker constructor each, never built), `Exit err a
  = Done a | Failed err | Killed`; `spawn` and `spawnWith` written in Elm over the kernel `spawnRaw killed body` (the body's result is
  mapped to `Done`, its failure to `Failed`); kernels `address`, `self`, `send`, `receive`, `await`, `kill`.
- `compiler/src/Ficcus/Mono/Concurrent.hs` (new): the embedded overlay and runtime, the marker test `concOn`, the redirect to
  `elm/core:Concurrent.<name>`, the kernel table, and `patchSched`. Hooks: Make writes the overlay (like Vector); Spec makes the three
  types references (like Vector) and redirects the calls; Kernel lists arities and signatures; CGen maps the seven kernels and emits
  the runtime.
- `runtime/fic_conc.h` (new, about 380 lines): the process record `fic_cproc` beside the E2 `fic_proc` (own FIFO mailbox, receivers,
  awaiters, exit value, `Killed` value), the registry, the operations, the teardown, and `FIC_SCHED_SEED`.
- **`fic_sched.h` is not edited.** A callback cannot know the process that runs it, and E2's mbox re-runs a waiting binding (a send to a
  sleeping process would arm a second timer). So a program that calls a Concurrent kernel gets fic_sched.h with three checked text
  patches (`patchSched`; an anchor that is not found exactly once gives `#error` in the C): the run queue's pick is `fic_conc_pick()`,
  `fic_conc_cur_p` is the process being stepped, and `fic_platform_teardown` starts with `fic_conc_teardown()`. Every other program gets
  the unchanged text.
- Blocking uses E2's receive task: its router is a `fic_conc_router` (a `fic_router` prefix) naming the manager slot
  `FIC_MAX_MGR - 1` (`fic_nmgr` never reaches it; checked), whose onSelfMsg continues the process. One wake mail per block.

## 3. Semantics (the rules the expected outputs are reasoned from)

- **R1** The run queue is E2's FIFO. A process runs until it waits (receive on an empty mailbox, await of a running process, an E2
  binding: `Process.sleep`, `Process.spawn`, `Time.now`, ...) or ends. The operations that complete at once do **not** yield (O1).
- **R2** `spawn`: the child goes to the back of the queue; the parent goes on.
- **R3** `send`: append to the mailbox; if processes wait in `receive` on it, the oldest live one is queued; the sender goes on.
- **R4** `receive`: the head at once if there is one, else wait; a woken receiver takes the head (or waits again).
- **R5** `await`: the exit value at once if ended (any number of times), else wait; at the end the waiters are queued in await order.
- **R6** `kill`: of a running process: E2's kill (timer cancelled, root and stack dropped), exit `Killed`, mailbox dropped, waiters
  queued; a self kill ends the process after the operation; of an ended process: no-op. `Process.spawn` children go on.
- **R7** the end of the body: `Done a` or `Failed err`, mailbox dropped, waiters queued.
- **R8** a send to an ended process is dropped and counted (`FIC_STATS concurrent: ... dropped`).
- End (T1-D13): when the queue and the timers are empty; still-running processes are killed without waking anyone, then the registry
  drops every exit value and record (cycles through handles in mailboxes, stacks and exit values are broken). `FIC_STATS` (or
  `FIC_WARN_BLOCKED`) prints `spawned sent dropped blocked_at_end`.
- Shuffle (`FIC_SCHED_SEED=n`): the pick chooses uniformly among the queued Concurrent processes and the first queued other process (the
  app's processes keep their FIFO order); xorshift64*; per-sender order holds in every schedule (mailboxes are FIFO).

Case reasoning (expected files in `ficcus-tests/t1a/expected/`):

- **T1aOrder**: P (the app's perform process) spawns A, B (R2), logs, awaits A and waits (R5). A runs to its end (R1), wakes P (queued
  behind B); B runs; P then gets `Done 10`, `Done 20` at once, and `Done 10` again.
- **T1aMailbox**: R waits on its empty mailbox; S1's first send queues R behind S2 (R3); S1, S2 finish; R takes all six without waiting
  (R4): `Num 1..3` then `Word a..c`. The final value is split by sender, so it is the same under every shuffle.
- **T1aKill**: the four children run before P's 10 ms timer: two wait, the sleeper's timer is at 100 ms. P kills the sleeper (its timer
  goes: "woke" never prints) and the receiver, sends `Die k`, awaits (`Killed`, `Killed`), kills the ended `q` (no-op, `Done 5`),
  sends 7 to the killed receiver (dropped 1), awaits k: k self-kills (R6), P gets `Killed`.
- **T1aFailed**: `Task.fail "boom"` becomes `Failed "boom"`; the orphan parent's `Process.spawn` is a binding (it yields behind P and the
  child); P kills it at 10 ms; its child still logs at 50 ms.
- **T1aDeadlock**: A waits for B with two self-addressed `Ping`s in its mailbox, B waits in receive, P waits for B: the program ends,
  no `update`, `blocked_at_end 2`, live 0. (This case found a bug: the teardown's kill woke P outside a drain, so `update` ran during
  teardown; teardown now wakes nobody.)
- **T1aMany**: 10000 processes each send `{k, s}` (a boxed record); sums 50005000 and 38894 digits; finished records are swept.

## 4. Tests and gates

`ficcus-tests/t1a/run.py` (gates.sh step `t1a`): 6 cases, --rc (O2, ASan+UBSan, DROP_ALL; live 0, the stats line) and --no-rc;
shuffle seeds 1..30 (multiset, last line, sender order, reproducible, at least two orders where races exist) and 1..4 under the
sanitizers; identity of the C text of effects3 and e2review (33 programs, both modes) against `elmficP1b`. Also checked by hand: clang
`-Wall -Wextra -pedantic` clean, tcc output equal. Gate results: section 6.

## 5. Left for T1a-2

Done in T1a-2 (section 8).

## 6. Gate results

Targeted, serial, 27 Nov 12:44-13:06, `bin/elmficT1a`, log `/home/gordon/claude-tmp/gates-t1a.log`: runtime 0 non-ok; attach --rc
378 cases 0 differ; types 267 PASS 1 XFAIL; JS identity 28 identical; effects e1, e2, e3 all ok; e1p all ok; t1a all ok (identity 66
texts 0 differ); a3b-identity --more vs elmficP1b 100 compiles 0 differ; rcgate-san 16 ok; suite 16/16 PASS.

## 7. Open points for the Opus review

- **O1** No yield after an operation that completes at once (R1); `Process.spawn` (E2) does yield. Elm has no reference; is
  run-to-block the order we want to promise?
- **O2** The text patch of fic_sched.h (three anchors, `#error` when one is missing) versus editing fic_sched.h, which would change
  the C text of every effects program.
- **O3** The reserved manager slot `FIC_MAX_MGR - 1` and the `fic_router` prefix of `fic_conc_router`.
- **O4** A Concurrent process is recognised in the run queue by a negated E2 id (the id is otherwise unused).
- **O5** The registry keeps an ended record while anything else holds it (swept when only the registry does), so a long-running
  program that keeps handles keeps their records; a record is small (exit value kept).
- **O6** Gating: as `Vector`, any module of a `.c` build can import `Concurrent`; T1-D1 asks for `.fic` only.
- **O7** `Debug.toString` of a handle prints the empty string (Elm prints `<internals>` for kernel values); `==` on handles is not
  specified (the marker types are custom types whose objects carry another tag).
- **O8** A leaked `Mailbox` (sent to another process) lets two processes receive from one mailbox: handled (receivers queue, R4),
  but T1-D2 meant the mailbox to be private.

---

# T1a-2: the effect manager, the rest of the API, the JavaScript reference

27 Nov 2026, same branch, from 2d4f8148. Binary `bin/elmficT1b`. Decisions applied (planning chat, as recommended): O1 kept, O2 kept,
O6, O7, O8 as below.

## 8. What was built

- **API complete** (T1-D2): `channel`, `toAddress`, `listen`, `sendCmd`, `receiveWithin`. `overlay/Concurrent.elm` is now an `effect
  module` (command `SendCmd`, subscription `Listen`). Elm allows effect modules only in `elm/*` packages; Build parses the overlay's
  `Concurrent` (that file of the overlay directory only) as a module of a kernel package (`Pkg.kernel`), nothing else changes.
- **The manager** keeps no message type: `Listen id deliver`, where `deliver : (msg -> Task) -> Task` reads the channel's current
  message and sends the tagged message to the app (the existential type of the channel stays inside the closure, so `subMap` composes).
  A send to a channel queues the message in the channel record and sends the record to the manager as a self message (router given by
  the kernel `attach` in the manager's first onEffects; before that the message is dropped). `onSelfMsg` runs the matching listens in
  the order of the subscription list, then `advance` drops the message (counted when nobody listened). `sendCmd` runs `send` in
  onEffects. So channel messages enter `update` only through the manager, on the loop: one writer of the model.
- **receiveWithin**: a message first gives `Just` (no timer); otherwise an E2 interval timer for the waiting process whose task wakes it
  with `Nothing`; a message first cancels the timer; an epoch makes a stale timeout a no-op; kill cancels it (E2's kill).
- **O6**: a `.elm` module of the project that imports the overlay's `Concurrent` gets `FICCUS ONLY MODULE` (new `Syntax.FicOnlyImport`,
  checked in `Build.crawlFile`), in C and JavaScript builds. JavaScript builds now get the overlay `Concurrent.elm` alone
  (`elm-stuff/ficcus-overlay-js`, not a root): other programs are generated as before (JS identity gate).
- **O7**: `Debug.toString` of a handle is `<internals>`; `==` compares records (one per process or channel, so ids) in C
  (`isConcType` in CGen) and JavaScript (an object with a numeric `$` and a distinct `id`).
- **O8**: `receive`/`receiveWithin` by any process but the mailbox's owner ends the program: `Concurrent.receive: the mailbox belongs to
  another process (only the body given to spawnWith may receive from it)`, exit 1 (C: stdout flushed, `exit(1)`; JS: an Error). With
  one receiver per mailbox, the receiver list became a flag.
- **JavaScript reference** (T1-D14 (2)): `runtime/fic_conc.js` (same rules), emitted once by `Generate.JavaScript` after elm/core's
  Scheduler and Platform kernels; each kernel definition of the overlay becomes `var $author$project$Concurrent$<k> = _FicConc_<k>;`.
  It wraps `_Scheduler_step` to know the current process (the C patch's twin) and uses Scheduler.js's field names (checked at load).

## 9. Rules added (for the user guide)

- **R1 (O1, kept)**: `spawn`, `send` and `kill` never yield: a spawned process starts when the current one waits or ends.
- **R9** A channel message is delivered to the listens the manager has when it handles the message, in the order of the subscription
  list as the manager receives it (Elm's gather order: `Sub.batch [a, b]` reaches the manager as `[b, a]`). A message sent in the same
  turn as the `update` that subscribes can reach the manager before the new subscription (E2's dispatch sends to the Task manager first,
  and a performed task runs at once). Since T1c (O9, narrow form) such a message is kept until the onEffects of that dispatch and then
  delivered to the new listens; a message that finds no listen while no dispatch of the manager is under way is dropped (as ports do),
  and a kept message that still has no listen after that onEffects is dropped there.
- **R10** `receiveWithin t`: `Just` at once when a message is there; else the first of a message (`Just`) and `t` ms (`Nothing`,
  `fic_timer_delay` rules as `Process.sleep`).
- **R11** only the owner receives (O8).

## 10. Cases (hand reasoned; C = JS = expected)

- **T1aWithin**: W waits 50 ms, K waits 30 ms, P sleeps 10. At 10 P sends 1 (W: `Just 1`, its timer gone), kills K (its timer gone:
  "never" never prints), sleeps 100. W waits 50 again: `Nothing` at 60, then waits 1000. At 110 P sends 2 (W wakes: `Just 2`) and 3,
  then awaits W; W's `receiveWithin 5` finds 3 queued: `Just 3` at once. `Got (Done [Just 1,Nothing,Just 2,Just 3],Killed)`.
- **T1aChannel**: init performs channel, channel, spawnWith worker: `Got (<internals>,<internals>,<internals>)`, `equal:
  (True,False,False)` (O7). The update starts the producer, which sends 0, 1, 99 (quiet channel), 2, 3 in the turn that subscribes:
  all reach the manager before the subscription and are kept (O9); its onEffects delivers each of 0..3 to both listens, `Doubled`
  first (R9), and drops 99 (no listen). (T1a-2 dropped 0 and needed a `Process.sleep 0`; stats then: dropped 2.)
  `FromChan 3` sends 42 by `sendCmd` and performs `await`: `worker got: 42`, `WorkerDone (Done 42)`. Stats: sent 6, dropped 1.
- **T1aOwner**: the leaker sends 5 to itself and ends with its mailbox; P receives from it: the two lines, then the O8 message, exit 1.
- The six T1a-1 cases give the same output on JavaScript.

Where C and JavaScript cannot agree by design: the `FIC_STATS` lines (C only), `FIC_SCHED_SEED` (C only; the reference is the
deterministic order), live counts. A crash differs on stderr (C prints the message; node prints the Error with its stack): compared by
exit code and message. Timers: C runs `FIC_TIME` (virtual), node real time; the cases use distinct deadlines.

## 11a. Gate results (T1a-2)

Targeted, serial, 27 Nov 13:38-14:00, `bin/elmficT1b`, log `/home/gordon/claude-tmp/gates-t1b.log`: runtime 0 non-ok; attach --rc 378/0;
types 267 PASS 1 XFAIL; JS identity 28 identical; effects e1, e2, e3 all ok; e1p all ok; t1a all ok (82 checks; identity 66/0);
a3b-identity --more vs elmficP1b 100/0; rcgate-san 16 ok; suite 16/16 PASS.

## 11. Open points for the Opus review (T1a-2)

- **O9** The start-up race of R9: the alternative (b) of T1-D6 (buffer a channel's messages until its first listen) would remove it,
  but differs from ports.
- **O10** The overlay parsed as a kernel-package module (only for `effect module`); no kernel JS import is used, the JavaScript is
  substituted by the generator instead.
- **O11** fic_conc.js depends on Scheduler.js's generated field names (`f`, `b`, `c`, `h`), checked at load for two of them only.
- **O12** A channel never ends: its record is swept when nothing holds it; messages queued for a manager that stops are dropped.

## 12. T1c: the review fixes (docs/T1A-REVIEW.md)

27 Nov 2026, feat/t1a with review/t1a merged, binary `bin/elmficT1c`.
- **F3** fic_conc.h: a C99 compile-time check (`fic_conc_router_layout`, a negative array size) that fic_conc_router starts like
  fic_router (`proc`/`cproc` and `mgr` at the same offsets, `mgr` of the same size).
- **F4** fic_conc.js checks at load, besides the tags: a binding's `b` and `c`, `proc.f` in `_Scheduler_step`, `router.h` and the self
  tag `$: 0` in `_Platform_sendToSelf`, and the `fx` mail in `_Platform_dispatchEffects`; each failure names what changed.
- **O9 (narrow form)** `advance ref 0` (onSelfMsg, no listen) keeps the channel (C: `fic_conc_held`, owned) while an effects dispatch of
  the manager is under way; onEffects takes the kept channels (`held`, a new kernel) right after `attach` and delivers each with the new
  subscriptions, before its commands; still no listen: `advance ref (-1)`, dropped and counted. "Under way" in C reads the scheduler's
  state: the manager's `cmds` is a list (fic_platform_dispatch has gathered but not yet sent the FX mail) or an FX mail waits in the
  manager's mailbox; in JS a counter: `_Platform_dispatchEffects` (wrapped) adds one, each onEffects (`attach`) takes one. Bounded by
  one dispatch: a kept message is never kept again. Kept channels left at the end are freed by fic_conc_teardown (not counted).
  T1aChannel: 0 now delivered without `sleep 0` (dropped 1); new case **T1aChanDrop** (kept and delivered; kept then dropped; dropped at
  once with no dispatch under way, after an unsubscribe; a later listen never sees a dropped message): sent 6, dropped 3.
- **F2** effects2/ref/run.js tracks each timer's virtual deadline (setTimeout/setInterval wrapped; the virtual now is the deadline of
  the timer that fires) and prints `FIC_JS_TIE: ...` on stderr when a timer is armed for the deadline of a pending one. Flag only, no
  virtual clock. t1a/run.py fails a JavaScript check that is flagged; t1ar/run.sh reports it, R3TieBreak is expected-flagged.
- **F1 (O5), documented, not fixed**: an ended process whose exit value holds its own handle (`spawnWith (\box -> Task.succeed
  (Concurrent.self box, x))`), or two whose exit values hold each other's, is a cycle; the sweep frees an ended record only at `rc == 1`,
  so it stays until fic_conc_teardown (live 0 at the end, but a long-running program that does this grows: R7CycleExit 111 MB against
  R7PlainExit 2.3 MB). Planned fix with the next Concurrent slice: weak handles (an id and a registry lookup).
- **F5, documented**: a comment at patchSched's anchors (Ficcus.Mono.Concurrent): the drain of fic_sched_enqueue is the only place
  fic_sched.h steps a process; a second stepping place added later would bypass the shuffle silently (fic_conc_cur would abort there)
  and must be patched too. fic_sched.h itself is not touched (other programs' C stays byte identical).
- Build: elm.cabal `extra-source-files` now lists `runtime/*.js` and `overlay/*.elm`; they are embedded (Template Haskell) but cabal
  did not see a change of them alone ("Up to date" with a stale overlay).
