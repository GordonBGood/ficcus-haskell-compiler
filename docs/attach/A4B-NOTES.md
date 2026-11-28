# A4b: derived `compare` and `hash`; `compare` on records, Maybe, Result, Array, Vector, Dict, Set; the A3b review items

Branch `feat/a4b` (worktree `ficcus-haskell-compiler-a4b`, from `ficcus` 75e3ed9a, which has A3b, A5a, A5b, A5c), binary
`bin/elmficA4bb`. Sources: `docs/A4-DERIVE-DESIGN.md` (on `design/a4`, section 2 and the slice plan), `docs/A3B-REVIEW.md` (A1 to A3),
`docs/attach/A3B-NOTES.md`, `docs/attach/A5C-NOTES.md`. Not merged; for the Opus review.

## 1. What works now

```elm
type Color = Red | Green | Blue where derive compare, hash
type Tree a = Leaf | Node (Tree a) a (Tree a) where derive compare, hash

List.sort [ Blue, Red ]                          -- [Red,Blue]: declaration order, the kernel sort with a C comparator
Dict.fromList [ ( Node Leaf 2 Leaf, "x" ) ]      -- a derived parametric type as a key (its argument must be comparable)
Node Leaf 1 Leaf < Leaf                          -- False (was TYPE MISMATCH in A4a)
List.sortWith Color.compare cs                   -- the derived member as a value
Color.hash Red                                   -- Int; `a has hash : a -> Int` works at Int, Float, String, Char, Bool, Order,
                                                 -- (), sized types, lists, tuples, records, containers, derived types
-- in a module that sees a type with attached functions (the gate, section 4):
compare (Just 1) Nothing                         -- GT: Nothing < Just
Dict.fromList [ ( { a = 1, b = "x" }, 0 ) ]      -- records compare their fields in alphabetical order
List.sort [ Ok 3, Err "e" ]                      -- Ok < Err
compare (Array.fromList [ 5 ]) (Array.fromList [ 4, 9 ])   -- GT: Array, Vector, Set and Dict (as toList) lexicographically
```

## 2. Design

The note's group S plan, with one simplification: the derived member is never cloned. A use of `T$$compare` (`T$$hash`) at the
exact type `T args` is the kernel `Basics.compare` (the new kernel `ficus:FicDerive.hash`) at the key `[ByType (T args)]`, and
`(member, T args)` goes into `MProgram.mpDerived`. The C generator's structural code then writes one helper per exact type, beside
A3b's `HEq`/`HCmp`. A part with a written member calls its clone (A3b's table), and a part with a derived member calls its helper.

| piece | where |
|---|---|
| the derived stub, the kernels, the parts of a type, types in source form, the constructor rank, the hash run time | new `Ficus/Mono/Derived.hs` |
| a derived member at an exact type is the kernel there: `memberClone` (hidden arguments, selectors, the walk), `wellKnownRef` (`compare`, `<`, `>`, `<=`, `>=`), `derivedRef` (a reference such as `Color.compare` or `Tree.hash`; the hidden parameters come first in the instance) | `Spec.hs` (`memberClone`, `wellKnownRef`, `derivedRef`, `foreignOrTop`) |
| `derivedAt`: record the type, walk its fields for their own members | `Spec.hs` |
| `builtinMember` `compare`/`eq`/`hash` walk the parts of a built-in type for members (a container held by a constrained function) | `Spec.hs` |
| `hash` of the sized types (the overlay writes their other members) | `Spec.memberRef`, `Type/Members.resolve` |
| the eta clone for a written `hash` of one parameter (point free) | `Spec.etaMember`, `memberArity` |
| `mpDerived`, `mpOwnMembers` | `Ir.hs` |
| `cmpExpr`: Bool (False < True), `()`; `cmpBody`: records (fields sorted by name), Array (Elm's `Array.get` per index, `HArrAt`), Vector, Dict (two in-order walks), custom types by `ctorRank` (Maybe: Nothing first) | `CGen.hs` |
| `hashExpr`, `HHash` (`hashBody`), the hash kernel call; the run time only when used | `CGen.hs` |
| `memberCall` takes the arguments and the result class (`hash`: one argument, Int) | `CGen.hs` |
| the type checker: `Policy` gives the argument positions a derived `compare` needs comparable, and `_containerOk` (the gate); records (closed only), `Maybe`, `Result`, `Array`, `Vector`, `Dict`, `Set` merge with `comparable` | `Type/Unify.hs` (`comparableContainer`, `closedFields`), `Type/Members.hs` (`policyOf`, `constrainedPositions`, `comparableContainers`) |
| the obligations `a has compare`/`a has hash` at the containers, records, Bool, Order, `()` (`BContainer`, `BEnum`), `hash` at the built-in scalars (shape `Hash`, built in only, not a well known name) | `AST/WellKnown.hs`, `Type/Members.resolve` |
| the CANNOT DERIVE refusal of a `Vector` part for `compare` removed (Vector compare is in this slice) | `Canonicalize/Derive.hs` |
| the built-in note names `hash` and the containers | `Reporting/Error/Type.hs` |

### The orders and the hash

* `compare`: constructors in declaration order (`ctorRank`), then fields left to right. `Maybe` is **Nothing < Just**, `Result`
  is `Ok < Err`, `Order` is `LT < EQ < GT`, `Bool` is **False < True** (not in the note; see open point 1). Records compare
  their fields in **code point order of the names**. The exact type keeps Elm's `Name` order, which is not alphabetical
  (`m` before `arr`), so the helper sorts them. `List`, `Array`, `Vector`, `Set` and `Dict` (as its `toList`: key, then value)
  compare lexicographically, shorter first. Floats compare as Elm does (`fic_f_cmp`: NaN is GT, also against itself; -0.0 EQ 0).
  The new compare helpers have no pointer shortcut (`if (a == b) return 0`): Elm's `_Utils_cmp` has none, and a cell holding
  NaN compares GT to itself (found by the twin of `a4b-containers`).
* `hash` (`Derived.hashRuntime`): `mix` is the splitmix64 finalizer and `combine h x = mix (h * 0x9E3779B97F4A7C15 + x)`.
  * Int, Char, Bool (0/1), the sized integers: `mix` of the 64 bit pattern.
  * Float and Float32: `mix` of the bits of the double, with -0.0 taken as 0.
  * String: FNV-1a 64 over the UTF-8 bytes, then `mix`.
  * `()`: `mix 0`.
  * Tuples and records: `h = number of fields`, then `combine` per field (records in name order).
  * List, Array, Vector: a constant, then `combine` per element. Dict: per key and value in order.
  * Custom types: `mix rank`, then `combine` per field. An enumeration is `mix tag`.
  * The hash has no seed: it is the same on every run and platform (`a4b-hash-values`), but it is not promised across compiler
    versions. NaN hashes by its bit pattern.

## 3. The A3b review items

* **A1 (guard).** `MProgram.mpOwnMembers` holds the written `eq`/`compare`/`hash` members, except those of the sized types,
  which are scalars of the structural code. `eqExpr`, `cmpExpr` and `hashExpr` fail the build ("internal: the type T has its own
  `m`, but the specializer did not request its clone ...") when such a type is reached without a table entry. For derived
  members: `cmpBody`/`hashBody` generate a custom type only when it is in `mpDerived` or is one of elm/core's (`Maybe`, `Result`,
  `Set`, `Order`), and fail the build otherwise. Nothing in the gates or the cases trips either guard.
* **A2 (sorts).** `vectorSortMember`: an element type that holds only derived `compare` members now goes to the kernel sort
  (`HVecCmp`, a C comparator), after `containerMembers "compare"` on the element type. A written member or Word64 inside keeps
  the overlay's `sortMember` (unchanged). Tested by `a4b-sort` (100 elements, stable ties, `Vector.sort`, `Maybe Color`) and
  `a4b-has-compare`.
* **A3 (the walk).** `containerMembers` runs once per (member, exact type) (`S.sWalked`). The report now reads "`==` on the type
  `Nest Int`, which is used at another argument inside itself (non-regular recursion), is not supported by the C generator",
  with the operator as written and the type in source form (`Derived.mtypeSource`). `a4b-nonregular-member` compiles in 2.9 s
  (the review measured about 12 s for the same two uses).
* The NO MEMBER `fromFloat` nit was already fixed by A5c (the built-in note lists `fromFloat`).

## 4. The gate (the user's answer of 26 Nov)

`Type.Members.comparableContainers` is the one predicate: the containers are comparable (and have `compare`/`hash` for
obligations), and `Bool`, `Order` and `()` have them for obligations, only in a module whose member table is not empty. That is
the rule of `/` and of the Float literal. To make them comparable always, the predicate returns True. Plain Elm programs keep
Elm's TYPE MISMATCH exactly (`a4b-err-gate-maybe`, `a4b-err-gate-record-key`). An accepted use sets the module's
`$customOperators` flag, so the JavaScript output refuses it (NOT AVAILABLE IN JAVASCRIPT YET, `a4b-js-container`). Only a
closed record is comparable: an extensible one could gain a function field through its row variable (`a4b-err-open-record`).

## 5. Cases

`ficus-tests/attach/a4bgen.py` (standalone: it imports only `attach` and `mkhome`, so the g71gen trap of A5B-NOTES cannot fire):
23 cases, attach is now 363. Twins in `a4b-twins/`, never hand written outputs. The `elm` twins are plain Elm on `bin/elm0193`.
A derived type becomes a representation whose structural order is the derived one:
* an enumeration becomes an `Int`, `Maybe a` becomes `List a`, a record becomes the tuple of its fields in alphabetical order;
* `Result` becomes `( tag, [ok], [err] )`, Word64 becomes `( hi, lo )`;
* `Array`, `Vector`, `Set` and `Dict` become their lists;
* or the twin uses a hand-written comparison function with `Dict`/`Set` computed from it;
* `hash` is the identity, so `hash a == hash b` prints `a == b`, the law.

The `oldc` twin is the documented hash algorithm written with Word64 in Ficus, run on `bin/elmficA5c`.

| case | what | result |
|---|---|---|
| a4b-enum | Color.compare, compare, `< <= > >=`, sort, sortWith Color.compare, sortBy, max, min, maximum, minimum, Dict/Set keys, tuple keys, lists | RUN (elm) |
| a4b-tree | `Tree Int`, `Tree String`: the group report (compare matrix, operators, stable sort, Dict, Set, maximum), Tree.compare, Maybe/list/tuple of trees, `<` | RUN (elm, hand-written cmpTree) |
| a4b-containers | records, Maybe, Result, Array (lengths 0 to 1101: the tree), Vector, Dict, Set, nested ones, `Dict (Maybe Int) (Set String)`, NaN and -0.0 in Maybe and records | RUN (elm) |
| a4b-word64 | Word64 above 2^63 in a derived type, Maybe, record, Array; Big.hash | RUN (elm) |
| a4b-nested | derived record type over a written `compare` (Ci), a derived enumeration, `List Ci`, `Maybe Int` | RUN (elm) |
| a4b-sort | kernel sorts of derived elements (A2), stable ties, Vector.sort, and an element holding a written member | RUN (elm) |
| a4b-cross-module | derived members of an exposed union and an opaque type of another module, `Shapes.Shape.compare` | RUN (elm) |
| a4b-has-compare | `a has compare` at Maybe, record, derived enumeration and tree, list, Result | RUN (elm) |
| a4b-hash | the law: equal values have equal hashes (-0.0 and 0, Dicts and Sets built in other orders, record field order), distinct ones differ; all built-in types, containers, Word64, Float32, derived | RUN (elm) |
| a4b-hash-written | derived hash over a written `eq` and a point-free written `hash` (eta clone of one parameter) | RUN (elm) |
| a4b-hash-values | the stable values | RUN (oldc) |
| a4b-err-gate-maybe, -gate-record-key | plain Elm | TYPE MISMATCH (Elm's) |
| a4b-js-container | gate open, JS build | NOT AVAILABLE IN JAVASCRIPT YET |
| a4b-err-fun-in-tree, -fun-in-record, -open-record | `Tree (Int -> Int) < ..`, a record with a function, an extensible record | TYPE MISMATCH (C) |
| a4b-err-cannot-hash-function, -cannot-compare-inner, -nonregular-hash | | CANNOT DERIVE |
| a4b-err-define-hash | | DERIVE AND DEFINE |
| a4b-nonregular-eq-elm, -nonregular-member | plain Elm / with a member: A3's report | REJECTC with the new text |

All RUN cases pass with gcc and clang (`-Wall -Wextra -pedantic`, no warning) and with `--rc` under ASan+UBSan with 0 live objects.

**Derive matrix** (`ficus-tests/derive`, `derivegen.py`): `c-operator-refused` and `operator-param-not-yet` are removed (they run
now; `a4b-enum` and `a4b-tree` test the same with twins). `c-use-refused` uses `Color.toString` (still refused until A4c).
`cannot-json-hash` is new (it needs `elm/json` as a direct dependency, which only `derive.py` sets up). Three rows had A5c's old
titles (NO MEMBER, MISSING CONSTRAINT), because A5c did not run this matrix. They now say NO ATTACHED FUNCTION and INCOMPLETE
TYPE ANNOTATION. 56 cases. `gates.sh` gained a `derive` step.

## 6. Deviations from the note

1. **No stub kernels `structCompare`/`structHash` and no member clone.** The specializer maps the derived member to the
   `Basics.compare` kernel or the new hash kernel at the exact type. The effect is the one planned (one C helper per exact
   type, direct calls), with fewer moving parts. `Color.compare` used as a value is the kernel's closure.
2. **`Bool` is False < True.** The note is silent, and elm/core declares `True` first. `Bool` and `Order` get `compare` and
   `hash` for obligations (and inside derived types), but `True < False` stays a TYPE MISMATCH: Bool is not in the scoped list
   of comparable containers.
3. **`hash` is a built-in member** (shape `s -> Int`, `WK.builtinShapeOf`, like A5c's `zero`), not a well known name: a written
   `hash` of a custom type can still have any type.
4. **Result and Set** are comparable too (the user's answer). The Vector refusal of A4a's CANNOT DERIVE is lifted.
   `appendable`/`comappend` for Vector (the rest of the Vector parity item) are not done.
5. **The type checker recognizes the core `Vector` by its id** `author/project:Vector.Vector` (as `Canonicalize.Derive` does), and
   the sized types for `hash` by `author/project:Word64.Word64` etc. A project's own module `Vector` would be taken for the
   core one by the type checker; the C generator then refuses it loudly. The decision of 24 Nov asked for recognition by home
   module; within one project the overlay's module and a user's module of that name are the same id.
6. **Law tests are case based**, not a fuzz over generated values. The group report checks antisymmetry (the matrix against
   the twin) and that `EQ` agrees with `==`, and `a4b-hash` checks the hash law; there is no random generator of values as in
   the sized fuzz.
7. `e1p-identity` in `gates.sh` still compares against `elmficG70a` (an E1p check of which functions may change); only
   `a3b-identity` moved to `elmficA5c`.

## 7. Open points for the Opus review

1. **The orders to confirm:** `Bool` False < True; record fields by code point order of the names (uppercase before lowercase:
   `aB` before `ab`).
2. **Ownership.** `memberCall` with one argument (a written `hash`) dups an owned parameter like the two-argument case. The hash
   kernel's signature is `b` (borrowed). The new helpers (`HHash`, `HArrAt`, the container compares) only read. Tested with
   ASan and 0 live, including the point-free `hash` eta clone.
3. **The derived member as a kernel.** Every path to a derived `compare`/`hash` goes through `memberClone`, `wellKnownRef`
   or `derivedRef`. A path that cloned the stub would reach the A4a refusal ("is not generated yet"), not wrong code.
   Is any path missing (a `let` alias of `Color.compare`, a record field holding it)?
4. **The comparable policy for a derived parametric `compare`:** the argument positions come from the `a has compare` lines of
   the synthesized signature (`constrainedPositions`); a phantom parameter is free (`Id (Int -> Int)` stays comparable).
5. **Records:** only closed ones (`closedFields`); a record whose extension is still a flexible variable at the time of the
   unification (from an accessor) is refused even if it would later close.
6. **`a has hash : a -> z` at Int** decides `z` through the built-in shape, as `zero` does after A5c's M1 fix (the shape check
   of signature `where` lines covers only well known names).
7. **Hash quality:** not seeded, not DoS resistant (as the note says); NaN payloads hash apart.
8. Array compare reads element i of both arrays through the tree (`HArrAt`, O(n log n)); a parallel leaf walk would be O(n).

## 8. Gates

2026-11-26, once at the end, on `elmficA4bb` (ae24c16f): `BIN=elmficA4bb KEEP=1 S=/home/gordon/claude-tmp/gates-a4bb
ficus-tests/gates.sh` (log /home/gordon/claude-tmp/gates-a4bb.log). All green:
* runtime 0; attach 363/0 (with `--rc`, ASan+UBSan, 0 live); derive 56/0; sized-fuzz 40/0; stringdiff all agree;
* types 267 PASS + 1 XFAIL; JS identity 28/0; examples 298 x3; fbip 0;
* effects-e2, e1review, effects-e1, e1p all ok; e1pr all ok (2 target rows); e1p-identity all ok;
* **a3b-identity against elmficA5c: 100 compiles, 0 differ.** The C text of the suite and the e1p/effects programs is unchanged,
  `--rc` and `--no-rc`: programs without a derive line or a member inside a container are byte identical;
* e2review gates all ok (3 info, as before); rcfaults 2403/0 missed, rcfaults-big 239/0; rcgate-san ok; suite 16/16;
* typed 568 SAME + 12 BOTH_REJECT_SAME + 1 VERDICT_DIFF (salix-aws-spec, known); lib 108 PASS + 59 FIXED; elmdiff 1175 SAME, 0 DIFF.

## 9. Proposed text for the shared files (for the user or the planning chat)

* `docs/Ficus-Design-Decisions.md`:
  > **DONE (26 Nov) A4b (`feat/a4b` ae24c16f, `elmficA4bb`, not merged; docs/attach/A4B-NOTES.md):**
  > * derived `compare` and `hash`, as C helpers per exact type: the specializer maps the member to the kernel at the type, no clone;
  > * `compare` on closed records (fields in code point order of the names), `Maybe` (Nothing < Just), `Result` (Ok < Err), `Array`,
  >   `Vector`, `Dict` (as toList) and `Set`, behind one gate `Type.Members.comparableContainers`: a module that sees a type with
  >   attached functions; plain Elm keeps Elm's TYPE MISMATCH, and JS refuses the accepted uses;
  > * `hash` is a built-in member of the scalars, sized types and containers (splitmix64 finalizer, FNV-1a 64 for strings, no seed);
  > * the A3b review's A1 (guard), A2 (kernel sort for derived-only elements, members requested first) and A3 (walk cached, message
  >   in source form);
  > * 23 a4b cases with twins (attach 363), derive matrix 56; gates all green, a3b-identity vs elmficA5c 100/0.
  >
  > To decide: `Bool` False < True (chosen). The Opus review is next.
* `docs/PHASE1-CHECKLIST.md`: tick A3b+A4b (derived `compare` and `hash`) and A4b-rev, with "Opus review still to do".
