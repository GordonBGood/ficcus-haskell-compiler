# The Regex kernel (elm/regex, decision L24) (REGEX session, 2026-11-12)

Worktree `ficcus-haskell-compiler-regex`, branch `feat/regex` (rebased onto `ficcus` at `ff33c1ab`), binaries `bin/elmficr2` and up. Not merged into
`ficcus`: the COMPILER session merges after S6. Files this branch adds or changes:

| file | what |
|---|---|
| `runtime/fic_regex.h` | the engine: parser, compiler to bytecode, matcher, the nine kernels (about 750 lines of C99) |
| `overlay/FicOverlayRegex.elm` | the API of `Regex` written in Elm on the nine kernels |
| `compiler/src/Ficcus/Mono/{Kernel,CGen,Overlay,CRuntime,Spec}.hs`, `terminal/src/Make.hs` | registration: kernel table and signatures, C calls, redirect of the package functions to the overlay, embedded runtime file, classes of `Regex` and `Caps`, `Debug.toString` and `==` of a `Regex`, overlay written for projects that depend directly on elm/regex |
| `runtime/test_regex.c`, `.expected`, `runtime/test.sh` | standalone test of every kernel (gcc and clang, with sanitizers under `SAN=1`) |
| `ficcus-tests/kernel_tests.py` | one program and one ASan+UBSan build for each of the nine kernels |
| `ficcus-tests/regex/` | the differential tests: `run_diff.py` (Ficcus against Elm 0.19.3 under node and against a model), `ref_api.js`, `gen_cases.py`, and the engine-level pair `re_driver.c` / `ref.js` |
| `ficcus-tests/regexex/`, `expected/regexex.*` | an example project (output equal to Elm's), added to `examples.py` |

## 1. Design

**Dialect (L24).** ECMAScript 262, the dialect of Elm's `new RegExp(source, 'g' + 'm'? + 'i'?)`: literals, `.`, classes (`[a-z]`, `[^..]`,
`\d \D \w \W \s \S` also inside classes), the escapes `\n \r \t \f \v \0 \cX \xHH \uHHHH` and octal and identity escapes as in the Annex B
of the standard, anchors `^ $` (with the multiline flag at line terminators), `\b \B`, groups `( )`, non capturing `(?: )`, backreferences
`\1` (a group that has not taken part matches the empty string), lookahead `(?= )` `(?! )`, lookbehind `(?<= )` `(?<! )` (evaluated
backwards, as the standard says, so captures inside a lookbehind are taken right to left), greedy and lazy quantifiers `* + ? {n} {n,} {n,m}`
(with the empty iteration check and the reset of captures at each iteration of the standard), alternation in order (leftmost alternative, not the
longest). The flags are the two Elm exposes: case insensitive and multiline.
`fromString` gives `Nothing` for what node rejects (unbalanced parentheses and brackets, `a{2,1}`, nothing to repeat: `*`, `a**`, `^*`, `\b+`,
a quantified lookbehind, `[z-a]`, a trailing backslash), and for what Ficcus does not support: `\p`, `\P`, inline
flags `(?i)`, and a pattern nested deeper than 200 levels. Everything else that node accepts is accepted with the same meaning (`a{`, `]`, `}` and
`{,2}` are literals, `\8` is `8`, `\c1` is the text `\c1`, `\u12` is `u12`, `\101` is `A`).

**Code points (L22, L11).** The subject is valid UTF-8 and the engine reads code points: `.` and a class match one code point (an astral
character is one character, `[😣]` is one alternative), `Match.index` counts code points. The kernels work on byte offsets; the code point
index is carried along (`exec` is given the code point index of its start offset and returns the one of the match), so the cost of `find` is
linear. A `😣` pair in a pattern is read as one code point; a lone surrogate escape matches nothing.

**Case insensitive** is the Canonicalize of the standard without the `u` flag: the full upper case of the code point when it is one code point,
and never an ASCII result from a non ASCII code point (so `ß` does not match `ss`, `ſ` and the Kelvin sign do not match ASCII letters, and
`ς σ Σ` and `µ μ Μ` are one letter). A class matches when one of the candidates `c`, `canon(c)`, `lower(canon(c))`, `lower(c)` that has the same
canonical form is in it (this finds every case variant of the 1 to 1 mappings; the three way `ǅ ǆ Ǆ` set is the one place where a class that
lists only the title case form `ǅ` does not match `Ǆ`). Cased letters outside the BMP fold too (JavaScript without `u` does not; the engine works on
code points).

**Engine.** `fic_re_compile` parses (recursive descent, depth limited), builds a small AST and emits int32 bytecode into a raw vector, which is
the `Regex` value (reference class, `Debug.toString` prints `{}`, L29; `==` compares the programs). `fic_re_exec` runs the matcher at each start
position (a literal first byte uses `memchr`, a leading `^` without the multiline flag tries only position 0). The matcher is a backtracking
machine with an **explicit stack**: no C recursion on the subject or on the pattern at match time (the test runs under `ulimit -s 256` with a
subject of 200,000 characters). The stack holds choice points and undo records (captures, loop counters), so a failure restores the state
exactly; lookarounds are markers on the stack (a positive lookahead keeps the undo records and drops the choice points, a negative one unwinds).
A single character quantifier (`.*`, `[a-z]+`, `a{2,5}?`, forward direction) uses one range record for the whole run, whatever its length,
so `[ab]*c` on a text of a million characters needs one record. Other loops use a counter register and an iteration mark.

**Resource limits.** One call of `exec` may take `FIC_RE_BUDGET` steps (default 400,000,000: an instruction, a backtrack, an iteration of a
single character loop) and the stack `FIC_RE_MAX_STACK` entries (default 2^25, 24 bytes each: 768 MB). Exceeding either is **resource
exhaustion**: the scratch memory is released, then the message `Ficcus: a regular expression exceeded its step budget` (or `backtracking stack`)
is written and the program aborts, like a stack overflow. (Node would run on for minutes or hours: `(a*)*b` on 30 `a` takes 2^30 steps.)
`fic_re_exhausted_hook` replaces the abort in the tests. Both are `#define`s of the C text.

**Elm API on the kernel.** `overlay/FicOverlayRegex.elm` is compiled only into a project that lists `elm/regex` as a direct dependency (as
Json and Bytes) and the specializer redirects `fromStringWith never contains find findAtMost replace replaceAtMost split splitAtMost` to it.
Nine kernels, all arguments borrowed (`s` Int):

| kernel (`author/project:FicOverlayRegex.`) | arity | signature | |
|---|---|---|---|
| `compile` | 2 | `sb` | flags (1 i, 2 m) and pattern: the program; an invalid pattern gives a program with magic 0 |
| `valid` | 1 | `b` | the magic word |
| `groups` | 1 | `b` | the number of capture groups |
| `exec` | 4 | `bbss` | `exec re text byteFrom cpFrom`: the capture vector (a raw vector of Int: start, end, start and end code point index, then the offsets of each group, -1 for a group that did not take part) or an empty one |
| `found` | 1 | `b` | the vector is not empty |
| `cap` | 2 | `bs` | one element of the vector |
| `slice` | 3 | `bss` | the text between two byte offsets (negative end: to the end), a new string |
| `size` | 1 | `b` | the byte length |
| `advance` | 2 | `bs` | the offset after the code point at an offset (size + 1 at the end) |

`Regex` and the capture vector (`type Caps`, declared in the overlay) are reference classes. Matches, `Maybe`s and lists are built in Elm, so
no C code knows the layout of a record. A match allocates one small vector.

**Iteration rules (L24).** `find`, `findAtMost`, `replace`, `replaceAtMost` use the rule of `matchAll`: the next search starts at the end of the
last match, one code point further after an empty match; `number` counts every match, empty ones included; `replaceAtMost n` calls the function
for the first n matches and keeps the rest of the text. `contains` is a search from 0. A group that matched the empty string is `Just ""`, a
group that did not take part is `Nothing` (library case R-capture-empty).
`split` follows `String.prototype.split` with the limit of Elm and without the captured groups (L30): a match that starts at the end of the
text is not a separator, and neither is an empty match where the current piece starts (so `split "" "abc"` is `["a","b","c"]` and
`split "\\b" "foo bar"` is `["foo"," ","bar"]`); `splitAtMost n` splits at the first n separators and keeps the rest of the text as the last piece
(`n <= 0`: the text). `findAtMost` and `replaceAtMost` with `n <= 0` give `[]` and the text.

## 2. Points that L24 does not decide (choices made, to confirm)

1. **The limits.** 400,000,000 steps and 2^25 stack entries per search, abort with a message (the planning chat asked for "a step budget treated
   as resource exhaustion"; the numbers are mine).
2. **`split` of the empty text.** JavaScript gives `[]` when the pattern matches the empty text (`"".split(/(?:)/)`) and `[""]` otherwise; the
   overlay does the same (`Regex.split (rx "") ""` is `[]`, `Regex.split (rx ",") ""` is `[""]`, the case of R-docs). The literal matchAll rule
   would give `["",""]`.
3. **Named groups (decided by the planning chat after the first report)**: `(?<name>..)` is an ordinary capturing group (numbered with the others,
   `submatches` has no names) and `\k<name>` a backreference to it, as in node; a repeated name, an invalid name, or `\k<x>` for an unknown
   name (when the pattern has any named group) is `Nothing`; without named groups `\k` is an identity escape (the letter k), as in node.
   **Rejected (documented deviation)**: `\p`, `\P` (node, without the u flag, reads them as the letters `p`, `P`: `\p{Letter}` is then a class
   of those letters, never what the author meant), inline flags `(?i)`, nesting beyond 200. All others follow node (Annex B forms above).
   Elm quirk: with a named group Elm's `replace`/`replaceAtMost` pass the callback a Match whose `index` is the subject text and whose
   `submatches` has an extra entry (JavaScript hands the callback the groups object); Ficcus returns the correct Match, and the differential
   test compares those two columns with the model only.
   Corpus scan (1984 projects with Elm sources, 226 that mention Regex; regex literals in source only): named groups 0, `\k` 0, inline flags 0,
   lookbehind 2 occurrences (1 project, edkelly303/elm-yafl, `(?<=Just )[^,]+`, supported), `\p{Letter}` 6 occurrences in 2 projects
   (billstclair/elm-xml-eeue56, dillonkearns/elm-xml-encode: both a name check that Elm turns into a letters class; Ficcus gives `Nothing`).
   Proposal: if exact Elm behaviour matters more than the author's meaning, make `\p`/`\P` identity escapes (one line in
   `fic_re_char_escape`).
4. **Case folding outside the BMP and of `ǅ`** as described in section 1.
5. **`Regex` equality** is the equality of the compiled programs (same pattern and flags). Elm compares two `RegExp` objects as plain
   objects (always equal or an error); no program can depend on it.

## 3. Differences from Elm 0.19.3 (all decided, all with a case)

| behaviour | Elm | Ficcus | case |
|---|---|---|---|
| `find` after an empty match | stops (regex#13) | `matchAll` rule | R-find-empty-matches |
| `replace` with a pattern that matches empty | JS `replace` (as ours) | same | |
| capture that matched `""` | `Nothing` (regex#5) | `Just ""` | R-capture-empty |
| `split` with an empty match | RangeError or out of memory (#6, #18) | as JS `split` | R-split-empty-pattern, R-split-zero-width |
| `Match.index`, `.` and classes on astral text | UTF-16 units, half a pair | code points | R-index-astral |
| `split` with capture groups | captures dropped | same | R-split-captures |
| catastrophic backtracking | runs for hours | aborts at the budget | |

`ficcus-tests/regex/run_diff.py` shows exactly the cases where the two sides are the same (305 of 393 in the default run: everything without an
empty match or capture) and checks the others against a model of the decided behaviour written with node's own `RegExp`.

## 4. Tests and results

Binary `bin/elmficr2` (build `cabal build -j1 --ghc-options="+RTS -M6g -RTS"`; the heavy steps ran with more than 8 GB available).

| gate | result |
|---|---|
| library cases R (9) | 9 of 9 PASS |
| library suite, `--no-rc` / default flags / `--rc` ASan+UBSan (`libsuite.sh`) | 155 PASS in each (rebased on `ficcus` at `ff33c1ab`); all 148 original cases pass. The 7 others (K-decoder-equality-constants, K-deep-nesting, K-lone-surrogate-json-text, K-number-int-float-equality, Y-decode-negative-width) are newer cases of the LIBRARY session whose expected result is "undecided"; none is Regex |
| kernel tests (`kernel_tests.py`, all kernels) | 124 of 124, 0 without a test, 0 live objects; the 9 new ones each reach their `fic_re_` function |
| `runtime/test.sh` (gcc, clang) | `test_regex` ok on both, also under `SAN=1` (ASan+UBSan, `ulimit -s 256`). Under `SAN=1` the older no-RC tests test_runtime, test_closure, test_jsarray, test_ustring report leaks (they allocate without counts); unchanged by this branch |
| examples plain / `FIC_DROP_ALL` / `FIC_RC=1 FIC_SAN=1` (gcc, clang) | 224 ok lines each, 0 failures; the new example `regexex` (27 Debug.log lines) equals the output of Elm 0.19.3 under node |
| `norc_identity.py` | 16 of 16 identical to the reference (`elmfic60`) |
| `run_diff.py` seeds 1, 2, 3 (507, 807, 807 cases, with the named-group cases; seeds 2 and 3 with `--san`) | Ficcus equals the model on every case; equals Elm 0.19.3 on 422, 677 and 663 of the same number of cases (the others, 81 to 140, have an empty match or capture, where Elm differs by decision, and are checked against the model only); 4 cases rejected by design (`\p`, `\P`, `(?i)`) say Nothing; 0 live objects |
| engine level (`re_driver` against `ref.js`, matchAll of node's RegExp, 3 seeds of 10,185 cases) | 0 differences (once the NUL subject, which a C string cannot hold, was removed) |

The differential test needs about 200 pairs against Elm itself: the default run has 422. `python3 ficcus-tests/regex/run_diff.py --elm bin/elmficr2
--elm-ref bin/elm0193 --elm-home H --work DIR --safe tools/safe [--san] [--seed N] [--random K]`. The random patterns are generated from the
supported grammar with a few inserted errors; the hand written list has about 230 cases: empty matches, greedy and lazy quantifiers, alternation, classes,
anchors, groups, backreferences, lookaround, escapes, case folding, and the syntax that must give Nothing.

Speed (not a gate): `\w+` over 825 KB of text, all matches, 0.03 s; a literal pattern uses `memchr`.

Not run: the fuzz, fault tests and typed corpus of the earlier sessions (nothing they check was touched: only additions in the C generator and
kernel table, and the no-RC text of the 16 programs is identical).

## 5. Proposals for the shared files (not edited)

- Decisions file: "DONE 12 Nov: Regex kernel (L24) on branch `feat/regex`, binary `elmficr<N>`: library suite 148 of 148, kernel tests, differential
  tests" and the points of section 2 as DECIDED or OPEN. L24's step budget: 400,000,000 steps, stack 2^25 entries, abort.
- Checklist: tick the Regex kernel of H7.
- STAGE4-PLAN 8.1: add the nine rows of section 1 (`kernel_sigs.py --markdown` prints the whole table).
- COMPILER-HANDOFF: the library suite has no failing case left; `Regex` and `Caps` are reference classes (`Spec.classOfName`).
