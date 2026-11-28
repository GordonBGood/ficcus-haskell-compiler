# A3b review: members inside containers, Word64 in compared containers, the `fromFloat` literal

Read-only soundness review of `feat/a3b` (b1e8f696, binary `bin/elmficA3b` = f621dd68), on branch `review/a3b` (worktree
`ficcus-haskell-compiler-a3br`). Nothing in the compiler was changed. Scratch cases: `ficus-tests/a3br/` (runner `run.py`, cases in
`cases/`, each with a plain Elm `twin/` run by `bin/elm0193` + node where the answer matters).

## Verdict

**Merge.** I found nothing that must be fixed before merging. The ownership protocol of `memberCall` is right for every
argument kind and member ownership mode I could build. The member clones survive every pass. No path into
`eqExpr`/`cmpExpr` skips the table. The `fromFloat` literal leaves Elm-style code unchanged. Three items belong in A4b, which
extends these helpers (records, `Maybe`, `Array`, `Vector`, `Dict` as `compare` subjects). The rest are notes.

## What was run

| run | result |
|---|---|
| attach: the 30 cases A3b adds or converts (`a3b-*`, `a3-c-holds-*`, `sized-err-word64-tuple`, `sized-err-float-literal`), `--rc` (ASan+UBSan, 0 live) | 30 / 0 differ |
| `ficus-tests/a3br/run.py`: 18 scratch cases, each `--no-rc` (gcc -O2) and `--rc` (ASan+UBSan, FIC_STATS, FIC_NO_POOL, 0 live), output against the Elm twin | all as described below |

I did not re-run the full gates (the notes record them green on 9babac1d; HEAD differs only in a message and the notes).

| case | what it checks | result |
|---|---|---|
| `own-mixed` | members with **owned** parameters (`eq` stores `a` in a list and `b` in a tuple; `compare` wraps both in `Just`), a borrowed `eq` on a type holding a record, inside a list, `/=`, `Dict` keys and values (tuple key), a record with `Maybe (tuple, List Box)`, `Array` of 70 (tree and tail), `Set` of tuples with lists, `List (Maybe (List (Ci, Result _ Box)))`, `compare` of lists, `List.sort`, `List.maximum`, `max`, `List.member`, `List.map2 (==)` (`==` as a value) | ok, ok (0 live) |
| `forms` | a two-parameter lambda as the member, a partial application (closure value: `eq = eqBy partKey`), a constant member (`eq _ _ = True`, which Known turns into a constant function), a parameterised member type at two instances, a recursive type whose own `eq` compares `List Tree` (helper → member → helper), a generic `same x y = x == y` at containers with an unresolved variable (`([], Lam 1)`), a generic `Dict.get` | ok, ok |
| `eta-two` | point-free `eq` and one-parameter `compare` of `Tag a` at four instances (four eta clones with one name) | ok, ok |
| `enum-closure` | a member type of enum class (nullary constructors) in tuples, lists, `Maybe`, `Dict` keys; a type with only `compare` used both through `List.sortWith compare` (clone as a closure) and from the helpers | ok, ok |
| `init-order` | a top-level value whose initialiser runs `==` and `List.sort` on containers, where the members are closure values (`eqBy partKey`) that only the C helpers reach | ok, ok |
| `sort-ties` | stability and ties: `List.sort`/`sortBy` on keys that compare EQ but differ, `List.maximum`/`minimum`, `max`/`min` on tuples | ok, ok |
| `nan-mixed` | NaN and -0.0 Floats next to a member type in tuples and lists: `==`, `compare`, `<`, `>` | ok, ok |
| `sz-float32` | Float32 NaN and -0.0 inside tuples and lists against the top-level operators; `0.1 : Float32` against `Float32.fromFloat 0.1`; `-0.1` | the same answers inside and outside containers (no twin: Float32 has no Elm counterpart) |
| `ff-elm` | Elm-style Float code in a module that imports `Float32` (so a type with `fromFloat` is in sight): `[0.5, 1]`, `0.5 + 1`, unannotated `half = 0.5`, `scale x = x * 0.25`, a `let` literal used twice, `/`, `max`, overflow, `compare`, `-0.0`, NaN | ok, ok: same output as Elm |
| `ff-err-string`, `ff-err-shared`, `ff-err-toplevel` | the literal rule's errors and edges (finding N2 and section 7) | as described there |
| `ff-many`, `ff-many-noimport` | 5000 Float literals with and without `Float32` in sight | 1.04 s and 1.03 s (elmficA4b 0.60 s on the first, where it is a TYPE MISMATCH); no measurable cost |
| `ext-record` | `==` on an extensible record holding a member type | refused on both binaries (`cannot key elm/core:Basics.eq v0: an extensible record`): loud, not silently structural |
| `nonreg-elm`, `nonreg-member` | finding A3 | see there |
| `nan-sort-elm` | note N1 | see there |

## Findings, ranked

### Must fix before merge

None.

### Fix in A4b

**A1. A guard in the C generator for a member type without a table entry (review point 3).** I found no path today. Every
`==`/`compare` on an exact type goes through `wellKnownRef` (`Basics.eq/neq/compare/lt/le/gt/ge`; `max`, `min`, `List.member`,
`maximum`, and the `Dict`/`Set` functions are Elm code that calls those). Sorts go through `vectorSortMember`, whose `holdsMember`
is a sound over-approximation: it walks the arguments first, so a type seen once by name cannot hide a member at a second
instance. The two places where `wellKnownRef` could skip the walk both fail loudly later:
* `mtypeOf` returns Left only for an extensible record, and then `keyFor` reports "cannot key" (`ext-record`).
* An unresolved `number` is defaulted by Spec before the use; an unresolved variable becomes `ref` on both sides.

So the table key always equals the type the C generator sees. A4b adds new structural `compare` code (records, `Maybe`,
`Array`, `Vector`, `Dict`), and every new helper is another place where a missing entry would silently compare structurally.
Proposal: put the set of type ids that have `eq` / `compare` members into `MProgram`. In `customEq` (CGen.hs:2915) and in the
new `cmpBody` cases (2939), `failWith` when such a type is reached without a table entry. This costs about 10 lines.
Reproducer: none (by construction); `ext-record` is the nearest path.

**A2. Switching `List.sort`/`Vector.sort` on an element that only holds a member to the C kernel (review point 5).** Today the
element goes to the overlay's `sortMember`, which is `sortWith compare` (`overlay/Vector.elm:357`). That is the stable kernel
Powersort with the `compare` clone at the element type as the comparator, and that clone reaches the member through
`wellKnownRef` → `cmpExpr` → table. It is correct: `sort-ties`, `own-mixed`, `a3b-cmp`, `a3b-word64` and `a3-c-holds-sortby`
agree with Elm, including ties and stability. A switch to `sort` with `HVecCmp` (`sortMode`, CGen.hs:1785) would also be
correct, and faster (no closure call per comparison), **only if** `vectorSortMember` (Spec.hs:636) then calls
`containerMembers "compare"` on the element type. The kernel sort does not go through `wellKnownRef`, so without that call
the table has no entry for a type that is only sorted, and `vecCmpBody` would compare it structurally without saying so.
With guard A1 in place, that mistake would be a build failure instead of a wrong order. `memberCall` inside the qsort comparator is fine for
ownership: the elements are borrowed from the vector and an owned parameter gets its own count. Reproducer for the trap: none
(the switch is not made); `sort-ties` is the test to keep passing.

**A3. The 2000-type walk on programs with no member (review point 4).** `containerMembers` (Spec.hs:514) walks the type of every
`==`/`compare` use, whether or not the program has any member. For a plain Elm program with a non-regular type:

```elm
type Nest a = Nil | Cons a (Nest (List a))
... Cons 1 (Cons [ 2 ] Nil) == Cons 1 (Cons [ 2 ] Nil)
```

(`ficus-tests/a3br/cases/nonreg-elm`):
* `elmficA4b` **does not finish**: the compile was still running after 2 × 300 s and was stopped by the 3 GB / 300 s limit of
  `tools/safe`.
* `elmficA3b` stops with `FICUS ... the type (author/project:Main.Nest elm/core:Basics.Int) holds more than 2000 different
  types (a type used at another argument inside itself)`.

So A3b turns a pre-existing hang into a clean refusal. That is an improvement, but the refusal now comes from the member
code and its wording blames the type, not the missing support. With a member inside (`nonreg-member`) it is the same report,
about 12 s for two uses, because the walk is not cached and runs once per use.
* Can a regular program reach 2000? Only a type whose closure holds 2000 *distinct exact* types reaches it. Each regular type
  contributes a fixed, small set, so I could not build a realistic one. It is not reachable in practice.
* Proposal for A4b:
  * Cache the walk's result per `(member, exact type)` in `S`, so it runs once per type, not once per use.
  * Word the report as what it is: "`==` on a type that is used at another argument inside itself (non-regular recursion)
    is not supported by the C generator".
  * Print the type in source form (`Nest Int`, not `author/project:Main.Nest elm/core:Basics.Int`). The notes say f621dd68 did
    this, but `mtypeText` still prints the package ids.

### Notes (no action needed for the merge)

**N1. Sorting with NaN differs from Elm, before and after A3b.** In plain Elm with no members (`nan-sort-elm`),
`List.sort [ ("b", 2), ("a", nan), ("a", 1) ]` gives `[1,NaN,2]` on both elmficA4b and elmficA3b, in both modes; Elm gives
`[NaN,1,2]`. The comparator is inconsistent with NaN, so the result depends on the algorithm (V8's TimSort versus Powersort). The
decisions file already says "Sorting lists containing NaN stays unspecified" (slice 4, 9 Nov). A3b does not change it. I
dropped the line from `nan-mixed`, which otherwise matches Elm on NaN and -0.0.

**N2. The literal rule's errors (review point 7).** The rule is the same as the one for `/`: relaxed only when the module's
member table has a type with `fromFloat`. The table includes the types that an import's interface carries, so importing a
module that mentions `Float32` is enough.
* In such a module, a literal where another type is expected is **NO MEMBER** (`String.length 0.5`: "This Float literal needs
  a type that has the member `fromFloat`, but it is used as: String"), not Elm's TYPE MISMATCH. It is readable, and it is
  the recorded choice 2.
* Nit: the same report then lists the built-in well-known members ("`add`, `sub`, ... `append`") without `fromFloat`, which
  `Float` now has (`Reporting/Error/Type.hs:396`).
* A top-level unannotated `half = 0.5` defaults to Float before generalization. Using it at `Float32` is a TYPE MISMATCH, as in
  Elm (`ff-err-toplevel`).
* A `let h = 0.5` used once as Float32 is Float32 throughout (`ff-err-shared` prints `(0.5,2)`): monomorphic, correct.
* Programs with no such type in sight: the `CEqual` Float case only fires when `floatLiterals` finds a `fromFloat` in the table,
  and Elm code has none. Even with `Float32` in sight, Elm-style code gives Elm's output (`ff-elm`), and 5000 literals cost
  nothing measurable (`ff-many`).

**N3. Elm-twin semantics (review point 6).** The twins replace each member type by a representation whose structural order
*is* the member:
* `Ci` → its lowered string;
* `Desc n` → `negate n` (exact except at `minInt`, which no case uses);
* `Word64` → `(hi, lo)` with both parts below 2^32, whose lexicographic order is the unsigned order (the cases use
  2^63 and 2^64 - 5).
The constructions are right. NaN and -0.0 next to a member type were not covered by the A3b cases; `nan-mixed` adds them and
they agree with Elm. Float32 inside containers agrees with the top-level Float32 operators (`sz-float32`).

**N4. A type with `compare` but no `eq` (carried over from A3).** `==` on it is structural, also inside containers. So two `Dict`s
whose keys compare EQ but differ structurally are not `==`, although `Dict.get` finds either key in either dict (`enum-closure`
shows the `compare` side). This is A3's decision, now visible through containers too. It is worth one line in the decisions
file if not already there.

**N5. Evaluation order.** `memberCall` emits its call just before each field's `if (!e) return 0;` (and before each
`{ int c = ...; if (c != 0) return c; }`), so short-circuiting is kept. A member with `Debug.log` runs exactly as often as
the structural comparison would look at that field.

## Review points, answered

1. **Ownership.** The helpers borrow both arguments. `memberCall` (CGen.hs:2673) copies an argument and gives it a count of its
   own exactly when the final clone's `paramOwns` says Owned, and the clone consumes it. That count also keeps the cell's
   count at 2 or more during the call, so reuse (reset/reuse) in the member cannot fire on a cell the helper still reads.
   * `paramOwns` is read from the clones after `Rc.inferBorrow`, the same `MDef` that `Rc` used to count the clone's body,
     so caller and callee agree by construction.
   * Borrow inference starts from "all borrowed" and sees no IR call sites for a clone reached only from C. That is fine: a
     borrowed parameter needs the argument alive for the whole call, and the helper's argument is a field of a value the
     helper borrows.
   * Tested under ASan+UBSan with 0 live: owned/owned, owned/borrowed, borrowed/borrowed, enum class (no counts), and eta
     clones over closure values. The arguments were fields of list cells, tuple and record structs, `Maybe`/`Result`/union
     cells, `Dict` nodes, `Array` tree and tail, `Set`, and nested combinations of these.
   * I could not build a double free, a leak or a use after drop.
2. **Survival.** `mpMembers` is a field of `MProgram`, and every later pass updates the program with record syntax, so the
   table passes through Known, Inline, Unbox, Twin, ModelUnpack and Rc/LeafSplit.
   * The clones are roots in `ordered` (visited before main, which also puts a closure-valued member's initialiser before any
     top-level value that compares: `init-order`), in `Inline`'s filter and in `Known.finalize`.
   * Known's constant-function rewrite (`eq _ _ = True`) rewrites calls, not the clone, so the clone keeps its parameters.
   * Unbox's worker/wrapper only touches clones with unboxed results, and the members return `Bool`/`Order`.
   * ModelUnpack only touches `update`. Twin only copies lifted clones and leaves the originals. LeafSplit changes bodies,
     not parameter lists.
   * In `--no-rc` none of the passes run.
   * So `memberCall`'s check (two parameters of the subject class, an enum result) is the only failure mode, and it fails the
     build rather than guessing. The eta clones share a name (`T$$m$eta`) but C names come from the clone id (`eta-two`, four
     of them in one program).
3. **Guard.** No path found; see A1.
4. **The 2000 stop.** Not reachable by a realistic regular program; see A3 for what changes for non-regular ones.
5. **List.sort.** Correct as is; switching is safe only together with `containerMembers` on the element type; see A2.
6. **Twins.** Sound; see N3.
7. **fromFloat.** Consistent with `/` (same table test, same default, same "settled before generalization"). NO MEMBER replaces
   TYPE MISMATCH only where a fromFloat type is in sight. No effect on Elm programs. See N2.

## Proposed text for the shared files (for the user or the planning chat to apply)

* `docs/Ficus-Design-Decisions.md`:
  > **DONE (26 Nov) A3b review (docs/A3B-REVIEW.md on `review/a3b`):** merge recommended, nothing to fix first. For A4b: a
  > guard in the C generator for a member type reached without a table entry; `containerMembers` on the element type if
  > sorts move to the kernel comparator; cache the type walk and reword the non-regular recursion report (`==` on such a
  > type hung on elmficA4b and is now refused). Notes: NaN sort order stays unspecified (unchanged); a type with only
  > `compare` is compared structurally by `==` inside containers too.

  Bump the revision line.
* `docs/PHASE1-CHECKLIST.md`: tick "A3b review" if there is such an item; add the three A4b items above under A4b.
