# E2 review: scheduler, timers, Random, ports, teardown (feat/effects-e2 at d3fa66aa)

25 Nov 2026. Read-only review of effects slice E2 (steps 4 to 8): `runtime/fic_sched.h`, `Ficus.Mono.ManagerOrder`,
`Ficus.Mono.ManagerTable`, `overlay/FicOverlayTime.elm`, the Random hook, ports and teardown in `CGen`, against `docs/EFFECTS-CHECK.md`,
D-fx-1 to D-fx-11 as amended, `docs/E1-REVIEW.md` and elm/core 1.0.5 `Scheduler.js`/`Platform.js`. No compiler source was changed.
Binary `bin/elmficE2f` (= 48c18ac4, the generated C of d3fa66aa). Marks: **[R]** run, **[S]** read in the source.

New tests: `ficus-tests/e2review/` (programs `src/*.fic`, which are also the Elm references, goldens from `bin/elm0193` under node with
`effects2/ref/run.js`) and the runner `ficus-tests/e2_review.py`. Each gate is compiled `--rc` (gcc -O2, ASan+UBSan without the pool,
`-DFIC_DROP_ALL`) and `--no-rc`, and stdout, the exit status, `live 0` and Elm's manager order are compared. Result on E2f: **gates all
ok** (13 programs, 14 entries, 5 compile rejects; 77 checks), **targets 4 fail** (below), 3 info entries differ (decisions to record).
`effects_e2.py` is all ok on E2f in this worktree too.

| program | question | what | E2f |
|---|---|---|---|
| R1Kill | 1 | kill while queued after `Time.now`, while sleeping, after finishing; kill from a later update | gate, = Elm |
| R2Spawn | 1 | spawn inside the own step, three deep, with `Time.now`/`sleep 0`; spawn in `sequence`, `map2` | gate, = Elm |
| R3Yield | 1, 5 | `sleep 0` yields to the host, `now`/`here`/`getZoneName` only to the queue; delays 0, 0.5, -3, NaN, 1 | gate, = Elm |
| R5PortBacklog | 1, 6 | `fx` messages reach the outgoing port while it sleeps; two ports | gate, = Elm |
| R6Maps | 2, 3 | nested `Cmd.map`/`Sub.map` over Task, Random, Time, both ports, 10 message types, logging taggers | gate, = Elm |
| R7OrderA/B/C | 4 | 5 managers and ports, helper modules with permuted names (C: Random before Task, observable) | gate, = Elm |
| R8Every | 5 | two intervals, one dropped, kept, re-subscribed | gate, = Elm |
| R10Zone, R10ZoneTokyo | 9 | `here`, `getZoneName`, TZ=UTC and Asia/Tokyo | gate, = Elm |
| R11Ports, R11PortsBad | 6 | port order, field order, `output`, `Json.Value` both ways, Int 1.0/1e3/-0/3e9; a decode failure | gate, = Elm (exit 1) |
| R12Crash | 7 | `Debug.todo` with a timer pending and a port message queued | gate, = Elm (exit 1) |
| X2, X3, X4, X5, X6 | 4, 6 | Array port out/in, Browser.Events, Http, Browser.element: compile errors | gate |
| **R4Delay** | 5 | fractional and huge delays | **target: differs** |
| **R9Slow** | 5 | `Time.every 5` after one slow update (real time) | **target: differs** |
| **X1Flags, X1FlagsString** | 6 | worker with `Int` / `String` flags | **target: compiles; 0 / segfault** |
| R1KillTwice, R10ZoneKolkata, R11PortsBig | 1, 9, 6 | Elm crash on a second kill; ICU zone name; integer beyond 2^53 | info |

## Verdicts

**Q1 Scheduler and dispatch: sound; the D-fx-6 text is wrong.** [R] R1, R2, R3, R5, E2Tasks, E2Sleep equal Elm. [S] `step`,
`enqueue`, `rawSpawn`/`spawn` (child first, parent queued behind), `rawSend`, the effects queue and the dispatch are equivalent.
- *Killed while queued*: R1 (a) kills a child waiting in the run queue after `Time.now` (which yields to the queue); it never runs.
- *Kill of the running process* is a self kill, which Elm code cannot express (an id goes only to the spawner; no task can get its own).
  The C kill clears the stack (`fic_sched.h:226`), so a self kill ends the process; Elm keeps the stack and continues. Unobservable,
  but D-fx-6 ("a synchronous self kill continues, as in Elm") is wrong for the code.
- *`sleep 0`* yields to the host (R3); *spawn during the own step*: equal (R2).
- **The header (line 16) and D-fx-6 say a message to a process waiting in a binding does not run the binding again; the code does**
  (`fic_sched_step` → `fic_sched_bind` → a second `fic_tm_add`, lines 263, 572). That is Elm's behaviour and it is observable: with a
  guard (no re-arm while a timer is pending) in a copy of R5's C, the port lines move after the ticks and R5 differs from Elm [R]. The
  code is right; the text must change. Only the outgoing port's manager sleeps while it receives mail.
- New: Elm 0.19.3 **crashes on a second `Process.kill` of a killed process** (`_Scheduler_kill` reads `null.$`, node exit 1); Ficus
  continues (R1KillTwice). To record as a D-fx-6 deviation.

**Q2 Per-node taggers: sound; not observable in Elm 0.19.3.** Effect modules exist only in `elm/*` and `elm-explorations/*` packages
(`Parse.Module` `NoEffectsOutsideKernel`, inherited), so no user program supplies a map function. Every shipped one composes: Task
(`Task.map`), Random (`Random.map`), Time/AnimationManager (`f << tagger`), Http (`toMsg >> f`), Browser.Events (`Decode.map`); ports
are the runtime's. For these, one node at a time calls the user's taggers the same number of times, in the same order, at the same
moment (when the message is made), for any tagger, lawful or not, `Debug.log` included; lawfulness concerns the manager's map, not the
tagger [S]. R6 logs every tagger call through 2- and 3-deep maps over Task, Random, `Time.every` and an incoming port: equal [R].

**Q3 Map pair table: sound; the comment is inaccurate.** [S] Spec clones every manager's `cmdMap`/`subMap` at every pair of
`sMapPairs` (at the fixpoint), and `ManagerTable.mapPairs` collects the pairs from the same keys that `pairIndex` looks up, so every
map node finds its pair; the fallback `_ -> 0` (`ManagerTable.hs:120`) needs a key that is not `[ByClass a, ByClass b]`, which these
kernels never have. No counterexample: R6 (10 message types, 5 Cmd and 1 Sub class pairs) is equal; a probe with a free inner message
over a Task leaf (`Cmd.map (always X) (Task.perform never (forever ()))`) and a port got pair 1, a real clone, correct output [R].

**Q4 ManagerOrder: sound.** [S] The walk is `Generate.JavaScript.addGlobal`'s (same `Set Opt.Global` fold, manager after `init`,
`onEffects`, `onSelfMsg`, `cmdMap`, `subMap`, debugger kernel skipped, mains folded right). [R] R7A/B/C (permuted module and function
names; C registers Random before Task, visible in the output) and R5/R6/R11 (up to 8 ports) equal `_Platform_effectManagers`.
Browser.Events (X4), Http (X5) and `Browser.element` (X6) fail to compile, but the message lists kernels, not the feature.

**Q5 Timers and the clock: unsound in two places.** Delays 0, 0.5, negative, NaN and 1 are 1 ms in creation order, as node (R3); two
intervals, dropped and re-subscribed, are equal (R8). But:
- (a) **node truncates a delay to whole ms and makes a delay above 2^31-1 ms (also Infinity) 1 ms**; `fic_tm_add` (line 545) does
  neither. `sleep 1.5` made before `sleep 1` fires first in Elm, second in Ficus; `sleep 1e10` and `sleep (1/0)` fire after 1 ms in
  Elm, last (virtual clock) or never in Ficus; in real time an infinite delay reaches `nanosleep` through a UB `double`→`time_t`
  conversion. Target **R4Delay**.
- (b) **node re-arms an interval from the start of the late callback**; C re-arms from the previous deadline (line 669), so after one
  slow update Ficus fires the missed ticks back to back (0 ms gaps) where Elm keeps the spacing and has fewer ticks. Target
  **R9Slow** (real time: `True` in C, `False` in Elm). Under `FIC_TIME` both rules give the same deadlines.

**Q6 Ports: sound except flags.** Equal to Elm [R: R5, R11, E2Ports, E2PortsIn]: order within a port (batch reversed) and across
ports (table order, one `sleep 0` each); record fields in Elm's order (`z, name, pair, tags, score`); `output` as text; `Json.Value`
both ways (0.1, 1e+21, -0, 1.5e-7, `\u0001`, U+2028, non-BMP); Int given `1.0`, `1e3`, `-0`, `3000000000`; a record with an extra
field; a decode failure (R11PortsBad: stdout up to it, exit 1, later lines not sent). `Array` in and out: a clear error naming the type
(X2, X3). **Flags are not rejected**: `Program Int ..` compiles and `init` gets 0 (`CGen.hs:400` emits `init(0)`), `Program String ..`
segfaults (targets **X1Flags**, **X1FlagsString**). An integer beyond 2^53 through `Json.Value` keeps its digits (decision L21;
JavaScript rounds it: R11PortsBig, info).

**Q7 Teardown and exit: sound.** [R] Every gate that ends normally, and the 15 `effects_e2` tests, have live 0 under `--rc` at -O2,
are clean under ASan+UBSan, and `FIC_DROP_ALL` says `0 bad, 0 live after the free`. [S] Order: loop ends; platform torn down (process
root, stack, mailbox; router; table counts; timers; queues); model; globals. Statics (`fic_sched_none`, port closures) see balanced
dup/drop. A normal exit with a pending timer or queued port message cannot happen (the loop runs until no timer is left, and a queued
port message has its `sleep 0` timer); the other exits are crashes, and R11PortsBad and R12Crash (`Debug.todo` with both pending) give
node's stdout and exit status, LeakSanitizer silent. Nit: with several timers on one process (the port's re-run) the first to fire
sets `p->timer = -1` (line 664), so a later kill would miss the others; no kill reaches a port manager today.

**Q8 FIC_SEED: safe.** It needs a manager with home exactly `elm/random:Random` *and* the reading process being that manager's
(line 622); a same-named fork or overlay cannot be an effect manager (Q2), and the elm/random overlay keeps the home (E2Seed). Without
Random the variable is ignored (R1Kill: same output with it unset, `7`, `abc`). Nit: `abc` silently means seed 0.

**Q9 Time zone: sound where the system tz data and ICU agree; the name is host-dependent.** [R] TZ=UTC and Asia/Tokyo equal node
(gates). For Asia/Kolkata the offsets agree but ICU (node 21, ICU 74.1, tz 2023c) names it `Asia/Calcutta`, Ficus gives TZ as set
(R10ZoneKolkata, info; Elm's result already depends on the browser). C side, TZ=America/Edmonton with `FIC_TIME`: 15 Jan 2026 `here`
-07:00, 15 Jul 2026 -06:00, `Name "America/Edmonton"` both (Berlin +01:00/+02:00; `:America/Edmonton` the same). System tzdata 2026f
keeps Edmonton at -06:00 from Nov 2026, where ICU 2023c still has -07:00 in winter: a data difference; Jan and Jul 2026 agree. Harness
limit: under `FIC_TIME` the C zone follows the virtual date, node's `new Date()` the real one (`run.js` pins only `Date.now`), so node
comparisons need a zone without daylight time. Edge: TZ `EST5EDT,M3.2.0,M11.1.0` gives the TZ offset but `/etc/localtime`'s name.

## Required fixes before merge (ranked)

1. **Reject flags.** A worker whose flags type is not `()` must fail with a clear compile error ("flags are not supported by the C
   back end yet"), in `Spec.specWorker` or `CGen.stepperMain`. Today Int gives 0 silently and String segfaults. Targets X1Flags and
   X1FlagsString.
2. **Delays as node** (`fic_tm_add`, also `FIC_BIND_INTERVAL`): `ms = trunc(ms); if (!(ms >= 1 && ms <= 2147483647)) ms = 1;`. Target
   R4Delay; also removes the infinite `nanosleep`.
3. **Interval re-arm as node:** the next deadline is the loop time when the tick runs plus the period (`fic_loop_now() + period`), not
   `deadline + period`. Target R9Slow. If the user prefers drift-free intervals, record the deviation instead (R9 shows it).
4. **Correct the text** (docs only):
   - D-fx-6 and the `fic_sched.h` header: the binding *is* run again on a message (Elm's behaviour, required by R5); a self kill ends
     the process (unreachable from Elm code); a second kill of a killed process crashes Elm and is a no-op in Ficus.
   - The `ManagerTable` comment on pair 0.
   - D-fx-7: the zone name is the TZ text and differs from ICU's canonical name for links (Asia/Kolkata).

## Optional improvements

1. `pairIndex`: an internal error instead of the silent `0` (dead today, but a wrong pair would misread words).
2. Keep `p->timer` while another timer of `p` is pending (a count, or test the heap), so a kill always cancels all of them.
3. One clear message for unsupported managers and platforms ("elm/browser's Browser.Events is not supported by the C back end yet").
4. Crash 4 on stderr: add Elm's problem text (`Json.Decode.errorToString`).
5. `FIC_SEED`: reject a non-integer value.
6. `getZoneName` with a POSIX TZ rule string: return `Offset` of the current offset rather than `/etc/localtime`'s name.
7. Gates: add `step e2review; python3 $R/ficus-tests/e2_review.py --elm $B --elm-home $H > $G/e2review.txt 2>&1; tail -1
   $G/e2review.txt` (expected `gates all ok`), with `--targets` after fixes 1 to 3. The run takes about 75 s.

Proposed for the shared files (not applied): decisions, the D-fx-6/7 amendments above plus the quirk "Elm crashes on a second kill";
checklist, G17 (d) Platform differential cases: + E2 review gates.
