# H16 stage 2, slice W6: rule 1b (spine specialization) and a second Inline pass

Branch `feat/stage2-w6`, based on `ficcus` 5dec9ccd (binary `elmficW5`), final binary `bin/elmficW6`. Files: `compiler/src/Ficus/Mono/Known.hs` (rule 1b),
`Inline.hs` (second pass), `terminal/src/Make.hs` (`FICUS_KNOWN_DUMP`).

## Rules
* **1b, spine specialization (Known).** A static spine is a Value clone whose body is a list of at most 8 capture free known functions (`oneOf [a, b, c]` after
  rule F). `trySpecialize` picks such an argument for a parameter that is only the scrutinee of `case p of [] -> ..; h :: t -> ..` (variables or wildcards)
  and whose tail is only passed, at the same position, to the function itself. The key is the clone of the list, so the copy has the list substituted.
  `rw` reduces `case G of ..` on a static spine to the matching branch (head: the function, tail: a floated static value of the rest, made once, `sTails`);
  `p s` is then a direct call, and `oneOfHelp s rest` becomes a call keyed on the tail. Spine copies do not count against the per-origin limit of 32 (A2
  needs 30 for one `oneOfHelp` clone); own limit 64. Refused (counters): a list with a captured or run time element, longer than 8, a parameter used for
  anything else (`List.length rest`), a copy with lifted children. Switch `FICUS_S2_NO_SPINE=1`. Counters in `FICUS_KNOWN_STATS`: `spine-specializations`,
  `spine-reductions`, `spine-tails`.
* **Second Inline pass (Inline).** `inlineProgram` runs `inlineStats` twice (the table of the second run is built from the rewritten bodies). The table
  holds the bodies as they were before the pass, so a producer's nested producer calls (`map2`'s `case symbol s of ..`) were never inlined into its callers:
  E1 of the experiments note found 4 of 108 candidates, W5 about half. With the second pass `lambda@67:5` copies are taken apart in their callers. Needs the
  Known pass on. Switch `FICUS_NO_INLINE2=1`.
* Tried and dropped: a relaxed rule A copy limit (`copyOk`: a consumer branch used by up to 4 leaves, size <= 24, no binders). With the second pass it
  gave 3.25 M against 3.33 M allocations at 1 MB for 2 % more C text; without it, 4.93 M and more text. Not kept.

## Numbers (P1 A2, parse = stage 2 - stage 1, median of 5, checksum correct, machine load 1.0 to 1.3)
| | pass off | W5 | W6 | W6 checkpoint |
|---|---|---|---|---|
| 50 MB parse time | 8,063 ms | 2,964 ms | **1,790 ms** | <= 2.6 s |
| 50 MB parse allocations | 832.1 M | 269.5 M | **156.9 M** | <= 215 M |
| 50 MB dups / drops | 929 / 714 M | 434 / 412 M | 196 / 186 M | |
| 50 MB closures | 165.5 M | 6.7 M | 6.7 M | |
| 1 MB parse time / allocations | 166 ms / 17.7 M | 63 ms / 5.73 M | 38 ms / 3.33 M | |
| C text / `.text` | 645 / 109 KB | 699 / 88 KB | 710 / 81 KB (1.10 x / 0.74 x off) | <= 1.5 x |

Rule 1b alone (before the second pass): 2,584 ms, 226.1 M (the checkpoint of 215 M was missed, the second pass was then added by decision of the user).
Compile time (median of 5, `--rc`): A2 0.95 s off, 0.99 s W5, 1.03 s W6 (1.08 x); the 16 suite programs 1.00 x (one 1.30 x reading of `mandel` was noise:
0.70 to 0.78 s in five repeats on both sides). The 16 suite programs' C text is byte identical to `elmficM1` in every setting, also with all defaults
(`ficus-tests/w6_identity.py`: `--no-rc`, pass off, all four stage 2 switches off, the W6 switches off, defaults), so their times cannot change.

## Remaining parse allocation sites (A2, 1 MB, 3.04 M attributed; `ficus-tools/h16_w5_sites.py`)
By call cycle (clones in a cycle of the call graph of Known's output; `/home/gordon/claude-tmp/w6/scc_attr.py` method: per-clone counts of the stage 2 run
against the SCCs): **in a cycle 1.03 M (34 %), acyclic 2.01 M (66 %)**.
| | allocations | share | note |
|---|---|---|---|
| `oneOfHelp` spine copies, `Good` + box (acyclic) | 0.84 M | 27.6 % | results of the inlined alternatives, returned to the callers |
| `oneOfHelp` `Bad` | 0.08 M | 2.5 % | |
| `lambda@67:5` (`map2`/`ignore`) in a cycle: box, `Good`, `Bad` | 0.63 M | 20.6 % | `value -> jarray/jobject -> value` |
| `lambda@67:5` acyclic: box, `Good`, `Bad` | 0.46 M | 15.1 % | not inlined (callers in another body, or no producer) |
| `More` (`lambda@439:33`) | 0.15 M | 4.9 % | |
| `lambda@83:5` box + `Good` | 0.17 M | 5.7 % | |
| `loopHelp`, `fold`, `sepByHelp`, `wordHelp`, `foldlHelp`, tree nodes | 0.39 M | 12.7 % | |
No `oneOf` alternative is called through a closure any more (the `oneOfHelp` `State` box for `fic_ap1` is gone); `jarray`, `jobject` and `value` are direct calls.
For W7: about two thirds of what is left is acyclic `Step` traffic between direct calls (rule 2 applies to it as well as to the cycle).

## Tests
`known12` (static spines of 1, 2, 3 and 7 parsers, nested `oneOf`, a recursive grammar through `lazy`; spine counters 23/23/17) and `known13` (must not fire:
a list also used as a value, a parser that captures a run time value, a list of 9, a list from a run time argument, a list in a record, a tail used by
`List.length`; no spine counter); goldens from Elm 0.19.3 (`ficus-tests/expected/`). `known_tests.py` settings `no-spine`, `no-inline2`. `libshape.parser_shape`:
`oneOf` over static lists of 1 to 8 alternatives, a nested recursive grammar, a capturing alternative, a list used as a value. rcfuzz settings `nospine`, `noinline2`.

Gates (KEEP=1, once, final binary): attach 159, types 267 PASS + 1 XFAIL, JS id 28, examples 296 x3, rcfaults 0 missed, elmdiff 1175 SAME 0 DIFF, typed 568/12/1, suite 16 PASS; rcfuzz 200 seeds x (default, nospine, noinline2, noknown) 0 failures; v2fuzz 200 seeds x (default, no spine, no inline2) 0 flagged.
