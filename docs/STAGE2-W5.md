# H16 stage 2, slice W5: rule 1a (lifted clones in the Inline table) and rule 1c (case identity)

Branch `feat/stage2-w5`, based on `ficcus` 5f9d3bbf (binary `elmficM1`), final binary `bin/elmficW5`. All in `compiler/src/Ficus/Mono/Inline.hs`.

## Rules
* **1a.** `table` admitted only clones with `mdLifted == Nothing`. Now a lifted clone that captures nothing (`Free.captures`) is admitted too, if it is not
  an owner of lifted clones, has no self call, size <= 80 (the existing limits). A lifted clone is dropped from the table while a body of its own
  call cycle (SCC with a cycle) is rewritten (`tScc`, `tAdm`). Clones with captures stay out. Needs the Known pass on (`FICUS_NO_KNOWN`
  switches it off); own switch `FICUS_NO_LIFTED_INLINE=1`.
* **1c (rule I).** `case x of C y1..yn -> C y1..yn` (same constructor, pattern variables in order, scrutinee and branch class `CRef`) gives `x`;
  the branch pattern becomes wildcards; a non variable scrutinee is let-bound first; a `case` whose branches are all identities is the scrutinee.
  The retyped form (`Bad c m` at `Step a`, rebuilt at `Step b`) is the same rule: the pattern variable and the argument are one local, so the field
  classes are equal at both keys. Switch `FICUS_NO_IDENT=1`; needs the Known pass on. Reuse and the Rc pass see the new body and decide afresh.
* The `--no-rc` text and the pass off `--rc` text are unchanged (the 16 suite programs are byte identical to `elmficM1` with `--no-rc`, `FICUS_NO_KNOWN=1`,
  and with each switch; with the defaults too: neither rule changes a suite program). `ficus-tests/w5_identity.py`.

## Numbers (P1 A2, parse = stage 2 - stage 1, median of 5, checksum correct, machine load 1.0 to 1.6)
| | pass off | M1 (before) | 1a | 1a + 1c | target |
|---|---|---|---|---|---|
| 50 MB parse time | 8,133 ms | 4,295 ms | 3,367 ms | **3,023 ms** | 3.0 s |
| 50 MB parse allocations | 832.1 M | 426.7 M | 319.2 M | **269.5 M** | 270 M |
| 50 MB dups / drops | 929 / 714 M | 540 / 491 M | 472 / 437 M | 434 / 412 M | |
| 50 MB closures | 165.5 M | 6.7 M | 6.7 M | 6.7 M | |
| 1 MB parse time / allocations | 169 ms / 17.7 M | 141 ms / 9.07 M | 72 ms / 6.8 M | 65 ms / 5.7 M | |
| C text / `.text` | 645 / 109 KB | 688 / 103 KB | 707 / 92 KB | 699 / 88 KB | |

1a alone: 3,323 ms in the first run, 3,367 ms in the second (checkpoint 3.3 s / 310 M: accepted in substance by the user). 1c: 23 ms over 3.0 s, allocations met.
The 15 M gap between 1a (319 M) and the E1 scratch binary (303.8 M) was not chased (decision of the user).

Compile time (median of 5, `--rc`, `h16_w5_compile_time.py`): A2 0.94 s off, 1.00 s on (1.07 x); the 16 suite programs together 10.94 s off, 11.00 s on (1.01 x).

Remaining parse allocation sites at 1 MB (5.47 M): `oneOfHelp` State box 19.7 %, `lambda@67:5` box/Good/Bad 13.1 / 12.3 / 5.9 %, `lambda@46:5` Good and box 7.0 % each,
`lambda@56:5` 4.4 % each, `More` (`lambda@439:33`) 2.7 %. By function: lambdas 72.7 %, `oneOfHelp` 21.1 %. They cross closure calls (`oneOfHelp`'s list) or
recursion: rule 1b and rule 2 of the design note.

## Tests
`known10` (parsers: capture free copies, copies with captures, a recursive copy), `known11` (identity: fires, retyped, non variable scrutinee, borrowed scrutinee;
swapped fields, changed field, other constructor, effect in a branch: must not fire); goldens from Elm 0.19.3. `known_tests.py` settings `no-lifted`, `no-ident`.
`libshape.parser_shape` in `rcfuzz.py` and `v2fuzz.py`; rcfuzz settings `nolifted`, `noident`, `noknown`.
