# Review of A3 (well known members, operators, `number` / `comparable` / `appendable`)

Branch `feat/a3`, head `9c98adf5`, binary `bin/elmficA17`. A read only review: the code was read from `docs/attach/A3-NOTES.md`
sections 3 and 5 (`Type/Unify.hs` `unifyFlexSuperStructure`, `Type/Members.hs` `policyOf` `shapeErrors` `relax` `defaulting`,
`Compile.hs` `markCustomOperators` `checkShapes`, `Ficus/Mono/Spec.hs` `wellKnownRef` `holdsMember`), and about 20 probe programs
were compiled with `elmficA17` to C (gcc, `--no-rc`) and, where it mattered, to JS. Date: 2026-11-22.

## Verdict

The solver change is small and well contained (one relaxed spot in `unifyFlexSuperStructure`, everything else in `Type.Members`). No
Elm 0.19.3 program that I could construct changes type, error text or generated code unless a type with well known members is in sight.
**Two findings block the merge** (F1: silent wrong result, F2: an ill-typed program is accepted). F3 is cheap and should go in with
them. F4 to F6 can be tracked.

## Findings

### F1 (high): decision 5 is not enforced for custom types whose constructors hold a member type: `==` is silently structural

`holdsMember` (`Spec.hs`, around line 490) walks type arguments, tuples and records, not the fields of a user union. A union that
holds a type with `eq` gets the structural `==` of the C generator, which ignores the member. A3-NOTES section 5.1 mentions it in
its last sentence, but it is the silent fallback that decision 5 rules out.

```elm
type Name = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) = String.toLower a == String.toLower b

type W = W Name

-- W (Name "a") == W (Name "A")     C output: False   (the member says True; no error)
```

Only `eq` is affected today, because a union is not `comparable` unless it defines `compare` itself. Once A4 adds derived `compare`, the same gap
will apply to `compare`. Fix: let `holdsMember` look through the constructor fields of user unions (transitively, with a visited
set for recursive types) and refuse, the way it already refuses `Box Name`, `(Name, Int)` and `{ n : Name }`. Those three were
checked and are refused.

### F2 (medium-high): an imported user `modBy` / `remainderBy` is relaxed: an ill-typed program type-checks

This is limit 6 in A3-NOTES, but the effect is worse than "mistaken": the type checker accepts a program that Elm rejects, and the
C path then fails with an internal error.

```elm
module Lib exposing (modBy)
modBy : Int -> Int -> Int
modBy a b = 42 + 0 * a * b

module Main exposing (main)
import Lib
type Money = Money Int where ... mod : Money -> Money -> Money ...   -- any type in sight with `mod`
x = Lib.modBy (Money 3) (Money 10)
```

What happens: type checking passes. The C output fails with `internal: instance of author/project:Lib.modBy does not match its scheme ...
(Basics.Int) against (Main.Money)` and an "ExitFailure 1" crash box. The JS output is refused only because the module carries the
`$customOperators` marker. Elm reports TYPE MISMATCH. The cause is that `Members.relax` matches on the bare name and the written
type; `CForeign` does not carry the home module. Fix: relax only `elm/core` `Basics` (pass the home module through `CForeign`, or
mark the four Basics functions in their interface annotation); `Type.Constrain` would need a one line change.

### F3 (medium): decision 5 refusals do not use the "cannot be compiled to C yet" report

The `holdsMember` refusal (and any `report` that `wellKnownRef` issues) prints a raw line, then Elm's "I ran into something that
bypassed the normal error reporting process ... ExitFailure 1 ... open a NEW issue at github.com/elm/compiler" box, then
"Success! Compiled 3 modules." Repro: `pairEq x y = (x, 1) == (y, 1)` used at `Name`, or `{ n = Name "a" } == { n = Name "A" }`.
The P6 path above shows that the `-- FICUS: the program cannot be compiled to C yet` header exists. The `wellKnownRef` refusals should go
through it, not end in a crash box or report "Success".

### F4 (low): a let-bound function with a relaxed `/` is not generalized; a literal argument then takes the custom type

```elm
-- Money (number bundle + div) in this module
poly = let h y = y / 4 in ( h 3, h (Money 800) )     -- (Money 0, Money 2); `h 3` alone gives 0.75
```

Elm rejects this program, so Elm compatibility is not affected. Still, the literal `3` silently becomes `fromInt 3 : Money`
because the two uses unify. Either generalize let definitions over the `has div` obligation, or record the rule in the notes
(only top-level definitions are generalized) and add the case.

### F5 (low): changed error text for an invalid Elm program when a type with `div` is in sight

`f : number -> number` with `f x = x / 2` gives "This use of `/` needs the type `number` to have the member `div`, but the type annotation ...
`number has div : number -> number -> number`". Elm's text is the TYPE MISMATCH "The (/) operator is specifically for floating-point division".
It happens only in modules that can see a `div`, so it is allowed by decision 3. But I did not check that the suggested `number has div`
is accepted (a constraint on a `number` rigid variable). If it is not, the suggestion should not be given.

### F6 (note): the JS refusal of `eq` depends on the defining module's marker being in the build

`eq` is refused "by definition", in the module that defines the type. Checked: `Main` uses `==` on `N.Name`, whose `eq` is in module `N`.
The JS output is refused with "N: operators on custom types". This works today, but only because every module's marker node reaches
`Generate`. Add this as a test (`a3-js-eq-imported`) so that a later change to the dead code pruning does not quietly turn it into a
structural `==`.

## Checked and found correct

| item | probe | result |
|---|---|---|
| unconstrained `number` defaults to Int | `big = 2 ^ 40`, `big + 1` in a module with `Money` | 1099511627777 |
| literals through `fromInt` at a polymorphic type | `double : number -> number`, `double x = x * 2 + 1`, at `Money` and at Int | `Money 700`, 7 |
| `/` defaulting | unannotated top level `half x = x / 2`; let-bound `h` used only at a literal; unused let `g y = y // 2` | 1.5, 0.75, ok |
| a type with `div` only in an imported module, plain Elm `Main` | `let h y = y / 4 in h 3` | 0.75 (unchanged) |
| higher order and kernel paths with a user `compare` / `eq` | `List.sortBy`, `sortWith compare`, `sortBy .k` (record key), `Dict.keys`, `List.maximum`, `List.map2 (==)`, `(==) x` partial | all use the member |
| `compappend` | `compApp : compappend -> compappend -> Bool` at a type with `compare` and `append` | correct |
| parameterized type with members | `type V a` with `add compare append`: `++`, `List.sort` | correct |
| refusal for `Box Name`, `(Name, Int)`, `{ n : Name }` | `==` | refused (but see F3) |
| names `add`, `compare`, `eq`, ... in Elm code | members exist only in `where` blocks (mangled names, `AST.Members.split`); `Spec` keys on `elm/core:Basics.*` canonical ids | no Elm program is affected; elmdiff 1175 SAME and corpus 568 SAME agree |
| built-in members reach `Spec` as primitives | byte identity of the 16 suite programs (A3-NOTES section 8) and `builtinMember` | trusted from the gates, not re-run |

Not probed in depth: B2 AMBIGUOUS CONSTRAINT together with a bundle variable (only `a3-err-ambiguous-literal` exists). Also not probed:
`a has add` in a `where` block combined with `+` in the body. By decision 1 this should be a mismatch with the "missing" note; it needs a case.

## Missing test shapes (add to `ficus-tests/attach`)

1. F1: `type W = W Name`, `==` (expected after the fix: refused).
2. F2: imported `Lib.modBy` with a `mod` type in sight (expected: TYPE MISMATCH).
3. F4: let-bound `/` used at a literal and at `Money`.
4. F5: rigid `number` with `/` in a module with `div`, plus the suggested fix compiled.
5. F6: JS with `eq` defined in an imported module.
6. `(==)`, `compare` passed as values; `List.sortBy` with a member type key in a record.
7. `compappend` at a custom type; a parameterized type (`V a`) with the bundle; wrong shape on a parameterized type (`add : V a -> V b -> V a`).
8. `f : a -> a -> a where a has add` with `x + y` in the body (decision 1: an error, with the note).
