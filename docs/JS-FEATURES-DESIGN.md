# JS features: `derive`, attached functions, `Vector` and the sized integers on the JavaScript output (design note)

28 Nov 2026, branch design/js-features from ficcus 780d60b8. Input: docs/PLAYABILITY-AUDIT.md (audit/play 3f863e4d), gaps 1 and 2
of "Blocking HTML programs on JS". Each claim is tagged: **[src]** source or note read at 780d60b8, **[run]** run here with
`bin/elmficR1` (same code as 780d60b8) and node v21.5.0 / gcc, **[asm]** assumed, not checked.

## 0. Summary

The three gaps have one cause: Elm's JS generator works on the Opt graph, which has no types, while every Ficus feature is
resolved by type (in `Ficus.Mono.Spec`, on the typed Canonical modules). A constrained function already *takes* its members as
hidden leading parameters in the Opt graph; only the call sites lack the arguments **[src]**. **Recommendation (option A):**
fill the call sites in by type (dictionary passing, with arguments fixed where the type is known), during Optimize, only in
modules that use a Ficus feature. Give the structural derived members source bodies for JS, and give `Vector` and the sized
modules JS kernels through the redirect that `Concurrent` already uses. Elm-only programs never reach the new code. Estimate:
7 slices, 9 to 12 Sonnet sessions.

## 1. Where `derive` generates code, and why JS cannot see it

- `Canonicalize.Derive.prepare` turns each listed member into an ordinary member `T$$m` with a made-up signature (plus
  `a has m` per parameter) **[src]**. Group E members (`minValue` ... `enumerate`) get **source bodies** (`Canonicalize/DeriveEnum.hs`,
  A4c) **[src]**. Group S members (`compare`, `hash`, `toString`) get the **stub** `Elm.Kernel.FicDerive.T.m` in `finish`, plus one
  marker definition `$derived$T$m1,m2` per type **[src]**.
- The real code for group S is written only after specialization. `Spec` turns a use of `T$$compare`/`T$$hash` at an exact
  type into the kernel `Basics.compare`/`FicDerive.hash` at `[ByType (T args)]` and records it in `mpDerived`. Then `CGen` writes
  `fic_cmp_N`/`fic_hash_N` per exact type. `toString` becomes the C `showStmt` of `Debug.toString` (A4b, A4c notes) **[src]**.
- `Generate.checkForConstraints` (dev, prod, debug) refuses any Opt graph that holds a derive marker, a constrained function, a
  selector, an inferred-constraint marker or the custom-operator marker (`Nitpick.Constraints.constrainedNodes`) **[src]**. So
  JS refuses `derive` even when the program uses only the group E members, which have real bodies.

Why the JS generator cannot do the same: Opt nodes carry no types, the specializer's input (`Ficus.Mono.Modules`, typed Can plus
the recorded types) is kept only when the output is `.c`/`.mono` (`Flags.setKeepModules`) **[src]**, and Spec produces
`MExpr`, whose nodes carry C representation classes, not Elm types **[src]**.

Options: **(a)** `finish` writes Elm source bodies for `compare`, `hash`, `toString` (as DeriveEnum does); JS compiles them
like user code, C keeps redirecting by type (Spec ignores the body), so C output is unchanged. Alone, (a) covers only types
without parameters whose parts are built in. **(b)** a JS generator from Mono IR (option B, section 6). **(c)** (a) plus the
call-site arguments of section 2 (option A, recommended).

Problems specific to JS:

- **`toString` under `--optimize`:** prod erases constructor names and refuses `Debug` (`checkForDebugUses`) **[src]**, so
  the JS body holds the names as literals and uses helpers in a JS-side `FicDerive` overlay (Elm's escape set L16, parentheses
  around negatives and nested constructors) **[asm: writable in Elm over `String.fromFloat`/`fromInt`]**.
- **`hash`** is 64-bit splitmix/FNV-1a (`Derived.hashRuntime`) **[src]**; a JS `Int` is a double, so the C value cannot be
  an `Int` on JS (Q3).
- **`compare`** must follow the C orders (declaration rank, `Nothing < Just`, `False < True`, record fields in code point
  order, NaN GT even against itself; A4b notes) **[src]**. Not Elm's `_Utils_cmp` on custom types **[asm: it compares `$`,
  a name in dev and an index in prod]**.
- `encode`/`decoder` are missing on C too (audit P04) **[src]**: a separate item for both backends, as group E source.

## 2. Attached functions and `has` requirements on JS

**Today [run]** (scratch project, elm/core and elm/json):

| program | JS | C |
|---|---|---|
| `Money.compare a b`, `Money.add a b` (qualified call to a written member) | compiles, prints `(LT,Money 3)` | same |
| `Money 1 < Money 2` (operator on a custom type) | NOT AVAILABLE IN JAVASCRIPT YET: "operators on custom types" | `True` |
| `total : List a -> a -> a where a has add ...` used at Int | refused, names `C.total` | `6` |

A member called by its qualified name is an ordinary top-level function, so it works. Everything that is resolved by type is
refused: `where` functions, inferred ones (A5a D6), bare member names (selectors, A5b), operators on custom types, and every
sized operator (`+` at `Word8` is the A3 member `Word8.add`, SIZED-PLAN section 2) **[src]**.

**What is needed.** A constrained definition is already `sum (a$has$zero as zero) (a$has$add as add) xs = ...` in Can and Opt
(A2 section 1) **[src]**. At a use, the canonical node is `VarForeign home name ($where ...)`, and the specializer finds the
member from the exact type of the instance **[src]**. For JS, **elaboration** puts the same choice into the Opt graph as
arguments:

1. Known type head `T`: pass `T$$m`; a built-in type: the built-in member's definition (`ficBoolSucc`..., A4c) or a JS
   kernel (sized; `compare`/`eq` on records and containers: helpers, or `_Utils_cmp`/`_Utils_eq` where they give the C order
   **[asm]**).
2. A type variable of the enclosing constrained function: pass its own hidden parameter (dictionary passing).
3. A member with constraints of its own (`Tree a`'s `compare`): pass `Tree$$compare cmpA`, a closure per call, hoisted when
   constant **[asm]**.
4. Operators: `a < b` at `Money` becomes a case on `Money$$compare a b`; `+` at `Word8` becomes `Word8$$add a b`.
5. Selectors and inferred constraints: same rules; the `checkForConstraints` refusals and the A5a D6 hint go.

Where: in `Optimize` (Can to Opt), from the instance types the type recorder keeps by region and kind **[src: A4c notes]**,
today only for typed output; turn it on for modules with a Ficus marker **[asm: per module is possible; check Compile, Flags]**.
In Optimize, not on Can, so C (which reads Can from `Modules.takeAll`) is unchanged **[src]**. `ManagerOrder` reads Opt, but
elaboration adds no managers **[asm]**. Cost: an argument or closure per constrained call, acceptable on JS.

## 3. `Vector` and the sized integers on JS

**Selection.** A JS build writes only `elm-stuff/ficus-overlay-js/Concurrent.elm` (`Make.writeConcOverlay`), not a root, so a
program that does not import it is generated "exactly as before"; `concKernelOf` turns its kernel definitions into
`var ... = _FicConc_<name>` when the marker is in the graph and adds `runtime/fic_conc.js` once **[src]**. Extend this: write
`Vector`, `Int8`..`Word64`, `Float32`, `Float64`, `Bitwise64` there too (the module rule of `Build.crawlModule` stays); each
marker switches on its redirect table and kernel file (`fic_vector.js`, `fic_sized.js`). The overlay bodies are dummies
**[src]**, so every export and member needs a JS kernel or a real body.

**Representation (recommendation):**

| type | JS value | operations |
|---|---|---|
| `Int8`, `Int16` | number | compute, then `(x << 24) >> 24` / `(x << 16) >> 16` |
| `Word8`, `Word16` | number | `x & 0xFF` / `x & 0xFFFF` |
| `Int32`, `Word32` | number | `x | 0` / `x >>> 0`; `*` through `Math.imul` (then `>>> 0`) so that no product passes 2^53 |
| `Int64`, `Word64` | BigInt | `BigInt.asIntN(64, ...)` / `asUintN(64, ...)` after each operation |
| `Float32` | number | `Math.fround` after each `+ - * /`; `^` is `Math.pow` rounded once (as C: `(double)(float)pow`) |
| `Vector a` | Array | copy on update; bulk operations as JS kernels |

- SIZED-PLAN section 3 carries over: divide by 0 gives 0, `minBound // -1` wraps, shift counts `& (w-1)`, `fromInt`
  truncates, `fromString` out of range is `Nothing`, `Word64` prints unsigned **[src; JS forms asm]**.
- **BigInt vs pairs:** BigInt is exact, short, in every current engine; pairs are faster but much more code. BigInt needs
  `toString` and port handling in `fic_sized.js` (Elm's `Debug.toString` has no bigint case, `JSON.stringify` throws)
  **[asm; `_Utils_eq`/`_Utils_cmp` probably work since `===` and `<` accept bigint]**.
- **Plain `Int` stays a double on JS** (byte identity, interop), so it differs from C's 64-bit `Int` above 2^53 **[run:
  `2 ^ 60 + 1` is `1152921504606847000` on JS, `1152921504606846977` on C]**.
- **Float32 printing:** shortest digits that read back to the same float32 **[src]**; JS needs that search (1 to 9 digits,
  first that `Math.fround` reads back), fuzzed against C.
- **No typed arrays now:** the generator does not know a `Vector`'s element type (`Vector.empty` has none); elaboration could
  pick per-type kernels later (the instance type is known).
- **In-place update:** C updates a unique vector in place **[src]**; JS copies, so a `push` loop is quadratic. Mitigation:
  JS kernels for every bulk function (the Elm-written half of the overlay too); Baker rerooting arrays later if measured.
- **`sort`:** port the merge order of `fic_sort.h` (Powersort, stable, L15 **[src]**) rather than `Array.sort`, so results
  agree even for inconsistent comparators.

**Byte equality test:** the reference is the C output. (i) `sized-*`, `vector-*`, `a4*`, `a5*` attach cases on both
backends; (ii) a JS leg for the sized fuzz (40 seeds in the gates, SIZED-PLAN section 7) **[src]**; (iii) a Float32 printing
fuzz over random bit patterns.

## 4. Hard constraint: Elm-only programs stay byte identical to elm0193

- Every new piece is guarded by something an Elm program cannot contain: elaboration only in modules with a constrained use,
  derive marker or sized/Vector type; redirects only when an overlay marker is in the graph; overlays not roots (the T1a-2
  pattern; `addGlobalHelp` already branches only on the `Concurrent` marker) **[src]**.
- Gates: `jsid.sh` (28/0 in the A4c and A5c gates) **[src]**, elmdiff (1160 packages, 15 apps), and new: corpus apps
  compiled to JS by both compilers, bytes compared **[asm: elmdiff may compare only verdicts today]**; elm-stuff bytes of a
  pure Elm project equal elm0193's (the recorder must not change `.elmi`/`.elmo`) **[asm]**.

## 5. Differential testing of JS against C on the same Ficus programs

A runner (`ficus-tests/jsc/run.py`) builds every `.fic` case of attach, examples, effects and the sized fuzz to `.js` and
`.c`, runs node with `effects2/ref/run.js` **[src]** and the binary with the same `FIC_FLAGS`, `FIC_PORTS_IN`, `FIC_TIME`, and
compares stdout. Statuses: SAME, DIFF, KNOWN, JS-REFUSED, C-REFUSED.

**Known divergences exist today, in plain code [run].** One `.fic` program gave, JS versus C:
`remainderBy 0 5` `NaN`/`0`, `2^60+1` rounded/exact, `String.length "😀"` 2/1, `logBase 10 1000` 2.9999999999999996/3. `modBy 0 5`
throws on JS and gives 0 on C. Equal on both: `String.toUpper "straße"` (`STRASSE`) and `Bitwise.shiftLeftBy 31 1`. These are
library decisions L1, L5, L11 and the 64-bit `Int` decision: the C runtime follows them, while JS keeps Elm's kernels. The runner
therefore needs (a) a list of KNOWN differences keyed by case, and (b) a rule for new test programs: keep `Int` below 2^53, no
division by zero, ASCII strings, unless the case is about the divergence. This decision is open (Q1).

## 6. Options

**A: elaborate in Optimize, keep Elm's JS generator (recommended).** Pros: small; reuses A2's hidden parameters; Elm-only
output untouched by construction; separate compilation and the cache keep working; HTML keeps Elm's Browser/VirtualDom.
Cons: dictionary-passing cost; semantics defined twice (Spec, elaboration), so the jsc runner is essential; no typed arrays.

**B: JS from Mono IR** (Spec as for C, emit JS from `MProgram` before Rc). Pros: one resolution of members, derived helpers
and sized operators; exact types (typed arrays). Cons: `MExpr` is shaped for C (representation classes, kernels keyed for
the C runtime), so every kernel Elm programs use (Browser, VirtualDom, Http, Json, effects) needs a Mono-keyed JS mapping,
the work the C backend has not finished (audit); whole program, no per-module cache; JS grows with clones; a second JS
generator. 18 to 25 sessions **[asm]**.

**C: hybrid:** A now; later B or elaboration-chosen typed arrays for hot `Vector`/sized code if JS speed matters.

## 7. Slices (option A; Sonnet sessions)

| slice | content | sessions |
|---|---|---|
| JS-a | Overlay selection for JS (Vector, sized, Bitwise64, FicDerive into ficus-overlay-js, not roots); the redirect generalised from `concKernelOf` to a table per marker; `fic_sized.js` for Int8..Word32 and Float32 (with the printer); the jsc runner with KNOWN lists | 2 |
| JS-b | Int64/Word64 on BigInt; `Debug.toString` and port handling for bigint; sized fuzz JS leg | 1 |
| JS-c | `fic_vector.js`: primitives and bulk kernels, `fic_sort.h` merge order ported, `Debug.toString` of a Vector equal to C | 1.5 |
| JS-d | Elaboration in Optimize: recorder per marked module, rules 1 to 5 of section 2, removal of the `checkForConstraints` refusals (kept for unresolved cases as a compiler bug report); attach cases on both backends | 2.5 to 3.5 |
| JS-e | Group S source bodies for JS: `compare`, `toString` (prod-safe, FicDerive helpers), `hash` per Q3; derive refusal removed | 1.5 |
| JS-f | Gates: jsid, elmdiff, corpus JS bytes, elm-stuff bytes, jsc runner over attach, examples, effects, fuzz | 0.5 to 1 |
| JS-g | Review (Opus) | 1 |

Total 9.5 to 12. Order: JS-a, then JS-d (sized operators need it), then JS-b, JS-c and JS-e in any order, then JS-f. Derived
`encode`/`decoder` (both backends) is a separate item **[src: audit gap C3]**.

## 8. Risks

1. **Two resolutions** (Spec, elaboration) may pick different members (A5 rule 1, the A5a M1 case). Guard: jsc over the
   whole attach suite; an unlisted DIFF blocks the slice.
2. **Recorder coverage** of local and let-generalised uses (A5 section 3); fall back to the enclosing dictionary, else a
   compiler bug report **[asm]**.
3. **JS speed:** quadratic `Vector` loops, BigInt 10 to 50 times slower **[asm]**, member closures. Documented.
4. **Byte identity** via Optimize, which every build uses; elaboration must return its input unchanged without a marker.
5. **Prod mode:** generated bodies as ordinary Opt code get field shortening for free **[asm]**.
6. **Packages:** the dictionary convention enters the cached `.elmo` format without a version stamp **[asm]**.

## 9. Questions for the planning chat

- **Q1.** Do `.fic` programs on JS keep Elm's kernels (`remainderBy 0` NaN, `modBy 0` throws, UTF-16 `String.length`,
  `logBase`, `Int` to 2^53) or get Ficus ones (L1, L5, L11)? Recommended: Elm's now, a KNOWN list, a later "Ficus core on JS".
- **Q2.** Option A (recommended) or B?
- **Q3.** Derived `hash` on JS: (a) the 64-bit value as a double (differs above 2^53); (b) a 32-bit `hash` on both backends
  (changes C output and the A4b tests); (c) refused on JS. Recommended (b) if `hash` is for tables only.
- **Q4.** Int64/Word64: BigInt (recommended) or pairs of int32?
- **Q5.** `Vector` on JS: copy on update as a known limit (recommended), or Baker arrays in JS-c?
- **Q6.** `Int64`/`Word64` in JS ports: refuse, JSON number (exact to 2^53) or string? Must agree with E3's C port API.
- **Q7.** Accept a closure per constrained-member call (rule 3), or specialise small constrained functions from the start?
