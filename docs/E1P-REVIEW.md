# E1p review: the leaf split in the Rc pass

25 Nov 2026, Opus 5.5, read only (no compiler source changed). Branch `review/e1p` from `feat/e1p` 99990ade, worktree
`ficcus-haskell-compiler-e1pr`, binary `bin/elmficE1pa` (reference `bin/elmficG70a`). Read: `docs/E1P-DESIGN.md`,
`docs/E1-REVIEW.md`, `Ficcus.Mono.LeafSplit`, `Rc.trySplit`/`rcDef`/`rcCase`, the ModelUnpack switch, `rcMutateSplit`,
`rccheck_faults.py`, `e1p_measure.py`, `e1p_identity.py`, the slice report (decisions file, 25 Nov DONE entry).
New tests: `ficcus-tests/e1pr/src` (5 programs), goldens `expected/e1pr_*.out` (Elm 0.19.3 under node), runner
`ficcus-tests/e1p_review.py --elm B --elm-home H [--strict]`. Every run: `--rc`, gcc -O2 and ASan+UBSan, output compared with Elm.

## Verdicts

| Q | verdict |
|---|---|
| 1 soundness | **Sound for counts and values.** No double drop, leak, use after move or wrong value found. One **defect: a name clash** that makes valid programs fail to compile (R1Name) |
| 2 profitability | **Never costs a count** (argument below). But profit is computed **after** the dealias, so a `{ m \| .. }` whose only saving is the dealias is neither split nor dealiased (C2 stays) |
| 3 exclusions | **Sound.** Borrowed parameters are never split. A struct captured by a lambda is excluded; that is sound but matters (R4Lambda, R14) |
| 4 counter reset | **Sound and cheap.** The identity claim holds only with ModelUnpack on: with the default (off) 10 effects programs fail mode 3 |
| 5 interactions | **Sound.** RcCheck rechecks every count of the split, but not binder names or which field a variable holds |
| 6 order | **Deterministic** (A2 twice: byte identical). **Complete** except for the two gaps of Q2 and Q3 |
| 7 coverage | The three kinds are right but overlap the removal kinds. The design's p2 and p3 and two new kinds are missing. 2 of 5 new programs are targets |
| 8 D-fx-3 | Inaccurate in two places; corrected text below |

## Q1. Soundness of the split

**Why it holds.** `env` holds only owned variables (`Rc.hs:115`: parameters with `Owned`, plus owned twin captures, which are
excluded). A candidate must be outside `live`, so nothing after `e` reads it. `usesOf` accepts only field reads and whole uses
in owned positions. It rejects a binder of the same name, a lifted function that captures `m` (`sfCaps`), and `m` as a
scrutinee or as a borrowed argument. View roots and late or deferred variables are excluded. The `case` that `trySplit` builds
always meets `unpackable` (`m ∈ env'`, not live, not named in the body), so it becomes `MUnpack`. From there the `_spK_f` are
ordinary owned variables, so branches, early exits and the drops on dead paths come from the existing machinery.
`rewriteSplit` ignores shadowing. That is safe because `usesOf` rejects any rebinding of `m`, and Elm forbids shadowing, so only
generated names could shadow. The dealias drops `let x = m` only when `x` is read by field, `m` is not rebound and no lifted
function captures `x` (`captured`). Fields are positional on both sides (the `MAccess` index and the positional rebuild).

**Tried, all equal to Elm, live 0, clean under the sanitizers; copies identical with and without the split:**
R10Alias (`let old = m`, then `setA m`, then `old.a`: the dealias makes `old.a` a read of `m.a`, so the helper gets a shared
array: 1960 copies, exact), R11Capture (closures capture `m` and an alias of `m`: 1960, exact), R12Twice (ad hoc, not added:
`(setA m, setB m, m.a)` returned in a tuple: 3920, exact). Positive: R13TailBranch, which rebuilds `m` on one branch, returns it
whole on a second, passes it to a writing helper on a third and wraps it in a nested record on a fourth: 300,000
tail-recursive steps under ASan (constant stack), 5 copies; without the split, 313,600.

**Defect (required fix 1): the fallback names clash.** When `m` is used whole, `planSplit` names each unread field `"f" ++ show i`
(`LeafSplit.hs:83`, `Rc.hs:189`). A real field called `f0` at another position then gives two pattern variables named `_sp0_f0`.
In `E1pR1Name`, `g m = (5 :: m.f0, m)` with `{ a : List Int, f0 : List Int }` stops with "rc check: pattern variable _sp0_f0 has
1 count(s) left". With `{ b : Int, f0 : List Int }`, RcCheck accepts and gcc stops with "conflicting types for v__sp1_f0".
Elm compiles both. It is a compile failure, never silent: C99 rejects a second declaration in one scope. Fix: name the variables
by position (`_sp<K>_<i>`, or `_sp<K>_<i>_<field>` for readability).

## Q2. Profitability

**A split never adds a count.** For each reference leaf ℓ, without the split ℓ is dup'd once for every consuming use of `m.ℓ`
and every whole owned use of `m` while `m` is live. It saves one count only if `m`'s last use consumes ℓ, either as the dying
read (`Rc.hs:315`) or as a whole move. With the split, `_sp_ℓ` is dup'd once for every consuming use except its own last one.
The last use of `m` that consumes ℓ is also ℓ's last use, so dups(after) ≤ dups(before). Drops: one for each path where the
last use does not consume, the same or fewer. A borrowed read is a view on both sides (`m.ℓ` is a field view, `_sp_ℓ` is a
local). Live ranges never grow: each `_sp_ℓ` dies at its last use, which is no later than `m`'s death, and unread leaves are
dropped at the unpack. Takes and drop specializations only gain, because their operand is now an owned local (R13: 313,595
updates in place against 0). No in-place update is lost.

**Imprecisions.** (a) fires when the later use is a read of the **same** field (`(m.a, m.a)`): the split saves nothing and the
text changes. (b) fires where counts stay equal; it only drops earlier. Both are harmless; see optional improvement 3.

**Gap (required fix 3): profit is computed after the dealias.** `planSplit` tests `analyse` on `dealias e`. When the dealias
removes the only extra count, nothing is left to find and the plan is dropped, so the dealias is dropped with it.
`{ m | n = m.n + 1 }` on `{ xs : List Int, n : Int }` keeps `let _up3 = Dup m` (SubsOrder's `update`). In a helper this is
E1's C2, not fixed. In `update` it is a **regression against G70a**, where ModelUnpack removed it: SubsOrder 64 → 84 dups and
190 → 210 drops in 20 steps (one each per step), static dup+drop 1 → 3. Fix: run `analyse` on the original `e0` (the `let`'s
`Dup m` is then a non-last whole use and counts as profit), or apply the dealias whenever `m` dies in `e`.

## Q3. Exclusions

- **Borrowed parameters: confirmed never split.** Only `Owned` parameters enter `env`. Borrowed captures go through `MOwn` and
  never enter `env`. A struct pattern variable that is only viewed stays a view.
- **View roots** are excluded conservatively: every root in `cViews`, live or not. This is sound and cost nothing in H1 to H7,
  R1 to R5 or the corpus shapes.
- **Twin captures (D5)**: sound to exclude. No program measured here needs them.
- **Captured structs** (a lambda reads `m.n`, so the lifted clone captures `m`) are excluded because the capture is by name. That
  is sound, but it costs: R4Lambda loses ModelUnpack's entry bindings (+6 dups, +6 drops in 20 steps, static 10 → 12), and
  **R14LambdaSet copies 1960 times in 1000 steps, the same on G70a**: `{ m | a = Array.set .. m.a, d = Dict.map (\_ v -> v + m.n) m.d }`.
  E1's ModelUnpack does not fix this shape either. Real fix: closure conversion captures the fields a lambda reads, not the
  struct (optional improvement 1).
- Nothing unsound is let through: see Q1.

## Q4. The counter reset

**Sound.** The second run (`Rc.hs:123`, `cSplit = False`, from state `s0`) contributes only `rsN`; its output and its errors
are discarded. Inside a split clone one counter still makes every name unique. `rc_N` are C locals, so overlapping numbers in
different functions are harmless. **Identity:** with `FICCUS_NO_MODEL_UNPACK=0`, `e1p_identity.py --more` (16 suite programs
plus 37 e1p, effects and effects2 programs) is **all ok, no GROWS**. With the default (ModelUnpack off) it gives **10
failures**: G17b, G17bFields, R4Lambda, R5Capture, SubsOrder, E2Teardown, G17, G17a, G17c, G17s. `update` changes without a
split, which shifts the `rc_N` of later clones. The static count grows in three `update`s: SubsOrder 1 → 3, R4Lambda 10 → 12,
G17s 9 → 10. So the slice report's claim that every changed function has a split and none grows was checked only on the 16
suite programs. **Cost** (one compile each, load 1.8): A2 (`JsonCombV`, 67 split clones) 1.21 s against 1.16 and 1.18 s
(+3 %), peak RSS +2 %. Suite, 16 programs: 11.06 s against 10.99 s (+0.6 %). An 800-arm `if` chain that is analysed at every
level and never split: 2.16 s against 2.24 s (no overhead).

## Q5. Interactions

- **lateSpec**: the split runs after the dead drops and the lateSpec test, and excludes `cLate` and `cDeferred`. `lateSpec` calls
  `rc` on `e`, so the split is still tried there.
- **Takes**: split variables become take operands (a gain).
- **Rule 2**: `let t = worker in case t` has `t` as a scrutinee, which `usesOf` rejects, so `FICCUS_UNBOX_CHECK` stays valid.
- **Known and Inline clones**: ordinary clones. **Twin clones**: their owned captures are excluded.
- **RcCheck** independently checks every split count. `MUnpack` must take distinct indices that are in range, the components
  per class, and each `_sp` variable once per path. That catches a double drop, a leak, a use after the move, a split of a live
  variable and a leaf taken twice. It does **not** check that pattern binders are distinct (R1Name `h` passes it) or which field
  a variable is bound to: swapping two fields of one class passes RcCheck and only the Elm goldens catch it.

## Q6. Candidate order

`Map.toList env` orders by `String`, that is by code point on every platform. The `_spK` counter follows the traversal order. A2
compiled twice gives byte-identical C. Completeness: every `rc` node retries every candidate. After a split the next candidate
is tried in the branch body on the rewritten expression. When a borrowed whole use rejects the plan at a node, the children are
retried below it. Missed against the design: the dealias without profit (Q2) and captured structs (Q3).

## Q7. Mutations and tests

The 61 split faults (double drop, leak, read after the unpack) are worth keeping. Kinds 1 and 3 overlap the existing removal and
use-after-consume faults. **Missing**: the design's p2 (a whole use of `m` after the unpack: a live split) and p3 (two variables
take one leaf: RcCheck's distinctness test is never exercised). **Proposed**: p4, a duplicate binder name (needs the RcCheck rule
of fix 1). p5, swap two variables of the same class in the rewrite: RcCheck must accept it and `e1p_measure`/`e1p_review` must
fail; this measures the goldens, not the checker.

**New programs** (`e1p_review.py`; with `FICCUS_NO_LEAFSPLIT=1` R1Name passes and R13 copies 313,600 times):

| program | result on E1pa |
|---|---|
| E1pR1Name | **TARGET**: compile fails (fix 1) |
| E1pR10Alias | ok: 1960 copies, exact |
| E1pR11Capture | ok: 1960 copies, exact |
| E1pR13TailBranch | ok: 5 copies, 300,000 steps |
| E1pR14LambdaSet | **TARGET**: 1960 copies (also on G70a; optional improvement 1) |

## Q8. D-fx-3

Two errors. (1) "the Rc pass splits the struct wherever that saves a count" is true only after fix 3, and only where no lambda
reads the struct. (2) The guaranteed list ("reads the model's fields directly, through `{ m | .. }`") still covers fields read
under a lambda, as E1's text does explicitly; R14 copies. The E1 sentence "including fields read under a lambda" was already
wrong for a lambda next to the write. Corrected text (rule 2 and the guaranteed and limits passages):

> (2) A reference field of an owned struct that dies in an expression is moved out of it instead of being read as a view plus a
> count: the Rc pass splits the struct into its fields where that saves a count (`update`'s model, a helper that receives the
> whole model as an owned parameter, a nested record `{ m | inner = { i | .. } }`), and `{ m | .. }` is read as `m` itself.
> ModelUnpack still binds `update`'s fields at entry [drop this clause if it is turned off]. **Guaranteed** (no copy by the
> protocol): `update` is a lambda or a top-level function of two arguments that reads the model's fields directly, through
> `{ m | .. }`, or by passing the model, or a record inside it, to a helper whose struct parameter is owned (H1 to H5 and H7:
> 1,960 copies to 5, the writes to the immortal `init` literal). **Not guaranteed, correct but copying:** a lambda that reads
> any field of the struct whose leaf is written in the same expression (the lambda captures the whole struct: R14, 1,960); a
> helper whose struct parameter inference borrows (H6DictFull, D3); the closure fallback (`update = f config`). A leaf with a
> second owner is decided by the reference count.

## Required fixes before merge (ranked)

1. **Name clash** (Q1): positional split variable names; add an RcCheck rule that the binders of one pattern are distinct.
   R1Name must pass.
2. **ModelUnpack default** (Q2, Q4): keep it **on** while the split is on (`noUnpack` back to `== Just "1"`). With it on,
   identity `--more` is all ok and `e1p_measure`, `e1_review` and `effects_e1` pass. The exception is the G17bFields row with
   `FICCUS_NO_MODEL_SEED=1`, which goes back to its G70a value of 199,200 copies; restore that expectation. D2 is not met: its
   test counted copies, not dups and drops.
3. **Dealias independent of profit** (Q2): profit computed on `e0`, or the dealias applied wherever `m` dies. Re-measure
   SubsOrder and R4Lambda with ModelUnpack off; D2 can be revisited after that.
4. **Run `e1p_identity.py --more`** in the gates; correct the slice report's identity sentence.
5. **D-fx-3**: the text in Q8.

## Optional improvements

1. Closure conversion captures the fields a lambda reads instead of the whole struct. This fixes R14, removes most uses of the
   capture exclusion, and restores E1's "under a lambda" claim.
2. Mutation kinds p2 to p5 (Q7). Add `e1p_review.py` to `gates.sh` (targets do not fail it; `--strict` once fixes 1 and 3 land).
3. Profitability (a): ignore a later use that is a read of the same field; this reduces text churn and does not change counts.
