# A3b: members inside containers, Word64 in compared containers, the `fromFloat` literal

Branch `feat/a3b` (worktree `ficcus-haskell-compiler-a3b`, from `ficcus` e364228a), binary `bin/elmficA3b` (f621dd68). Plan:
`docs/A3B-PLAN.md`. Lifts A3-NOTES 5.1 (the refusal of member types inside containers) and the sized limit of rev 166 point 2, and adds
the literal of rev 166 point 3. Not merged; for the Opus review.

## 1. What works now

```elm
type Ci = Ci String
    where
        eq : Ci -> Ci -> Bool
        compare : Ci -> Ci -> Order
Set.fromList [ ( ci "a", 1 ) ] == Set.fromList [ ( ci "A", 1 ) ]       -- True, through Ci.eq
Dict.get ( ci "K", [ ci "l" ] ) d                                      -- a tuple key compared through Ci.compare
List.sort [ ( big, 0 ), ( small, 0 ) ]                                 -- Word64 parts in unsigned order
x : Float32
x = 0.1                                                                -- Float32.fromFloat 0.1
```

* **`eq`** is called wherever the type appears inside a type compared with `==`/`/=` (also `List.member`, `Dict`/`Set` equality):
  lists, `Array` (tail and tree), `Vector`, `Dict` keys and values, `Set`, tuples, records, `Maybe`, `Result`, user unions (also
  recursive, mutually recursive, parameterized), across modules.
* **`compare`** is called inside what the type checker accepts as comparable: lists and tuples, so `compare`, `<` `<=` `>` `>=`, `max`
  `min`, `List.sort`/`sortBy`/`maximum`/`minimum`, `Dict` and `Set` keys of them. Records, `Maybe`, `Array`, `Vector`, `Dict` as
  `compare` subjects are not comparable in the type checker: that is A4b (derived built-in `compare`).
* **Word64** inside a compared tuple or list: unsigned order (the structural code already used `fic_sz_u64_cmp`; only the refusal went).
* **A member written point free** (`compare = byKey`), as a lambda, or with one parameter is called through a two-parameter eta clone.
* **`fromFloat : Float -> T`** is a well known member. A Float literal in a module that sees a type with it is typed like the relaxed
  `/` of A3 (decision 3): a fresh subject with `has fromFloat`, defaulting to Elm's `Float` before generalization. At `Float32` it is
  the kernel of `Float32.fromFloat` (rounded to float, so `0.1 : Float32` equals `Float32.fromFloat 0.1`), at a user type the clone of
  its member. Without such a type in sight nothing changes (every Elm program).

## 2. Design (as planned)

| piece | where |
|---|---|
| find the member types inside an exact type (type arguments, tuple/record parts, constructor fields with the arguments substituted; each exact type once; sized types are scalars; a non-regular type stops after 2000 types with a FICCUS report) | new `Ficcus/Mono/ContainerMembers.hs` |
| at a use of `==`, `compare`, `<` ... at such a type: request the member clone of each (shape type), record `(member, exact type) -> clone`; an eta clone (`T$$m$eta`) when the member is not a function of two parameters | `Spec.hs` 514-570 (`containerMembers`, `containerMember`, `etaMember`), replacing the refusal in `wellKnownRef` (503) |
| the table in the program; its clones are roots | `Ir.hs` 156 (`mpMembers`); `Spec.hs` 159 (state), 230 (`MProgram`), 255-262 (`ordered`: extra roots before main); `Inline.hs` 113; `Known.hs` 281 |
| the structural helpers call the clone: `eqExpr`/`cmpExpr` look the exact type up first; `memberCall` makes a direct call, dups an argument whose parameter is owned (`--rc`; the helpers borrow), turns Order into a sign | `CGen.hs` 94 (`iMembers`), 145, 2642-2694 (`eqExpr`, `cmpExpr` now takes `Info`, `memberCall`), the four `cmpExpr` call sites |
| `fromFloat` shape, `Float` has it | `AST/WellKnown.hs` (shape `FromFloat`, `fits`, `expectedText`, `shapeAnnotation`, `builtinHas BFloat`) |
| the relaxed Float literal | `Type/Members.hs` 252-268 (`floatLiterals`, `floatLiteralName`); `Type/Solve.hs` 1 (`PatternGuards`), 110-135 (a `CEqual` case for the `Float` category, same error handling as `CEqual`) |
| NO MEMBER wording for a literal | `Reporting/Error/Type.hs` 221-242 |
| specializer: literal at Float32 / at a custom type; `fromFloat` of Float = identity; shape type | `Spec.hs` 454-457, 657, 973-985 (`floatLiteralAt`), 1013-1030; `Sized.hs` 180 (`memberOp` has `fromFloat`) |
| Float32 gets the member | `ficcus-tools/gen_sized.py`, `overlay/Float32.elm` (regenerated: one member) |

JS: unchanged. Every new case is refused there (`$customOperators` from the comparable policy or the relaxed obligation; `eq` by
definition), checked for the six container cases and `a3b-js-fromfloat`.

## 3. Cases (`ficcus-tests/attach`, 267 = 252 + 15; generator `a3bgen.py`)

Expected outputs come from twins in `ficcus-tests/attach/a3b-twins/` (`a3bgen.py --expect`), never by eye: plain Elm on `bin/elm0193`
+ node, with each member type replaced by a representation whose structural `==`/`compare` is the member (`type alias Ci = String`,
`ci = String.toLower`; `Desc n` as `negate n`; `Word64` as `(hi, lo)` with hi, lo < 2^32, printed `hi:lo`), or, for Float32, a Ficcus
program with explicit `Float32.fromFloat` run on `elmficA4b`. The converted A3 cases use their own sources with the strings of `Name`
lowered and the `where` block removed.

| case | elmficA4b | elmficA3b |
|---|---|---|
| a3b-eq-builtin (26 lines), a3b-eq-unions (15), a3b-eq-vector (5), a3b-ci-keys (13), a3b-cmp (19), a3b-member-forms (8), a3b-imported (5), a3b-word64 (13) | FICCUS refusal ("has its own ... member") | RUN c ok (gcc, clang, `--rc` ASan/UBSan 0 live) |
| a3b-fromfloat-user (9), a3b-fromfloat-float32 (11) | TYPE MISMATCH | RUN c ok |
| a3b-fromfloat-defaults (js+c, 6) | ok | ok (guard: a `fromFloat` type in sight, literals at Float, JS and C as Elm) |
| a3b-err-float-literal-elm | TYPE MISMATCH | TYPE MISMATCH (guard: nothing in sight) |
| a3b-err-fromfloat-missing | TYPE MISMATCH | NO MEMBER (`fromFloat`) |
| a3b-err-fromfloat-shape | ACCEPT | WELL KNOWN MEMBER WITH THE WRONG TYPE |
| a3b-js-fromfloat | TYPE MISMATCH | CONSTRAINED FUNCTIONS |
| a3-c-holds-* (13 cases) | REJECTC | RUN c ok (rows changed from REJECTC) |
| sized-err-word64-tuple | REJECTC | RUN c ok (name kept) |
| sized-err-float-literal | TYPE MISMATCH | RUN c ok (it imports Float32: `0.5 : Float32` now valid; name kept) |

## 4. Gates (2026-11-26, `KEEP=1`, binary of 9babac1d)

All green: runtime 0, attach 267/0 (`--rc`), sized-fuzz 40/0, stringdiff agree, types 267 PASS + 1 XFAIL, JS identity 28, examples
298 x3, fbip 0, effects-e1/e2, e1review, e1p, e1pr (2 target rows), e1p-identity, **a3b-identity 100 compiles 0 differ** (new step:
suite + e1p/effects programs, `--rc`/`--no-rc`, against `elmficA4b`), e2review gates ok (info 3 differ, as on A4b), rcfaults 2403/0
missed, rcfaults-big 239/0, rcgate-san ok, suite 16 PASS, typed 568/12/1, lib 108 PASS + 59 FIXED, elmdiff 1175 SAME.
A2 (`JsonCombV`) C text identical to `elmficA4b` in `--rc` and `--no-rc`, so no timing run. After the message fix (f621dd68):
attach 267/0 and a3b-identity 100/0 rerun.

## 5. Choices to confirm (smallest reading)

1. `compare` inside containers only where the type checker accepts it (lists, tuples); records, `Maybe`, `Array`, `Vector`, `Dict` are A4b.
2. The literal rule is the `/` rule: relaxed only when a type with `fromFloat` is in sight. Consequence in such a module: a Float literal
   where e.g. a `String` is expected is NO MEMBER (``String`` has no `fromFloat`) instead of Elm's TYPE MISMATCH; a let value with a literal
   is held (not generalized) and settled by its uses (as F4/F8). No Elm program is affected (no type has `fromFloat`).
3. `-0.5` at a user type needs `neg` and the `number` bundle (Elm types `-x` as `number`); at Float32 it works.
4. The two converted sized cases keep their `-err-` names (renaming would lose history); their rows say RUN.
5. `fromFloat` of Float is `identity` (for `a has fromFloat` at Float).

## 6. Open points for the review

1. **Ownership in `memberCall`** (`CGen.hs`): the helpers borrow; an owned parameter of the member clone gets a dup first. The call is
   outside the MIR, so `RcCheck` does not see it; it relies on `paramOwns` of the final clone. Tested under ASan with 0 live, including
   an eta clone with one owned parameter (`a3b-member-forms`).
2. **Roots**: member clones are kept by `ordered`, `Inline` and `Known.finalize`. Any later pass that drops unreferenced clones must
   keep `mpMembers` too, and a pass that changed a kept clone's parameters (count or class) would break the direct call; `memberCall`
   checks two parameters of the subject class and an enum result and fails the build otherwise.
3. The C generator does not itself refuse a member type that reached `eqExpr`/`cmpExpr` without a table entry (it would be structural);
   every path found goes through `wellKnownRef` (`Basics.eq/neq/compare/lt/...`), sorts go through `vectorSortMember` (unchanged,
   still `holdsMember`). A guard would need the set of member types in `MProgram`.
4. Non-regular recursion (`type Nest a = Nil | Cons a (Nest (List a))`) with a member inside stops with a FICCUS report after 2000 types
   (3 s); without a member inside, `==` on such a type was not looked at (pre-existing).
5. `vectorSortMember` still routes element types that *hold* a member (not only types with one) through the overlay's `sortMember`
   (Elm level sort with `compare`); the kernel sort with a helper comparator would now also be correct and faster. Left as is (no C change).
