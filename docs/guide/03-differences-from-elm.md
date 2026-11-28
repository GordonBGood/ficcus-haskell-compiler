# 3. Where Ficus differs from Elm 0.19.3

State: binary `elmficA16`, C output. The goal is that a program that compiles with Elm 0.19.x compiles with Ficus
and prints the same bytes. This page lists every place where it does not, and why. Each example is in
`ficus-tests/guide/d-*`. Where the example is `vs-elm`, the runner also compiles it as Elm 0.19.3 and runs it under node,
so the "Elm 0.19.3 prints" blocks are real output. Decision numbers (L0 to L48) are those of
`docs/Ficus-Design-Decisions.md`.

The rule behind most differences (L0): where Elm's kernel is wrong against its own documentation or arithmetic,
Ficus gives the right answer, unless published packages depend on the wrong behaviour (then Elm's behaviour is kept,
and said so). Library functions are total: where Elm would crash, loop or give a NaN typed as `Int`, Ficus gives a
defined result.

What does **not** differ: JavaScript output. `--output=x.js` and `--output=x.html` are Elm 0.19.3's generator, untouched,
with Elm's semantics (doubles, 32 bit `Bitwise`, Elm's division by zero). None of the changes below applies there
(checked by a JS identity suite and a differential run over the package corpus).

## 3.1 What compiles to C

`elm make src/Main.fic --output=main.c` (or `src/Main.elm`; `.fic` and `.elm` are read the same way).
Today a C program is a `Platform.worker` that prints with `Debug.log`. Not available in C yet: `Html`, `Browser`, `Task`,
`Process`, `Time`, ports, `Bytes.getHostEndianness` (L43). A program that reaches them stops with a message:

<!-- guide-out: n-task err -->
```text
-- FICUS: the program cannot be compiled to C yet ---------------------------------

`elm/core:Task.command` has no definition and is not in the kernel table (at 284:3-284:10)
```

`elm/json`, `elm/bytes`, `elm/parser`, `elm/random` and `elm/regex` are built in (their kernels are in the runtime), so an
application that uses them, even only through another package, compiles (L42). A project module that imports one of
them without a dependency gets Elm's own error. Every example here has `elm/core` and `elm/json` in its `elm.json`.

## 3.2 Int is 64 bit

L2 and the numbers section of the decisions file. `Int` has 64 bits on every target, not 32 or 53. Arithmetic wraps
around in 64 bit two's complement (observed below; the decisions file has no entry for overflow). An integer literal above 9223372036854775807 is a compile error.

<!-- guide: d-int/Main.fic -->
```elm
        _ =
            Debug.log "2 ^ 40" (2 ^ 40)

        _ =
            Debug.log "2 ^ 62 * 2" (2 ^ 62 * 2)

        _ =
            Debug.log "9223372036854775807 + 1" (9223372036854775807 + 1)

        _ =
            Debug.log "4294967296 * 4294967296" (4294967296 * 4294967296)

        _ =
            Debug.log "2 ^ 53 + 1" (2 ^ 53 + 1)

        _ =
            Debug.log "truncate 1.0e10 * 1.0e10" (truncate (1.0e10 * 1.0e10))
```

<!-- guide-out: d-int -->
```text
2 ^ 40: 1099511627776
2 ^ 62 * 2: -9223372036854775808
9223372036854775807 + 1: -9223372036854775808
4294967296 * 4294967296: 0
2 ^ 53 + 1: 9007199254740993
truncate 1.0e10 * 1.0e10: 9223372036854775807
```

Elm 0.19.3 prints (numbers are doubles, `truncate` is 32 bit):

<!-- guide-out: d-int elm -->
```text
2 ^ 40: 1099511627776
2 ^ 62 * 2: 9223372036854776000
9223372036854775807 + 1: 9223372036854776000
4294967296 * 4294967296: 18446744073709552000
2 ^ 53 + 1: 9007199254740992
truncate 1.0e10 * 1.0e10: 1661992960
```

A program that relied on Elm's rounding above 2^53 (hashes computed in doubles, for instance) prints different numbers.
`String.toInt "9007199254740993"` is `Just 9007199254740993` (Elm: `...992`, L14). An overflow is not reported.

<!-- guide-out: d-literal err -->
```text
-- INTEGER TOO LARGE ---------------------------------------------- src/Main.fic

This integer is too large for an `Int`:

6|     Debug.log "big" 9223372036854775808 |> always ()
                       ^^^^^^^^^^^^^^^^^^^
An `Int` is a 64 bit number, so the largest literal is 9223372036854775807 (2^63
- 1).
```

The smallest `Int` has no literal: write `-9223372036854775807 - 1`. Only C builds give this error; the JS output keeps Elm's.
`Float` is the C `double`; printing equals JavaScript's `Number.toString` (the runtime has its own shortest round-trip printer).
`sin`, `cos`, `pow` and the other math functions are ports of V8's fdlibm, so the digits equal Elm on node (L18).

## 3.3 Division, powers and rounding are total (L1, L2, L4, L5)

<!-- guide: d-div/Main.fic -->
```elm
        _ =
            Debug.log "10 // 0" (10 // 0)

        _ =
            Debug.log "modBy 3 -7" (modBy 3 -7)

        _ =
            Debug.log "2 ^ -1" (2 ^ -1)

        _ =
            Debug.log "-1 ^ -3" ((-1) ^ -3)

        _ =
            Debug.log "round (0 / 0)" (round (0 / 0))

        _ =
            Debug.log "floor (-1 / 0)" (floor (-1 / 0))

        _ =
            Debug.log "logBase 10 1000" (logBase 10 1000)
```

<!-- guide-out: d-div -->
```text
10 // 0: 0
modBy 3 -7: 2
2 ^ -1: 0
-1 ^ -3: -1
round (0 / 0): 0
floor (-1 / 0): -9223372036854775808
logBase 10 1000: 3
1 / 0: Infinity
```

<!-- guide-out: d-div elm -->
```text
10 // 0: 0
modBy 3 -7: 2
2 ^ -1: 0.5
-1 ^ -3: -1
round (0 / 0): NaN
floor (-1 / 0): -Infinity
logBase 10 1000: 2.9999999999999996
1 / 0: Infinity
```

- **L1** `x // 0`, `modBy 0 x` and `remainderBy 0 x` are all 0. Elm: `modBy 0` crashes ("Cannot perform mod 0"),
  `remainderBy 0 5` is `NaN` typed as `Int`. (So `x == (x // y) * y + remainderBy y x` does not hold for `y = 0`.)
  `Float` division is IEEE as in Elm (`1 / 0` is `Infinity`).
- **L2** `floor`, `round`, `truncate`, `ceiling` of NaN give 0 and of plus or minus infinity the largest or smallest `Int`.
- **L4** `Int ^ negative` is the truncated integer: 0 for a base of magnitude above 1, exact for 1 and -1 (Elm: `2 ^ -1` is 0.5 in an `Int`).
- **L5** `logBase` uses `log2` and `log10` for the bases 2 and 10, so `logBase 10 1000` is exactly 3.

<!-- guide-out: d-modby-zero elm -->
```text
RUN ERROR: Error: Cannot perform mod 0. Division by zero error.
```

Ficus prints `modBy 0 5: 0` for the same program, and `remainderBy 0 5: 0` where Elm prints `NaN`.

## 3.4 Strings and Chars: code points, not UTF-16 units (L8, L9, L11, L12, L14)

Strings are UTF-8. `String.length`, `slice`, `left`, `right`, `dropLeft`, `dropRight`, `indexes` and comparison count and compare
**code points** (L11, L12), so a character outside the Basic Multilingual Plane is one position, not two. `String.length` and
indexing are O(1) for ASCII text and fast for the rest (an offset cache).

<!-- guide: d-string/Main.fic -->
```elm
        _ =
            Debug.log "length \"a😀b\"" (String.length "a😀b")

        _ =
            Debug.log "slice 1 2" (String.slice 1 2 "a😀b")
```

<!-- guide-out: d-string -->
```text
length "a😀b": 3
slice 1 2: "😀"
left 2: "a😀"
indexes "b": [2]
toList: ['a','😀','b']
reverse: "b😀a"
compare: LT
toUpper: "STRASSE"
Char.toUpper: 'ß'
toInt: Just 9007199254740993
```

<!-- guide-out: d-string elm -->
```text
length "a😀b": 4
slice 1 2: "�"
left 2: "a�"
indexes "b": [3]
toList: ['a','😀','b']
reverse: "b😀a"
compare: GT
toUpper: "STRASSE"
Char.toUpper: 'SS'
toInt: Just 9007199254740992
```

(`compare "\u{FF5E}" "😀"`: by code point `U+FF5E` is below `U+1F600`; by UTF-16 unit it is above the surrogate `D83D`.)
The same code point rule applies to the columns, offsets and indexes of `Parser` and `Regex` (L22, see 3.7).

- **L8** `String.toUpper` and `toLower` use the full Unicode mapping (tables pinned to Unicode 15.1: `ß` to `SS`).
  `Char.toUpper 'ß'` is the simple one code point mapping, so it stays `'ß'`. Elm answers `'SS'`, a `Char` of two units.
- **L9** `Char.fromCode` of a surrogate, a negative number or a value above `0x10FFFF` gives U+FFFD. A surrogate in a
  literal (`"\u{D800}"`, `'\u{D800}'`) is a compile error. Elm accepts both.

<!-- guide-out: d-char -->
```text
fromCode 0xD800: 65533
fromCode -1: 65533
fromCode 0x110000: 65533
fromCode 0x1F600: '😀'
```

Elm gives `NaN` for the first line (the other three equal).
- **L7** `Char.isAlpha`, `isUpper` and the like stay ASCII only, as in Elm. **L13** `words` and `lines` keep Elm's results.
  **L14** `toInt` and `toFloat` keep Elm's grammar; only the 2^53 precision bug is fixed (parse in 64 bit, overflow is `Nothing`).
  **L15** `sort`, `sortBy`, `sortWith` are stable (documented). **L16** `Debug.toString` keeps Elm's escapes.

## 3.5 Bitwise and Bitwise64 (L6, L19)

`Bitwise` is exactly Elm's, 32 bit, so hashing and random-number code that relies on the 32 bit wrap keeps working.
The shift count is taken `& 31` (L19).

<!-- guide-out: d-bitwise -->
```text
shiftLeftBy 40 1: 256
shiftLeftBy 31 1: -2147483648
and 0xFFFFFFFF 0x1FFFFFFFF: -1
complement 0: -1
shiftRightZfBy 0 -1: 4294967295
shiftRightBy 1 -8: -4
```

Elm prints the same six lines. Ficus adds a module **`Bitwise64`** (C builds; `import Bitwise64`) with the same seven functions
(`and or xor complement shiftLeftBy shiftRightBy shiftRightZfBy`, count first) on the whole 64 bit `Int`, count taken `& 63`.
`shiftRightZfBy` returns the 64 bit pattern read back as a signed `Int`.

<!-- guide-out: d-bitwise64 -->
```text
shiftLeftBy 40 1: 1099511627776
shiftLeftBy 63 1: -9223372036854775808
and 0xFFFFFFFF 0x1FFFFFFFF: 4294967295
complement 0: -1
shiftRightZfBy 0 -1: -1
shiftRightZfBy 1 -1: 9223372036854775807
shiftRightBy 1 -8: -4
shiftLeftBy 64 1: 1
```

`Bitwise64` does not exist in Elm and not in the JS output. A module `Bitwise64` of your own wins over it (see 2.6).

## 3.6 The library decisions L0 to L48

Elm's behaviour is kept unless a row says otherwise. "Kept" means a known Elm quirk that packages depend on.

| id | topic | Ficus |
|---|---|---|
| L0 | kernel bugs | fixed, not copied, unless packages depend on them (refined at L33) |
| L1 | `//`, `modBy`, `remainderBy` by 0 | all 0 (3.3) |
| L2 | `floor`/`round`/`truncate`/`ceiling` of NaN, infinity; Int literal range | saturate; NaN is 0; literal above 2^63-1 is an error (3.2) |
| L3 | NaN ordering | as Elm (`compare` gives GT) |
| L4, L5 | `Int ^ negative`, `logBase` | truncated integer; exact for 2 and 10 |
| L6 | `Bitwise` | stays 32 bit; `Bitwise64` is new (3.5) |
| L7, L13, L16 | Char classes, `words`/`lines`, `Debug.toString` escapes | as Elm |
| L8, L9 | case mapping, `Char.fromCode`, surrogate literals | full Unicode mapping; U+FFFD; literal error (3.4) |
| L10 | Int literals | covered by L2 (the library cases carry the number L10) |
| L11, L12 | string length, slices, indexes, comparison | code points (3.4) |
| L14 | `toInt`, `toFloat` | Elm's grammar, 64 bit exact |
| L15 | sorting | stable |
| L18 | `sin`, `cos`, `pow`, ... | V8's fdlibm ported: same digits as Elm on node |
| L19 | shift counts | low 5 bits (`Bitwise`), 6 bits (`Bitwise64`) |
| L20 | `Json.Encode` of NaN, infinity | `null`, as Elm |
| L21 | `Decode.int`, `Decode.float` | integers exact to 2^63-1 and `Nothing` beyond; `float` rounds (3.7) |
| L22 | `Parser`, `Regex` offsets, columns, match indexes | code points (3.7) |
| L23 | `Bytes.Decode.string` on invalid UTF-8 | fails (`Nothing`); Elm returns a wrong string (3.7) |
| L24 | `Regex` engine | ECMAScript subset backtracking matcher in the runtime (3.7) |
| L25, L26, L33, L34 | `Parser.int`/`float` edge cases, `deadEndsToString`, `chompUntil`, `lineComment`, `getIndent` | kept: Elm's actual behaviour (`123a` is `Ok 123`, `TODO deadEndsToString`, `getIndent` starts at 1); `multiComment NotNestable` fixed |
| L27 | `Json.Decode.errorToString` | ported exactly; one fixed wording for text that is not JSON |
| L28 | `Decode.index` with a negative index | fails like an index too large |
| L29, L30 | printing `Bytes`, `Regex`; `Regex.split` with groups | `<N bytes>`, `{}`; groups ignored, as Elm |
| L31 | `elm/random` stream | as Elm: the same numbers for the same seed |
| L32 | `Random.float lo hi` with `lo > hi` | swaps the bounds (Elm returns values outside the range) |
| L35, L36 | JSON object key order; `field "length"` on an array | as Elm: integer keys first ascending, then insertion order; accepted |
| L37 | `==` on decoders holding a constant | `False` for lists, tuples, records, `Maybe` (deviation, no package depends on it) |
| L38 | Json `Int` equal to `Float` | as Elm |
| L39 | negative width in `Decode.bytes`, `Decode.string` | fails (Elm gives `Just ""` for `string`) |
| L40 | lone surrogate escape in JSON text | U+FFFD |
| L41 | JSON nesting limit | 1,000,000 levels (2000 without the big stack), then a clean error |
| L42 | json, bytes, parser, random, regex | built in for C; reached through a package is fine |
| L43 | `Bytes.getHostEndianness` | not available until `Task` exists |
| L44 | named groups `(?<n>..)`, `\k<n>` | work (numbered); Elm gives a wrong `Match` to `replace` callbacks |
| L45 | `\p`, `\P` | identity escapes, as Elm |
| L46 | case-insensitive matching of astral letters | by code point (Elm folds halves) |
| L47 | `split` on empty text | `[""]` or `[]`; Elm: `[""]` or a RangeError (3.7) |
| L48 | regex resource limits | a step budget, then abort (3.8) |

There is no L17 (the entry was removed: Elm's `Debug.toString` field order is already alphabetical).
The library suite (`tests/lib`, 167 cases) marks 45 cases `deviation`; they are the rows above that differ from Elm
(L1, L2, L4, L6, L8, L10, L9, L11, L14, L18, L21, L22, L23, L27, L28, L31, L32, L37, L39, L40, L41, L46, L47, L48 and the Vector cases).

## 3.7 The kernels: Json, Parser, Bytes, Regex, Random

<!-- guide-out: d-json -->
```text
int beyond 2^53: Ok 9007199254740993
int beyond 2^63: Nothing
keys: Ok [("2",4),("10",2),("b",1),("a",3)]
encode NaN: "null"
```

Elm 0.19.3 prints `Ok 9007199254740992` and `Just 9223372036854776000` for the first two (L21), and the same for the last two.

<!-- guide-out: d-parser -->
```text
chompIf: Ok (2,1)
chompWhile: Ok (2,1)
symbol: Ok (2,1)
```

(column, offset) after the character 😀; Elm 0.19.3 prints `Ok (2,2)` three times, counting UTF-16 units (L22).
`Regex` indexes (`.index` of a `Match`) count code points too. Regex literal syntax: the ECMAScript subset of L24 (classes,
anchors, groups, backreferences, lookahead and lookbehind, lazy quantifiers, `\b \d \w \s`, case-insensitive and multiline flags).

<!-- guide-out: d-regex-empty -->
```text
split x* on empty text: []
```

Elm: `RangeError: Invalid array length` (L47). `Regex.split "," ""` is `[""]` in both.

<!-- guide-out: d-bytes -->
```text
decode string: Nothing
```

Elm decodes the invalid bytes C3 28 to `Just "è"` (a wrong string; L23).

<!-- guide-out: d-random -->
```text
draws: (723,823,True)
```

The two `Random.int` draws from seed 42 equal Elm's (L31). `Random.float 10 0` equals `Random.float 0 10` here (the last value
`True`); Elm prints `False` because it returns a number outside the bounds (L32).

## 3.8 Limits

- **Regex step budget (L48).** One regex search stops after 400,000,000 steps, or when its backtracking stack passes
  2^25 entries (about 800 MB), with a message and an abort. Elm has no limit and would run for a very long time.

<!-- guide: d-regex-budget/Main.fic -->
```elm
        rx =
            Maybe.withDefault Regex.never (Regex.fromString "(a*)*b")
    in
    Debug.log "contains" (Regex.contains rx (String.repeat 40 "a" ++ "c")) |> always ()
```

<!-- guide-out: d-regex-budget stderr -->
```text
Ficus: a regular expression exceeded its step budget
```

  The program prints nothing else and exits with a failure (the C `abort`, status 134 in a shell). Rewrite the pattern
  (`a*b` instead of `(a*)*b`) or shorten the text. `FIC_RE_BUDGET` and `FIC_RE_MAX_STACK` are fixed constants of the runtime, not options.
- **Stack.** `main` runs on a thread with a 1 GB stack (address space only: `-DFIC_STACK_MB=n` changes it; `-DFIC_NO_BIG_STACK`
  runs on the process stack). Deep non-tail recursion that Elm's JavaScript would overflow works; beyond the stack the program is killed.
  Self tail calls become loops.
- **JSON nesting** 1,000,000 levels (L41), **Regex** see above, **`Int`** 64 bit.
- **Equality of functions** crashes at run time, as in Elm: "Trying to use `(==)` on functions.".
- **Memory** is reference counted: a value is freed when its last holder goes away. Cycles cannot be built (as in Elm); there is no collector.
- Cases that Elm 0.19.3 accepts and Ficus rejects: a recursive group that Elm's generalization bug lets through
  (`docs/KNOWN-REJECTS.md`: one package, `mdgriffith/elm-markup 3.0.1`, in 581 packages scanned).

## 3.9 Planned, not implemented

Sized integers `Int8..Int64`, `Word8..Word64`, `Float32` (decided names, rev 132); operators for your own types and
`derive` (chapter 1); `Console` and file modules; `Vector` literal syntax; hashing `Dict`; JavaScript output for
`Vector`, `Bitwise64` and constrained functions; arbitrary-precision integers (a separate branch, `feat/bigint`, not in this binary).
