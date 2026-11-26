# A3b plan: members inside containers, Word64 in compared containers, the `fromFloat` literal

Branch `feat/a3b` from `ficcus` e364228a (G71 merged, so the attach suite starts at 252). Reference binary `bin/elmficA4b`.
Inputs: A3-NOTES 5.1 and 9 (F1), A4-DERIVE-DESIGN sections 1 and 5 (group S shares this container code), decisions rev 161,
166 (point 2 and 3), rev 171.

## 1. Refusals to lift

| where | today | after |
|---|---|---|
| `Spec.wellKnownRef` → `nested` (`holdsMember ... "eq"/"compare"`) | FICCUS "has its own `eq`/`compare` member ... does not call yet" for `==`, `/=`, `compare`, `<` `<=` `>` `>=`, `max`, `min`, `List.member`, `Dict`/`Set` keys, `sortBy` key, `List.maximum`, at any type that holds a custom type with the member | no refusal: the member clones of every member type inside the exact type are requested and handed to the C generator (section 2) |
| same, `Sized.wordWithoutStructuralOrder` (Word64 inside a compared type) | FICCUS "has its own `compare` member" (`sized-err-word64-tuple`) | no refusal: `cmpExpr` already compares a Word64 part with `fic_sz_u64_cmp` (unsigned) |
| Float literal at a type that is not `Float` | TYPE MISMATCH (`sized-err-float-literal`) | when a type in sight has a `fromFloat` member, the literal is typed as the relaxed `/` is (decision 3 of A3): a variable with the obligation `has fromFloat`, Elm's `Float` as its default |

`Spec.vectorSortMember` (sorting through the overlay's `sortMember`) keeps `holdsMember` as it is: correct, and no C text change.

## 2. Helper design per container (C path)

* **Specializer** (new module `Ficcus.Mono.ContainerMembers`, a few lines in `Spec`): `containerMembers` walks an exact type like
  `holdsMember` (type arguments, tuples, records, constructor fields of custom types with the arguments put in, a set of the exact types
  seen) and returns every exact custom type inside that has the member (not entering it: its own member is called). `Spec` requests the
  clone of each (`memberClone`, at the member's shape) and records it in a table `(member, exact type) -> clone`, which goes into
  `MProgram` (`mpMembers`). Those clones are roots of the program: `Spec.ordered`, `Inline` (dead clone filter) and `Known.finalize` keep them.
* **C generator**: `eqExpr` and `cmpExpr` look the exact type up in the table first: a member clone is called directly
  (`fN_eq(a, b)`; Order is turned into the sign: `tag - 1`); otherwise the existing structural code, unchanged. So the existing helpers
  (`fic_eq_N`, `fic_cmp_N`: lists, `JsArray`/`Array`, `Vector`, `Dict`, `Set`, tuples, records, `Maybe`, `Result`, custom types) call the
  member wherever the type with the member appears inside them. The helper borrows its arguments; when the clone's parameter is owned
  (`paramOwns`, Borrow pass) the argument is dupped before the call (`--rc`). A member that is a value (`eq = eqBy f`) is applied as a
  closure (`fic_ap2`, as `HVecSortCmp`). A type with the member that has no table entry is refused by the C generator (never silently
  structural).
* **Which containers.** `eq`: every type `==` accepts (lists, `Array`, `Vector`, `Dict`, `Set`, tuples, records, `Maybe`, `Result`,
  custom types). `compare`: what the type checker accepts as comparable today: lists and tuples (and `Dict`/`Set` keys, `sort`, `sortBy`,
  `max`, `min` of them). Records, `Maybe`, `Array`, `Vector`, `Dict` as `compare` subjects are A4b (built-in derived `compare`), not here.
* **JS**: unchanged; such programs are already refused (`$customOperators` for `compare` through `comparable`, `eq` by definition).

## 3. `fromFloat` (rev 166 point 3: "a `fromFloat` literal member like `fromInt`, so `0.5 : Float32` works")

`fromFloat : Float -> T` becomes a well known member (`AST.WellKnown`: shape `FromFloat`; `Float` has it, as identity). In the solver
a Float literal in a module that sees a type with `fromFloat` gets a fresh subject with a relaxed obligation (default `Float`, settled
before generalization as `/` is); without such a type nothing changes. Specializer: a Float literal at a custom type is the clone of its
`fromFloat` applied to the literal; at `Float32` the kernel `fic_sz_f32_fromfloat` (rounds to float, as `Float32.fromFloat`). `Float32`
gets the member (`gen_sized.py`, regenerated `overlay/Float32.elm`). JS: the relaxed obligation that meets a custom type sets the
`$customOperators` marker (`_note`), as for `/`. `-0.5` is `neg (fromFloat 0.5)`.

## 4. Test matrix (attach style, `ficcus-tests/attach/cases/a3b-*`)

RUN `c` cases, with `expected.out` taken from a hand written Elm twin of the program (the member calls written out) run by `bin/elm0193`
and node, never by eye: `eq` through list, tuple, record, `Maybe`, `Result`, user union, recursive and mutually recursive union,
`Dict` (values and keys), `Set`, `Array`, `Vector`, nested (`List (Maybe (Name, Int))`), imported member type, generic function at
the type, `List.member`, `/=`; `compare` through tuple, list, nested, `<` `>=` `max` `min`, `List.sort`, `sortBy`, `List.maximum`,
`Dict` and `Set` keys (tuple, list), a member defined point free (value); Word64 in tuple, list, nested, `Dict`/`Set` keys, `sort`,
`max`; `fromFloat` at a user type, at `Float32` (typed, let, argument, negative, in a list), Float uses unchanged in the same module;
errors: no `fromFloat` in sight (Elm's TYPE MISMATCH, unchanged), a type without `fromFloat` (NO MEMBER), wrong `fromFloat` shape.
Every RUN case also under `--rc` with ASan/UBSan (the attach gate). The old `a3-c-holds-*` REJECTC cases become RUN cases (same sources,
expected output from the Elm twin); `sized-err-word64-tuple` becomes RUN; `sized-err-float-literal` stays a TYPE MISMATCH when nothing in
sight has `fromFloat` (it imports `Float32`, so it becomes accepted: its row is re-recorded).
Each new case is first run on `elmficA4b` (expected: REJECTC or TYPE MISMATCH), table in the report.

## 5. Identity

Programs without a member inside a container: C text byte identical to `elmficA4b` (suite 16, `--rc`/`--no-rc`), JS identity 28,
elmdiff 1175 SAME. Then the full `gates.sh` once at the end.
