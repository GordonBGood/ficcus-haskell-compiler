# H16 stage 2 design: known constructors across copies, unboxed results, scalar replacement

Written for: the user and the Sonnet sessions that will implement W5 to W9. Branch `feat/known-pass` at fc2303d2 (binary `elmficK5`).
Read first: `docs/H16-DESIGN.md` section 6 (the outline this note replaces), `docs/H16-EXPERIMENTS.md` (W1, W2), and on branch
`bench/h16a` `docs/H16A.md` (hand versions S1, S2). `M.` = `compiler/src/Ficcus/Mono/`. A2 = `targets/p1/src/JsonCombV.elm`.

Inputs that are not in the repository and were pasted by the user: the W3 report (step 3 measurement), the K4/K5 verification report
(allocation sites, `FICCUS_ALLOC_SITES=1`), and the intermediate report on the 12 suite programs whose `--rc` text changes with the pass on.

## 0. Measured state (P1 A2, 50 MB, pass on = elmficK4/K5)

| | pass off | pass on | hand S1 | hand S2 |
|---|---|---|---|---|
| parse | 8,543 ms | 4,448 ms (1.92 x) | 1,951 ms | 803 ms |
| allocations (parse) | 832 M | 427 M | 158 M | 22.8 M |
| closures | 165.5 M | 6.7 M | 1.9 M | 1.9 M |
| paps / vector objects | 5.0 M / 7.0 M | 5.0 M / 7.0 M | | |
| dups / drops | | not measured | 184 M / 169 M | 52.8 M / 58.2 M |
| C text / `.text` | 645 KB / 109 KB | 688 KB / 103 KB | | |

`fic_free_slow` is 48 % of the whole run (W3 perf). The allocation sites with `FICCUS_ALLOC_SITES=1`: stage 2 of the program makes 490.2 M
allocations, stage 1 makes 63.5 M, so 426.7 M are parse. The top 15 sites cover 36 % of the run (table in the K5 report). They come as pairs:
a `Good` cell and a **box** of equal count (13.5/13.5 M in `oneOfHelp` f65, 12.4/12.4 M at lambda@215, 7.0/7.0 M at lambda@56,
7.1/7.1 M in f187). The box is the `State` record: a struct field of a constructor is always boxed (CGen.hs:351, `boxedClass`), so
**every `Good c a s` costs two allocations**. The other boxes (rows 2 and 3, 25.7 M + 17.2 M, freed in the same activation) are the `State`
argument boxed for the uniform closure ABI (`fic_ap1` in `oneOfHelp`'s call `p s`, CGen.hs:633). These three facts explain the costs:

1. `Step` results with the `State` box inside: two heap objects per successful step and one per failure.
2. `oneOfHelp` still calls its alternatives through a list of closures: one `State` box per attempt (43 M), and their results cannot be
   seen by any known-constructor rule.
3. `oneOfHelp` rebuilds what it matched (`Good c a s1 -> Good c a s1`): 41 M allocations (rows 4, 5, 9, 10) to copy a value it already owns.

## 1. Rule 1: case of known constructor across the specialized copies

### 1a. Inline the small capture-free copies, then the existing rule A

W3 made capture-free lifted clones eligible for Inline (Inline.hs, eligibility behind `FICCUS_NO_KNOWN`). Rule A (Inline.hs:424) takes apart
`case e of ...` when every leaf of `e` is a constructor application or a producer call (`candidate`, Inline.hs:273). After inlining
`symbol 44`'s copy into `ignore`'s copy, `case (if .. then Good True () {..} else Bad False "symbol") of ...` is a candidate. Rule A rewrites it
to the branch bodies with the fields let-bound. No cell or box is made.

**What is new:** nothing in rule A. The work is getting the copies inlined (size limit 80, `sizeLimit` Inline.hs:72; producer
classification `tProd`; the copies' calls must be direct `MGlobal` calls with matching arity). **That is experiment E1 (section 7):** the
eligibility change is already on in K5, yet 427 M allocations remain, and I could not establish from reading why rule A does not fire more.
Possible causes are the size limit, a copy that is not a producer by `tProd`'s definition, the call going through `oneOfHelp`'s list (no
rule can see it, see 1b), or the copy being in the same SCC as its caller.

**Soundness.** Inlining a capture-free clone is a beta reduction. Inline let-binds non-atomic arguments in order (`atom`), so effects
(`Debug.log`) keep their order, and a capture-free body needs no scope. The K5 closedness check (`checkClosed`) runs on the result.
Rule A under Perceus: `case C x1..xn of C y1..yn -> e` becomes `let y1 = x1 .. in e`. The cell was never shared (it was just built), so
ownership of each `xi` moves to `yi` with no count. This is the existing rule with the existing gates. Nothing changes in Rc, Borrow or
RcCheck.

### 1b. Spine specialization of static lists of known functions (generic `oneOf` unrolling): needs a user decision

`oneOf ps = \s -> oneOfHelp s ps` with `ps` a static list (a floated constant whose elements are known functions). W3's keyed
specialization extends to this: the key `(oneOfHelp, Spine l)` where `l` is the origin id of a static list cell. In the specialized body,
`case ps of [] -> ..; p :: rest -> ..` is a case on a known constructor. It reduces to the second branch with `p` a known function, so `p s`
is a direct call, and `rest` is again static, so `oneOfHelp s rest` becomes a call of the copy keyed on the tail. The result is S1's "chain
of `case`" with the library's flag logic kept, reached by two rules that already exist (keys, known constructor). It is not special-cased
for `oneOf`.

* **Conditions:** the list argument is a static list of knowns (all cells and elements static), and the recursive function only
  `case`-matches it and passes its tail to itself. Any other use of the list (length, being stored, passed to an unknown function) refuses
  the rule. Spine length is at most 8 (A2's `value` has 7 alternatives).
* **Termination:** static list cells are finite and fixed before the pass, and each key is a cell of them, so the keys are finite. A
  recursive grammar (`value` inside `jarray` inside `value`) is tied by the memo, as in W2/W3.
* **Soundness:** it is specialization (W3, already gated) plus rule A on a list cell. The list stays a static Value, and its cells are
  never freed or counted in the copy because the copy no longer reads them. Init order: the copy reads no Value, so it cannot read one
  before its initialisation.
* **Why a decision:** `H16-DESIGN.md` set the stage 1 target "without `oneOf` unrolling". This rule is the generic form of that unrolling.
  Without it, rule 2 has little to act on in A2 (section 4).

### 1c. Case identity: return the scrutinee instead of rebuilding it

`case x of C y1..yn -> C y1..yn` (same constructor, the pattern variables in order, none used elsewhere in the branch) becomes `x` in that
branch. The scrutinee is let-bound first when it is not a variable. This removes `oneOfHelp`'s rebuilt `Good` and its box (41 M), and
`Bad c m -> Bad c m` in `oneOfHelp`, `map`, `map2` and `andThen`.

* **Retyping variant:** `Bad c m` matched at `Step a` and rebuilt at `Step b` is the same object when the constructor's field classes are
  equal at both keys (Layout equality of the two `MCtor` keys). Otherwise refused.
* **Soundness:** Elm values are immutable and the result is structurally equal. Under Perceus: if `x` is owned, the branch moves `x`
  (no dup of fields, no drop of `x`), which is strictly cheaper than reuse (which writes the header and the fields again). If `x` is
  borrowed, one dup of `x` replaces an allocation and n field dups. Reuse (M.Reuse) sees the new body and decides afresh. A branch that
  used to reuse the cell now does not need it.

## 2. Rule 2: unboxed results (worker/wrapper)

### 2.1 Decision: return a C struct (record encoding with filler slots), not continuations, not a C union

For a function `f` whose result is a sum type `T` and where at least one direct call site of `f` is a `case` scrutinee or a tail position
in another worker:

* **Worker `f_w`** has the same parameters and returns the record class `CStruct (CU32 : slots)`. The slots are the fields of all
  constructors of `T` at that key. A slot is shared between constructors when the class is equal (A2's `Step (Json)`: tag, `c`, `a`, the
  `State` as a nested struct, `m` sharing `a`'s slot when both are `CRef`: 4 to 5 words). A slot not used by the active constructor holds a
  **filler**: 0 for scalars, the immortal sentinel (`FIC_IMMORTAL` header, as `fic_nul0` and the JSON objects in `runtime/fic_json.h`) for
  references, and fillers component-wise for structs. Every leaf `C x1..xn` of the body becomes the record `{tag = k, slots}`. A tail call
  of a worker in the same set becomes a tail call of its worker. Any other leaf of type `T` (a variable, an unknown call) becomes
  `case e of C.. -> {..}`, and the worker is refused when more than half of its leaves are of that kind.
* **Wrapper `f`** stays under its clone id and C name, so value uses, closure entries and calls from code that is not rewritten are
  unchanged: `f ps = case f_w ps of {tag, slots} -> C_tag(slots)`. It is removed when it has no uses (sweep).
* **Call sites:** `case f args of alts` with `f` in the worker set becomes `case f_w args of {tag, s1..sk} -> if tag == k then alt_k[..]`.
  This is a record pattern followed by a tag dispatch, both existing IR. The fields of the matched alternative are the bound slots, and the
  other slots are dead.

**Why the record encoding.** It is built only from nodes that exist (records, record patterns, `if`, literals, a filler atom), so
**Rc, Borrow, RcCheck and CGen do not change**. Soundness reduces to the soundness of the existing struct handling plus the immortality of
the filler:

* the worker result is an owned, fresh struct;
* the record pattern on an owned struct moves its components (CGen.hs:979-987, "a struct that comes out of a box takes a count on each
  reference component" is the boxed case; an unboxed local is moved);
* dead slots are dropped at branch entry by Perceus' ordinary rule (drop dead variables first). A dropped filler is a test of the immortal
  bit, and a dropped live slot of a non-matching branch cannot happen because the tag picks the branch the slots belong to;
* compared with today, the program computes the same values. Where it used to allocate a unique cell and immediately match and free it,
  it now passes the fields and never makes the cell. Perceus would have done "dup fields, drop unique cell" (a free that walks the fields
  and cancels the dups), so the counts on every field are the same up to that cancelled pair. RcCheck verifies this on every test.

Rejected alternatives:
* **C union with a tag-guarded drop:** smaller struct, but every Rc/RcCheck/CGen path on structs would need a "component valid only under
  tag k" notion. Kept as a possible later refinement if E3 shows the filler dups and drops are measurable.
* **Continuations** (pass `good` and `bad` to the callee): in C a continuation is either a closure, which is the allocation being removed,
  or a copy of the continuation code into the callee (a join point per call site, multiplying with nesting depth). Struct return gives the
  same allocation result with neither.

### 2.2 C ABI, closures, `--no-rc`

* **ABI:** direct calls already pass and return structs by value (records are structs; CGen.hs:399 typedefs). x86-64 SysV returns
  structs up to 16 bytes in `rax:rdx` and larger ones through a hidden pointer to the caller's stack frame (no heap, cache hot). WASM via
  clang does the same through `sret`. TinyC returns structs by value; nested structs with mixed classes are E3. Self tail calls: CGen's
  `continue` (CGen.hs:478-496) concerns arguments, so a worker that calls itself keeps it. A tail call of another worker is
  `return g_w(..)`, which gcc may or may not turn into a jump. The stack depth is then the same as today's, never worse.
* **Closures:** a worker is never a value. The closure entry of `f` is the wrapper's, with the uniform word ABI unchanged (CGen.hs:633). A
  function used both directly and as a value has both. That code growth is counted in the budget.
* **Budget per worker:** at most 8 slot words. Otherwise refused, because the sret copy grows and the gain shrinks.
* **`--no-rc`:** the rule lives in a new module `M.Unbox`, called only in the `rcMode` branch of Make.hs:208:
  `Rc.rcProgram (Twin.twinProgram (Unbox.unboxProgram (Inline.inlineProgram (Known.knownProgram p))))`. Spec is untouched, so the
  `--no-rc` text is byte identical by construction, checked by `norc_identity.py` without `--update`.
* **Pass-off identity:** with `FICCUS_NO_STAGE2=1` the `--rc` text equals `elmficK5`'s pass-on text. With `FICCUS_NO_KNOWN=1` it equals
  `elmficA19` (as now).

### 2.3 Scope: needs a user decision

Rule 2 is general: `Maybe` and `Result` returning library functions (`Dict.get`, `List.head`, `String.toInt`) qualify, and that would change
most programs. **Recommendation:** in stage 2, apply it only to clones created by `M.Known` (copies, specializations) and the functions in
their SCCs. Keep a switch `FICCUS_UNBOX_ALL=1` for a measured experiment on the 16 suite programs and elmdiff afterwards.

## 3. Rule 3: scalar replacement of `State` and of small records; invariant fields

A `State` is already a struct passed by value in direct calls. It is boxed only inside a constructor (removed by rule 2, where it becomes a
nested struct slot) and across `fic_ap` (removed by 1a/1b where the call becomes direct). **Rule 3 therefore removes almost no allocations.**
Its gain is in counts: every `{ s | offset = s.offset + 1 }` dups `s.src` and drops the old `State`. This is S2's part (b), and the dups
fall from 184 M to 53 M between S1 and S2.

* **3a. Parameter split** (in `M.Unbox`, on the same clone set as rule 2): a parameter of record class whose uses are only field reads,
  record updates that are passed on, or being returned in a result slot, is replaced by one parameter per field. Fields that are never read
  are dropped (dead fields). Call sites pass the fields. Value uses keep the wrapper. Borrow then infers `src` per field: passed through,
  never consumed, so borrowed (as W3 found for extra capture parameters).
* **3b. Invariant result field:** a result slot that equals, on every `Good` leaf, the same field of a parameter (`src` threaded unchanged)
  is removed from the result. The caller uses its own argument's field instead. With 3a, `{ s | offset = o }` then costs no count at all.
* **Soundness:** the split is a change of calling convention between direct calls, with all uses rewritten in one step. The values are the
  same and Rc counts the fields as it counts struct components today. 3b depends on syntactic equality (the same variable, through updates
  that do not touch the field), so the caller's reference is the same object, held by the caller, and needs no count. `Rc.takeCall`
  (Rc.hs:632) wants the vector as an owned local: a split field is a plain local, so the take fires at least as often. Known13 (section 5)
  checks this against `Vector.update` in a loop.
* **Not planned:** dropping the unread `Bad` message (S2's part (c)) needs a cross-function dead-field analysis. The message is a static
  string (no allocation), so it saves a word and a count, not an allocation.

## 4. Expected effect, and a prediction of the 50 MB time

**Time model:** a straight line through the two hand versions, t = 0.61 s + 8.5 ns x allocations (S1: 158 M, 1.95 s; S2: 22.8 M, 0.80 s).
It gives 4.23 s for A2 pass on (measured 4.45 s, the rest being `fic_ap` and closures) and 7.7 s for pass off (measured 8.5 s, with 165 M
closures). It is good to about 10 %, and the slope includes the dup/drop/free work an allocation carries.

**Breakdown of the 427 M parse allocations.** It is estimated: the site table shows only the top 15, and the long tail (64 %) I could not
see.

| group | estimate | source |
|---|---|---|
| T: tree, vectors, slices (needed) | ~23 M | S2's total |
| P: paps 5 M, closures 6.7 M | ~12 M | W3 counters |
| O1: `State` boxes for `fic_ap1` in `oneOfHelp` | 43 M | sites 2, 3 |
| O2: results of the alternatives called through `fic_ap1` (Good + box, Bad) | ~63 M | 21 M Goods (= rebuilt count) x 2 + ~22 M Bads |
| O3: `oneOfHelp` rebuilds | 41 M | sites 4, 5, 9, 10 |
| C: `Step` cells and boxes in combinator chains, `More`/`Done`, the rest | ~245 M | remainder |

| rule | removes (estimate) | after |
|---|---|---|
| 1c case identity | O3: 41 M (high confidence) | ~386 M |
| 1a inline + rule A | 50-70 % of C: 120-170 M (depends on E1) | 215-265 M |
| 1b spine | O1 43 M, and makes O2 visible to 1a: ~50 M of O2 | 120-170 M |
| 2 unboxed results | ~85 % of the cells left at recursive boundaries (`loopHelp`/`stringBody` `More`, `sepByHelp`, `wordHelp`, the remaining O2): 60-100 M | 45-80 M |
| 3 scalar replacement | ~0 allocations; dups/drops toward S2's 53 M / 58 M | 45-80 M |

**Prediction at 50 MB:**
* **Rules 1, 1b, 2, 3:** 45-80 M allocations, 0.61 s + 0.5 s = 1.1 s from the line. With what the compiler keeps and S2 did not (the
  commit flags as data, the message, wrapper rebuilds, counts not removed by 3), **1.3 s, likely range 1.0 to 1.8 s**.
* **Without 1b:** 1c, 1a and 2 leave ~170 to 220 M, plus the remaining `fic_ap1` calls: **2.3 s, range 2.0 to 2.8 s**. That meets the old stage 1
  time target only at the good end.

## 5. Slice plan, gates, fuzzing, budgets

| slice | content | size | measurement after it |
|---|---|---|---|
| E | experiments E1 to E4 (section 7), no source change kept | half a day | go/no-go on the predicted shares |
| W5 | 1a (whatever E1 shows is missing for inlining the copies; Inline only, behind a switch) and 1c (case identity, retyping by layout); test known10 | ~300 lines | A2 1 MB and 50 MB |
| W6 | 1b spine keys in `M.Known` (static list detection, key, memo, budget, refusals in `FICCUS_KNOWN_STATS`); test known11 | ~300 lines | **checkpoint: 50 MB <= 2.6 s, allocations <= 200 M**, else stop and report |
| W7 | rule 2, new `M.Unbox`: worker set, slot layout, fillers, wrappers, call sites, sweep, `FICCUS_UNBOX_CHECK` (each wrapper is the case on its worker, every leaf matched, slot classes consistent); test known12 | ~350 lines | A2; the 16 suite programs (text changes only through Known clones) |
| W8 | rule 3 in `M.Unbox`: parameter split, dead fields, invariant result slot; tests known13, known14 | ~300 lines | A2 with dups/drops |
| W9 | validation only: full `gates.sh` with `KEEP=1` and the variant rows, elmdiff size and compile time, suite timing, final table, proposed decisions-file entry | machine time | final |

**Switches** (environment, read once, like `FICCUS_NO_KNOWN`):
* one per rule, so that each rule can be measured on its own: `FICCUS_S2_NO_INLINE`, `FICCUS_S2_NO_IDENT`, `FICCUS_S2_NO_SPINE`,
  `FICCUS_S2_NO_UNBOX`, `FICCUS_S2_NO_SRA`;
* `FICCUS_NO_STAGE2` (all of them off);
* `FICCUS_UNBOX_CHECK` (on in all tests).

**Every new switch goes into `rcfuzz.py` as a setting** (`s2off`, `noident`, `nospine`, `nounbox`, `nosra`) and into `known_tests.py`'s
settings.

**Fuzz shapes** (`libshape.py`, used by rcfuzz and v2fuzz):
* sum-returning recursive functions with 2 to 4 constructors and mixed field classes (reference, scalar, a record with a reference field);
* their results matched at a direct site, returned in tail position, stored in a list or record (wrapper path), and passed through a
  closure;
* records with a vector field threaded through a recursion that updates it (`Vector.update`, the take rule);
* static lists of functions consumed by a recursive function, and the same list also used as a value (refusal path);
* identity alternatives with an owned and with a borrowed scrutinee, and retyped `Bad`.

`rccheck_faults.py` gets the worker programs, so that a fault in a worker or wrapper must be caught.

**Gates after each slice:**
* `norc_identity.py` 16/16, never `--update`;
* pass-off identity: `FICCUS_NO_STAGE2=1` against K5 pass-on, and `FICCUS_NO_KNOWN=1` against A19, on the 16 programs and known1-9;
* `targets/run_all.py --san`;
* `known_tests.py` in all settings under ASan and `-O2`;
* rcfuzz and v2fuzz with 200 seeds per setting;
* `rccheck_faults.py`.

Full `gates.sh` (`KEEP=1`) after W7 (the broadest slice) and in W9.

**Size and compile time budget:**

| measure | budget |
|---|---|
| A2 C text | <= 1.5 x pass off (now 1.07 x) |
| A2 `.text` | <= 1.3 x |
| A2 compile time | <= 1.5 x |
| elmdiff total C bytes, pass on against off | <= 1.15 x |
| elmdiff total compile time, pass on against off | <= 1.2 x |
| program budget | the existing one (max(20,000, 1.0 x)), shared with stage 1 |
| per worker | <= 8 slot words |
| per spine | <= 8 cells |

## 6. Success numbers, and whether to limit the pass

**Stage 1** (`H16-DESIGN.md` 3.3) against the measured state:

| measure | target | measured | met? |
|---|---|---|---|
| 50 MB parse | <= 2.6 s and >= 3 x | 4.45 s, 1.92 x | no |
| 1 MB parse | >= 2.9 x | 1.90 x | no |
| allocations | <= 260 M | 427 M | no |
| closures | <= 10 M | 6.7 M | yes |
| C text | <= 2 x | 1.07 x | yes |
| `.text` | | 0.94 x | yes |
| compile time of A2 | <= 1.5 x | **not measured** (not in the W3 or K5 reports) | |

**Stage 2** (proposed):

| measure | target |
|---|---|
| 50 MB parse | **<= 1.6 s** (2 x hand S2) and >= 5 x pass off in the same session |
| 1 MB parse | >= 4.5 x |
| allocations (parse) | <= 100 M |
| dups | <= 120 M |
| closures | <= 7 M |
| code and compile time | the budget of section 5 |
| 16 suite programs | none more than 3 % slower, none with more allocations |

Stretch: 1.0 s.

**Limiting the pass to programs that benefit: no.** The 12 suite programs whose text changes (keyed specialization of library functions
such as `List.foldl`, `List.map` and `Array.initialize`):
* none is more than 3 % slower (worst `sieve_plain_hoist` +2.6 % at 5 ms, `fannkuch` +1.9 % with identical counters);
* none allocates more (`mandel` -45 k, `wordfreq` -200 k);
* the generated C grows at most 5 %, and `.text` is smaller or equal except `sieve_*` at +0.6 %.

A program-level limit would cost a heuristic and buy nothing measurable. The limit "functions with function arguments or that return
closures" changes nothing, since every specialization was already of that kind. Limit stage 2 per rule instead: rule 2 to Known's clones
(2.3), rule 1b to static spines (1b), with budgets (section 5). Re-measure the 16 after W7.

## 7. Open questions (need an experiment first) and the biggest risk

* **E1, why rule A does not fire today.** With W3's eligibility change on, dump (`FICCUS_KNOWN_STATS`, Inline's rule A/B counts) which
  specialized copies are inlined in A2 and which are refused, and why (size, `tProd`, SCC, the call going through the list). The 1a estimate
  (120 to 170 M) depends on it. **This is the biggest risk:** if the copies cannot be inlined for a structural reason, W5 grows and every
  later estimate shrinks with it (rule 2 then does the work of rule 1 at higher cost).
* **E2, complete site attribution.** All sites, not only the top 15, grouped by function and stage. In particular site 1 (26 M list cells
  at `List.lambda@261`): is it parse or generation? `genChars` (site 8) is generation. If site 1 is parse, it is a fifth group that no rule
  here removes.
* **E3, struct return in C.** A hand C micro-benchmark of a 5-word struct return (sret) with filler dups and drops against today's
  heap `Good` + box. Compile it with gcc, clang and TinyC, including a nested `State` struct inside a result struct (CGen.hs:316 suggests
  nested structs are supported; not verified for TinyC). Check that `fic_dup` and `fic_drop` treat `FIC_IMMORTAL` as a no-op on the inline
  path (the K5 report implies it for `fic_nul0`; I did not read the runtime code).
* **E4, `Bad` never freed** (site 14, 5.6 M, no free seen). Confirm that it is reuse, not a leak, under ASan with `FIC_NO_POOL`.
* **E5, compile time.** Stage 1 compile time of A2 and of elmdiff, pass on against off. It is in no report, and stage 2 adds to it.
* **Later:** `FICCUS_UNBOX_ALL` on the suite and elmdiff (2.3); the union encoding if the fillers cost (2.1); the `unres`
  `-Wfree-nonheap-object` warning (K5 report). Fillers use the same immortal sentinel, so the warning may appear in more programs.

## 8. What I could not check

* Nothing was built or run for this note. All allocation shares beyond the 15 attributed sites are estimates, and the prediction rests on
  a two-point line through hand-written programs.
* The `lambda@N` site names map to source lines of A2 at my reading (56 = `map`, about 172 to 215 = `symbol`/`chompIf`/`chompWhile`,
  439 = `stringBody`). The line numbers are those of the H15b/H16a copy of `JsonCombV.elm`. I did not verify the mapping against the
  generated C.
* I did not trace why rule A does not fire on the copies today (E1), whether the runtime's dup and drop skip immortal objects on the fast
  path (E3), or how records are constructed in the IR (I assume the existing record node can carry the filler atom; W7 may need a small
  `MKernel` filler instead).
* Compile time of stage 1 (not in any report), and whether the 16 suite programs' text changes further under rule 2 restricted to Known's
  clones (it should not, since their specializations are of non-sum-returning folds, but that is not checked).
