# H16 rule 2 design: unboxed results of Known clones (W7a, W7b)

Written for: the user and the session that implements W7a/W7b. Branch `design/rule2` from `ficcus` e7b620c0. No source change, nothing built.
Read: `docs/H16-STAGE2-DESIGN.md` (2.1 to 2.3, 3, 5), `H16-STAGE2-EXPERIMENTS.md` of `exp/stage2` (E3, E6), `H16-W7-ESTIMATE.md` of `exp/w7-estimate`
(classification, versions A and B, risk, test shapes 1 to 8), `docs/W7-K/README.md` of `exp/w7-k` (hand conversion, findings 1 to 7), and the code cited below.
`M.` = `compiler/src/Ficcus/Mono/`. A2 = P1 `JsonCombV`, 50 MB unless said otherwise.

## 0. State and targets

| | W6 (measured) | W7-K, 2 chains by hand (measured) | B, acyclic (predicted) | A, full (predicted) | target |
|---|---|---|---|---|---|
| parse time | 1,790 ms | 1,490 to 1,537 ms | 1.25 s (1.23 to 1.54) | 0.94 to 1.1 s | <= 1.6 s |
| parse allocations | 156.9 M | 119.5 M | 86.3 M | 48.1 M | <= 100 M |
| dups (informational) | 196 M | | 163 M | 147 M (per-field fillers) | report only |

k = 8.0 ns per removed allocation (W7-K, 7.7 to 8.3); the B range uses k = 3.9 (E3 floor) as its upper end. Scope: `M.Known` clones and their SCCs; `FICCUS_UNBOX_ALL` later.

**Pipeline.** `terminal/src/Make.hs:232` today: `Rc.rcProgram (Twin.twinProgram (Inline.inlineProgram known))`, counted builds only. W7 inserts
`Unbox.unboxProgram base` between Inline and Twin. `base` = 1 + the largest clone id of the program given to `Known.knownRun` (Known numbers its new clones from
there, `Known.hs:182`), so "a Known clone" = a clone id >= `base`. This needs no change in Known; it does need that Inline makes no clones of its own with ids
in that range that are not Known's (I did not check Inline for clone creation; if it makes any, they are equally specialised and may be admitted).

## 1. Result encoding: slot layout

### 1.1 The options and what each costs per result

The worker returns `CStruct (CU32 tag : slots)`. W7-K found that the per-field rule of design 2.1 ("share a slot when the field class is equal") leaves a
reference filler on every `Good` of a key whose `a` is a scalar or a struct, because `m : CRef` can share neither `a : u8` nor the `State` struct.
`Class` (`Class.hs:29`) is `CI64 | CF64 | CU32 | CEnum | CUnit | CRef | CStruct [Class]` (plus the sized ints), and `Vector`, `String` and custom types are all `CRef`.

Filler counts per result (dup at the producer + drop at the consumer; each is a read-modify-write of the static's count, E3 / E6(b)):

| key of `Step` | fields: Good / Bad | (a) per field (design 2.1) | (b) by leaf class (recommended) | (c) tagged (union) | (d) fillers only for Bad |
|---|---|---|---|---|---|
| `a` scalar (Char, Int, Float, `()`): W_A | `c a {src off}` / `c m` | Good 1+1 (`m`), Bad 1+1 (`src`) | **Good 0, Bad 0** | 0 / 0 | Good 0, Bad 1+1 |
| `a` = `Json` (ref): W_B | `c a {src off}` / `c m` | Good 0, Bad 1+1 | Good 0, Bad 1+1 | 0 / 0 | Good 0, Bad 1+1 |
| `a` = `(Vector, Json)` | `c (v j) {src off}` / `c m` | Good 1+1, Bad 3+3 | Good 0, Bad 2+2 | 0 / 0 | Good 0, Bad 2+2 |
| slot words (W_A / W_B) | | 32 B / 32 B (W7-K) | 24 B / 32 B | 24 B / 24 B | as (b) |

(b) Leaf-class layout: flatten every constructor's fields to their leaves (a struct field contributes its leaves in order), and give each leaf class the
number of slots that the constructor with most leaves of that class needs. Constructor k puts its i-th leaf of class X in slot X_i. Fillers are needed only for
the deficit: `max over constructors (refs) - refs of k` reference fillers on k. This is the slot count minimum for leaves of distinct classes, needs no union
and no type punning (every slot has one C type), and is what W7-K finding 1 asks for.

(c) needs "component valid only under tag k" in Rc, RcCheck and `unpackDrops` (CGen.hs:998 drops every untaken leaf): rejected for W7, as in design 2.1. E3
measured it 15 to 45 % faster than fillers on a 2 ns step; with (b) most of the difference is gone (W_A has no filler left).

(d) as a layout is the same as (b) for `Step`; "no filler on Good" is what (b) gives by construction, while a Good without a counted value in a reference slot
would again need tag-guarded drops, i.e. (c).

### 1.2 Cost of (b) in the IR, and its soundness

* **Producer leaf** `Good c a s`: the worker emits `case s of {src, offset} -> {tag = 0, c, a, r0 = src, i0 = offset}` (a record pattern on a struct that dies:
  `Rc.unpackable`, Rc.hs:555, gives `MUnpack`, moves, no count), never `s.src`/`s.offset` accesses (the first access is not dying, so it would be a dup and a
  later drop: Rc.hs:259). When `s` is a record literal (`{ s0 | offset = .. }` after lowering) the fields go straight into the slots.
* **Consumer branch k:** the call-site record pattern binds every slot (section 3.1); branch k rebuilds a struct field from its leaves with `MRecord` of
  locals (moves; CGen.hs:612 compound literal). No new IR node, as E3 found for the filler (`MLit 0`, `MCtor n 0 key` in `MOwn`, `MRecord` of fillers).
* **Filler atom:** always the tag-0 nullary constructor so that every reference filler is `fic_nul0` (a filler of another tag would be `fic_nul1`..., which spreads
  the balance over several statics; section 4).
* **Soundness:** identical to design 2.1, since (b) only changes which slot a leaf travels in: every slot is written exactly once at the producer with an owned
  value (a moved leaf or a counted filler), and at the consumer every slot is either moved into a variable or dropped by `unpackDrops`/liveness. Rc counts
  slot variables like any struct component; RcCheck checks it (`MUnpack`, RcCheck.hs:226: no component taken twice, each variable gets its count; every
  `withOwned` variable must end at 0, RcCheck.hs:150). Slots shared by leaves of different fields of different constructors are distinguished only by the tag,
  and the tag selects the branch statically (the `if tag == k` dispatch), so a branch never reads a leaf of another constructor as its own.

**Recommendation: (b), counted fillers.** Expected filler pairs at 50 MB: A2's W_A keys 0 (per-field: about 1 pair per Good, W7-K measured step 1 at +4.7 M
dups and drops net for one chain), W_B and pair keys 1 or 2 per `Bad` only. The estimate's +18.1 M dups for A (1 per Bad) is then an upper bound; with (b)
I expect about half of it (the Bad split by key was not measured; open question X4), i.e. dups for A about 140 M rather than 147 M.

### 1.3 Immortal skipping (no `dup`/`drop` on known filler slots): not in W7

Skipping counts on fillers is sound only if *every* producer and *every* consumer of a filler slot skip together. Today one consumer cannot know: `unpackDrops`
drops every untaken leaf without looking at the tag, and the wrapper and the viewBranch path drop whole structs. A one-sided skip makes `fic_nul0`'s count drift by
one per result (down when only the producer skips: it reaches 0 after 2^30 net drops and is freed, E3). Doing it right needs a `Filler` atom in Rc (no `MOwn`),
RcCheck treating a known filler slot variable as immortal (count 0 allowed), and tag-aware drops in CGen: three modules that W7 otherwise leaves alone.
With (b) the gain is at most the Bad fillers of ref keys. **Decision proposed: no skipping in W7; revisit only if X4 shows Bad filler pairs above about 10 M at 50 MB.**

## 2. Identity after unpack

W7-K finding 3: `f262`'s `Bad c m -> if c then Bad c m else ..` after the struct match drops the dead `src` filler and builds a fresh one (one pair of `fic_nul0`
RMWs) where `return r` would do. Rule 1c (identity on the heap cell) cannot see it after Unbox, since the scrutinee is no longer a cell.

**Rule (in `M.Unbox`, at call-site rewriting): filler forwarding.** In branch k of a rewritten call site, a leaf `C_j x1..xn` of the worker's own result type is
built as a record whose slots take, in this order: (1) the leaf's own values; (2) for a slot that needs a filler, a **bound slot variable of the matched struct
that is a filler in branch k** (a slot not used by constructor k: its value is statically the sentinel), of the same class, not used elsewhere on that path;
(3) a fresh filler. When j = k, the layouts are equal and every `xi` is the pattern variable of the same slot, this is exactly "return the unpacked result
unchanged" (all slots moved, no count).

Conditions:
* the outer result key equals the matched key (same layout, so the same slot holds the same leaf class); for a retyped `Bad` (`Step a` matched, `Step b`
  returned) only step (2) applies, slot by slot, where the classes agree;
* a forwarded variable is used once on that path (it is moved), and on other paths it is dropped by liveness as before;
* not when the branch is a `viewBranch` (the struct is still used in the branch): then the slot variables are views and moving one would be a second owner.
  With the call-site form of section 3.1 the struct variable is never used in a branch, so `unpackable` holds; Unbox asserts it in `FICCUS_UNBOX_CHECK`.

Soundness: a filler slot variable in branch k owns one count on the sentinel (the producer's dup). Moving it into the result instead of dropping it and dup'ing
a fresh one leaves the sentinel's count unchanged on that path; RcCheck sees an ordinary move. In the non-k path the variable is dropped as before. The values are
equal (the sentinel is one object). Switch `FICCUS_S2_NO_UNBOX_IDENT=1`. Gain: one pair per `Bad` that passes through an identity branch (`lambda@67:5` copies:
71.6 K of 91.7 K calls of f242 at 1 MB, mostly `Bad`).

## 3. Boundary, SCC and entry rules, wrappers, tail calls

### 3.1 Worker, wrapper, call sites

* **Candidates:** a Known clone (id >= `base`) whose result class is `CRef` of a custom type with at least 2 constructors at its key, with leaf-class layout
  <= 8 slot words, and whose body leaves are constructor applications, tail calls of candidates, or identity forwards (2); refused when more than half of the
  leaves are other expressions (design 2.1).
* **Worker `f_w`:** same parameters (Borrow infers them again; an `MRecord` owns its components as a constructor does, Borrow.hs header, so a parameter that
  was stored in a `Good` is owned in the worker too, and the inference result is the same).
* **Wrapper `f`** (the original id and C name): `case f_w ps of {tag, slots} -> if tag == 0 then C_0(..) else ...`. It is the only place that allocates a
  result cell, and it is swept when it has no uses.
* **Call sites, rewritten in every clone (worker or not):** `case f args of alts` -> `case f_w args of {tag, s..} -> if tag == k then alt_k`, the pattern
  binding every slot, the struct variable never used in a branch (so `unpackable` fires, `MUnpack`, CGen.hs:543). A tail position in a worker of the same key
  -> `f_w args`. Every other use (`let x = f args`, an argument, a field, a value use, a closure entry) calls the wrapper.

### 3.2 Where the boundary is, and how to keep it small

The boundary is any point where a worker's result becomes a cell: a wrapper call. Since call-site rewriting applies to non-workers as well, a non-worker that
*matches* a worker result never allocates; the boundary is only where a non-worker *returns* (passes on) a worker result: tail calls of a worker from a
non-worker, its identity branches, value and closure uses, callers outside the Known set. W7-K finding 4 (a reused `Bad` cell becomes a fresh allocation) is
the case "consumer converted to match the struct, consumer's own result still a cell": in A and B the consumers in the chain are workers too.

Rules:
1. **SCC all or nothing (A):** the worker set is closed under the SCCs of the call graph (`Graph.stronglyConnComp` over `exprRefs`, as `Known.mkInfo`,
   Known.hs:149, on the clones after Inline): if one member is refused the SCC is refused. Reason: tail calls (3.3) and no boundary inside a cycle.
2. **Pass-through closure:** a non-worker clone in the Known set whose leaves are only tail calls of workers and identity forwards (the `lambda@109:5`
   forwarders) is a worker by the leaf rule; nothing extra is needed, but `FICCUS_UNBOX_STATS` lists every refused candidate that has a worker callee in tail
   position, so a broken chain is visible.
3. **Boundary counter:** `FICCUS_UNBOX_STATS` reports per wrapper its static use count by kind (value, entry, non-Known caller, other). Dynamically, wrapper
   allocations are ordinary `FICCUS_ALLOC_SITES` sites named after the wrapper; the W7a report lists the top 10.
4. **Refusal heuristic:** a candidate whose static uses are more than half wrapper uses is refused (its results would be re-boxed more often than matched).
   Not needed for soundness; a knob.

### 3.3 Tail calls and stack

* A self tail call of a worker stays `continue` (CGen.hs:489-505: the loop concerns arguments only).
* Worker to worker of the same key in tail position: `return g_w(..)`, an sret tail call. W7-K finding 7: gcc -O2 compiled it without stack growth. Elm
  guarantees only self tail calls (CGen.hs:14), so this is never worse than today.
* Worker to non-worker in tail position (B only, a worker calling into a cycle): becomes `case g(..) of C -> {..}`, not a tail call; one extra frame, bounded,
  because the callee's cycle cannot reach the worker back (otherwise the worker would be in that cycle). Non-worker to worker in tail position: the wrapper's
  frame, also bounded. Rule 1 makes this impossible inside a cycle in A.
* Non-tail recursion (the JSON nesting `value -> jarray -> value`): each frame grows by the result struct (24 to 40 B in the caller's frame for sret). Depth is the
  nesting depth (12 in A2), but test shape 7 (deep non-tail recursion) must compare the maximum depth reached against pass off (X6).

## 4. Sentinel balance check

Three layers, from static to dynamic:

1. **RcCheck (static, always on in tests).** Fillers are ordinary counted values: `MCtor` in `MOwn` at the producer (RcCheck.hs:184 already refuses an
   uncounted one), slot variables bound by `MUnpack` must be consumed on every path (RcCheck.hs:150, 226). A missing drop of a dead filler slot is a "count
   left at the end of its scope" error. **No RcCheck change is needed** as long as no filler is skipped (1.3). `rccheck_faults.py` gets worker programs with three
   injected faults: a dead filler slot not dropped in one branch, a filler without `MOwn`, a forwarded filler used twice (2).
2. **`FICCUS_UNBOX_CHECK=1` (compile time, structural, on in all tests):** each wrapper is a case on its worker with every tag matched; every call-site pattern
   binds every slot with the slot's class; every reference filler is the tag-0 nullary constructor; branch k reads only constructor k's slots plus forwarded
   fillers (2); slot classes agree between producer leaves and the layout; `unpackable` holds at every rewritten site (counted: rewritten sites, `MUnpack`
   sites, sites that fell to `viewBranch`; the last must be 0).
3. **Exit check (dynamic, `-DFIC_UNBOX_CHECK`):** emitted by the generator, only in programs where Unbox made a worker (a header change moves the text of all
   16 suite programs, E6(a)): at exit, when the `FIC_STATS` live count is 0, `fic_nul0`'s count must equal `FIC_IMMORTAL`; else print the delta and abort.
   With live objects left at exit (globals holding `[]`, `Nothing`), compare the delta with the same program built with `FICCUS_S2_NO_UNBOX=1` on the same
   input: equal deltas required. W7-K used exactly this check (delta 0).

**Fuzzing:** rcfuzz and v2fuzz compile with `-DFIC_STATS -DFIC_UNBOX_CHECK` in every unbox setting and fail on an abort; the delta comparison against the
`nounbox` setting is the oracle when live is not 0. This makes the count impossible to drift silently: RcCheck catches the IR, the exit check catches CGen.

## 5. The owned `Vector` field after unpack

**What changes.** A leaf that came out of a heap cell was either moved (`MSpec`, unique cell), dup'd (`viewBranch`, when the branch consumes it) or a view
(only read). After `MUnpack` it is an owned local in `env` (Rc.hs:540-544). `takeCall` (Rc.hs:633) fires on `unsafeGet i t` when `t` is an owned local of `env`,
not live after, and every later use is `unsafeSet` at the same `i`. Before, a vector that is updated was consumed, so it was dup'd into `env` by `viewBranch` or
moved by `MSpec`: the take already had the chance. The difference is only where the dup was: (heap) dup of the field and drop of the cell; (struct) a move.

**Why the outcome cannot change.** The take is decided statically from liveness and is safe at any count: `fic_vector_take` / `fic_ja_take` test `rc == 1` at
run time and give a counted copy for a shared container (runtime/fic_jsarray.h:57-64, fic_vector.h:296). The in-place/copied outcome of the later `set` depends
only on the container's count at that moment. For a fresh result the struct path gives the leaf the same count as the heap path after the cell's death:
a unique cell's free cancels its dup (design 2.1); a shared result cell can arise only from a non-constructor leaf (a borrowed scrutinee returned by identity,
rule 1c), which the worker turns into `case e of C.. -> {..}` with a dup of each reference leaf, so the extra owner is counted in both encodings.
Hence: **same counts, same in place / copied, up to the removed dup/drop pair of the cell.** No restriction is needed for B.

Expected results (to be test shapes V1 to V5; "inplace/copied" = `FIC_STATS` counters, which must equal the `nounbox` setting):

| shape | Elm | expected with unbox | in place or copied |
|---|---|---|---|
| V1 unshared | `case step v of Good r -> Vector.update i f r.vec` (`v` dead after) | vec leaf moved, 0 dups on it, take fires | in place |
| V2 shared | the caller keeps `v` and reads it after the match | producer dups `vec` (owned position, borrowed or live arg): rc 2 | copied (the take gives a counted copy; the set copies) |
| V3 loop | worker self tail loop that updates its vector parameter and returns `Good` with it each step | parameter owned (stored in result), `continue` | in place on every step after the first unique one |
| V4 after Bad | `case w x of Bad _ m -> v0; Good r -> update r.vec` with `vec` sharing a reference slot with `m` (leaf layout) | Bad branch drops `m` (a String in the shared ref slot); Good branch moves `vec` | in place; no vector op ever sees the slot in the Bad branch (tag guarded) |
| V5 read twice | `r.vec` read by `Vector.get` and then updated | the second use is not an `unsafeSet`, `updatesOf` gives Nothing, no take | vector in place if unique; the element is copied (as today) |

Also: the vector reached as `s.src` through a bound `State` variable is an `MAccess`, not an `MLocal`, so the take needs the field bound by a pattern (Unbox's
record-pattern rebuild in 1.2 gives a local only for slot leaves; a nested field accessed later stays an access, as today). Not a soundness issue, only a missed take.

**Not exercised by W7-K** (finding 6: `src` is only read). Safety net: switch `FICCUS_S2_UNBOX_NOVEC=1` refuses workers whose layout has a reference leaf of
type `Vector`/`Array`; a fuzz setting `novec`; if V1 to V5 differ from `nounbox` in any counter, W7a ships with `NOVEC` as the default and stops for a decision.

## 6. B before A

* **Filter `FICCUS_S2_UNBOX_ACYCLIC=1`:** the call graph of 3.2 rule 1 (clones after Inline, edges = `exprRefs`, value references included). A candidate is
  admitted in B when its SCC is trivial: a single clone, a self edge allowed (`loopHelp`, `wordHelp`: self tail loops are `continue`, non-tail self calls call
  `f_w`). This matches the estimate's split (acyclic 65 % of class (a), 70.6 M at 50 MB).
* **What A adds:** the non-trivial SCCs: the 8 `lambda@67:5` copies of `value`/`jarray`/`jobject`, the two `sepByHelp` copies, two `lambda@468:5` (38.2 M).
* **Soundness specific to the cycle:** none in the counting. Rc and RcCheck work per clone; Borrow is a fixed point over all clones, so mutual recursion is
  covered already (Borrow.hs header). What is specific: (i) tail calls between members (3.3; `return g_w` must be checked at -O2 with gcc and clang, tcc does
  no sibling calls today either), (ii) stack per frame (X6), (iii) all-or-nothing refusal, so a cycle with one refused member stays boxed entirely, (iv) members
  of one SCC with different result keys each get their own layout; a tail call implies equal result type, so a cross-key tail call cannot occur.
* **Order:** W7a implements the whole machinery with the filter fixed to B (A's SCC code path exists but is off); W7b turns it on, adds the cross-worker tail
  call and the all-or-nothing rule, and keeps `ACYCLIC=1` as a switch, so the B measurement can be repeated at any later point.

## 7. Slice plan

| slice | content | size | measurement |
|---|---|---|---|
| W7a (B) | new `M.Unbox`: candidates (`base`), leaf-class layout, fillers, worker, wrapper, call-site rewrite in all clones, tail in worker, filler forwarding (2), sweep, `FICCUS_UNBOX_CHECK`, `FICCUS_UNBOX_STATS`, exit check; Make.hs one line; switches `FICCUS_S2_NO_UNBOX`, `_UNBOX_ACYCLIC` (forced on), `_NO_UNBOX_IDENT`, `_UNBOX_NOVEC`; test known12 | ~300 lines | A2 1 MB and 50 MB; **checkpoint: stop and report if B is above 1.5 s or above 100 M allocations at 50 MB** |
| W7b (A) | SCC all-or-nothing, cycle members, worker-to-worker sret tail calls, boundary report; test known13 (cycle) | ~150 to 300 lines | A2; expected 0.94 to 1.1 s, <= 60 M allocations; stop if above 1.6 s |
| W7c (optional) | float `More ()` (a constructor with only constant fields) to a static immortal object (Known/Inline; CGen needs static objects of non-nullary constructors: not checked whether it has them) | ~100 to 150 lines | -7 M allocations, -28 to -60 ms |

**Gates after each slice** (as design 5): `norc_identity.py` 16/16 without `--update`; pass-off identity (`FICCUS_S2_NO_UNBOX=1` = W6 text, `FICCUS_NO_STAGE2=1`
= K5 pass-on, `FICCUS_NO_KNOWN=1` = A19) on the 16 programs and known1 to 11; `run_all.py --san`; `known_tests.py` in all settings under ASan and -O2;
rcfuzz and v2fuzz 200 seeds per setting; `rccheck_faults.py`; full `gates.sh` with `KEEP=1` after W7a and after W7b.
`--no-rc` is identical by construction (Unbox is only in the `rcMode` branch, Make.hs:232).

**Fuzz additions** (`libshape.py`, used by rcfuzz and v2fuzz; new settings `nounbox`, `acyclic`, `noident`, `novec`, each built with `-DFIC_UNBOX_CHECK`):
the 8 shapes of the estimate (section 4 there), plus
* S9 consumers with 2 to 4 constructors where each branch leaves a different set of slots dead (filler drops), with mixed leaf classes so that slots are shared
  across constructors (ref with ref of another field, Float with Float, a struct field split over slots);
* S10 identity after unpack: `Bad c m -> if c then Bad c m else ..` at the same key, retyped key, owned and borrowed scrutinee;
* V1 to V5 of section 5, with the `inplace`/`copied` counters compared with `nounbox`;
* fault programs of section 4 for `rccheck_faults.py`.

**Code size budget:** A2 C text <= 1.5 x pass off (now 1.10 x); `.text` <= 1.3 x; elmdiff total C bytes <= 1.15 x pass off; compile time <= 1.5 x (A2) and
<= 1.2 x (elmdiff); per worker <= 8 slot words. The W7a report gives the number of workers, wrappers kept, wrappers swept, and the text growth by each.

**gcc warning block (`unres`, decisions rev 169):** fillers put `&fic_nul0` into straight-line code, which is what made gcc report `-Wfree-nonheap-object` in
`unres`. The decided generator block (opaque `free` only in programs where Known made copies) covers every worker program, because workers exist only in Known
clones. Gate: A2, known12/13 and the fuzz programs compiled with `gcc -Wall -Wextra` at -O1/-O2/-O3 give no `-Wfree-nonheap-object`; if Unbox makes a worker
where Known's counters are empty (it cannot, by the `base` rule), the condition must be widened to "Known made copies or Unbox made workers".

**Immortal skipping:** not in W7 (1.3). Recorded as a decision with the condition to revisit.

## 8. Open questions (experiment first) and the biggest risk

* **X1, acceptance of the hot clones.** Dump `FICCUS_UNBOX_STATS` on A2 before any timing: which of the 34 hot clones of the estimate are workers, which are
  refused and why (slot words, leaf rule, SCC). The A and B predictions assume every hop is a worker.
* **X2, the `case`-site form at the Rc level.** That `case f_w(..) of {all slots}` with the struct unused in every branch really goes through `unpackable`
  (Rc.hs:555 needs `PVar`/`PWild` of exactly the field class; the `_` path of `rcCase`, Rc.hs:512-519, binds the call to a fresh owned `t`). Read, not run.
* **X3, sret tail calls** between workers in gcc and clang at -O2 for a 24 to 40 byte struct (W7-K saw it for one forwarder only).
* **X4, `Bad` per key.** The `Bad` counts per result key at 1 MB, to fix the filler pairs left by (b) (my guess: about half of the estimate's 18.1 M).
* **X5, `Inline` and clone ids.** Whether Inline creates clones (then `base` admits them too) and whether `knownRun`'s safety fallback (`closed-check-fallback`,
  Known.hs:174) can leave a program with ids >= `base` that are not Known clones (it returns the input clones, whose ids are all < `base`: should be fine).
* **X6, stack.** Maximum non-tail depth reached by a deep recursive shape with and without unbox (frame growth by the sret struct).

**Biggest risk:** not soundness but **broken chains**: the leaf rule or the 8-word limit refusing a forwarder or an identity pass in the middle of a hot chain,
which turns the removed cell into a boundary allocation (W7-K finding 4) and moves B towards the S row of the estimate (-13 %, 1.55 s). X1 answers it in one
build. The largest soundness risk is section 5 (the owned vector leaf), argued sound above but not exercised by any run; V1 to V5 and `NOVEC` cover it.

## 9. Decisions for the user

1. Slot layout by **leaf class** (b), counted fillers, instead of per field (design 2.1 changes).
2. **No immortal skipping** in W7; revisit only if X4 shows more than about 10 M Bad filler pairs.
3. Identity after unpack as **filler forwarding** in `M.Unbox` (2), with `FICCUS_S2_NO_UNBOX_IDENT`.
4. **SCC all or nothing** in A; B = trivial SCCs (self edge allowed).
5. Known clones identified by **clone id >= `base`** (no Known change).
6. No restriction on `Vector` leaves in B, with `FICCUS_S2_UNBOX_NOVEC` as the fallback and the V1 to V5 counters as the gate.
7. Exit check emitted by the generator only in programs with workers (not in `fic_rt.h`).

## 10. What I could not check

* Nothing was built or run; every line reference is from reading `ficcus` e7b620c0.
* Whether Inline creates clones (X5); whether CGen can emit a static immortal object of a constructor with fields (W7c).
* That the call-site form reaches `MUnpack` and not `viewBranch` in all cases (X2); the sret tail call at -O2 beyond W7-K's one forwarder (X3).
* The `Bad` counts per key (X4), so the filler-pair figure for (b) is a guess.
* The ficcus-tools scripts (`rcfuzz.py`, `v2fuzz.py`, `libshape.py`, `rccheck_faults.py`) were not read; the new settings follow the pattern the design note
  describes.
* The text of decisions rev 169 (the opaque `free` block) was not read; I used the E6(a) proposal as its content.
