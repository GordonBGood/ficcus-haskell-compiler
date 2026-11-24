# H16 stage 2, slice W7a: rule 2, unboxed results of Known clones (version B: single clone SCCs)

Branch `feat/stage2-w7a` from `ficcus` e7b620c0, final binary `bin/elmficW7a`. Files: `compiler/src/Ficcus/Mono/Unbox.hs` (new), `CGen.hs` (the sentinel exit
check), `terminal/src/Make.hs` (the pass between Inline and Twin, the dumps, the post-Rc check), tests under `ficcus-tests/`. Design: `docs/H16-RULE2-DESIGN.md`
(decisions 1 to 7 accepted); estimate: `H16-W7-ESTIMATE.md` of `exp/w7-estimate`.

## What the pass does
* **Candidates:** a Function clone with clone id >= `base` (Known's first free id; Inline makes no clones: checked, X5), a result of class `CRef`, not in a call cycle
  of more than one clone (a self edge is allowed). Every tail leaf must be a constructor application, a tail call of another worker, or the forwarding of a let bound
  worker call that is only matched (`let v = g .. in case v of C .. -> .. v ..`, the output of rule 1c). Any other leaf (a variable, a library call, a global value)
  refuses the clone (no `case g .. of` re-box path for such leaves: design 3.3's boundary case for a worker calling a non worker is NOT built in W7a, see "Refused" below).
* **Layout (by leaf class, decision 1):** the struct is `refs, i64, f64, u32, enum (the tag first), unit`; each constructor's flattened leaves take the slots of their class
  in order; the slot count of a class is the maximum over the constructors; at most 8 words. A family (the workers that tail call each other) shares one layout (union of
  its constructors). A `Good c a s` of `Step ()`/`Step Int`: 3 words; of `Step Json`: 4 words (`p p i e e`).
* **Worker `f~unbox`** (new clone id): same parameters, same body, tail constructor leaves become the struct (reference slots not used by the constructor hold the counted
  sentinel `fic_nul0`, scalar slots 0), tail calls become worker calls (self tail calls stay `continue`). **Wrapper** (the original id): `case f_w .. of {slots} -> C ..`,
  the only place a cell is built. Every `case f args of` with plain constructor patterns, in any clone, calls the worker and matches the slots: one tuple pattern of every
  slot, the tag selects the alternative; the Rc pass takes the struct apart with `MUnpack` (checked by `FICCUS_UNBOX_CHECK`, `Unbox.checkCounted`). A struct field of a
  constructor (the parser `State`) is flattened into slots at the producer (`case s of {src, offset}` unpack) and rebuilt from the slots at the consumer.
* **Identity after unpack (decision 3), generalized:** in the alternative for constructor k of a rewritten site the reference slots k does not use are the sentinel with one
  count; a tail constructor leaf takes them (a move) for its own filler slots instead of dropping them and counting fresh ones (3 in A2's 26 sites at the stats build, 7 in
  known15). A leaf `v` (the let bound scrutinee returned unchanged, rule 1c) becomes the constructor of the alternative rebuilt from the slots, so a retyped identity
  (`Bad _ _ -> id` at another `Step b`) needs no family union with the callee and the type check passes; a default alternative forwards the whole struct.
* **Exit check (decision 7):** a program with workers ends with `if (fic_live_objects == 0 && fic_nul0.rc != FIC_IMMORTAL) -> "FIC_UNBOX_CHECK: the count of the sentinel
  drifted by N"` under `-DFIC_UNBOX_CHECK` (generated only when a worker exists; `fic_rt.h` and the other programs' text are unchanged).
* **Switches:** `FICCUS_S2_UNBOX_ACYCLIC=1|0` (unset: on), `FICCUS_S2_NO_UNBOX=1`, `FICCUS_S2_NO_UNBOX_IDENT=1`, `FICCUS_S2_UNBOX_NOVEC=1` (needs the field types of
  `mpUnions`: sees a field declared with a Vector/Array type, not a type parameter instantiated with one), `FICCUS_UNBOX_CHECK=1`, `FICCUS_UNBOX_STATS=1`,
  `FICCUS_INLINE_DUMP=t`, `FICCUS_UNBOX_DUMP=t`; see `docs/FLAGS.md`.

## Step 0 (before the timings): the biggest risk, broken chains
`FICCUS_UNBOX_STATS` on A2 (JsonCombV, 1 MB): 146 candidate clones, **107 workers, 39 refused**. Refusals: 24 in call cycles (B, as designed; 33.3 M of the 108.8 M removable
allocations at 50 MB), 6 `wordHelp` (original id 121 < `base`, so not a Known clone) and 3 forwarders that tail call it (3.9 M), 6 clones that are not `Step` producers
(`always`, `apply`, `List.foldl`). **No forwarder or identity pass of the acyclic hot chains is refused** by the leaf rule or the 8 word limit (workers have 2 to 4 words).
Static prediction (workers' removable allocations from the estimate's site table): 71.5 M at 50 MB, estimate 70.6 M. B did not slide towards the spine only version.

## Results (P1 A2, parse = stage 2 minus stage 1, median of 5, checksum `nodes=87689 sum64=237203670393` correct in every run, machine load 0.8 to 1.3)
| | pass off (`FICCUS_NO_KNOWN=1`) | W6 | **W7a** |
|---|---|---|---|
| 50 MB parse time | 8,151 ms | 1,785 ms | **1,246 ms** (-30 % vs W6; 6.5 x pass off) |
| 50 MB parse allocations | 832.1 M | 156.9 M | **90.35 M** |
| 50 MB dups / drops | 928.9 / 713.7 M | 196.1 / 185.9 M | 167.0 / 169.0 M |
| 1 MB parse time / allocations | 169 ms / 17.69 M | 37.5 ms / 3.33 M | 25.4 ms / 1.92 M |
| C text / `.text` | 645 / 109 KB | 710 / 81 KB | 835 / 75 KB (1.29 x / 0.68 x of pass off; budget 1.5 x / 1.3 x) |
| compile time A2 (`--rc`, median of 5) | 0.913 s | 0.996 s | 1.084 s (1.19 x pass off, 1.09 x W6; budget 1.5 x) |
| compile time, 16 suite programs (total) | 10.625 s | 10.685 s | 10.636 s (1.00 x) |
Checkpoint (B above 1.5 s or above 100 M allocations at 50 MB): not reached. Predicted B (estimate): 1.25 s, 86.3 M. W7-K (hand): 1.25 s at k = 8.0.
Dups are not what the time follows; 167 M is above the estimate's 163 M by 4 M (fillers on `Bad`).

**Remaining allocation sites (A2, 1 MB, 1.66 M attributed of 1.92 M):** the cyclic `lambda@67:5` copies (`value -> jarray/jobject -> value`): State box 270 K, `Good` 230 K,
`Bad` 159 K = 659 K (34 %, W7b); `More ()` 150 K (9 %, W7c); the number parser's closure entry `lambda@83:5` box 58 K + `Good` 33 K + box 33 K; the stage 2 tree walk (`Tree.fold`,
`foldlHelp`, entry boxes) 8 %; `oneOfHelp` 99 K (the cyclic `oneOfHelp` copies and the wrappers of the closure entries); `sepByHelp` 64 K; `wordHelp` 55 K (not a Known clone).

## Tests
`known14` (three constructors of mixed leaf classes; every use of a result: matched, tail call, self tail loop, non tail recursion, stored in a list and a record, closures,
wildcard and nested patterns), `known15` (four constructors, slots shared across them, identity after unpack at the same and at another type, owned and borrowed, a producer with
a local loop), `known16` (the vector shapes V1 to V5 on `Array`: in place / copied counters equal with the rule off: 15 / 63), `known17` (must not fire: a library result, a
result taken from a list, a call cycle, 10 + 10 fields over 8 words, results used only as values: 0 workers). Goldens from Elm 0.19.3 (`ficcus-tests/golden.py`).
`known_tests.py` settings `unbox`, `no-unbox`, `no-unbox-ident`, `unbox-novec` (all known1 to known17 pass in every setting under ASan + UBSan and -O2 with
`-DFIC_UNBOX_CHECK`); `unbox_tests.py` (rule on/off outputs equal the golden, in place/copied counters equal, workers expected or none, `--no-rc` text identical);
`rccheck_faults.py` with known14 to known16 (220 mutations, 0 missed); `libshape.unbox_shape` in rcfuzz and v2fuzz (four constructors, identity, `Vector` shapes V1 to V5,
loops, recursion; the programs of earlier seeds are unchanged up to a section at the end), rcfuzz settings `unbox`, `unboxnoident`, `unboxnovec`, `nounbox`.
`w7a_identity.py`: `--no-rc` (also with the rule on), `FICCUS_NO_KNOWN=1`, `FICCUS_S2_NO_UNBOX=1` and all stage 2 switches off: the 16 suite programs byte identical to
`elmficW6`; with the rule on 15 of 16 identical, **`bintree` changes** (1 worker, 1 unpacked site: time 175.6 ms against 175.7 ms, 0.0 %, no warnings).

## Checks
gcc and clang `-Wall -Wextra` at -O1, -O2, -O3 on A2 and known12 to known17: no `-Wfree-nonheap-object` (and no new warning: an unused alias `let` was dropped). Stack: the
worker frames in A2 are 48 and 64 bytes at gcc -O2 (`-fstack-usage`), the largest frame of the program 256 B (240 B with the rule off); X6 (a deep non-tail recursion through
a worker, compared by depth) was NOT measured: no test program has a worker in a non tail recursion that is deep enough to tell (the deep recursion of A2, `value -> jarray`, is
a call cycle and not a worker in B). X3 (sret tail calls): worker to worker tail calls exist in the A2 chain (`oneOfHelp` and its forwarders); ASan/-O2 runs and the 50 MB run
have no stack growth (the process uses the same 783 MB at 50 MB as before).

## Refused, and what is left for W7b and later
* Cycles (B): the `lambda@67:5` copies, two `sepByHelp`, two `lambda@468:5`, `oneOfHelp` copies in a cycle: 33.3 M allocations (W7b: SCC all or nothing, worker to worker sret tail calls).
* A worker whose tail callee is not a worker is refused instead of re-boxing with `case g .. of C -> {..}` (design 3.3): with A2's chains it costs the 3 forwarders of `wordHelp`
  (1.4 M allocations at 50 MB); W7b needs the full constructor table (from `mpUnions` with the key) for it.
* `wordHelp` and other original (not Known) clones: id < `base`.
* `More ()` (150 K allocations at 1 MB): W7c.
