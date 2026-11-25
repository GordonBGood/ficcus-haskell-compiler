# E1 review: ownership of the model (feat/effects-e1 at ce4bdbf9)

24 Nov 2026. Read-only review of E1 step 3 (`Ficcus.Mono.ModelUnpack`, the Borrow seed in `Program.modelSeeds` and `Borrow.inferBorrow`,
`Spec.workerPhase`/`workerFn`, `CGen.stepperSection`/`stepperMain`), against `docs/EFFECTS-CHECK.md` (design/fx-check) and D-fx-2/D-fx-3
as amended. No compiler source was changed. Binary `bin/elmficE1c` (= ce4bdbf9). Every program below was compiled `--rc`, run N steps
with `-DFIC_STEP_TEST=N -DFIC_STATS` at `-O2` and under ASan+UBSan (no pool), and compared byte for byte with Elm 0.19.3 under node
(the reference folds `update` N times in `init`, as G17bRef does). Marks: **[R]** run, **[S]** read in the source.

| program (N) | what it does | output = Elm, live 0, ASan clean | model copies | without unpack |
|---|---|---|---|---|
| U1Partial = **R1** (1000) | `{ m \| a = Array.set .. m.a, n = .. }`, keeps `d` | yes | **1960** | 1960 |
| U1Full (1000) | the same, all fields written (`d = m.d`) | yes | 5 | 1960 |
| U2Alias = **R2** (30) | `b = m.a` every third step | yes | 30 | 30 |
| U3History = **R3** (40) | old arrays kept in a list field | yes | 6 | 40 |
| U4Nested (500) | `{ m \| inner = { i \| a = Array.set .. i.a } }` | yes | 820 | 820 |
| U5Custom / U5Tuple (500) | model `M (Array Int) Int` / `(Array Int, Int)` | yes | 3 / 3 | 3 / 3 |
| U6Helper (500) | `update` passes `m` to a helper that sets `m.a` | yes | 820 | 820 |
| U7Lambda = **R4** (20) | field reads in a lambda, on one branch; `m` returned/logged whole | yes | 0 | 15 |
| U8Closure (250) | `update = updateWith 2`, `subscriptions = always Sub.none` | yes | 408 | - |
| U8Full / V2Curried (250) | as U8, full record / `update msg = \m -> ..` | yes | 408 / 408 | - |
| U9Recur (300) | `update` calls itself twice per step | yes | 3 | 984 |
| U10Capture = **R5** (12) | a closure in the model captures the old `m.a` | yes | 12 (1 per step: required) | 12 |

The few copies in U1Full, U5 and U9 come from the first write to the global `initModel`. All counts are identical in the O2 and sanitizer
builds.

## Verdicts

**Q1. Is ModelUnpack sound? Sound** [S, R]. The fields are pure, total reads, and Elm is strict, so hoisting them to the entry cannot change
a value, an effect or a crash. Each binding is `Own (Access m f)`, a dup: on any path that still uses `m` whole (U7 returns `m`, U9 recurses
with it), `m` and the variable each hold a count, and the Rc pass drops both. `reads'` and `substAccess` agree on shadowing (lambda, `let`,
case patterns), so every substituted access has a binding. Where they differ (the Rc-only nodes, which do not exist yet when the pass
runs) an access is bound but left in place, which is harmless. The pass runs before Rc, so RcCheck checks its output. Aliasing with a
second owner is sound because the counts are the truth: R2, R3 and R5 write in place only when the leaf is unique, and their output equals
Elm's. Tuple and custom-type models are not touched (no `MAccess`); their patterns already move the fields out (3 copies in 500 steps). A
model passed whole to a helper stays correct (U6) and copies, as the E1 report says. The pass never adds copies (last column).
**Performance gap, not a soundness issue:** `Spec` lowers `{ m | a = e }` to `let _upK = m in { a = e, d = _upK.d, n = _upK.n }`
(Spec.hs:987-994). `_upK` keeps a count on `a` while `e` runs, so `Array.set` sees two counts and copies (FICCUS_RC_DUMP of R1 shows
`Let _up21 = Local m` between `_mf0_m` and the set). G17b reaches 0 copies only because it writes all three fields, which lowers to
`MSeq m record` instead. 977 of the 1385 two-argument `update` bodies in `corpus/` (70%) use this partial form. Nested records (U4) have the
same problem one level down.

**Q2. Is the Borrow seed sound with Rc and RcCheck? Sound** [S, R]. The seed only adds `(update, m)` to the owned set (and as a root of the
update rule, which propagates to callers only). Every path is then handled by the ordinary owned-parameter machinery of Rc. The IR has no
early return. `Debug.todo` exits with status 1 as Elm does, so a leak there is moot. `Debug.log` was tested in U1, U7 and U9. The stepper
reads `paramOwns` of the clone that Rc counted: owned means the model is moved in; borrowed (`FICCUS_NO_MODEL_SEED=1`) means `fic_m` is
dropped after the call. Both modes give live 0 on every program. The message is handled the same way.

**Q3. Is the model taken out of the result without a copy only when the box is unique? Sound; there is no box on the direct path** [S].
`update` returns `struct(model, cmd)` by value, and `adaptOwn` with equal classes is the identity, so `fic_r.f0` is moved into the slot. A
box exists only on the closure fallback: `adaptOwn CRef (CStruct _)` dups the struct's leaves and drops the box. A unique box is freed and
its counts cancel, so nothing is copied. A shared box leaves the leaves shared, so the next write copies. That is correct either way. A
shared result box cannot be built in E1 (no scheduler), so this case is by reading only.

**Q4. The closure fallback: correct, without the guarantee** [R]. U8 (partial application), V2 (curried) and `always Sub.none` all equal
Elm with live 0. They give 408 copies in 250 steps even when the body writes every field: the seed and the unpack land on the wrapper
`update _w0 _w1 = f _w0 _w1`, and the real function's model parameter stays borrowed. Frequency in `corpus/` (1,971 programs with an
`update` field): 77 are an applied expression (mostly framework packages, e.g. `update pages config`) and 6 have the wrong arity, about 4%.
`subscriptions = always ..` appears in 353 programs (18%). That case costs one box allocation per step and never copies, because
`subscriptions` borrows. `Browser.*` programs cannot reach the C target yet, but their `update` has the same shape. A local `update` in
`main`'s `let` is rejected earlier by the program-shape check, so the "captures variables" internal error is unreachable today.

**Q5. Does always emitting update and subscriptions change behaviour versus Elm? No divergence found; three are fixed, and there is one
compile regression** [R]:
- Elm calls `subscriptions model` once after `init` (`_Platform_initialize`). E1 does too (SubsOrder golden). W7a never called it.
- A crash in `subscriptions` (S1, `Debug.todo`): both Elm and E1 print the `init:` line on stdout, then the error, and exit 1. W7a exited 0.
- A top-level value reachable only from `update` or `subscriptions` with a `Debug.log` (S3, four name orders): Elm prints it at startup.
  E1 matches Elm's order in all four. W7a never printed it.
- No program can lack `subscriptions` (the record field is required by its type).
- **Regression:** a program whose `update` or `subscriptions` mentions a manager (`Task.perform`, `Time.every`) no longer compiles ("not
  supported by the C generator yet"), even when no message ever arrives (S2: W7a compiled it and its output equalled Elm's). It is
  transient until E2. None of `targets/` or `ElmFiccusSamples/` is affected.

**Q6. Tests that catch an unsound ModelUnpack that G17b misses.** G17b never shares a leaf, so a missing dup, or a substitution under a
shadowing binder, would still give its checksum. Five tests are added on review/e1 (`ficcus-tests/effects/src/R*.fic`, Elm sources in
`effects/ref/src/`, goldens in `expected/e1r_*.out`, runner `ficcus-tests/e1_review.py`). Each runs O2 and sanitizer builds, with
and without each switch:
- R2Alias, R3History and R5Capture: a leaf of the model is also held by another field, a list or a closure. An in-place write that should
  have copied changes the printed arrays, or ASan reports a use after free.
- R4Lambda: field reads under a lambda and on one branch only, with `m` returned whole on another branch. This covers the substitution
  and the extra counts on mixed paths.
- R1Partial: the acceptance test for fix 1 below. `--targets` fails it until it copies ≤ 5 times (it copies 1960 times now).

All 30 runs pass at ce4bdbf9 without `--targets`.

**Q7. Is a per-leaf move in the Rc pass worth it? Yes, as its own slice after fix 1** [R, corpus count]. Functions that update a field of
a record parameter from that same field (`{ p | f = g .. p.f .. }`) in `corpus/`:

| | all such functions | with `Array.set/push`, `Dict.insert/update/remove`, `Set.insert/remove` |
|---|---|---|
| `update` | 1121 | 92 |
| helpers | 2151 | 272 |

So helpers hold about 3/4 of the sites where an in-place write matters. `targets/` and the Ficcus tests have none (init-only programs).
The cost of a miss: for `Array`, a path copy (about 2 JsArray nodes per `set` here); for `Dict`, a reuse miss per node on the path; for
`Vector`, the whole vector (O(n)) per write. That last case makes the move necessary for vector models. A per-leaf move ("an owned
struct whose remaining uses do not touch leaf i gives leaf i away instead of duplicating it") lives in Rc. It has the ownership facts that
a pre-Rc rewrite lacks, so it covers helpers, nested records and the record-update temporary uniformly, and ModelUnpack could then be
deleted. A helper whose only write is through `Dict` may still be borrowed by the hybrid rule. That is a separate gap, which the move
does not fix.

## Required before merge (ranked)

1. **Partial record update on the model** (Q1). In `ModelUnpack`, treat `let _upK = Local m` (the lowering of `{ m | .. }`) as an alias of
   `m` when `_upK` is used only through field reads: substitute `_upK.f` by `_mf_f` and drop the `let`. Apply it recursively to nested
   `_up` lets of `m`. This is about 15 lines in the pass, with no change to Rc. Accept when: R1Partial copies ≤ 5 (= U1Full, which
   unpacks by hand), G17b and G17bFields stay at 0, and `e1_review.py` and `effects_e1.py` pass. Without it, D-fx-3's "make the ownership
   hold whatever `update`'s body looks like" is false for most real `update`s.
2. **Narrow the D-fx-3 claim** in the decisions text (proposed; the user applies it): the guarantee covers an `update` that is a lambda
   or a top-level function of two arguments, reading model fields directly or through `{ m | .. }`. Helpers, nested records (until the
   per-leaf move) and the closure fallback are correct but copy.
3. **Record the compile regression** of Q5 as a decision: a worker whose `update` or `subscriptions` reaches a manager stops compiling
   in E1, until E2.
4. **Gate:** add `e1_review.py` (without `--targets` until fix 1) next to `effects_e1.py`.

## Optional

- Per-leaf move in Rc (Q7). Do it before G17 proper in E2, then delete ModelUnpack or keep it as a switchable fallback.
- Closure fallback: when the field is a partial application of a known top-level function (`updateWith 2`), seed and unpack that
  function's last parameter too, so the 4% case gets the guarantee.
- `subscriptions = always x`: call nothing (the result is `x`) instead of boxing the model each step.
- A Vector-model variant of R1, to measure the O(n) case once fix 1 is in.
- When `let` in `main` is accepted later: lift the "update captures variables" internal error into a user message.
