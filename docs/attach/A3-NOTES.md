# ATTACH A3: well known members, operators, `number`, `comparable`, `appendable` (stage A3 of docs/ABILITIES-PROPOSAL.md, section 3.3)

Branch `feat/a3` (worktree `ficcus-haskell-compiler-a3`, from `ficcus` 2e5f3b16), binary `bin/elmficA18` (A17 before the review fixes of section 9).
A3c (section 10): branch `feat/a3c` from `ficcus` fd65b5a6, binary `bin/elmficA19`, F7 and F8 fixed.
Tests: `ficus-tests/attach/` of the branch (`python3 ficus-tests/attach/attach.py --elm bin/elmficA17 --rc`; 122 cases, 43 new: `a3-*`).
Note: `tests/attach` in the workspace is a symlink into the *main checkout* (`ficcus-haskell-compiler/`, branch feat/known-pass), so cases written
there would land on the wrong branch; the new cases are in the worktree and `gates.sh` now runs from the worktree it lives in (section 8).

## 1. What a program can do now

```elm
type Money = Money Int
    where
        add : Money -> Money -> Money
        ...
a + b      -- Money.add a b, a direct call in the C output
```

| member | shape (the type the member must have) | used by |
|---|---|---|
| `eq` | `T -> T -> Bool` | `==`, `/=` (`/=` is "not eq"); a type without `eq` keeps the automatic structural `==` |
| `compare` | `T -> T -> Order` | `<` `<=` `>` `>=`, `compare`, `min` `max` `clamp` (Elm code, so derived), `Dict`/`Set` keys, `List.sort`, `sortBy`, `maximum`, `minimum` |
| `append` | `T -> T -> T` | `++` |
| `add` `sub` `mul` `pow` | `T -> T -> T` | `+ - * ^` |
| `neg` `abs` | `T -> T` | unary `-` and `negate`, `abs` |
| `fromInt` | `Int -> T` | an integer literal at `T` |
| `div` | `T -> T -> T` | `/` |
| `idiv` `mod` `rem` | `T -> T -> T` (`mod` and `rem` take the modulus first, as `modBy` and `remainderBy` do) | `//`, `modBy`, `remainderBy` |

Bundles (Elm's own variables, exact Elm meaning, no new names): `number` = `add sub mul pow neg abs fromInt compare` (no division),
`comparable` = `compare`, `appendable` = `append`. A custom type takes the place of such a variable when it has every member of the bundle with the
shape above. Custom types stay non comparable unless they define `compare` (derivation is A4). `Int` and a user type do not mix without `fromInt`.

Built-in types get their members from one table (`AST.WellKnown.builtinHas`): `Int` all of `number` plus `eq idiv mod rem`; `Float` all of `number` plus
`eq div`; `String` `append compare eq`; `Char` `compare eq`; `List` `append eq` and `compare` when its element has it; tuples `compare` (parts) and `eq`;
every other built-in type (Bool, Maybe, records, unit, ...) `eq`; functions nothing. In the C output they are the existing primitives
(`MKernel "elm/core:Basics.add"` at `Key [ByType Int]` ...): the C text of the 16 suite programs is byte identical (section 8).

## 2. Decisions taken (to be confirmed in the review)

1. **`+` needs the whole `number` bundle.** An operator is typed by Elm's own scheme (`number -> number -> number`), and a `number` variable becomes a
   custom type only when the type has all eight members. A per member rule (`+` needs only `add`) would need to know which operator made the variable;
   that origin is lost when two variables are merged. It is the reading the task gives ("a BigInt-like type with `number` but no `div`").
   A type with `add` only can be used through `a has add` constraints (A2), not through `+`. The error says what is missing (section 6, notes).
2. **A well known name carries its shape in every program.** `add : Money -> Int -> Money` is now an error, WELL KNOWN MEMBER WITH THE WRONG TYPE
   (also without a type annotation: WELL KNOWN MEMBER WITHOUT TYPE ANNOTATION). The shape check is what lets the specializer call the member without
   looking at its type. One A2 case (`constraint-wrong-type`) used `add : T -> Int -> T` and was changed to the member `plus`.
3. **`/`, `//`, `modBy`, `remainderBy` are typed by Float and Int in Elm**, so they cannot take a user type. When a type in sight (this module or an
   import) has `div` (`idiv`, `mod`, `rem`), the use is typed `a -> a -> a` with the obligation `a has div`; Elm's type is the default of `a`
   (`Float` for `/`, `Int` for the others), applied before the generalization of a top level definition. So every use at `Float` and `Int` means what
   it meant (case `a3-defaults`). When nothing in sight has the member nothing changes at all, and `/` on a type without `div` is Elm's own error
   ("The (/) operator is specifically for floating-point division"). When some other type has `div`, it is NO MEMBER.
4. **`eq` is always met.** `a has eq : a -> a -> Bool` is met by any type but a function: a custom type without `eq` gets the structural `==`.
5. **`min`, `max`, `clamp` are not members**: they are Elm code over `lt`/`gt`, so they follow `compare`. `abs` is a member (it is in `number`).
6. **JavaScript.** A module that uses a custom type as a `number`/`comparable`/`appendable`, or uses `/ // modBy remainderBy` at a custom type, or defines an
   `eq` member, gets a marker node `$customOperators` in its object graph; `Generate` refuses the program with the existing CONSTRAINED FUNCTIONS report
   (text extended, the marker is named "Main: operators on custom types"). `elm make --output=x.js` of a program without members is unchanged.
   `eq` is refused by definition, not by use (used or not, like a constrained function): `==` has no type in the solver to look at.
7. **`appendable` keys.** A clone keyed by an `appendable` variable is keyed by class (`ByApp`); at a custom type with `append` it is keyed by the exact type.

## 3. Solver changes (for the review)

Nothing in `Type.Occurs`, `Type.Instantiate` changed; the review round (section 9) added the home module to `CForeign`/`COperator` (`Type.Type`, `Type.Constrain.Expression`). The line numbers are those of the branch head.

| file | lines | change |
|---|---|---|
| `Type/Unify.hs` | 5-7, 51-89 | `Policy` (a custom type may take the place of a `SuperType` variable; an IO function so that the solver can note that it did), `noPolicy`, `unify = unifyWith noPolicy`, `unifyWith` |
| | 90-95, 164-176, 222-232 | the policy travels in `Vars` (the state of the CPS unifier): `Vars`, `onSuccess`, `register`, `customOk`, `guardedUnify` |
| | 440, 460-462, 488-492 | `unifyFlexSuperStructure`: a type constructor that is not an atom of the variable's kind, and not a List, goes to `custom` (merge when the policy allows, else the old mismatch). The only place where Elm's rule is relaxed |
| `Type/Members.hs` | 24-32, 44, 54, 64 | exports and imports |
| | 163-192 `policyOf` | the policy from the member table: the type has every member of the bundle, each with its shape (`WK.fits`); sets the flag (the JS marker) when it says yes |
| | 193-223 `shapeErrors` | the well known members of the module's own types with the wrong type or no annotation |
| | 224-278 `relax`, `relaxedObligation`, `relaxedUse`, `defaulting` | the `/ // modBy remainderBy` typing of decision 3 and its default |
| | 279-342 `notesFor` | extra sentences on a mismatch that involves a custom type with well known members (what is missing; `Int` does not mix) |
| | 343-365 `Obligation`, `Tools` | `Obligation` has a `_default` field; `Tools` has `_policy` and `_note`; 381, 412-420, 427-461, 541-544, 567-628, 687, 706 are the constructor patterns that follow |
| | 411-562 `resolve` | built-in subjects through the table (`builtin`, `shaped`: the member must have the shape at the subject type; `compare` of a list or tuple makes obligations for the parts); a custom type without the member but `eq` is met; `_note` when a relaxed use meets a custom type; the policy is used for the unifications |
| `Type/Solve.hs` | 22-27 | imports |
| | 49-64 | `runWith`: the flag; the marker annotation `$customOperators` in the result when it was set |
| | 74, 89-99 | `State` has `_flag` (`emptyState`) |
| | 112-192 | the five `Unify.unify` calls (CEqual, CLocal, CForeign, COperator, CPattern) are `unifyWith (policyOf ...)`; CForeign and COperator instantiate through `instantiateUse`; mismatches go through `noted` |
| | 240-255, 282-284 | before `Members.hold`: `Members.defaulting`; its errors join the hold errors; the `State` patterns carry `flag` |
| | 349-355 `noted`, 363-382 `instantiateUse` | the notes; the relaxed instantiation (`(a, a -> a -> a)` instantiated once, the second part is the type of the use) |
| | 394-395 `discharge` | the tools carry the policy and `_note` |
| `Compile.hs` | 11, 16-17, 27, 55-71, 93, 115 | imports; `compile`/`compileTyped`/`typeCheck*` call `checkShapes` and `markCustomOperators` |
| | 127-150 | `markCustomOperators` (the marker node; also for a module that defines an `eq` member), `checkShapes` (before type checking) |
| `AST/Constraints.hs` | 37, 198-205 | the name of the marker |
| `AST/WellKnown.hs` (new) | 1-220 | names, shapes, `fits`, the shape as an annotation, bundles, the built-in table, the operator to member map |
| `Reporting/Error/Type.hs` | 61-64, 196-200, 266-295, 371-397 | errors `WellKnownShape`, `WellKnownNoSignature`, `WithNotes` and their reports; the built-in note and the number sentence reworded (the built-in types have members now) |
| `Nitpick/Constraints.hs`, `builder/src/Generate.hs`, `builder/src/Reporting/Exit.hs` | 30-52; 42, 192-194; 1971-1976 | the marker is a constrained node; the refusal text |
| `Type/Dump.hs` | 723-725 | the dump does not call a relaxed use a failed instance match |
| `elm.cabal` | 145 | `AST.WellKnown` |

### Specializer (`Ficus/Mono/Spec.hs`, the C path)

| lines | change |
|---|---|
| 342-360 `hiddenMembers` | the constraint members go through `memberRef` (before: custom types only) |
| 361-434 `memberRef`, `memberClone`, `builtinMember` | the clone of a member of a custom type (the A2 code, factored out); for a built-in subject the primitive (`Basics.add` kernel at `[ByType t]`, `Basics.abs`/`identity` clones, `toFloat`, the `append` keys) |
| 435-510 `wellKnownRef`, `derived`, `wellKnownDerived`, `shapeType`, `holdsMember` | an operator or `Basics` function at a type with the member is the member's clone (decided from the instance type of the callee: its first parameter); `< > <= >= /=` are `FicOverlay.ficLt ...` (compare/eq at the member); the guard for a type that *holds* a custom type with `eq`/`compare` (limit 1) |
| 1279-1289 `resolve` | `foreignOrTop` asks `wellKnownRef` and `wellKnownDerived` first |
| 750-759, 772-786, 787-800 | `customTypeOf`; an integer literal at a custom type is `fromInt`; unary `-` is `neg` |
| 952-957 | a number pattern at a custom type is an error |
| 529-537 (`keyForM`), 732-745 (`keyFor`) | appendable keys (decision 7) |
| `overlay/FicOverlay.elm` 197-224 | `ficLt ficGt ficLe ficGe ficNeq` |

No change in `CGen`, the IR, the runtime or the Rc passes: a member call is an ordinary call of a clone.

## 4. Worked examples (all are cases of `ficus-tests/attach`, run as C with gcc and clang, and `--rc` under ASan+UBSan with 0 live objects)

| case | what it shows |
|---|---|
| `a3-money` | every operator on a `Money`: `+ - * ^ -x negate abs / // modBy remainderBy ++ < <= > >= compare max min clamp == /=`, `number`/`comparable`/`appendable` functions, `List.sort`, `Dict`, `Set` |
| `a3-bigint` | `number` and nothing else (no `div`, no `eq`): 25!, 2^100, literals, `Dict` and `List.sort` keys, structural `==` |
| `a3-keys` | `Version` with `compare` only as `Dict` key, in `Set`, `List.sort`, `sortBy`, `maximum`; a wrapper `Desc` with a reversed order |
| `a3-neq` | `/=` and `==` through `eq` (case-insensitive name, an unordered pair), `List.member`, `filter`; types without `eq` keep `==` |
| `a3-literals` | literals through `fromInt`, `-3`, `List.sum`, `List.product`, a `number` constant used at `Tenths`, `Int` and `Float` |
| `a3-constraint-builtin` | A2 constraints met by `Int`, `Float`, `String`, `List`, `Char`, tuples, `Maybe` and a custom type |
| `a3-defaults` | the `/ // modBy remainderBy` typing in a module that has a type with `div ...`: Float and Int uses unchanged |
| `a3-err-missing-member` | TYPE MISMATCH plus "It is missing: `sub`, `mul`, ..." |
| `a3-err-div` | `/` on a `number` type without `div`: Elm's own error |
| `a3-err-div-others` | the same with `div` on another type: NO MEMBER |
| `a3-err-mix-int` | `Money 1 + seven`: TYPE MISMATCH plus "do not mix: there is no automatic conversion" |
| `a3-err-ambiguous-literal` | `total [ 1, 2, 3 ]` with `a has add`: UNKNOWN MEMBER TYPE (a literal is `number`, never decided) |
| `a3-err-wrong-shape`, `a3-err-no-signature` | the two well known member errors |
| `a3-err-not-comparable` | a custom type without `compare` as a `Dict` key: Elm's message |
| `a3-js` | `--output=out.js` of a program that adds two `Money`: CONSTRAINED FUNCTIONS |

## 5. Not done, known limits

1. **A type that holds a custom type with `eq` or `compare`** (a list, tuple, record, `Maybe`, `Dict`, or a custom type with such a type in a constructor field) used with `==`, `/=`, `compare`,
   `<`, `max`, `Dict`/`Set` keys, `List.member`, `sortBy`, ...: the C generator builds structural code per type and does not call the member, so the specializer refuses
   (`Spec.holdsMember`, called from `wellKnownRef`) instead of generating code that ignores the member. The search follows type arguments, tuples, records and the constructor
   fields of every custom type of every module (aliases are already expanded in the union table), with a set of the custom types entered, so recursive and mutually recursive types end.
   The report names the type with the member and the path to it (`W > Name`). A custom type with the member itself is not searched: its own member is called. Fix to lift the
   limit: have `CGen.eqExpr`/`cmpExpr` call the member clones (needs the clone ids and the ownership of their parameters in the `--rc` build).
   Checked paths (all refused, cases `a3-c-holds-*`): `==` and `/=` on a union, recursive, mutually recursive, aliased, imported and generic (`same x y = x == y` at `W Name`)
   types; `List.member`; `<` and `max` on a tuple, `List.maximum`; `Dict` keys (tuple, list), `Set.member`, `sortBy` with a record or tuple key. A type that does not hold a member type
   keeps the structural code (`a3-holds-ok`).
2. The JS output refuses operators on custom types (decision 6). `eq` by definition.
3. `derive` is A4; sized integers are not part of this change (no sized `Int` types exist in the table: they would add rows to `builtinHas`).
4. A well known member cannot have constraints of its own (`where` on its signature): WELL KNOWN MEMBER WITH THE WRONG TYPE.
5. `hash`, `toString` are not well known members yet (proposal 3.3).
6. (fixed in the review round, section 9) `modBy` and `remainderBy` were relaxed by name; now only `elm/core` `Basics`.
7. The `.types` dump of a relaxed use shows the type at which it is used (`Money -> Money -> Money`), not the scheme of `Basics.idiv`.

## 6. Errors (Elm's voice)

NO MEMBER (existing, now also for `/ // modBy remainderBy`), UNKNOWN MEMBER TYPE (existing), TYPE MISMATCH with notes ("`Money` can be used as a `number` when it defines all
the members of `number` (...) with the types the language needs. It is missing: ..."; "`Money` and `Int` do not mix: there is no automatic conversion. `Money.fromInt` makes a `Money` from an `Int`."),
WELL KNOWN MEMBER WITH THE WRONG TYPE, WELL KNOWN MEMBER WITHOUT TYPE ANNOTATION. A note is added only when the custom type has at least one well known member, so an ordinary Elm mistake keeps Elm's text.

## 7. What changed in other files

`ficus-tests/gates.sh`: `R` is the worktree the script is in (it was `$W/ficcus-haskell-compiler`, the main checkout), the attach step runs `$R/ficus-tests/attach/attach.py`
(not the `tests/attach` symlink), default binary `elmficA17`, expected attach count 95. A2 cases: `constraint-wrong-type` (member `plus`), the text of `constraint-no-members-at-all`
(`expected.tsv`). `bin/BUILDS.txt`: the line for `elmficA17`.

## 8. Gates

Full `ficus-tests/gates.sh` (`KEEP=1`, binary `elmficA17`, code commit 9eafcedc), all green:

| gate | result |
|---|---|
| runtime, stringdiff | 0 non-ok, all agree |
| attach (`--rc`, ASan/UBSan) | 95 cases, 0 differ from expected.tsv |
| types matrix | 267 PASS, 1 XFAIL (unchanged) |
| JS identity | 28 identical, 0 different |
| examples (plain, drop-all, rc+san) | 281 each |
| fbip / rcfaults / rcfaults-big | 0 failures / 0 missed of 1362 / 0 missed of 295 |
| rcgate-san | ok |
| suite (`run_all.py`) | 16 programs: 16 PASS |
| typed corpus | 581 projects: 568 SAME, 12 BOTH_REJECT_SAME, 1 VERDICT_DIFF (same single one as before: salix-aws-spec) |
| lib-rcsan | 108 PASS, 59 FIXED, 0 fail |
| elmdiff | 1175 comparisons: 1175 SAME, 0 DIFF (1160 + 15 apps) |

Byte identity: the C text of the 16 suite programs, `--rc` and `--no-rc`, is identical between `elmficA16` and
`elmficA17` (32 of 32), so no explanation of differences is needed.



## 9. Review round (docs/review/REVIEW-A3.md)

| finding | what was done |
|---|---|
| F1 | `holdsMember` follows constructor fields (section 5.1). `Ficus.Mono.Spec`: `sUnions` in the state, `holdsMember tops unions member type` gives the path. Cases `a3-c-holds-*` (union, recursive, mutual, alias, generic, `List.member`, tuple, record, `Dict` key, `sortBy`, `Set`, imported type, imported holder and member type) and `a3-holds-ok` (no false positive; recursive and mutual types without a member compare structurally) |
| F2 | `CForeign` and `COperator` carry the home module (`Type.Type`, `Type.Constrain.Expression`, `Type.Solve.instantiateUse`); `Members.relax` relaxes only `ModuleName.basics`. Cases `a3-err-lib-modby`, `a3-err-lib-remainderby` (TYPE MISMATCH as in Elm), `a3-modby-user` (a local `modBy`, an imported user `modBy` on Int, `Basics.modBy` at `Money`) |
| F3 | every refusal of the specializer and the C generator is raised as `Exit.MakeFicus` through the task error path (`Make.failWith`), rendered as `-- FICUS: the program cannot be compiled to C yet`; no crash box (it came from `exitWith` inside the task, caught by the exception reporter), exit status 1, and `Reporting.attemptWithStyle` flushes stdout first so the front end's "Success! Compiled" line comes before the report, never after it. `attach.py` has the outcome REJECTC that checks all of this |
| F5 | `number has div` is accepted by the type checker, so the suggestion is right. It exposed a bug (below, fixed): case `a3-rigid-div`, `a3-err-rigid-div` (the message) |
| F6 | `a3-js-eq-imported` |
| F4 | not fixed; case `a3-known-let-div` records the behaviour (C only) |
| shapes 6, 7, 8, B2 | `a3-values`, `a3-param`, `a3-err-param-shape`, `a3-err-constraint-plus`, `a3-err-ambiguous-bundle`, `a3-err-ambiguous-number` |

New findings and fixes of this round:

* **F9 (fixed)**: a relaxed `/`, `//`, `modBy`, `remainderBy` inside a generic function with `a has div` (or `number has div`) called at `Float` or `Int` ended in `internal: instance of Basics.fdiv does not match its scheme`
  (the instance type is the variable, the scheme says Float). `Spec.wellKnownRef` now maps that use to the built-in member (`builtinMember`).
* **F10 (fixed)**: WELL KNOWN MEMBER WITH THE WRONG TYPE showed the expected type without the parameters of a parameterized type (`append : V -> V -> V`); it shows `V a -> V a -> V a`.
* **F7 (fixed in A3c, section 10; found by the parameterized-type case)**: a member of a parameterized type applied to an unresolved number literal, `compare (V [ 1 ]) (V [ 2 ])` or `V [ 1 ] ++ V [ 2 ]` with `type V a = V (List a)`, compiles but the program crashes (SIGSEGV in `List.length`): the instance type has the `number` variable
  unresolved and `mtypeOf` turns an unmapped variable into `ref`, so the clone of the member is keyed with `V ref` and the list holds unboxed Ints. With typed elements (`V [ one ]`, `one : Int`) it works (`a3-param` uses them). Present in A17, not caused by this round. Fix idea: default a `number` variable of an instance type to `Int` in `wellKnownRef`.
* **F8 (fixed in A3c, section 10)**: the F4 program is accepted by `--output=x.c` and rejected by `--output=/dev/null` (`h needs Float`, as in Elm): the same source type checks differently in the two output modes. Not investigated.

Gates of the review round (`KEEP=1`, `elmficA18`, code commit 673cec97), all green: runtime 0, stringdiff agree, attach 122 cases 0 differ (`--rc` ASan/UBSan), types 267 PASS 1 XFAIL, JS identity 28/0,
examples 281 x3, fbip 0 failures, rcfaults 0 missed of 1362, rcfaults-big 0 missed of 295, rcgate-san ok, suite 16 PASS, typed corpus 581: 568 SAME, 12 BOTH_REJECT_SAME, 1 VERDICT_DIFF (salix-aws-spec, as before),
lib-rcsan 108 PASS 59 FIXED, elmdiff 1160 + 15 SAME, 0 DIFF. C text of the 16 suite programs: identical to `elmficA16` in `--rc` and `--no-rc` (32 of 32).


## 10. A3c: F7 and F8 (branch `feat/a3c`, binary `elmficA19`)

**F7, root cause.** Not the type checker: `compare (V [ 1 ]) (V [ 2 ])` type checks with the obligation `V number has compare`, which `V`'s member discharges;
the `number` variable itself has no obligation. The specializer defaults such a dead variable to Int (`Type.Readout.applyDefault`, used by `nodeType` and
`keyFor`), but `Spec.foreignOrTop` passed the *raw* instance type to `wellKnownRef` and `wellKnownDerived`, so the member clone was keyed `V ref`
(boxed elements) while the literal list was built as `List Int` (unboxed): SIGSEGV. Fix: the instance type is defaulted there too (`instD`).
Rule (Elm's): an unconstrained `number` defaults to Int, also inside a member's subject type (`V number`). A literal whose *own* variable has an obligation
(`smallest 3 2` with `a has compare`) is not defaulted: UNKNOWN MEMBER TYPE, as before (`a3-err-ambiguous-literal`), in every output mode.
**Check.** `Spec.mtypeOf` returns an error for a `number` variable that is neither in the clone's environment nor defaulted, and `Spec.classOfTy`
reports one (`internal: the number variable ... is not resolved`, naming the definition): the build stops with the FICUS report instead of a crash.
It stops no existing program: 0 hits in the suite (16), examples (281 x3), attach (126), library (167), rc tools, and the typed corpus run through the
specializer (`TYPED_OUT=x.mono typed_check.py`, 581 projects: 524 SAME, 11 BOTH_REJECT_SAME, 1 BOTH_REJECT_TEXT_DIFF, 45 VERDICT_DIFF, every project with the same status on `elmficA18` and `elmficA19`, no internal error; the 45 are old limits of the `x.mono` path: packages it cannot resolve (`Random`, `Regex` imports), the Int literal range, dependency resolution).

**F8, root cause.** Not the output target as such, but the rank structure: `Members.defaulting` and `Members.hold` (A3, A2c) tell a top level definition
from a let definition by its rank (`outer > outermostRank`). Elm's solver opens no rank for a `CLet` without variables, which is what a definition whose
annotation has no type variable makes (`poly : ( Money, Money )`). So in plain mode (`/dev/null`, JS) such a definition (a) never defaulted its own relaxed
uses (`q : String`, `q = Debug.toString (3 / 4)` with a `div` type in sight was UNKNOWN MEMBER TYPE: an Elm-valid use rejected) and (b) its let definitions
counted as top level ones, so `h y = y / 4` was defaulted to Float at once (the F4 verdict). The typed mode (`--output=x.c`, `.types`) gives every definition
a scheme variable (`Constrain.Expression.defHeader`), so the definition always had a rank and the program was checked as decision 3 intends. Same source,
two verdicts, decided by the annotation and the mode.
Fix (`Type.Solve`, `topLevel`): a `CLet` with a header at the outermost rank always takes the general case (a rank of its own) in both modes. For a program
without a type with `div`/`idiv`/`mod`/`rem` in sight (every Elm 0.19.3 program) no relaxed obligation exists, so defaulting and hold do nothing; the
only other effect is that the body of such a definition is generalized in its own pool (its type has no variable, so nothing escapes) and the hidden
cycle check of `generalize` (D10, 1491) now also runs for it, as it already did in typed mode. Gates: types matrix, JS identity, elmdiff unchanged.
**Recommendation on F4 (decision for the review).** Keep the typed mode's reading in both modes: a let function using a relaxed `/` is not generalized
over `has div`; it is held and settled by its uses (F4 gives `(Money 75, Money 200)`); used at two types it is a TYPE MISMATCH (`a3-f8-err-let-div-two-types`).
Elm rejects F4, but the acceptance cannot change the meaning of any program Elm accepts: the relaxation exists only when a type with a `where` member
`div` (or `idiv`, `mod`, `rem`) is in sight, which no Elm program has, and Float/Int uses keep Elm's type (top level default, checked against
`bin/elm0193` on `a3-f8-closed-annotation` with the type removed: same output). F4 proper (generalizing a let `/` over `has div`) is not done.

Cases (`ficus-tests/attach`, 126): `a3-f7-literal` (typed and untyped definitions, Float literals, `<`, `max`, `++`, `List.sort`, `sortBy` on a record
field, a literal inside a record field, `Dict` keys and `Dict.get`, a generic `a has compare` function at `V`), `a3-f7-err-literal-obligation`,
`a3-f8-closed-annotation` (js+c: direct, in a let, with arguments, recursive, unannotated), `a3-f8-err-let-div-two-types`; `a3-known-let-div` is no longer
`c_only` (checked in both modes). On `elmficA18`: `a3-f7-literal` SIGSEGV, `a3-f8-closed-annotation` UNKNOWN MEMBER TYPE, `a3-known-let-div` TYPE MISMATCH.

Gates (`KEEP=1`, `elmficA19`, commit b1a9cb3e), all green: runtime 0, attach 126 cases 0 differ (`--rc` ASan/UBSan), stringdiff agree, types 267 PASS 1 XFAIL,
JS identity 28/0, examples 281 x3, fbip 0 failures, rcfaults 0 missed of 1362, rcfaults-big 0 missed of 295, rcgate-san ok, suite 16 PASS, typed corpus 581:
568 SAME, 12 BOTH_REJECT_SAME, 1 VERDICT_DIFF (salix-aws-spec, as before), lib-rcsan 108 PASS 59 FIXED, elmdiff 1160 + 15 SAME, 0 DIFF.
C text of the 16 suite programs: identical to `elmficA18` in `--rc` and `--no-rc` (32 of 32).
