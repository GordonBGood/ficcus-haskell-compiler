# P1: JSON parsing with parser combinators (Ficus, Rust, C)

Bench session, 16-17 Nov 2026. Branch `bench/p1` (from `ficcus` at `4888a213`, own worktree), binary `bin/elmfic80`, no compiler change, shared files untouched, nothing committed or merged.
Machine: AMD Ryzen 7 7840HS, gcc 16.2.1, rustc 1.100.0, load below 1.5. Serial, `ulimit -v` 6 GB, median of 5 wall times (whole process), max RSS of one more run.
Results: `results/p1/p1_bench.json` (workspace), inputs `results/p1/json_1mb.json` (990,950 bytes, 87,689 nodes) and `json_50mb.json` (46,649,545 bytes, 4,131,606 nodes).

## Files
- `ficus-tools/gen_json.py N [OUT]`: the generator (specification in its header) and the oracle checksum (Python `json`). `N=7500` is the 1 MB document, `N=375000` the 50 MB one.
- `ficus-tools/p1_bench.py`: the driver (builds, measures, compares, patches a per-tag allocation count into a copy of the generated C, removes its builds).
- `targets/p1/` (an Elm/Ficus project): `src/JsonConfig.elm` (records, stage; rewritten by the driver), `JsonGen.elm`, `JsonTree.elm` (type `Json`, checksum fold), **`JsonComb.elm` (version A)**, `JsonHand.elm` (C), `JsonStrComb.elm` (A on a String), `JsonPkg.elm` (B, real elm/parser); `json_hand.c` (hand C).
- `targets/rust/`: `json_common.rs`, `json_comb_dyn.rs`, `json_comb_impl.rs`, `json_rd.rs`.

## Method
The C path cannot read a file (a `Platform.worker` has no input), so, as in wordfreq, **every version builds the document itself** from the same integer generator, and `gen_json.py` is its specification. The text is a `String` (Ficus) or a byte buffer; it is converted once to a `Vector Int` of byte values (the text is pure ASCII, non-ASCII characters occur as `\u` escapes). The program takes a stage (a constant in Ficus, an argument in Rust and C): 0 generate, 1 also convert, 2 also parse and print `nodes sum64 strlen depth`. **Generation = stage 0, conversion = stage 1 - stage 0, parse = stage 2 - stage 1.** Every stage 2 output equals the checksum of `gen_json.py` on both sizes, A and C also equal Elm 0.19.3 under node on the 1 MB document (`Vector` replaced by `ficus-tests/vecshim`); stage 0 and 1 print the text length, which equals the file size. (The generated text itself was not compared byte for byte; equal checksums and lengths from independent parsers are the evidence.)
Document: depth up to 12, objects, arrays, strings with escapes (`\" \\ \/ \n \t \b é A`), integers, floats (multiples of 1/64, some with an exponent, so sums are exact), booleans, null.
Checksum prints `floor (sum * 64)`: Elm's `truncate` wraps at 32 bits (known quirk), `floor` does not.

## Differences from elm/parser (version A)
The state is `{ src : Vector Int, offset : Int }` (no row, column, indent, context); predicates take Int byte codes; `Parser a` is a type alias of `State -> Step a`, not a wrapper; `keep` and `ignore` are named functions; a problem is a `String`; `symbol` takes one byte, `word` a list of bytes; `getChompedString` builds a `String` from the byte range and `unescape` decodes it; `number` is built from `int10`, `oneOf`, `andThen`, `map` (every number is a `Float`). The grammar rules `jarray`, `jobject`, `member` are functions of `()` (see finding 1). `value = lazy (\_ -> oneOf [...])` builds its parser list at each call, as elm/parser code does.

## Results (ms, whole process; parse = stage 2 - stage 1)
| version | 1 MB gen | conv | **parse** | total | RSS MB | 50 MB gen | conv | **parse** | total | RSS MB |
|---|---|---|---|---|---|---|---|---|---|---|
| Ficus A (combinators, Vector Int) | 23 | 6 | **186** | 214 | 16 | 939 | 274 | **8297** | 9510 | 640 |
| Ficus C (recursive descent) | 34 | 8 | **25** | 67 | 16 | 913 | 273 | **767** | 1953 | 640 |
| Rust, Rc<dyn Fn> combinators | 8 | 0 | **232** | 239 | 10 | 223 | 0 | **11761** | 11980 | 362 |
| Rust, impl Fn combinators | 8 | 0 | **14** | 21 | 10 | 226 | 0 | **627** | 850 | 357 |
| Rust, recursive descent | 8 | 0 | **11** | 20 | 11 | 217 | 2 | **529** | 748 | 403 |
| hand C, recursive descent (gcc -O3) | 7 | 1 | **12** | 19 | 15 | 234 | 0 | **574** | 807 | 606 |
| Ficus B, real elm/parser (String) | 22 | - | **13,176** | 13,199 | 10 | not run | | | | |
| Ficus A on a String | 23 | - | **481,619** (1 run) | 481,642 | 10 | not run | | | | |

Ratios (parse, 50 MB): A / C = **10.8** (1 MB: 7.4), A / hand C = 14.5, C / hand C = 1.34, Rust dyn / Rust rd = 22, Rust impl / Rust rd = 1.19, Ficus A / Rust dyn = 0.71. Peak memory: a `Vector Int` is 8 bytes per input byte (373 MB of the 465 MB at stage 1); Rust and C hold 1 byte per byte.
String variant, quadratic (one run each): 125 records 207 ms, 250 774 ms, 500 3,290 ms, 1000 9,407 ms (136 KB), 7500 481,642 ms. B on the same grammar: 13.2 s for 1 MB.

## Counters (FIC_STATS, parse only = stage 2 - stage 1; closures = closure + partial application allocations)
| | allocs | dups | drops | closures | partial applications | reuse hits |
|---|---|---|---|---|---|---|
| A, 1 MB | 21.3 M | 22.3 M | 16.2 M | 4.66 M | 0.11 M | 1.28 M |
| A, 50 MB | 1,003.9 M | 1,049.6 M | 763.0 M | 219.6 M | 5.0 M | 60.2 M |
| C, 50 MB | 67.4 M | 21.9 M | 30.5 M | 1.9 M | 0 | 0 |
| B, 1 MB | 28.3 M | 39.6 M | 23.7 M | 4.95 M | 0.04 M | 1.0 M |
A makes 21.5 allocations, 22.5 dups, 16.4 drops and 4.8 closures per input byte (50 MB); C 1.4, 0.5, 0.7, 0.04.

## Estimated share in version A (50 MB parse, 8.3 s; C does the same job in 0.77 s)
- Reference counting: (dups + drops) = 1,812.6 M. At 1 to 3 ns each: **1.8 to 5.4 s, 22 to 66 % of the parse time; 3.6 s (44 %) at 2 ns.** (C: 52 M operations, 0.05 to 0.16 s.)
- Closure allocation: 224.6 M closures and partial applications. At 5 to 10 ns each for allocate, fill, free (the pool allocator and the counted captures): **1.1 to 2.2 s, 14 to 27 %.** The other 779 M allocations are `Good` steps, list cells and the state records of the combinators; they are not included.
- The two overlap (a closure's captures are counted) and both are estimates from the counters, not measurements; the remaining A - C difference (7.5 s) is also indirect calls and the 779 M step objects. A profile of the generated C (perf) would give the exact split; not done.

## Findings (for the planning chat; none fixed, no compiler change)
1. **Initialisation order of top-level values through `lazy`** (a compiler bug, start up segmentation fault): `value = lazy (\_ -> oneOf [ jarray, ... ])` and `jarray = ... value ...` (a cycle of top-level values through a lambda; Elm accepts this form in general, but I did not try this exact cyclic version under Elm 0.19.3, only the workaround form) is initialised in the wrong order, `jarray` reads `value` before it is set (null dup in `fic_init`). Workaround: the recursive rules are functions of `()`. Not minimised into a test yet.
2. **`String.slice` costs O(offset) on the C path** (`fic_us_slice` scans from the start; the elm/parser kernel has the offset cache, `slice` has not). It makes version B (real elm/parser, whose `getChompedString` and `number` slice the source) 13.2 s for 1 MB (A on a Vector: 0.19 s) and the String variant of A quadratic. Probable cause of B's time, not profiled. A library issue: `slice` could use the same cache (or an ASCII fast path when `len == cps`).
3. **The `succeed (Done (List.reverse acc))` pattern is quadratic in a strict language** (the reverse is evaluated at every step; it is how elm/parser's docs write `loop`). My first A did it: 1 MB 630 ms, 50 MB did not finish in 39 min. Fixed in A, B and the String variant (`Done acc`, one `List.reverse` after the loop); the same in Elm.
4. Version B builds on the C path and gives the right checksum (slow only for finding 2).

## Rust versions
- `json_comb_dyn.rs`: **`Rc<dyn Fn>`, not `Box<dyn Fn>`** (deviation from the task): the Elm parsers are shared closures (`value`, `item` of a loop), and the safe Rust form of sharing is a counted pointer; Box would rebuild the parser at each use. The step of `sepBy` writes the `oneOf [more, done]` out (the two alternatives share the one owner of the list); `loop_` takes a maker of the initial state.
- `json_comb_impl.rs`: parsers are `impl Fn + Copy` closures, everything monomorphized: `one_of!` is pairwise `or`, the one recursive rule is cut by a plain function (`value_step`), `loop_with` / `loop_once` are the two forms of `loop`. An upper bound for combinators in safe Rust.
- Hand C: `gcc -O3` was the fastest of gcc/clang at -O2/-O3 on both sizes (builds listed in the JSON); malloc'd tree freed at the end, like the others.

## For the Roc translation
Translate **`targets/p1/src/JsonComb.elm` (632 lines; everything but `toVector` and `main` is the library, the grammar and `unescape`) with `targets/p1/src/JsonTree.elm`** (the tree and the checksum); read the file instead of generating it:
`python3 ficus-tools/gen_json.py 375000 json_50mb.json` (or `7500 json_1mb.json`); the expected line is printed by that command and stored in the JSON results (`nodes=4131606 sum64=11196337623888 strlen=10937203 depth=12` for 50 MB, `nodes=87689 sum64=237203670393 strlen=233720 depth=12` for 1 MB). The generator (`JsonGen.elm`, 242 lines) is only needed if Roc must build the text itself. The smallest complete version is `JsonHand.elm` (C, 439 lines), the one with the higher order code that the Morphic comparison needs is A. Notes: `Parser a` is a plain function type (a Roc function), `Step` and `Loop` are tags, `Vector Int` is `List U8`, the sepBy accumulator is reversed once at the end (finding 3), the recursive rules are functions of `{}`.

## Reproduce
`python3 ficus-tools/p1_bench.py --elm bin/elmfic80 --elm-home H --out results/p1 --sizes 7500,375000 --runs 5 --str-runs 1 --elm-check` (the String variant at 1 MB takes 8 minutes; `--only a,b` selects versions; H a private copy of an ELM_HOME with elm/core, json, parser).

## Update 17 Nov (FIX2, `docs/STAGE4-FIX2.md`)
Finding 1 is fixed (`Spec.ordered`; the cyclic form of `JsonComb` gives the right checksum, the programs here keep the `()` workaround so that results stay comparable). Finding 2 is fixed (`fic_us_off`): B on the 1 MB document 12,965 ms to 275 ms, A on a String 479,852 ms to 241 ms (whole process, `elmfic80`-era runtime against `elmficA14`).
