# T1a review: Concurrent (green processes, channels, effect manager, JS reference)

27 Nov 2026, branch `review/t1a` from `feat/t1a` f3650ba9, binary `bin/elmficT1b`. Read only: no compiler or runtime edits. Scratch tests
in `ficus-tests/t1ar/` (`run.sh`, 9 cases, expected outputs). Every case was built --rc at -O2 and under ASan+UBSan (no pool), and
run under node where JavaScript applies.

## Verdict

**Merge.** No ownership, use-after-free or leak-at-end defect was found: every case gives live 0 and a clean sanitizer run, including
kill of a waiting, woken-but-not-run, self-awaiting and await-blocked process, teardown with cycles through mailboxes, stacks, exit
values and a self-referencing channel message, and Concurrent combined with Time.every, Random, Process.sleep and ports. Two items are
real but not blocking (F1, F2). Three hardening items are cheap (F3 to F5).

## Must fix before merge

None.

## Fix later

**F1 (O5): a process whose exit value reaches its own handle is never swept before the end.** The sweep frees an ended record only when
`rc == 1`. `spawnWith (\box -> Task.succeed (Concurrent.self box, payload))` makes record → exitv → record a cycle, so the record and
its exit value stay until teardown. Two processes whose exits hold each other's Pid behave the same way. Reproducer: `R7CycleExit` vs
`R7PlainExit` (100,000 sequential spawn/await, 40-element list each): peak 4,300,031 live objects / 111 MB against 2,783 / 2.3 MB. Both
end with live 0. A long-running program that hands back its own address (a common reply idiom) grows without bound. Options: (a)
document it; (b) in the sweep, treat an ended record whose count equals the references from its own exitv as free (this needs a scan
of exitv and only catches self-cycles); (c) for T1b, make handles weak (an id plus a registry lookup) so exit values never own records.
I would take (a) now and (c) with the next Concurrent slice.

**F2: the claim "C = JS" fails at equal virtual deadlines.** `R3TieBreak`: R arms `receiveWithin 30` at 1 ms and W arms `sleep 20` at
11 ms, so both deadlines are 31 ms. C orders timers by (deadline, creation seq), so the timeout comes first and R gets `Nothing`. Node
orders by real time and by timer-list id (renewed when a list is rescheduled): in 8 runs it gave `r: Just 1` three times and
`r: Nothing` five times. This is an E2 property, not a Concurrent one, but `receiveWithin` makes it easy to hit. The T1a cases avoid
it by using distinct deadlines, as the notes say. Fix: give `effects2/ref/run.js` a virtual clock (fake `setTimeout` and `clearTimeout`
ordered by deadline then creation, `Date.now` from `FIC_TIME`). Until then, the harness should reject or flag a case where two timers
share a virtual deadline.

## Hardening (cheap; may go in with the merge)

**F3 (O3): nothing checks the `fic_router` prefix layout.** `fic_sched_receive` reads `((fic_router *)r->router)->mgr` from a
`fic_conc_router`. A field added to `fic_router` before `mgr`, or a change of `proc`'s type, would read garbage silently. Add a C99
compile-time check in fic_conc.h:
`typedef char fic_conc_router_layout[offsetof(fic_router, mgr) == offsetof(fic_conc_router, mgr) ? 1 : -1];`.
The reserved slot itself is sound. `fic_mgr_def` fills at most 64 slots, `fic_conc_slot` aborts on the first block if slot 63 is
taken, nothing iterates past `fic_nmgr`, and teardown clears the slot. Moving the check to start-up would make it fail early (abort
before any output); either is acceptable.

**F4 (O11): the load-time check does not test the field names.** It tests `$` of a binding (2) and of succeed (0). It does not test
`b`/`c` (binding callback and kill), `f` (process root), `h` (router process) or the SELF tag `{$: 0, a: …}` of a self message, all
of which `fic_conc.js` uses. The failure modes differ. If `c` were renamed, kill would no longer cancel a `receiveWithin` timer. If
`f` were renamed, a killed process would keep running. Both are silent. If `h` were renamed, the first channel send would crash
(loud). Add: `var b = _Scheduler_binding(0); b.b === 0 && 'c' in b`; `_Platform_sendToSelf.toString()` contains `router.h` and `$: 0`;
`_Scheduler_step.toString()` contains `proc.f`. The risk is low while elm/core stays 1.0.5 and the kernel field shortening is
unchanged.

**F5 (O2): the anchors cannot match in the wrong place, but the patch does not cover new step sites.** Both anchors are exact
multi-line texts inside one function each. Duplicated text fails with `#error`, and missing text fails too. But a future second site
that steps processes (for example the E3e post queue draining outside `fic_sched_enqueue`) would bypass the patch with no error.
`fic_conc_cur` would then abort (loud: "a Concurrent operation outside a process"), but the shuffle would silently skip that site.
Recommend a comment at the anchor in fic_sched.h ("patched by Ficus.Mono.Concurrent.patchSched; every step goes through here"),
and a check in run.py that `fic_sched_step(` occurs once in the patched text.

## Notes (no action)

- **O4, negated id.** `fic_sched_guid` starts at 0, so the first Concurrent id is -1; the id 0 and overflow (int64) cannot clash. The
  E2 id has no other reader in fic_sched.h; JavaScript compares process objects. One limit: the timeout processes of `receiveWithin`
  and the `Process.spawn` children of Concurrent processes have positive ids. The shuffle therefore treats them as the app's FIFO
  domain and never reorders them among themselves.
- **Kill (item 3).** Each case below gives the stated result and live 0 (`R1KillAwaiter`):
  - A process killed while blocked in `await b` stays in b's awaiter list, holding its E2 process, until b ends. b's wake is then
    dropped by `fic_sched_raw_send` (root none); JS checks `p.f !== null`.
  - A receiver woken by a send and killed before it runs never runs; its pending wake mail is freed with the process.
  - A process that awaits itself is killed cleanly.
  - Self kill is covered by T1aKill.
  - A `receiveWithin` timeout cannot race a kill: a fired timer drains the queue at once (`fic_sched_raw_spawn` outside a step), and
    the epoch together with `waiting` guards a stale timeout.
  - An exit delivered to a process that has ended or been killed is dropped (raw_send).
  - Under seeds 1 to 30: R2 to R5 always give one output; R1 gives two legal orders with the same last line.
- **Ownership (item 1).** A sent value is counted once per mailbox: `R8Vector` sends one Vector to two processes, each sets it, the
  sender sets it, and all three values stay distinct (vec_copy 3). A message left in a mailbox at kill, at end or at teardown is freed
  (`R5Teardown`: blocked_at_end 2, live 0). O8 rules out two receivers.
- **O12.** A channel record cannot be freed while subscribed, because each `Listen` closure captures the channel. Messages sent before
  `attach` are dropped and counted; messages queued at teardown are freed (`R5Teardown`).
- **Edge delays.** `receiveWithin` with 0, -5, NaN and 1e12 becomes 1 ms on both C and node (`R2Within0`, C = JS).
- **O10.** The JS substitution and the C redirect both need the marker constructor `FicConcPidBuiltin` in `author/project:Concurrent`,
  so a project's own `Concurrent` module is safe. Parsing as `Pkg.kernel` is limited to the overlay file (path prefix of the extra source
  dir). It is fragile only to a move of the overlay directory or to a second effect-module overlay, and either would fail at compile
  time.
- **Combined programs (item 2).** `R4Combined` (Time.every, Random.generate, sendCmd, a channel listen) gives C = JS, live 0, and one
  output under 30 seeds. `R6Ports` (incoming port → sendCmd → worker → channel → outgoing port, `FIC_PORTS_IN`) gives the right output
  with live 0 under ASan.

## O9: buffer a channel until its first listen?

Recommendation: **no, keep R9 (drop, as ports do)**.
- Unbounded buffering means that a channel which is created but never listened to (or is unsubscribed) holds every message for the
  life of the program, and a late listener gets stale messages.
- A bounded buffer makes the behaviour depend on an arbitrary constant.
- Both options break the symmetry with ports, which Elm users already know.

If the start-up race proves a nuisance, close exactly that race instead: a message for a channel with no listen is kept while an
effects (non-SELF) mail is waiting in the manager's mailbox (a dispatch in flight) and dropped otherwise. That needs one extra
`onSelfMsg` re-check after `onEffects`. It is bounded by one dispatch and removes the `Process.sleep 0` idiom. It needs a JS twin as
well (one more field-name dependency, see F4).

## Proposed text for the shared docs (not applied)

Decisions file: "27 Nov 2026 NOTE T1a review (review/t1a, docs/T1A-REVIEW.md): merge recommended; F1 (O5) self-cycles through exit
values are swept only at the end, F2 C = JS needs distinct virtual deadlines (virtual clock for run.js later), F3 to F5 hardening;
O9 keep drop semantics." Checklist: tick the T1a review.
