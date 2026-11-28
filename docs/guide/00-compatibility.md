# 0. How compatible is Ficus with Elm?

State: 28 Nov 2026, `elmficR1`. Draft (COMPAT-1). *Unverified* marks claims with no test result behind them.

Short answer: on every corpus run so far, Ficus accepted and rejected exactly what Elm 0.19.3 did (one typed corpus program is an exception, *unverified* which), and its JavaScript output is Elm's own. The C
backend gives Elm's results for pure and library code, apart from the deviations below, but cannot yet run browser,
HTTP or file programs.

## 0.1 Four measures

| | Measure | Result | Source |
|---|---|---|---|
| A | Accept or reject verdict (and output) equal to Elm 0.19.3, package and application corpus | full corpus: 3,971 comparisons, all SAME; sample corpus: 1,175 SAME, 0 different | `results/m1-full/summary.md` (5 Nov); gates log, `elmficA4bf` (27 Nov) |
| A | Same, current binary, full corpus | **[PLACEHOLDER: elmdiff rerun, `results/compat/elmficR1/totals.txt`]** | night queue job `compat-elmdiff` |
| A | Typed programs corpus (581 programs) | 568 same, 12 rejected by both with the same error, 1 verdict differs (*unverified* which) | gates log (27 Nov) |
| B | JS output byte identical on Elm only programs | JS identity suite 28 of 28; audit: 6 of 7 `.elm` programs byte identical (the seventh not stated) | gate log (27 Nov); `docs/PLAYABILITY-AUDIT.md` (branch `audit/play`, 28 Nov) |
| C | Behaviour equal to Elm on the C backend, pure and library code | 16 of 16 acceptance programs print Elm's bytes; library suite 167 cases, reported as 108 PASS and 59 FIXED, give the expected value, Elm's value except for decided deviations (38 of the first 160 cases) | gate log (27 Nov); `docs/lib-issues/REPORT.md` (8 Nov) |
| D | Share of corpus packages whose kernels exist on the C path | **[PLACEHOLDER: not measured]** | - |

For D, what is known: `elm/core`, `json`, `bytes`, `parser`, `random` and `regex` are built in (L42); `elm/time` worked in
the audit; `browser`, `html`, `virtual-dom` and `http` have no C kernels.

## 0.2 Decided deviations (C backend only)

None applies to the JavaScript output, which keeps Elm's semantics; building for JavaScript is always a work around.
Numbers are those of the decisions file; examples are in chapter 3.

| What | Why | Work around |
|---|---|---|
| `Int` is 64 bit and wraps; literal above 2^63-1 is an error | one fast integer type on every target | code relying on doubles above 2^53 (hashes) must use `Float` or `Bitwise` |
| L1: `modBy 0` and `remainderBy 0` give 0 | library functions are total (Elm crashes or gives NaN) | none needed |
| L2: `round`, `floor`, `truncate`, `ceiling` of NaN give 0, of infinity the `Int` limits | an `Int` cannot hold NaN | test with `isNaN` / `isInfinite` first |
| L4: `Int ^ negative` is the truncated integer (`2 ^ -1` is 0) | Elm puts 0.5 in an `Int` | use `Float` `^` |
| L8, L9: full Unicode `toUpper` (`ß` to `SS`); invalid `Char.fromCode` gives U+FFFD | Elm's results are wrong | none |
| L11, L12, L22: lengths, indexes, Parser and Regex columns count code points, not UTF-16 units | strings are UTF-8 | positions differ only for characters outside the BMP (emoji) |
| L14, L21: `String.toInt`, `Decode.int` exact to 2^63-1 | Elm rounds above 2^53 | none |
| L23, L39, L40: invalid UTF-8, negative widths, lone JSON surrogates fail or give U+FFFD | Elm returns wrong strings | none |
| L32: `Random.float hi lo` swaps the bounds | Elm returns values outside the range | none |
| L37: `==` on decoders holding a constant list, tuple, record or `Maybe` is `False` | no package depends on it | do not compare decoders |
| L44, L46, L47: Regex named groups, astral case folding, `split` on empty text | Elm gives wrong results or a RangeError | none |
| L48: Regex step budget, then abort | no runaway backtracking | rewrite nested quantifiers (`(a*)*b` as `a*b`) |
| Type issue 2097: `number`, `comparable`, `appendable` as type parameter or alias names are rejected | Elm 0.19.3 crashes on them | rename the variable |

Elm quirks that packages depend on are kept: NaN ordering (L3), 32 bit `Bitwise` (L6), Parser edge cases (L25), the `elm/random` stream (L31), JSON key order (L35).

## 0.3 Known limits of the C backend

From the playability audit (28 Nov):

- `Browser`, `Html` and `Http` programs do not compile to C.
- No I/O model yet: input only through the `FIC_FLAGS` and `FIC_PORTS_IN` variables; no argv, stdin, files or exit
  code. Output goes to ports and `Debug.log`.
- `make` stops at a `.c` file; you run gcc yourself with `-I` pointing at the compiler's `runtime/`.
- Derived `encode` and `decoder` are not generated yet.
- Ficus only features (`derive`, `Vector`, sized integers) do not compile to JavaScript yet.
- There is no `ficus` command yet.

## 0.4 What Ficus adds

All optional.

- `.fic` files beside `.elm`; native programs through C99, reference counted, no garbage collector.
- 64 bit `Int`, sized integers `Int8` to `Word64` and `Float32`, `Bitwise64`, and `Vector` (chapter 2).
- Attached functions and `derive` for `compare`, `hash`, `toString` and enumeration (chapter 1).
- `Concurrent` (lightweight processes, C and JS).
- Syntax: `1_000_000`, `-1 ->` patterns, `[a]` for `List a`.
