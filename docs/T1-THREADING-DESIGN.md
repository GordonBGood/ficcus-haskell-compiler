# T1 threading and process API (design note)

27 Nov 2026, worktree `ficcus-haskell-compiler-t1`, branch `design/t1` from `ficcus` 75e3ed9a. Read only: nothing built (two
ten-line C probes of tcc in the scratchpad), no shared file edited; proposed entries are in section 8.

**Marks.** **[S]** read in the source named. **[R]** run. **[A]** assumption or estimate, not checked.

Read: `docs/EFFECTS-DESIGN.md` (sections 1, 3.3, 4, D-fx-6, D-fx-10, D-fx-11), `docs/EFFECTS-CHECK.md` (design/fx-check),
`docs/E2-REVIEW.md`, `runtime/fic_sched.h`, `runtime/fic_rt.h` (header, pool, dup/drop, reuse), the `->rc` sites in `CGen.hs`,
`CRuntime.hs`/`Embed.hs`, `docs/E3-PORTS-DESIGN.md` (design/e3, D3, D12-D15), decisions rev 176 (the user's RFC) and line 50
(OPEN thread safety of counts), line 21 (OPEN TinyC atomics), checklist items 17, W4, T1, F1, E3e; elm/core 1.0.5 `Process.elm`.

---

## 1. Starting point

What the run time is today [S]:

- **One thread runs Ficus.** `fic_run_main` starts one pthread with a 1 GB stack; counts are plain `rc++`/`--rc`
  (`fic_dup`, `fic_drop`), the pool (`fic_free_list`, `fic_bump`, slabs), `fic_live_objects`, the `FIC_STATS` counters and the
  `FIC_DROP_ALL` registry are file statics.
- **Header** `{rc:u32, tag:u16, nptr:u8, cls:u8}`, statics start at `FIC_IMMORTAL` = 2^30 and are counted like any object, so a
  static is never unique and dup/drop have no branch. Bit 31 of `rc` is reserved for a shared flag (D-fx-10 a, accepted 17 Nov).
- **Uniqueness is tested by literal C text** in the generated code: `x->rc == 1` (CGen.hs 1199, 1618, 1639, 1670, 1689) and
  `fic_drop_shared` (a non-atomic `rc--` for a cell known to be shared). Kernels touch `->rc` directly in 53 places (fic_rt 21,
  fic_closure 17, fic_vector 10, fic_jsarray 4, fic_sort 1).
- **The runtime is part of the C text**: `CRuntime.prelude` embeds `runtime/*.h` by plain concatenation (`Embed.embedFiles`,
  `concat texts`), and `fic_sched.h` is emitted only by programs that use a task, a bag or a manager.
- **The E2 scheduler** is a line-for-line port of `Scheduler.js`: one FIFO run queue, `fic_proc {root, stack, mbox, mtail, id, seq,
  timer}`, a mailbox that only managers read (`TASK_RECEIVE` holds a router), kill as D-fx-6 (cancels the timer, drops root and stack,
  a resume after kill is a no-op, a second kill a no-op). All its state is file statics: `fic_rq`, `fic_tm`, `fic_fxq`, `fic_mgrs`.
- **E3 (proposed, D14)**: every `fic_hv_*`/`fic_port_*` call is loop-thread only; `fic_post` and `fic_post_json` are the only thread
  safe entries (a mutex queue plus an eventfd woken in `poll`); a "detached vector" made by another thread is left to T1.
- **Elm's own plan** (`Process.elm`, "Future Plans") is the RFC's: `type Id exit msg`, `spawn : Task exit a -> Task x (Id exit
  Never)`, `kill`, `send : Id exit msg -> msg -> Task x ()`, with `exit` the type of a failure seen by linked processes.
- **Toolchain** [R]: tcc 0.9.28rc (the installed one) compiles the `__atomic_*` builtins and `<stdatomic.h>`'s `memory_order_*`,
  and pthread keys, but rejects `__thread` ("';' expected") and `_Thread_local` ("not implemented"). GCC with `-std=c99` accepts
  both. So thread-local storage is GCC/Clang only.

Two facts shape everything below. (1) Ficus values are immutable in the language; the only physical mutation is an in-place
write when `rc == 1`. So the whole thread safety question is about **counts, the allocator and runtime globals**, never about data
races on values. (2) The model's single-owner protocol (D-fx-3) needs exactly one writer of the model: `update` and the managers.

---

## 2. User facing API

### T1-D1. Keep `Process` exactly Elm's; put the new API in a new `.fic` only module

**Recommend:** `Process.spawn/sleep/kill` and `Process.Id` stay as they are (Elm's semantics, the E2 kernels, D-fx-6). The new API is
a new module of the Ficus core package, **`Concurrent`** (name open), importable only from `.fic` modules (dialect gating as for
the other extensions), with its own types.

Alternatives: (a) change `Process.Id` to `Id exit msg` as Elm's plan says: breaks every Elm package that names `Process.Id` (Time's
manager state is `Dict Float Process.Id`) and the byte identity of Elm programs; rejected. (b) Add the new names to `Process` behind
the `.fic` gate: possible, but one module whose meaning depends on the importer's file type is harder to document and to shim in JS.

### T1-D2. The types and functions

```elm
type Pid exit msg          -- a spawned process: await it, kill it, send to it (Elm's planned Id exit msg)
type Address msg           -- the right to send, nothing else
type Mailbox msg           -- the right to receive; only the process's own body gets it
type Channel msg           -- an address whose messages reach `update` (T1-D6)
type Exit err a = Done a | Failed err | Killed

spawn         : Task err a -> Task x (Pid (Exit err a) Never)
spawnWith     : (Mailbox msg -> Task err a) -> Task x (Pid (Exit err a) msg)
address       : Pid exit msg -> Address msg
self          : Mailbox msg -> Address msg
send          : Address msg -> msg -> Task x ()
receive       : Mailbox msg -> Task x msg
receiveWithin : Float -> Mailbox msg -> Task x (Maybe msg)
await         : Pid exit msg -> Task x exit
kill          : Pid exit msg -> Task x ()
channel       : Task x (Channel msg)
toAddress     : Channel msg -> Address msg
listen        : Channel a -> (a -> msg) -> Sub msg
sendCmd       : Address a -> a -> Cmd msg
```

Why three handle types: a typed `receive` needs the mailbox's type, which a global `receive` cannot have (Erlang's untyped receive
is the thing Elm's types exclude), so the body gets a `Mailbox msg` capability; a reply address must not carry the replier's `exit`
type (`self` of a free `exit` would let `await` return any type), so `Address` is separate from `Pid`. `spawn` is the RFC's
signature with `exit = Exit err a`. A worked request/reply: `send server (Get (self box))`, then `receive box`.

Alternatives: (a) the RFC's single `Id exit msg` and no `self`: replies only through channels; smaller, but a process cannot be a
client of another process. (b) Untyped `receive` with a decoder (like ports): dynamic failures; rejected. (c) Go-style first class
channels instead of mailboxes: more general (several readers), but needs a select, and readers on two threads make the order
harder to state; possible later as a library over T1-D2.

### T1-D3. Mailbox semantics and ordering

**Recommend:** unbounded FIFO mailboxes; `send` never blocks and never fails (a send to a finished or killed process is dropped and
counted in `FIC_STATS`); **messages from one sender to one address arrive in send order** (Erlang's guarantee), and nothing else is
promised across senders. In the deterministic mode (T1-D11) the order is total and reproducible. No selective receive.
`receiveWithin t` is `receive` raced with a timer of the E2 heap (`fic_timer_delay` rules).

Alternatives: (a) bounded mailboxes with a blocking `send` (backpressure; Go): safer memory, but two processes that send to each
other's full mailbox deadlock, and the bound is a tuning knob with no good default. Proposed for later as `spawnBounded n`, after
a measurement shows unbounded growth in real programs. (b) Selective receive (`receiveMatch : (msg -> Maybe b)`): Erlang's known
quadratic trap; a process can keep its own buffer in its state instead.

### T1-D4. What a process can do; results and failure

**Recommend:** a process runs any `Task`: `sleep`, `Time.now`, `send`, `receive`, `spawn`, `Process.spawn`, Http later. It cannot
call `update` or touch the model; it reaches the app only through a `Channel` (T1-D6) or by being awaited (`Task.attempt` on
`await`). The body's result is `Done a`, its task's failure `Failed err`, a kill `Killed`; `await` of a finished process returns at
once, any number of times. A crash (`Debug.todo`, a port decode failure, an array bound abort) in any process ends the program with
Elm's message and exit 1, as a JavaScript exception ends an Elm program. Elm's `Process.spawn` keeps Elm's silent failure.

Alternatives: crash isolation per process (Erlang's "let it crash"): needs unwinding a C stack (`longjmp` out of arbitrary kernels
holding counts) or a process per OS process; not in T1. Links and monitors (Erlang's `link`, the RFC's "trapping errors"): `await` is
a one-shot monitor; links later if wanted.

### T1-D5. Kill

**Recommend:** on one scheduler, E2's kill exactly (cancel the pending binding, drop root, stack and mailbox; resume after kill is a
no-op), plus: waiters of `await` get `Killed`, the process's `Process.spawn` children are **not** killed (as in Elm). Across threads
(T1c) kill is **asynchronous**: it sets a flag and posts a kill to the owning scheduler; it takes effect at the process's next
scheduling point (a binding, a `receive`, or a task step); a running pure computation finishes first (no preemption). `kill`
returns at once; `await` then reports `Killed`. A native call already started on the worker pool (T1b) completes and its result is
dropped (EFFECTS-DESIGN section 4, the one observable difference already accepted).

Alternative: synchronous kill that waits for the target to stop: can deadlock (a process kills one that is killing it), and buys
nothing a following `await` does not give.

### T1-D6. Relation to `Task`, `Cmd`, `Sub` and the model

**Recommend:** every operation is a `Task` (as `Process`); the program uses `Task.perform`/`attempt` from `update`. `Concurrent` is an
**effect module of the Ficus core package** (as Time is in elm/time; effect modules are allowed only in core packages [S:
`NoEffectsOutsideKernel`]) with `command = SendCmd` (`sendCmd`, so `update` can send without a dummy message) and `subscription =
Listen` (`listen`). A message sent to a `Channel` goes to the manager as a self message (`sendToSelf`), and `onSelfMsg` calls
`sendToApp (tagger v)` once per current `listen` of that channel, in Elm's order for subscriptions (as an incoming port: E2 step 7).
A message to a channel nobody listens to is dropped (as a port with no subscriber) and counted. So **process messages enter
`update` only as ordinary `Msg` values, through a manager, on the loop thread**: the model keeps one writer and D-fx-3 holds
unchanged.

Alternatives: (a) a kernel `toApp : Task x (Address msg)` addressing `update` directly: its `msg` is a free type variable, unsound.
(b) Buffer channel messages until the first `listen`: friendlier for start-up races, but differs from ports and grows without
bound if nobody listens; possible as an option of `channel`.

---

## 3. Execution model

### T1-D7. Green processes on one scheduler first, then M:N over a worker pool

Options:

| Model | Parallel | Effect on E2 and ports | Cost |
|---|---|---|---|
| (a) OS thread per process | yes | every process needs the full thread-safe runtime; a process costs a stack (MBs) | large; does not scale to 10^5 processes |
| (b) green processes on the E2 scheduler | no | a new receive kind, await waiters, a process registry; nothing else | small |
| (c) M:N: one scheduler per worker thread, processes pinned at spawn, stolen when idle; the app's scheduler on the loop thread | yes | E2's statics become a per-scheduler struct; a cross-thread inbox per scheduler; the loop waits in `poll` (E3e) | large |
| (d) one thread plus explicit parallel pure work (fork-join) | yes, for pure work only | none on the scheduler; a binding that completes when the parts do | medium, needs shared objects (T1-D9) |

**Recommend:** (b) as T1a (the whole API, deterministic, ST runtime), then (c) behind the same API as T1c, and (d) as T1d on the
same worker pool. Reject (a). A program written against T1a runs unchanged on T1c; only interleavings differ.

**The isolation unit is a domain.** A domain is a `Concurrent` process together with the Elm-style processes it starts with
`Process.spawn` (and their `Task.perform` children if it were the app). The app is the domain of the loop thread: `update`, the
managers, the ports, and every Elm process. Inside a domain everything is Elm's E2 scheduler with Elm's order and objects shared
freely with plain counts; **between domains, values cross only through `spawn`, `spawnWith`, `send` and `await`**, which apply the
crossing rule of T1-D8 even when both domains happen to run on the same thread. Then a domain's objects are reachable only from that
domain (or are flagged shared), so a domain can move between workers (work stealing) with no count traffic: ownership passes with
the queue's release/acquire.

**Bindings that belong to the loop thread.** A domain on a worker may still hold app-side kernel values: an Elm `Process.Id` from
the app, a `Channel`. Operations on them (kill of an app process, a send to a channel) and the bindings whose resource is the loop's
(Http on libcurl multi, ports) are **posted to the loop thread**; the process waits as for any binding. `sleep` and `Time.now` run on
the worker's own timer heap.

**E3 consequences.** E3 D14 stands: hosts call `fic_post`/`fic_post_json` from any thread, everything else on the loop thread. T1c
makes the loop's post queue the general cross-thread inbox of the app scheduler (channel sends from workers use it too) and answers
E3's open item: a host-made "detached vector" is allowed **in MT mode only** (`malloc`ed, `cls 0`, atomic live counter, adopted by
the loop with count 1); in ST mode the host's buffer is copied.

**Fairness.** No preemption in any mode (Ficus has no safe points in pure code). In T1c a process yields after a budget of task
steps (scheduler loop iterations, not pure code), measured (section 7); T1a uses no budget, to keep E2's order.

---

## 4. Memory model

### T1-D8. Crossing rule: move what is unique, share what is not

At `send`/`spawn`/`await` the runtime walks the message graph from its root (owned; `send` consumes it, as E3 D3's `send`) in the
header-driven way of the generic drop (`nptr` words, PAP mask, vector descriptor; strings and raw vectors are leaves):

- a node with `rc == 1` is reachable only through its parent, which is crossing, so it is **moved**: it stays a plain object and the
  receiver owns it (a unique 64 MB `Vector` arrives with count 1 and is written in place by the receiver: O(1));
- a node with `rc > 1` is also held by the sender, so it and everything below it are **marked shared** (bit 31), stopping at nodes
  already shared and at immortals.

Cost: O(unique part + newly shared part), with no allocation; a resend of shared data is O(1). Sound under Perceus because a
borrowed reference cannot be consumed without a dup (the Rc pass invariant), so `rc == 1` on an owned root really means one holder.

Alternatives: (a) **deep copy** (Erlang): no flag and no atomics anywhere, but O(size) per message, a DAG (two versions of a `Dict`
sharing nodes) is copied as a tree unless a visited map preserves sharing, and big vectors are copied every time. Kept as an explicit
`Concurrent.copy` only if a measurement asks for it. (b) **Mark everything shared** (Lean 4's `markMT` of a task closure): simplest,
but a unique vector loses in-place update after one send. (c) **Move only, refuse shared**: the compiler cannot prove uniqueness
statically; a runtime refusal is a crash for ordinary code.

Which values may cross: all Ficus values (they are immutable). Kernel values that belong to the app domain cross as handles whose
operations are posted (T1-D7). A future mutable primitive (`Change` references, PROPOSED in the decisions file, line 68) cannot reach a send because
`runChange`'s region type keeps references inside the pure computation; a future `Lazy` would need its force to be a CAS on a shared
thunk: recorded as a constraint on those designs, not solved here.

### T1-D9. Counts in MT mode: bit 31 flag, signed fast path, sticky immortals

```c
#define FIC_SHARED  0x80000000u
#define FIC_IMMORTAL 0xC0000000u            /* MT mode only: statics are shared and sticky */
dup:   if ((int32_t)p->rc >= 0) p->rc++; else fic_dup_shared(p);       /* atomic add, nothing for rc >= FIC_IMMORTAL */
drop:  if ((int32_t)p->rc > 1)  p->rc--; else fic_drop_slow(p);        /* 1: free; flagged: atomic sub (acq_rel), free at FIC_SHARED+0 */
```

One signed compare per dup and per drop (Koka's and Lean 4's layout); drop's compare replaces today's test after the decrement.
**Statics and computed globals are sticky** (shared and immortal: the slow path only reads them, so no cache line moves between
cores and TSan sees no race); globals are marked so after initialization, before any worker starts. Under `--rc` the teardown frees
globals by a walk with the registry instead of by counts. `fic_drop_shared` (drop specialization) becomes a flag test in MT mode.
Invariant (Koka's): **a shared object never points to a local one**; the walk of T1-D8 keeps it, and no in-place write happens on a
shared object (T1-D10). Atomics are the `__atomic_*` builtins on the plain `uint32_t` field, so the header type does not change.

Alternatives: (a) atomic counts everywhere (Swift): costs every program, rejected by the A2 rule. (b) A side bit outside `rc`:
there is no spare header bit (`tag`, `nptr`, `cls` all used). (c) Statics not counted (Lean's `rc == 0` persistent objects): a
branch in ST mode too.

### T1-D10. Uniqueness, Perceus reuse and `Vector` in place under sharing

**Recommend, first:** unchanged text `x->rc == 1`: a flagged object is never equal to 1, so it is never reused and never written in
place; writes copy, which is always correct. **Then, if T1m shows it pays:** Lean 4's exclusive rule, "unshare on exclusive": a
flagged object whose atomic count is one reference (`FIC_SHARED|1`, acquire load) can have no other holder and no way to get one,
so it is turned back into a local object (`rc = 1`) and then reused or written in place; its children stay shared (local to shared
pointers are allowed). This needs the uniqueness test as a macro, `FIC_UNIQUE(x)`, in MT mode.

Reuse tokens and the drop-reuse pair are unchanged for local cells; a shared cell whose last count drops is freed by the thread that
dropped it (T1-D11). `Vector`: a moved vector is local and mutable; a vector shared with workers is read by them without counts in
borrowed loops and copied on a write. Fork-join (T1d) marks the input vector shared (O(1), a leaf) and moves each part's result back.

### T1-D11. Allocator and runtime globals in MT mode

**Recommend:** a pool per thread (the current free lists and bump pointer, made thread local); each slab records its owner;
`fic_free_obj` of a cell from another thread's slab pushes it on the owner's atomic remote list, which the owner drains when it next
allocates of that class (mimalloc's scheme). Without remote free, a producer/consumer pipeline moves memory from the producer's
slabs to the consumer's free lists and the producer keeps carving new slabs: unbounded growth. `fic_live_objects`, `fic_total_allocs`
and the stats become per thread and are summed at shutdown; the `FIC_DROP_ALL` registry and `fic_pool_release` take a mutex (test
builds only). `Debug.log` writes one line with one `fwrite` under `flockfile`.

**MT mode needs GCC or Clang** (thread-local storage, [R] above). TinyC builds an MT program as a single thread (`FIC_WORKERS=0`, the
deterministic mode of T1-D13), where the statics need no TLS. This answers the OPEN TinyC item (line 21) for T1.

Alternatives: one global pool under a lock (simple, contended); `malloc` for everything in MT mode (glibc's arenas are per thread; whether that is close to
the pool's speed is not measured [A], so it would be one more T1m row); pass a context pointer to every allocation (works under tcc, changes every call: no).

---

## 5. What stays byte identical

### T1-D12. Two runtime modes, chosen per program

**Recommend:** the compiler knows the whole program, so it selects **ST mode** (today's runtime, exactly) unless the program reaches
`Concurrent.spawn`/`spawnWith` with workers enabled, or `Parallel` (T1d); then **MT mode**. The MT pieces are separate files in
`runtime/` (counts, pool, scheduler state), emitted instead of the ST ones; because `embedFiles` concatenates with no separator
[S], splitting `fic_rt.h` into ST pieces can keep the text of an ST program byte for byte the same.

Guaranteed, and gated in every T1 slice:

- **Elm programs** (`.elm`, and `.fic` programs not using the API): the C text is identical to the reference binary in `--rc` and
  `--no-rc` (the a3b-identity gate, extended to the e2review and effects programs), so the RC code, the 16 suite programs and their
  performance cannot change. JS identity (28) unaffected: no `.elm` module can import `Concurrent`.
- **T1a programs** (the API, one scheduler) stay ST: the new kernels (`fic_conc.h`, emitted only when reached, as `fic_sched.h`)
  and no count change.
- **MT programs** pay the count branch, TLS and the walk; their cost is measured (T1m) and reported, not gated against ST.

Alternatives: (a) one runtime for all, MT always (simplest maintenance; costs every program the branch: rejected unless T1m shows
under 1 percent everywhere, which nobody reports for Koka or Lean [A]); (b) a user flag `--threads` instead of reachability: simple,
but a program that spawns without the flag must then be refused or silently serialised; reachability plus an override
`FIC_WORKERS=0` is the cleaner pair.

---

## 6. Failure, shutdown, determinism, sanitizers

### T1-D13. Shutdown, teardown, deadlock

**Recommend:** the loop ends when the app scheduler and every worker are idle, no timer is left anywhere, no pool job or post is
pending, and no host hold is set (E2's rule extended; E3 D13's `fic_hold`). **A process blocked in `receive` does not keep the
program alive** (as a never-resolved promise in node). So a deadlock (all processes waiting on each other) ends the program; under
`FIC_STATS` (and a new `FIC_WARN_BLOCKED`) the count of processes still blocked is printed to stderr. Teardown: workers are told to
stop and are joined (the join is the happens-before), then the loop thread kills every process in a **process registry** (needed
anyway: two processes holding each other's `Pid` are a counted cycle), drops mailboxes, await waiters and channels, then E2's
`fic_platform_teardown`, then the globals; `live 0` under `--rc` as for every effects test. A crash in a worker: flush stdout under
the `Debug.log` lock, print, `_exit(1)` (no leak check on a crash, as today).

Alternative: Erlang's rule (the program runs while any process exists): a forgotten blocked process then hangs the program forever.

### T1-D14. Determinism and testing

**Recommend:** three modes. (1) **Deterministic**: `FIC_WORKERS=0` (and every T1a program, and every tcc MT build): all domains on
the loop thread in E2's FIFO order; outputs are compared byte for byte. (2) **JS reference**: the JS backend gets a `Concurrent`
kernel on Elm's `Scheduler.js` (it already has `_Scheduler_receive` and `rawSend` [S]), so T1a has a differential reference under node
exactly as E2 had, instead of hand-written goldens. (3) **Parallel**: tests whose output does not depend on interleaving (results
collected and sorted, sums, `await` results), each run N times; plus a **seeded shuffle** mode on one thread (`FIC_SCHED_SEED`: the
run queue picks a random runnable domain), which explores orders reproducibly and is how a reported failure is replayed.

### T1-D15. Sanitizer gates

**Recommend:** ASan+UBSan and `FIC_DROP_ALL` on every T1 test in every mode (as now; pool off under ASan). **TSan** (separate build,
`FIC_NO_POOL`, `-fsanitize=thread`) on every MT test and on a runtime stress test (`runtime/test_conc.c`: producers and consumers,
ping-pong, kill during send, await during kill, teardown with blocked processes, `fic_post` from host threads): a race on a plain `rc`
is exactly an isolation bug. TSan only sees races that happen in a run, so add a **deterministic owner check** for MT debug builds:
with `FIC_CHECK`, the registry records each local object's owning domain, and a dup/drop/write of a local object from another domain
aborts; moves update the owner. Gate: 0 TSan reports, 0 owner faults, live 0.

---

## 7. Staged plan

| Slice | Content | Size [A] | Review |
|---|---|---|---|
| **T1a** | `Concurrent` API on the E2 scheduler (ST): user mailbox receive kind, `receiveWithin`, `await` waiters, exit values, channels through a core effect module, process registry, teardown; Spec/Kernel classes for the new types; `.fic` gating; JS kernel; differential tests C vs JS | C 500, Haskell 250, Ficus 150, JS 200; 2 sessions | **Opus** (kill/await/teardown semantics, the channel order, identity) |
| **T1b** | worker pool for blocking bindings (D-fx-10 b), `poll` loop with eventfd, `fic_post` (= E3e) | C 600; 1 to 2 sessions | **Opus**, with E3e (queue, TSan) |
| **T1m** | measurement only: MT count and pool variant of the runtime under a macro, no threads; the walk on synthetic messages | C 300, scripts; 1 session | none; report to the user |
| **T1c** | MT runtime: counts (D9), per-thread pools with remote free (D11), per-worker schedulers with stealing, the crossing walk (D8), cross-thread kill/await, mode selection and the `FIC_UNIQUE` macro in CGen (D12), owner check, TSan gate | C 2,500, Haskell 200, tests 1,500; 4 to 6 sessions | **two Opus reviews**: counts and allocator; scheduler and shutdown |
| **T1d** | `Parallel.map/foldl` over `Vector` and `List` (pure; chunked; input shared, results moved) on the pool | C 400, Ficus 200, Haskell 100; 1 to 2 sessions | **Opus** (purity is invisible except `Debug.log` order and which crash is reported) |
| later | bounded mailboxes, links/monitors, the exclusive rule (D10) if not taken in T1c | | |

Order: T1a now (after the E3a/E3b review, it touches the same runtime); T1b with E3e; T1m before T1c is started; T1c only after
the user has seen T1m; T1d after T1c. F1 (FFI) can start after T1b (blocking calls go to the pool).

**Measurements that decide open choices (T1m and T1c):**

1. The MT count variant (D9), single threaded, on the 16 suite programs, P1/A2, the benchmark set: median and worst slowdown.
   Threshold proposed: at most 3 percent median and 8 percent worst for MT mode to be acceptable for MT programs; if under 1 percent
   everywhere, revisit D12 (one runtime).
2. The crossing walk (D8) against a deep copy, for a small record, a 10^5-node `Dict`, a list of strings, a 64 MB vector, a DAG of
   two `Dict` versions: decides whether `copy` is offered at all.
3. The exclusive rule (D10): a pipeline that sends one vector round a ring of processes, with and without it.
4. Remote free (D11): resident memory of a producer/consumer pipeline over 10^7 messages, with and without.
5. Contention: 8 workers reading one shared `Dict` and one global; atomic count operations per lookup (expected near 0 under
   borrowing [A]) and scaling from 1 to 8 workers.
6. The fairness budget (D7) and the default worker count (cores minus one [A]); worker stack size (the 1 GB address-space rule).

**What this note cannot decide without a measurement:** whether MT mode is cheap enough to become the only runtime (1); whether
deep copy is ever better than the walk (2); whether the exclusive rule is worth its macro (3); the allocator's remote-free cost
(4); real scaling (5). Not measurable before T1c: the cost of stealing and of cross-thread kill.

---

## 8. Proposed entries for the shared files (not applied)

Decisions file: a DONE entry for this note; one DECIDED entry per accepted T1-D1 to T1-D15; line 50 (OPEN thread safety of counts)
becomes "answered by T1-D8 to T1-D12"; line 21 (TinyC atomics) gets "tcc 0.9.28rc has the atomic builtins but no TLS: MT programs
under tcc run single threaded (T1-D11)". Checklist: T1 ticked; new items T1a, T1b (merged with E3e), T1m, T1c, T1d; E3 D14's
detached vector answered by T1-D7; F1 depends on T1b, not on T1c.

---

## 9. Decisions for the user, in recommendation order

1. **T1-D1** new `.fic` module `Concurrent`; Elm's `Process` untouched (and the module's name).
2. **T1-D12** two runtime modes chosen per program; ST programs byte identical, gated in every slice.
3. **T1-D7** green processes on the E2 scheduler first (T1a), M:N over a worker pool later (T1c), fork-join last (T1d); domains as
   the isolation unit; app-side bindings posted to the loop thread.
4. **T1-D2** the types `Pid exit msg`, `Address`, `Mailbox`, `Channel`, `Exit` and the function set.
5. **T1-D3** unbounded FIFO mailboxes, per-sender order only, no selective receive.
6. **T1-D6** every operation a `Task`; `Concurrent` a core effect module with `sendCmd` and `listen`; messages reach `update` only
   through the manager.
7. **T1-D4** results through `await`; a crash anywhere ends the program; no links in T1.
8. **T1-D5** kill: E2's on one scheduler, asynchronous across threads.
9. **T1-D13** blocked processes do not keep the program alive; registry teardown; live 0.
10. **T1-D14** deterministic mode, JS reference kernel, seeded shuffle.
11. **T1-D15** TSan gate and the owner check for MT builds.
12. **T1-D8** crossing rule: move unique, mark shared (copy only if measured).
13. **T1-D9** bit 31 flag, signed fast paths, sticky statics and globals (MT mode only).
14. **T1-D11** per-thread pools with remote free; MT needs GCC/Clang, tcc runs MT programs single threaded.
15. **T1-D10** uniqueness unchanged at first; the exclusive rule after T1m.
16. The staged plan of section 7, its reviews, and the measurement thresholds (3 percent median, 8 percent worst).
