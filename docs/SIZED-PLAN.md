# Sized integers and Float32 (G24, G41): plan

Branch `feat/sized` from `ficcus` a34ecd14 (A3 and A3c in), binary `bin/elmficN1`. Not merged.

## 1. Surface

Modules `Int8 Int16 Int32 Int64 Word8 Word16 Word32 Word64 Float32 Float64`, each exposing its type and
`fromInt toInt toString fromString`, the integer ones also `and or xor complement shiftLeftBy shiftRightBy popCount`
(`Float32`: `fromFloat toFloat`). `Int64` and `Float64` are `type alias` of `Int` and `Float` (recommendation a: one type, no
conversion; `Int64.toInt` and `Float64.toFloat` are `identity`). Operators `+ - * ^ // / modBy remainderBy negate abs`, the
comparisons, `compare`, `min max clamp`, `==`, `Dict`/`Set` keys, `List.sort` work at every sized type through the A3 members.

## 2. Mechanism (no solver change)

A sized type is declared in its overlay module like `Vector` is: `type Int8 = FicInt8Builtin where add : Int8 -> Int8 -> Int8 ...`
with the A3 members of its row of the table (`number` bundle and `compare` for all; `idiv mod rem` for integers; `div` for
`Float32`; `eq` is structural). The type checker therefore already accepts `+` and `Dict` keys at it (A3 policy). The overlay
sources are generated (`ficcus-tools/gen_sized.py`, output checked in under `overlay/`) and added to the `.c`/`.mono` source
directories like `Bitwise64`; a project or package module of the same name wins (module rule, `Build.crawlModule`), and the
marker constructor tells the overlay's type from a user type of the same name (as `vectorMarker`).

The specializer (`Ficcus.Mono.Sized`, new; hooks in `Spec` and `CGen`) knows the set of sized types (unions with the marker):
* class: the 8 byte slot, `CI64` for integers and `CF64` for `Float32`; scalars, struct fields and `Vector` elements are the
  same slots as `Int`/`Float` (recommendation d; natural width storage is H24/G30);
* members and operators at a sized type become kernel calls `elm/core:Sized.<Type>.<op>` whose C is a macro of the new
  `runtime/fic_sized.h` (a call of a member by name, `memberRef`, and the operator functions, `wellKnownRef`, give the same kernel;
  `< > <= >= /=` are kernels too, no `ficLt` detour);
* a literal at a sized type is checked against the range of the type at compile time and emitted as a constant
  (`300 : Word8` is `-- INTEGER OUT OF RANGE`-style report, in the FICCUS refusal channel); `-128 : Int8` is accepted, `-1 : Word8`
  is rejected (write `complement 0`);
* structural code (`==` on records/lists, `Debug.toString`, structural `compare`) treats them as `Int`/`Float` slots, except
  `Word64` (unsigned print, unsigned order) and `Float32` (printed at float precision).

## 3. Semantics

Representation of an `IntN`/`WordN` value: the int64 holding the sign or zero extended value (so `toInt` is free); every
operation computes in `uint64_t` and re-normalizes with explicit casts, so no signed overflow exists in the C. `Int` already does
this (`FIC_ADD64`, `FIC_SUB64`, `FIC_MUL64`, `FIC_NEG64`, `fic_idiv`, `fic_ipow` are unsigned or special cased): **unsigned
operations, not `-fwrapv`**; the UBSan runs of the gates confirm it, and a test covers `minInt` cases.
* `//`, `modBy`, `remainderBy`: divisor 0 gives 0, `minBound // -1` wraps, as `Int` (`fic_idiv` and `fic_modby`).
* `^`: repeated squaring, wrapping; negative exponent as `Int` (decision L4).
* `neg` wraps (WordN too); `abs` of `IntN` wraps at `minBound`, of `WordN` is the identity.
* shifts: count `& (width - 1)`; `shiftRightBy` arithmetic for `IntN`, logical for `WordN`; `popCount` counts the bits of the
  width.
* `fromInt` truncates (two's complement); `toInt` extends (`Word64.toInt` reinterprets as signed); `fromString` gives `Nothing`
  for text out of range (it does not wrap), `toString` prints unsigned for `Word64`.
* `Float32` is held in a double that is always exactly a float value: each result is rounded with `(double)(float)(...)`, which
  is correctly rounded for `+ - * /` (the double has more than twice the precision), so the result equals C `float`
  arithmetic with `-ffp-contract=off`; `^` is `pow` in double rounded once. Printed with the shortest digits that read back to
  the same float, laid out as Elm prints a `Float` (JavaScript rules).

## 4. Known limits (reported, not hidden)

* `Word64` inside a tuple/list/record used as a `compare`/`Dict` key: structural code is signed, so it is refused with a clear
  message (the other sized types compare structurally correctly).
* JS builds: the overlay modules exist only in `.c`/`.mono` builds, so `import Int8` in a JS build is the usual missing module
  error; a clearer text is added if cheap (G10 later). `Checked` variants later (g).

## 5. Steps (each committed)

1. this plan; 2. `runtime/fic_sized.h` and a C oracle test with boundary values and a random check; 3. generator, overlay
modules, `Ficcus.Mono.Sized`, the hooks, build `elmficN1`; 4. tests (attach cases, boundary program against the C oracle, fuzz of
200 seeds, literal range errors, conversions, `Dict`/`List.sort`); 5. corpus scan (`vscan2.py`) for package modules named like
these; 6. full gates `KEEP=1`; notes `docs/attach/SIZED-NOTES.md`-style report in this file, `bin/BUILDS.txt`.

## 6. What was built, and where it differs from the plan above

Code: `compiler/src/Ficcus/Mono/Sized.hs` (new: types, kernel ids, C text, literal ranges), `runtime/fic_sized.h` (new, emitted only by programs that
use it, so the C text of other programs is unchanged: 32 of 32 suite outputs byte identical to `elmficA19`, `--rc` and `--no-rc`),
`ficcus-tools/gen_sized.py` + `overlay/{Int8..Word64,Float32,Int64,Float64}.elm`. Small changes to upstream files: `Spec.hs` (the set of
sized types from the marker unions, class, `memberRef`/`wellKnownRef` kernels, literals, `-x`, module functions, the unreached definitions
pass, `holdsMember` exemption), `Kernel.hs` (arity and signature through `Sized`), `CGen.hs` (kernel text, `cmpExpr`, `showStmt`, class table,
runtime emission), `CRuntime.hs`, `Overlay.hs` + `Make.hs` (the ten modules), `Exit.hs` (a message `@@ TITLE` is a report of its own),
`Reporting/Error/Import.hs` (hint for the JS refusal), `elm.cabal`. No change in the solver: A3 already accepts a type with the members.

Differences from the plan:
* `Float32` is a double that always holds exactly a float (not a C `float`); the results are the same as C `float` arithmetic and the
  tests compare with numpy `float32`. A separate formatter prints the shortest digits at float precision (`fic_sz_fmt_f32`).
* A number pattern at a sized type (`case x of 0 ->`) is a TYPE MISMATCH: Elm types an integer pattern as `Int`. Not changed.
* `-1 : Word8` is rejected (INTEGER OUT OF RANGE); `-128 : Int8` is accepted. A `Float` literal is not a `Float32` (`Float32.fromFloat 0.5`);
  an integer literal is (`3 : Float32`, through `fromInt`, rounded to float).
* The range check is in the specializer (the report is `-- INTEGER OUT OF RANGE`), so it needs the C output; it also covers definitions that
  `main` does not reach (when a sized type is in the program the other project definitions are specialized once more and dropped).
* `Word64` inside a list, tuple, record or custom type that is compared or used as a key is refused with the A3 limit message (held as signed
  bits, the structural order would be wrong); a `Word64` key or value of its own is fine. `==` is fine everywhere.
* `Int8(..)` has to be exported for the members, so the constructor `FicInt8Builtin` is visible; it is never a value a program should build.
* Extras: `minValue`, `maxValue` in every integer module.
