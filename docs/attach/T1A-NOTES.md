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

`channel`, `toAddress`, `listen`, `sendCmd` (the Concurrent effect module, T1-D6); `receiveWithin`; the JS kernel and differential tests
against node (T1-D14 (2)); `.fic`-only gating.

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
