# E1p: the per leaf move in the Rc pass (design note)

25 Nov 2026, branch `design/e1p` from `ficcus` 43e2bb04; no compiler source changed. Programs in `ficcus-tests/e1p/src`, Elm references
in `e1p/ref/src` (`init` folds `update` 1000 times, as G17bRef does), goldens in `expected/e1p_*.out`, runner
`ficcus-tests/e1p_measure.py --elm B --elm-home H [--targets]`. Every run: `--rc`, 1000 steps (`-DFIC_STEP_TEST=1000 -DFIC_STATS`), `-O2`
and ASan+UBSan, output = Elm 0.19.3 byte for byte, live 0. `bin/elmficE2g` and `bin/elmficG70a` give identical counts.

## 1. Which programs copy today, and why

The Rc pass dups and drops a struct variable as a whole. A field read of an owned struct is a view plus a count (`Own (Access m f)`).
The one exception is the read that is the struct's last use (`dying`, Rc.hs:260): that read becomes an `MUnpack`, which takes the
leaf without a dup. So a reference leaf is moved only when no later use of the variable remains. Three things leave the variable live
while an update kernel (`Array.set`, `Dict.insert`, a Vector write) runs on one of its leaves:

- **C1, a later read of another field.** In `{ a = Array.set k v m.a, n = m.n - 1 }`, the scalar `m.n` keeps `m` alive. So `m.a` is
  dup'd and the set sees 2 counts.
- **C2, the record update temporary.** Spec lowers `{ m | a = e }` to `let _upK = m in { a = e, d = _upK.d }`. `Dup m` at the `let`
  makes `_upK` hold `a` while `e` runs. `ModelUnpack.dealias` removes this only for `update`'s own `m`.
- **C3, a whole use while still live.** `setA m` followed by a read of `m.d` gives `Dup m`, which dups every leaf, including `a`,
  which nothing reads later.

`ModelUnpack` fixes C1 to C3 for the parameter `m` of `update` and for nothing else. That leaves out helpers, any other struct
variable (`let i = m.inner`, `m2`), and the real function behind the closure fallback. The table below gives the model copies
(`copied` + `vec_copy`) and the reuse misses of the FIC_STATS `model` line.

| program | shape | causes | copies | misses | split by hand (X) |
|---|---|---|---|---|---|
| H1Helper | `update` passes `m` to `setA m = { m \| a = Array.set .. m.a, n = m.n - 1 }` | C1 C2 | 1960 | 1960 | X1: 5 / 4 |
| H2HelperFull | the helper writes every field: `{ a = Array.set .. m.a, d = m.d, n = .. }` | C1 | 1960 | 1960 | |
| H3CallerLive | `let m2 = setA m in { m2 \| d = Dict.insert .. m.n m.d }` | C1 (helper), C2 (`m2`) | 1960 | 2954 | X3: 5 / 4 |
| H4TwoLevel | `step m = setA i { m \| n = .. }`, `setA i m = { m \| a = Array.set .. }` | C1 C2 twice | 1960 | 1960 | |
| H5Nested | in `update`: `let i = m.inner in { m \| inner = { i \| a = Array.set .. i.a, k = i.k + 1 } }` | C1 on `i` | 1960 | 1960 | X5: 5 / 4 |
| H6DictUpd | helper `{ m \| d = Dict.insert .. m.d, n = .. }` | C1 C2 | 0 | 951 | (as X1) |
| H6DictFull | helper `{ a = m.a, d = Dict.insert .. m.d, n = .. }` | the parameter is **borrowed** | 0 | 951 | 951 (Borrow, D3) |
| H7Closure | `update = updateWith 2`, H1's body in `updateWith` | C1 C2 | 1960 | 1960 | X7: 5 / 4 |

The **X programs** are the same programs split by hand with record patterns (`setA { a, d, n } = { a = Array.set .. a, d = d, n = n - 1 }`).
A record pattern on an owned struct that dies at the match is already an `MUnpack` (`rcCase.unpackable`), so they show today what the
design will produce: the floor, 5 copies (the first writes to the immortal `init` literal, R1Partial's target) and 4 misses. H7/X7
shows that the closure fallback's copies also come from C1 and C2 in the real function, not from the box (E1-REVIEW Q3).

Three minimal examples (sources in `ficcus-tests/e1p/src`; each has the 30 line prelude of R1Partial: the same `Model`, `initModel` and
`final`); the third is in `update` itself:

```elm
-- Example 1, H1Helper (C1 + C2): 1960 copies in 1000 steps
update _ m = ( final (setA m), Cmd.none )
setA m = { m | a = Array.set (modBy 100 m.n) m.n m.a, n = m.n - 1 }
```
`setA` after Rc (FICCUS_RC_DUMP): `Let _up25 = Dup m`, then `Own (Access .a (Local m))` as the array, and `Drop m` after the last `m.n`.

```elm
-- Example 2, H3CallerLive (C1 in the helper, C2 on m2): 1960 copies, 2954 misses
update _ m =
    let m2 = setA m
    in ( final { m2 | d = Dict.insert (modBy 7 m.n) m.n m.d }, Cmd.none )
setA m = { a = Array.set (modBy 100 m.n) m.n m.a, d = m.d, n = m.n - 1 }
```
`ModelUnpack` binds `_mf1_m = Own m.d` and moves `m` into `setA`. There `m.a` is dup'd (C1). Back in `update`, `_up23 = m2` holds `d`
while `Dict.insert` runs (C2 on a variable that is not `m`).

```elm
-- Example 3, H5Nested (C1 on a let-bound struct inside update): 1960 copies
update _ m =
    let i = m.inner
        m2 = { m | inner = { i | a = Array.set (modBy 100 m.n) m.n i.a, k = i.k + 1 }, n = m.n - 1 }
    in ...
```

## 2. The design: split an owned struct where its remaining uses are by field

**Alternatives.**
- (A) *Inline small helpers:* the inlined body still has C1 and C2, the code grows, and H3, H5 and large or recursive helpers stay.
- (B) *Pass the model unpacked:* a struct already goes by value in C; the problem is the counts in the callee, not the ABI.
- (C) *Worker and wrapper on the struct argument:* splits only at entry, makes new clones (Known and Unbox ids shift, so all C text
  changes), and misses `let`-bound structs, `_upK` and the caller.
- (D) *ModelUnpack for every function:* before Rc there are no ownership facts (Borrow runs inside `rcProgram`), and its binding
  `Own (Access m f)` is itself a dup while `m` lives.
- (E) *An Rc rule that moves the last use of each leaf:* **chosen**. It is built on `MUnpack`, so it adds no IR node and no checker
  rule.

**The rule.** In `rc ctx env live e`, after the dead drops and the `lateSpec` test and before `rcNode`, a struct variable `m` is split
at `e` when:

1. `m ∈ env` (owned), its class is `CStruct` with at least one reference leaf, `m ∉ live` (it dies inside `e`), and `m` is free in `e`;
2. every occurrence of `m` in `e` is either a field read `MAccess (MLocal m) f i` or a whole use in an owned position (the value of a
   `let`, an argument of an owned parameter or of an `o` kernel argument, a field of a record, tuple, constructor or list, or the
   result). In addition: no binder in `e` rebinds `m`; no lifted function in `e` captures `m` (`cCaps`); `m` is not the root of a
   view (`cViews`) and is not in `cLate`/`cDeferred`; and, in v1, `m` is not an owned capture of a twin (`mdCapsOwned`);
3. (profitability) either (a) without the split `e` would dup a leaf of `m`: a reference field read in a consumed position, or a
   whole owned use, that is not `m`'s last use in `e`; or (b) `m` has a reference leaf that `e` never reads, and `e` consumes a
   reference before `m`'s last use (a dead leaf held across a call: `m2.d` in Example 2 when the kept field sorts after `d`).

Then `e` becomes `case m of {i₁ = v₁, …, iₖ = vₖ} -> e[m.fᵢ := vᵢ, m := MRecord [v₀ … vₙ₋₁]]` (the fields `e` reads, or all of them
where `e` uses `m` whole; CGen records are positional, so the rebuild needs no names), counted by `rcCase` like any case. `m` is owned,
not live and not named in the branch, so `unpackable` gives `MUnpack m sc bound b`: each used reference field takes its leaves without
a dup, every other reference leaf is dropped on the spot (`CGen.unpackDrops`), and `m` leaves `env`. From then on the `vᵢ` are
ordinary owned variables: the last read moves, an earlier read dups, a variable dead in a branch is dropped at its start, and a
rebuilt record moves or dups each leaf. Several candidates at the same `e`
are split in name order, as nested cases. A field of struct class is a candidate again further down (H5). **Dealias** (part of the rule): a `let x = m`
whose body reads `x` only by field and does not rebind `m` is read as `m` first (ModelUnpack's `dealias`, for any owned struct variable). The split variables take their names
from a **separate counter** (`sp<N>_<field>`), not from `fresh`, so the `rc_N` names elsewhere do not shift.

How each cause goes: C1: `m.n` becomes a read of a scalar variable and `v_a`'s read is its last use, so it moves. C2: `_upK` is
dealiased to `m`. C3: at `setA m`, `m` is rebuilt as `{v_a, v_d, v_n}`: `v_a` moves and only `v_d` is dup'd. In Example 2, `m2` (after
the dealias of `_up23`) is split at the record, so its unread `d` is dropped before `Dict.insert`.

**Soundness.**
- **Values.** Field reads are pure and total, Elm is strict, and `m` is immutable. A variable bound to `m.f` earlier has the same
  value, and a record of all of `m`'s fields equals `m`. No effect moves: reads have no effects.
- **When moving a field is safe.**
  - *No other view:* condition 2 excludes views rooted at `m` and captures of `m`, and after the rewrite nothing in `e` names `m`.
  - *No second owner taken over:* the move transfers `m`'s own count only. A second owner (another field, a list, a closure, a
    command) keeps its count, and the kernels still test the count. The rule never asserts uniqueness, so R2Alias (10 copies in 30
    steps) and R5Capture (12) must keep their copies.
  - *No later read:* `m ∉ live` means nothing after `e` uses `m`, and inside `e` every use is rewritten.
- **How the rest is dropped.** `MUnpack` consumes `m` once; each leaf is taken by exactly one `vᵢ` (RcCheck: indices distinct and in
  range, components per class) or dropped once by `unpackDrops`; each `vᵢ` is consumed or dropped once on every path (RcCheck's branch
  balance). No double drop: `m` leaves `env` and condition 1 excludes a later use. No leak: every leaf has one owner.
- **RcCheck is unchanged and stays independent:** it already checks `MUnpack` and the variables by its ordinary rules; the rule adds
  nothing the checker must trust.
- **Borrow inference is unchanged.** It runs first and the split acts only on owned variables; `paramOwns` never changes, so callers
  are unaffected. In the counted helper form `{ p | f = .. p.f .. }`, `p` is owned through `let _upK = p`; array writes own it
  through the update rule. Not owned: a helper that rebuilds every field and writes only through `Dict` (H6DictFull), since a field
  read in an owned position leaves a struct borrowed (`Borrow.owned`: `MAccess r -> borrowed r`). See D3.
- **Rule 2 workers.** The split runs after Unbox and makes no clones. A worker result read field by field may now be split too,
  which only adds `MUnpack` sites; FICCUS_UNBOX_CHECK inspects only `let t = worker in case t` and stays valid.
- **ModelUnpack** runs before Rc. Its `let _mf = Own (m.f)` bindings are reads of `m`, which the split rewrites too. With the split,
  `update`'s `m` is split at entry, or per branch where `m` is returned whole (R4), so the pass becomes redundant (D2).
- **S4 and S6.** Split variables are plain owned locals, so takes (`takeCall`) and drop specializations (`specBranch`, `lateSpec`)
  now also reach fields: more in-place work, and the `sK`/`rK` mutation numbers shift. A tail call in `e` stays a tail call.

## 3. The four E1 ownership limits (decisions file, 24 Nov OPEN entry)

1. **Helpers: removed** where the helper's struct parameter is owned (record update form, array or vector writes: H1 to H4), and
   with them nested records (H5) and the record update temporary of any struct. *Not removed:* the borrowed H6DictFull form (D3).
2. **Tuple box: not touched.** The direct path has no box (E1-REVIEW Q3); it exists only on the closure fallback.
3. **Closure fallback: the copies go, the guarantee does not.** H7 1960, X7 5: the split reaches 5 when inference owns the real
   function's model parameter. The seed still lands on the wrapper (a borrowed real parameter still copies), and the box stays.
4. **Second owner: not removed.** It is correct as built, and R2, R3 and R5 keep their counts.

## 4. Test plan

**Switches.** `FICCUS_NO_LEAF_SPLIT=1` turns the rule off; `FICCUS_SPLIT_STATS=1` prints the splits per clone on stderr.

**Targets.**
- `e1p_measure.py --targets`: H1 to H5 and H7 at most 5 copies and 5 misses; H6DictUpd at most 5 misses; H6DictFull unchanged
  unless D3 is taken; the X programs unchanged.
- `e1_review.py --targets`: R1 at most 5, R4 0, and **exact** counts R2 = 10, R3 = 6, R5 = 12. Fewer copies there would mean an
  unsound in-place write, so the runner should check equality.
- G17b and G17bFields 0; G17, G17a/c/s as in `effects_e2.py`.
- Every program also runs with `FICCUS_NO_LEAF_SPLIT=1` (expected: today's counts) and with `FICCUS_NO_MODEL_UNPACK=1` (expected: the
  targets, which is the evidence for D2).

**New programs** (with Elm goldens, in `e1p_measure.py`):
- H8Vector: a helper writes a `Vector Int` field of the model (`vec_copy` 0, against an O(n) copy per step today).
- H9Branch: `m` is returned whole on one branch and passed to a writing helper on another, so it must be split per branch.
- Negative tests, where the copy is required:
  - H10Alias: `let k = m in ( setA m, k.a )`, a second owner made by an alias.
  - H11Capture: a closure captures `m`, then a helper writes `m.a`.
  - H12Twice: `(setA m, setA m)`, the whole struct used twice.

**rcfaults.** The removal mutations already reach the split's `MUnpack` (`rcMutate` counts every `MUnpack`). New prefix `pK`, per
split site:
- (p1) leave one rewritten read as `m.f` after the unpack (a read that was missed: a use after consumption);
- (p2) split a variable that is still live (keep one whole use of `m` after `e`);
- (p3) give two variables the same leaf.

RcCheck must reject each (`rc check:`). In full in `rccheck_faults.py`, on the default list and the e1p programs.

**rcfuzz and v2fuzz.** The existing seeds unchanged (rcfuzz 500 × `default,proj,reuse,s3rule`, v2fuzz 300), then 500 and 300 new seeds
from a generator extension: functions taking a record with `Array`, `Dict` or `Vector` fields, record updates of a parameter, calls
after which the record is live or dead, nested records.

**Identity (the C text may change only where a split happens).**
1. With `FICCUS_NO_LEAF_SPLIT=1`, the C text must be byte-identical to elmficG70a's for: the 16 suite programs (`--rc` and `--no-rc`),
   the 298 examples, the effects, effects2 and e1p programs, and A2 (both stages).
2. With the split on and `--no-rc`, the text must be identical: the rule is Rc only.
3. With the split on and `--rc`, a script cuts the C at the `/* cNN name key */` markers. Every function that differs must have at
   least one split in FICCUS_SPLIT_STATS, and no function with 0 splits may differ (the separate name counter guarantees this).
4. Per function, the static number of `fic_dup(` + `fic_drop(` must not increase. Report it, and explain any exception.
5. The 55 `.mono` listings must be unchanged (they are printed before Rc).

Expected spread, as an upper bound counted from G70a's Rc dumps (an `Own` over a field read of a struct local): 47 (program,
function) pairs over the 16 suite entries and the 25 effects/effects2 programs. Most of them are Array internals
(`builderToArray` in almost every program, `appendHelpBuilder`) and `update`.

**Gates.** The full `gates.sh` with the new binary, with the expected results in its header (fbip: 0 missed, reuse may improve), plus
`e1p_measure.py --targets` as a new gate. On an idle machine (`uptime`): the A2 50 MB bench (parse time within noise of G70a) and
`h16_w7a_compile_time.py` (the candidate test is O(nodes × struct variables), so test only where `m` is free).

## 5. Estimate

**One Sonnet slice of about a day:** 150 to 200 lines in Rc.hs (candidate test, rewrite, dealias, stats, switch), about 40 in
`rcMutate` (`pK`), the new programs and goldens (about 2 hours), an identity script (about 80 lines of Python), and the gates (about
1 hour) plus the bench.

**An Opus review should follow: yes**, because this changes an ownership rule in the Rc pass. Its focus: liveness condition 2
(captures, views, shadowing); whether profitability condition 3 could suppress a needed dup (it must not: it only selects where the
split happens, and the counts come from the unchanged machinery); the interaction with takes and late specialization; and the
negative tests H10 to H12.

## 6. Open decisions for the user

- **D1. Approach E** (a leaf split in Rc onto `MUnpack`, with the dealias). *Recommend yes.*
- **D2. ModelUnpack.** Keep it in the pipeline at the start of the slice. Once R1 to R5, G17* and H* are equal or better with
  `FICCUS_NO_MODEL_UNPACK=1`, turn it off by default in the same slice (the switch turns it back on), and delete it in a later
  cleanup. *Recommend.*
- **D3. Borrow for struct fields:** should a struct parameter whose reference field is read in an owned position become owned? This
  fixes H6DictFull, but it changes ownership, and with it callers' C text, in many library functions, and it adds dups where a caller
  keeps the struct. *Recommend: not in E1p.* Measure it in the slice behind `FICCUS_BORROW_FIELD=1` (counts, C text spread) and
  decide afterwards.
- **D4. Profitability condition 3,** or split whenever conditions 1 and 2 hold. *Recommend condition 3:* the text changes only where a
  dup is saved or a dead leaf is held across a call. "Always" would move leaf drops earlier in every function that reads a struct
  by field, which is never worse but spreads the C text change and the review.
- **D5. Owned captures of twins:** excluded in v1. *Recommend excluding them,* and revisit if a corpus count shows closures that
  write a captured record.
- **D6. D-fx-3 text** (a shared file, for the user to apply): after the slice, widen the guarantee to "a helper or a nested record
  whose struct parameter is owned", and narrow the closure fallback limit to "the seed does not apply". The slice report should
  propose the exact text.
