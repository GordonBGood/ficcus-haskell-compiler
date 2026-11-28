# G71: inference of member constraints and local definitions (test only)

Branch `test/g71` from `ficcus` cb7b6595 (includes E1p 5961e413 and A4a). Binary `bin/elmficA4b`. No compiler change.
Date 2026-11-26.

Cases: `ficus-tests/attach/cases/g71-*` (56), written by `ficus-tests/attach/g71gen.py --write`. The observed results
are in `g71expect.py` and the lines of `expected.tsv` (section `# G71`). The C cases are checked in C mode: RUN `c`
(`--output=x.c --no-rc`, gcc and clang, output compared), or REJECTC with the report title and a text. Three pure Elm
cases are RUN `js+c`. Run them with:

    python3 ficus-tests/attach/attach.py --elm bin/elmficA4b -j1 --only $(grep -o '^g71-[^\t]*' ficus-tests/attach/expected.tsv | paste -sd,)

Result: 56 cases, 0 differ. They were **not** run with `--rc` (ASan, counted). The gate's attach step runs every case
that way, so the next gate run is the first `--rc` run of the 39 RUN cases.

Types used (in `Main.elm`, as in G70's `Finance.Money`): `Money` (`zero`, `add`, `compare`), `Vec` (`Vec Int Int`, the
same three members), and `Cash` (every well-known number member of A3: `add … rem`, `compare`, `eq`, `div`, `idiv`,
`mod`). The helpers `sum` (`a has zero`, `a has add`), `plus` (`a has add`) and `cmp` (`a has compare`) are constrained
top-level functions. The B3 and B4 cases use the types from `docs/review/repros`.

## Case table

"Expected" means the result follows the rules as they stand today (A2 "constraints are never inferred", A2/B3 "let
functions are held and settled by their uses", A3 bundles, A3 F4/F8). The last column classifies any result that is not
plain success.

| case | tests | result | expected | class |
|---|---|---|---|---|
| **1. Unannotated top-level functions** |||||
| q1-nosig-qualified | control: `twice m = Money.add m m` | RUN `Money 4` | yes | |
| q1-nosig-bare-member | `total xs = List.foldl add zero xs` (bare member names, no constraint in scope) | NAMING ERROR ×2 (`add`, `zero`; suggests `abs`, `e`, `pi`) | yes (bare names exist only under a `where`) | limitation: message |
| q1-nosig-call | `twice m = plus m m`, used at Money and Vec | MISSING CONSTRAINT, gives `twice : a -> a where a has add …` | yes | by design (never inferred) |
| q1-nosig-call-one-use | same, used at Money only | MISSING CONSTRAINT (not defaulted to the single use) | yes | by design |
| q1-nosig-lt | `smaller a b = if a < b …` at Money, Vec, Int, String | RUN `((Money 2,Vec 1 1),(2,"a"))` | yes (`comparable` inferred as in Elm) | |
| q1-nosig-compare | `order a b = compare a b`, same four types | RUN `((GT,LT),(GT,LT))` | yes | |
| q1-nosig-eq | `same a b = a == b` at Money (no `eq`), Vec, Int | RUN `(True,False,False)` (structural) | yes | |
| q1-nosig-plus | `dbl x = x + x` at Cash, Int, Float | RUN `(Cash 4,6,3)` | yes (`number` inferred) | |
| q1-nosig-plus-money | `dbl` at Money (only `add`) | TYPE MISMATCH "It is missing: `sub`, `mul`, `pow`, `neg`, `abs`, `fromInt`." | yes | |
| **2. Annotated, missing constraint** |||||
| q2-missing-all | `total : List a -> a`, bare `add`/`zero`, no `where` | NAMING ERROR ×2 | yes | limitation: message (should be MISSING CONSTRAINT) |
| q2-missing-all-call | `twice : a -> a`, calls `plus` | MISSING CONSTRAINT "This use of `plus` needs the type `a` to have the member `add` …", gives `where a has add : a -> a -> a` | yes | |
| q2-missing-one | `where a has add`, body also uses bare `zero` | NAMING ERROR `zero` | yes | limitation: message (the `where` block is there; the missing line is not suggested) |
| q2-missing-compare | `where a has zero, a has add`, calls `cmp` | MISSING CONSTRAINT, gives `a has compare : a -> a -> Order` | yes | |
| q2-lt-plain-var | `smaller : a -> a -> a` with `<` | TYPE MISMATCH, Elm's text ("specifically wants a `comparable`") | yes | minor: no mention of `a has compare` |
| **3. Unannotated let functions** |||||
| q3-let-once | `let g x = plus x x in g m` (outer `Money -> Money`) | RUN `Money 4` | yes | |
| q3-let-twice-one-type | `g (g m)` | RUN `Money 8` | yes | |
| q3-let-two-types | `( g m, g v )`, Money and Vec | TYPE MISMATCH "`g` needs the 1st argument to be: Money" | yes (held, monomorphic) | limitation (no generalization; message gives no reason or fix) |
| q3-let-two-types-elm | pure Elm: `g x = x + x` at Int and Float | RUN `(4,3)` js+c, = elm0193 | yes | |
| q3-lifted-two-types | `g` at top level with `where a has add` | RUN `(Money 4,Vec 2 4)` | yes | lifting avoids q3-let-two-types |
| q3-lifted-nosig | `g` at top level, no signature | MISSING CONSTRAINT with the signature | yes | by design |
| **4. Two let functions, different members of one outer variable** |||||
| q4-two-locals-bare | outer `where a has zero, add, compare`; `total` uses bare `add`/`zero`, `check` bare `compare`; Money and Vec | RUN `((Money 3,GT),(Vec 4 6,LT))` | yes | |
| q4-two-locals-call | same, locals call `sum` and `cmp` | RUN, same output | yes | |
| q4-two-locals-concrete | outer `List Money -> Money -> …`, locals call `sum`, `cmp` | RUN `(Money 3,GT)` | yes | |
| q4-two-locals-nosig | outer unannotated, used at Money | MISSING CONSTRAINT; the suggested signature has all three lines (`add`, `zero`, `compare`) on the one variable `a` | yes (unified correctly) | by design |
| q4-two-locals-nosig-pinned | outer unannotated, body also calls `Money.compare limit limit` | RUN `(Money 3,GT,EQ)` | yes (the pin settles both held obligations) | |
| q4-lifted-one | `check` lifted with `where a has compare`, `limit` a parameter | RUN `((Money 3,GT),(Vec 4 6,LT))` | yes | |
| **5. Captures** |||||
| q5-capture | outer `where a has add`; `move y = add y base` captures `base`; Money and Vec | RUN `([Money 11,Money 12],[Vec 11 22])` | yes | |
| q5-capture-call | same with `plus y base` | RUN, same | yes | |
| q5-capture-concrete | outer at Money, `move` calls `plus` | RUN `[Money 11,Money 12]` | yes | |
| q5-lifted | `move base y` at top level with `where a has add`, used as `move base` | RUN, same as q5-capture | yes | |
| **6. Review 1 B3 and B4** |||||
| b3-repro | `repros/B3`: `let y = choose t`, `k` used at Int and String | RUN `(1,"s")` | yes | **fixed** (56bb4fd0) |
| b3-nolet | control without the let | RUN `(1,"s")` | yes | |
| b3-same-type | `k` used at Int twice | RUN `(1,2)` | yes | |
| b3-module-use | `k` in module K with a use at Float in K; Main uses it at String | RUN `"s"` | yes | **fixed**: the exported type no longer depends on uses in its module |
| b3-module-nouse | no use in K; Main at Int and String | RUN `(1,"s")` | yes | |
| b4-let | `repros/B4`: `let y = get (get w)` | RUN `(42,T 41)` | yes | **fixed** (56bb4fd0) |
| b4-pipe | `y = w \|> get \|> get` | RUN `(42,T 41)` | yes | |
| b4-two-bindings | `m = get w`, `y = get m` | RUN `(42,T 41)` | yes | |
| b4-nolet | `( get (get w) + 1, W.f w )` | RUN `(42,T 41)` | yes | |
| **7. Let generalization of `/`, `//`, `modBy`, `+`, `compare`, `<` (Cash in sight)** |||||
| q7-div-float | `h y = y / 4` at `3`, `2.5` | RUN `(0.75,0.625)` | yes | |
| q7-div-two | `h` at `3.5` and `Cash 800` | TYPE MISMATCH "`Cash` and `Float` do not mix" | yes (F4: not generalized) | limitation (F4) |
| q7-div-cash-only | `h` at `Cash 300`, `Cash 800` | RUN `(Cash 75,Cash 200)` (Elm rejects this; F4 acceptance) | yes | |
| q7-idiv-two | `h y = y // 4` at `9` and `Cash 800` | RUN `(Cash 200,Cash 200)`: **the literal `9` becomes `Cash 900`** | yes (F4) | surprising, see L4 |
| q7-idiv-int | `h` at `9`, `10` only | RUN `(2,2)` (Elm's result) | yes | |
| q7-idiv-typed-int | `h` at `nine : Int` and `Cash 800` | TYPE MISMATCH "`Cash` and `Int` do not mix" | yes (F4) | limitation (F4) |
| q7-modby-two | `h y = modBy 4 y` at `9` and `Cash 900` | RUN `(Cash 100,Cash 100)`: literal becomes Cash | yes (F4) | surprising, see L4 |
| q7-modby-int | `modBy` at `9`, `10` only | RUN `(1,2)` | yes | |
| q7-plus-two | `h y = y + y` at `1`, `1.5`, `Cash 2` | RUN `(2,3,Cash 4)` (generalized) | yes | |
| q7-compare-two | `c a b = compare a b` at Int, String, Cash | RUN `(LT,GT,EQ)` (generalized) | yes | |
| q7-lt-two | `l a b = a < b` at Int, String, Cash | RUN `(True,False,True)` (generalized) | yes | |
| q7-idiv-lifted-nosig | `h y = y // 4` at top level, no signature, used at `9` and `Cash 800` | TYPE MISMATCH (h defaulted to Int, Elm's type) | yes (top-level default) | |
| q7-idiv-lifted-sig | `h : number -> number where number has idiv`; unannotated `out = ( h 9, h (Cash 800) )` | MISSING CONSTRAINT on `out`, suggests `out : ( number, Cash ) where number has idiv …` | yes (A3c: a literal whose variable has an obligation is not defaulted) | surprising, see L5 |
| q7-idiv-lifted-sig-typed | same `h`, used at `nine : Int` and Cash | RUN `(2,Cash 200)` | yes | lifting avoids q7-idiv-two |
| **8. Pure Elm controls (js+c, compared with `bin/elm0193`)** |||||
| elm-nosig-bundles | unannotated `<`, `compare`, `==`, `+` at Int, Float, String | RUN `((2,"a",GT),(True,6,3))` = elm0193 | yes | |
| elm-let-ops | let functions with `/`, `//`, `modBy` (one type each), `+`, `compare`, `<` (two types each) | RUN, = elm0193 | yes | |
| elm-lt-plain-var | `a -> a -> a` using `<` | TYPE MISMATCH; elm0193 rejects with the same text | yes | |

## Answers

**1.** A top-level function without a signature is never given a constraint, even when it has only one use: MISSING
CONSTRAINT names the use that needs it and prints the full signature to write (q1-nosig-call, q1-nosig-call-one-use).
Nothing is defaulted. The bundles behave as in Elm. `<`, `compare`, `==` and `+` infer `comparable`, equality and
`number`, and the resulting functions work at member types (Money, Vec, Cash) as well as at Int, Float and String
(q1-nosig-lt, -compare, -eq, -plus). A bare member name (`add`) outside a `where` block is an ordinary unknown variable
and gives Elm's NAMING ERROR.

**2.** If the body calls a constrained function, MISSING CONSTRAINT names the member and prints the exact `where`
line. This holds both when the annotation has no `where` block and when it has some constraints but lacks the one
needed (q2-missing-all-call, q2-missing-compare). If the body uses the member name bare, the result is NAMING ERROR
instead, in both situations (q2-missing-all, q2-missing-one). `<` on an unconstrained `a` gives Elm's own TYPE MISMATCH,
identical to elm0193.

**3.** An unannotated let function that calls a constrained function is held, and its uses settle the type. Used once,
or several times at one type, it runs. Used at two types it is a TYPE MISMATCH at the second use. Lifted to top level
with a signature it runs at both types. Lifted without a signature it is MISSING CONSTRAINT, as in 1.

**4.** Accepted, and unified correctly in every form tried: bare members under the outer `where`, calls to `sum` and
`cmp`, an outer annotated at Money, and an unannotated outer pinned in its body. When the outer function is unannotated
and generic, the single MISSING CONSTRAINT lists all three members on the one variable `a`. Lifting one of the two
locals with its own signature also runs.

**5.** Captures work in all four forms (bare member, constrained call, concrete outer, lifted with the value as a
parameter and partially applied).

**6.** B3 and B4 are no longer present. Commit 56bb4fd0 ("ATTACH fix B2, B3, B4 (REVIEW-1) … pending obligations held at
the enclosing definition") fixed them, and the existing `constraint-let-*` and `constraint-top-nosig-*` cases cover the
single-module forms. The cross-module form of B3 (review 1, suspicion 5: the exported type of `k` depending on a use at
Float inside its module) is also gone: Main uses `k` at String and it runs (b3-module-use). All four spellings of B4 run.

**7.** With a type in sight that has `div`/`idiv`/`mod`:

| let function using | generalized? | evidence |
|---|---|---|
| `/` | no: held, settled by its uses (F4) | q7-div-float RUN, q7-div-two TYPE MISMATCH, q7-div-cash-only RUN |
| `//` | no | q7-idiv-int RUN `(2,2)`, q7-idiv-typed-int TYPE MISMATCH, q7-idiv-two literal becomes Cash |
| `modBy` | no | q7-modby-int RUN, q7-modby-two literal becomes Cash |
| `+` | yes (Elm's `number`) | q7-plus-two at Int, Float, Cash |
| `compare` | yes (Elm's `comparable`) | q7-compare-two at Int, String, Cash |
| `<` | yes (Elm's `comparable`) | q7-lt-two at Int, String, Cash |

The rule is: the relaxed operators of A3 (`/`, `//`, `modBy`, and by the same code `remainderBy`, which was not run
here) carry a member obligation (`has div`, `has idiv`, `has mod`). They are held, not generalized. The bundle
operators keep Elm's constrained type variables and are generalized as in Elm. Without such a type in sight, `/`, `//`
and `modBy` keep Elm's types and Elm's results (elm-let-ops = elm0193).

**8.** Every pure Elm control agrees with elm0193 in both verdict and output: elm-nosig-bundles, elm-let-ops,
q3-let-two-types-elm and elm-lt-plain-var (the last one rejected with the same text). The remaining rejections and
surprising results (MISSING CONSTRAINT, the let function at two member types, the F4 cases, NAMING ERROR for bare
members) exist only in programs with members, so Elm has no counterpart for them. The nearest Elm programs, a let
function using `+` at two types and a let function using `/` at Float, are accepted by both compilers with the same
output.

## Limitations worth fixing

- **L1 (message).** A bare member name with no constraint in scope gives Elm's NAMING ERROR, with suggestions like `abs`,
  `e`, `pi` (q1-nosig-bare-member, q2-missing-all, q2-missing-one). In q2-missing-one this is misleading: the signature
  already has a `where` block and lacks only one line. Suggested fix: when the unknown name is a member of a type in
  scope, report MISSING CONSTRAINT, or add a hint naming the line `a has zero : a` (or `Money.zero` when one type is
  meant). Lifting does not help.
- **L2 (generalization).** An unannotated let function that needs a member is monomorphic, so using it at two types is a
  TYPE MISMATCH with no reason given (q3-let-two-types). The same function using `+` is generalized, as in Elm
  (q3-let-two-types-elm), which makes the difference hard to guess. There are two possible fixes. The cheap one is a
  hint on this mismatch ("`g` is not generalized over `a has add`; move it to the top level with a `where` block"). The
  fuller one is to generalize let functions over member constraints (the specializer clones per instance already).
  Lifting with a signature avoids it (q3-lifted-two-types).
- **L3 (F4 proper).** A let function using `/`, `//`, `modBy` or `remainderBy` is not generalized over `has div`/`idiv`/
  `mod`/`rem`. Used at Float or Int and at a member type it is a TYPE MISMATCH (q7-div-two, q7-idiv-typed-int).
  Lifting with a signature avoids it (q7-idiv-lifted-sig-typed). Lifting without one does not: it defaults to Elm's type
  (q7-idiv-lifted-nosig).
- **L4 (surprising, follows from F4).** In such a let, a literal argument silently takes the member type of another use:
  `( h 9, h (Cash 800) )` with `h y = y // 4` gives `(Cash 200, Cash 200)`, while `( h 9, h 10 )` gives `(2,2)`
  (q7-idiv-two, q7-modby-two). No Elm program changes meaning, because Elm rejects any program with Cash. Still, the same
  `h 9` means different things depending on a neighbouring use. Fixing L3 removes this, because `h 9` would then default
  to Int. Without that fix, a warning (or a rejection) for a literal settled to a member type through a held let
  function would make it visible. Lifting with a signature avoids it only for a typed Int argument (L5).
- **L5 (literal at a constrained variable).** With the lifted `h : number -> number where number has idiv …`, the call
  `h 9` in an unannotated top-level value is not defaulted to Int (the A3c rule: a literal whose variable has an
  obligation is not defaulted). The result is MISSING CONSTRAINT on `out`, with a suggested constrained *value* type
  `out : ( number, Cash ) where number has idiv …` (q7-idiv-lifted-sig). For a literal this is UNKNOWN MEMBER TYPE
  elsewhere (`a3-f7-err-literal-obligation`). Either default such a literal to Int when Int (or Float) satisfies the
  obligation through its built-in member, or at least make the message say "the literal's type is not known; write
  `(9 : Int)` as a typed value" instead of suggesting a signature that will not help.
- **L6 (minor message).** `<` on an unconstrained annotated `a` gives Elm's hint only (change to `comparable`). A line
  saying that `a has compare : a -> a -> Order` also works would show the Ficus option.

Not limitations (by design, with good messages): constraints are never inferred for top-level functions (1, 3 lifted
without signature, 4 unannotated outer). The message gives the exact signature, including several members on one
variable.

**What lifting to the top level avoids:** with a signature, L2 (q3-lifted-two-types, q4-lifted-one, q5-lifted) and L3
(q7-idiv-lifted-sig-typed). L4 is avoided only when the Int argument is a typed value, because a literal argument then
hits L5. Lifting without a signature avoids nothing: it turns L2 into MISSING CONSTRAINT and L3 into Elm's Int default.
L1 and L6 are message problems that lifting does not touch.

## Proposed notes for the shared files (not edited here)

- Ficus-Design-Decisions.md: NOTE 2026-11-26 G71 (test only, `test/g71`, elmficA4b): review 1 B3 and B4 are no longer
  present, including the cross-module B3 (suspicion 5). Let generalization with a `div` type in sight: `/`, `//`,
  `modBy` are held (F4), and `+`, `compare`, `<` are generalized. Literals in a held let take the member type of another
  use (L4). Limitations L1 to L6 are in `docs/attach/G71-INFERENCE.md`.
- PHASE1-CHECKLIST.md: G71 done (cases and report). Candidate follow-ups: L1 and L2-hint (messages, small); L3/L4
  (F4 proper); L5.
- The attach suite is now 252 cases (`gates.sh` comment updated: 159 + 37 G70 + 56 G71).
