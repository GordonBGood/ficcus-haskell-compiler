# A4b review: derived `compare` and `hash`, comparable containers behind the gate, the A3b review items

Branch `review/a4b` from `feat/a4b` 639eeb26 (code ae24c16f), binary `bin/elmficA4bb`. Read only: no compiler change. Sources read:
`docs/attach/A4B-NOTES.md`, `docs/A4-DERIVE-DESIGN.md` (design/a4), `docs/A3B-REVIEW.md`, `docs/attach/A5C-NOTES.md`, and the diff
75e3ed9a..ae24c16f of `Type/Unify.hs`, `Type/Members.hs`, `AST/WellKnown.hs`, `Canonicalize/Derive.hs`, `Ficus/Mono/{Spec,CGen,
Derived,Ir,Kernel}.hs`. Scratch cases: `ficus-tests/a4br/` (README there has every case and its verdict).

## Verdict

**Merge after M1 and M2** (both small). M1 is a compiler that never stops on a program the deriver accepts. M2 is silently wrong
`compare`/`hash` results for a derived type whose field is an extensible record. Its root cause is older than A4b (P1), but A4b can
refuse that case with one check. F1 is a one-line fix and worth doing with them. Everything else can go to A4c or later.

The core of A4b is sound. I found no ownership bug: every nested container case, the owned-parameter path of `memberCall`, and the
member as a closure run clean under ASan+UBSan with 0 live objects, and their output equals Elm's. I found no path that clones a
derived stub. The orders agree with the Elm twins, apart from NaN sort order, which already differed before A4b. The gate is
complete and the "always" switch is one change.

## What was run

* 52 scratch cases under `ficus-tests/a4br/cases` with `run.py` (a copy of the A5a review runner: `--no-rc` gcc -O2 and `--rc`
  gcc -O1 with ASan+UBSan, FIC_STATS, FIC_NO_POOL; twins on `bin/elm0193` + node). 11 cases have Elm twins. The rest are expected
  rejections, measurements, or outputs I checked by hand (`mutual`, `alias`, `values`).
* `elmficA5c` (ficcus 75e3ed9a) was used as the "before" binary for P1, M1 and the NaN sort.
* Scratch build of the gate flip (`comparableContainers = True`), reusing a copy of a4b's `dist-newstyle`: 9 s, one module.
  The binary is `/home/gordon/claude-tmp/elmficA4b-flip`; the source change was reverted. No full gates (the notes record them
  green).

## Findings, ranked

### Must fix before merge

**M1. The compiler does not stop on derived `compare`/`hash` over mutually non-regular types (review point 3).**

```elm
type A a = A a (B (List a)) | AN  where derive compare
type B a = B (A a) | BN           where derive compare
compare (A 1 BN) (A 1 (B AN))
```

`elmficA4bb` was still running after 124 s, with RSS slowly rising (656 to 663 MB in 30 s). The same with `derive hash`
(`nonregular-mutual`, `nonregular-mutual-hash`). `elmficA5c` refused the use with TYPE MISMATCH. Plain `==` on the same types
gets A3's report (`nonregular-mutual-eq`). Cause:
* `Canonicalize.Derive.nonRegular` only looks for the type inside its *own* fields.
* `Spec.derivedAt` records each new exact type and walks its `fieldTypes` without a bound: `A Int`, then `B (List Int)`, then
  `A (List Int)`, and so on. Each type is new, so `sDerived` never stops the walk.
* A3's `membersInside` has the 2000-type bound, but `derivedAt` bypasses it (it recurses through `containerMember` ->
  `memberClone` -> `RKernel` -> `derivedAt`).

Fix (both parts):
* (a) Bound `derivedAt` the way `membersInside` is bounded, and report A3's non-regular text ("used at another argument inside
  itself"). This is the backstop.
* (b) Extend `nonRegular` to the type's mutual group in its module. Follow the fields into the module's other unions with the
  arguments substituted, and report CANNOT DERIVE at the declaration.

**M2. Derived `compare`/`hash` read the wrong fields of an extensible-record field (point 4).**

```elm
type T r = T { r | x : Int }  where derive compare, hash
T { x = 1, y = 2 } < T { x = 1, y = 3 }          -- Ficus False, Elm-twin True
compare (T { age = 5, name = "zz" }) (T { age = 5, name = "a" })   -- Ficus LT, twin GT
```

Cases `row-var-derive` and `row-var-derive-string-rev`, both against twins, under `--no-rc` and `--rc`. The union shape keeps the
field as the row-less record `{ x : Int }`. The helper then compares a one-field struct (`fic_o_SiE`) read out of the real wider
object (`fic_o_SiiE`), slot 0. That is whichever field comes first in the real layout, so the order and the hash are wrong
without any error. With refs first in the layout, a ref field of the shape always lands on a ref, so I could not make it crash
under ASan. A function in the row is refused correctly (`row-var-derive-fn`, `-hash-fn`), because the deriver constrains the row
variable and the unifier checks closed records.

Fix for A4b: in `Canonicalize.Derive.lacks`, report CANNOT DERIVE for `Can.TRecord _ (Just _)` for `compare`/`hash` (and the
later structural members), with a "not yet: an extensible record field" reason. Lifting it waits on P1.

### Fix in A4c or later

**F1. `a has compare` / `a has hash` accepts an open record (point 4).** `Members.resolve` has `Structure (Record1 fields _) |
open -> builtin BContainer "record" (Map.elems fields)` and never looks at the extension. So:

```elm
cmpRec : { r | x : Int } -> { r | x : Int } -> Order
cmpRec a b = cmpG a b            -- cmpG : a -> a -> Order where a has compare
cmpRec { x = 1, f = \n -> n + 1 } { x = 1, f = \n -> n }
```

The type checker accepts this, and so it does when unannotated, in a `let`, and through `hash` (`open-record-obligation`, `-hash`,
`-inferred`, `-let`). Today the specializer stops it ("cannot key ... an extensible record in an exact type (row variables:
slice 5)"). So no wrong C comes out, but the user gets a "cannot be compiled to C yet" message for a type error. Once row
variables land, it reaches `compare` on a function. The unifier's own record path (`closedFields`) is right
(`open-record-sortwith`: TYPE MISMATCH). Fix: give `resolve` the same closedness test, with `BOther` for an open record. It is
one guard, cheap enough to do with M1/M2.

**F2. A written `hash` of another shape inside a derived `hash`.** `hash` is a built-in member, not a well known name, so a type
may write `hash : T -> String` or `hash : T -> Int -> Int`. `derive hash` on a type holding it passes the deriver (`lacks` only
asks whether the member exists). The C generator then stops with an internal-sounding message: "cannot specialize the `hash`
member of ... T ...: the member has another shape than the constraint" (`hash-shape`, `hash-shape-arity2`). A use through
`a has hash` is refused correctly (`hash-shape-list`: ATTACHED FUNCTION MISMATCH). Fix: `lacks` checks the written member's shape
(`WK.fits ... Hash`) for `hash`, and the same for `compare`, which is already shape-checked as a well known name. On a mismatch it
gives CANNOT DERIVE "T.hash has the type T -> String; derive needs T -> Int".

**F3. `derive compare, hash` beside a written `eq` breaks both laws (point 5, point 6).**

```elm
type Ci = Ci String where
    eq (Ci a) (Ci b) = String.toLower a == String.toLower b
    derive compare, hash
( Ci "A" == Ci "a", compare (Ci "A") (Ci "a"), Ci.hash (Ci "A") == Ci.hash (Ci "a") )   -- (True, LT, False)
Dict.size (Dict.fromList [ ( Ci "A", 1 ), ( Ci "a", 2 ) ])                                -- 2
```

Case `derive-beside-eq`. The design note puts a *written* `compare` that disagrees with `==` on the user (a lint later). Here it is
the *derived* member that contradicts a written `eq` of the same type, so the compiler produced the inconsistency. Recommend:
CANNOT DERIVE "`Ci` has its own `eq`; a derived `compare`/`hash` would ignore it; write them". A derived member over a *part*
with a written `eq` is fine: it calls that part's written `compare`/`hash` (`a4b-hash-written`, `own-stress`). Design decision
for the user.

**F4. A project's own module `Vector` (point 8).**
* `Type.Unify.comparableContainerIds` and `Canonicalize.Derive.vectorId` recognise the core Vector by the id
  `author/project:Vector.Vector` alone. The C generator (`isVectorType`) and `Spec`'s `vecOn` also check the marker constructor
  `FicVectorBuiltin`, so C is never wrong.
* Without its own members, the user's `Vector Int` is accepted as comparable. The C generator then refuses it: "comparison at
  Vector Int is not supported by the C generator" (`own-vector`).
* With its own written `compare`, the user's member decides as it should (`own-vector-member`, twin ok).
* But the container branch is matched *before* `custom` in `unifyFlexSuperStructure`. So the user's type is wrongly refused at
  `Vector (a -> a)`, although its `compare` has no constraint (`own-vector-member-fn`: TYPE MISMATCH).

Fix: try `custom` first when the module's table has the type (a member always wins), and recognise the core Vector by the marker
constructor in the deriver and the checker too. The decision of 24 Nov (recognition by home module) needs the overlay's module to
be distinguishable from a project's; today it is not.

**F5. Phantom parameters reached through another type (point 3, wrong reject).** `type Id a = Id Int where derive compare` makes
`Id (Int -> Int)` comparable (`phantom`: Dict key, sort and hash run). But `type W a = W (Id a) where derive compare` gives
`W.compare` the line `a has compare`, because `stub` constrains every variable that occurs in a field. So `W (Int -> Int) <
...` is a TYPE MISMATCH (`phantom-wrapped`). This is conservative and sound. A precise answer needs the inner type's constrained
positions (the same `constrainedPositions` the policy uses). Low priority.

**F6. `Tree.compare` as a value at `Tree comparable` asks for a `where` line (A5's rule; wrong reject).**
`sortTrees : List (Tree comparable) -> List (Tree comparable); sortTrees = List.sortWith Tree.compare` gives INCOMPLETE TYPE
ANNOTATION: "add `comparable has compare`" (`value-at-comparable`). Every type that meets `comparable` has `compare`, so the
obligation could be discharged by the super type. With the line, or without an annotation, it runs (`value-poly-annotated`,
`value-poly-inferred`). `x < y` at the same type needs nothing. Belongs with the A5 rules.

### Pre-existing (not A4b's, found here)

**P1. A custom type whose field is an extensible record loses the row: wrong `==` and `Debug.toString` in plain Elm programs.**
`type T r = T { r | x : Int }`: `( T { x = 1, y = 2 } == T { x = 1, y = 3 }, T { x = 1, y = 2 } )` prints
`(True,T { x = 1 })`. Elm prints `(False,T { x = 1, y = 2 })` (`row-var-eq-show`, twin; same on `elmficA5c`). This is valid Elm,
so it is a back-compatibility bug with silent wrong output. The union shape (`UnionShape` fields) has no place for the row: at
an exact type `T { y : Int }` the field should be the record with the row put in. That is the place to fix it, and then M2's
refusal can be lifted. For the decisions file as an open item.

### Notes (no action needed for the merge)

* **N1. The gate (point 7) is complete.**
  * Every path reads `comparableContainers`: the unifier through `policyOf`'s `_containerOk`, and the obligations through
    `resolve`'s `open` (`notesFor` uses its own `Map.null` only for message text).
  * The JavaScript refusal holds across modules, without any `derive` line, when the gate is opened only by an import, and for
    `hash` at Int (`gate-js-*`). A plain module beside a gated one keeps Elm's TYPE MISMATCH (`gate-plain-beside`). Packages
    cannot open it: they cannot write `where` blocks, and a package's `comparable` is unified in the calling module.
  * **Flip:** with `comparableContainers = True` (one line), a plain-Elm program sorting records and keying a Dict by `Result`
    compiles to C, matches its twin, and JS refuses it (`flip-plain`). The 13 target programs' JS is byte identical between
    `elmficA4bb` and the flipped binary.
  * Text nit: the JS refusal lists a container comparison under "operators on custom types (`+`, `<`, `==`, ...)".
* **N2. Bool, Order and `()` are comparable on the obligation path but not in the unifier.** `sortW [ True, False ]`,
  `sortW [ { b = True }, { b = False } ]` and `sortW [ Just GT, Nothing ]` run (`a has compare`), and so does a derived type
  with a Bool field. `List.sort [ { b = True } ]` is a TYPE MISMATCH (`bool-consistency`, `bool-direct`). This is not unsound
  (the C code has all three), but one rule should hold for both. Either Bool/Order/`()` join the gated comparable list in
  `unifyFlexSuperStructure`, or the obligation path stops offering them outside derived types. Linked to open point 1 (False <
  True), which I would keep: it is the order of every language that orders Bool, and 0 < 1 in C.
* **N3. Ownership (point 1): no finding.**
  * `own-stress` (twin, ASan, 0 live) has keys built at run time: a derived type over a record of `Ci` (written `compare`/`eq`/
    `hash` whose argument is stored in a `Just`, so the clone's parameters are Owned), `Maybe (Vector Int)`, `Set String` and
    `Result String (Array Float)`. They are used as Dict and Set keys (`Dict.update` over 151 keys), as nested Dict keys
    `Dict (Dict Key Int) String`, in sorts and `maximum`, and in the law checks.
  * The generated C has the `mv` copies of `memberCall`'s owned path.
  * The helpers only read (borrowed `readF`, `HArrAt` returns a word without a count), allocate nothing, and the Dict walks use a
    128-entry stack, enough for any red-black tree.
  * `mutual`, `values`, `ops-paths`, `array-long` and `deep-derived-list` (a 1,000,000-deep derived list) are clean too.
* **N4. No derived stub is cloned (point 2).**
  * Paths tried: a `let` alias, a record field `{ cmp = Tree.compare, h = Tree.hash }`, partial application, `List.map2`, a
    higher-order parameter, `List.map Color.hash`, the member inside an annotated or inferred polymorphic function, operators as
    values (`List.map2 (<)`), `max`/`min`/`maximum`/`minimum`, Dict `union`/`diff`/`intersect`/`merge`/`remove`, Set
    `map`/`diff`, `sortWith`/`sortBy`, Vector `sort`/`sortBy`/`sortWith`.
  * All go through `derivedRef`, `wellKnownRef` or `memberClone` (`values`, `value-poly-*`, `ops-paths` with a twin).
  * The helpers are produced by the C generator from `mpDerived`, so no later pass can drop them. The written members they call
    are A3b's table roots. A pass that changed such a clone's parameter classes would trip `memberCall`'s check (loud).
* **N5. The policy's positions (open point 4).**
  * `constrainedPositions` is sound for what reaches it. Written constrained operator members are refused earlier ("OPERATOR
    FUNCTION WITH THE WRONG TYPE", `written-constrained-*`), so only derived `compare` gets positions.
  * Latent: `custom` applies `unifyComparableRecursive` to the positions for *every* super type. If a later slice derives a
    `number` or `appendable` member, the arguments must be unified at that super type instead.
* **N6. Orders (point 5).**
  * Agree with the twins: `a4b-containers` and `a4b-word64` in the branch, plus `array-long` (40,000 elements, depth 3; built by
    `set`, `push`, `slice`, `append`, `foldl push`, `repeat`) and `float-ties-nonan` (-0.0 EQ 0, infinities, stable ties in
    `sortBy`/`sortWith`, Dict/Set sizes, `==`).
  * With NaN the compare matrix and `==` agree, but sort order differs. The plain-Elm tuple version differs the same way on
    `elmficA5c` (`float-ties`, `float-ties-plain`). This is the known unspecified NaN order (A3b review).
  * Derived `compare` is EQ exactly when `==` holds for the types tried, except NaN, which is GT against itself while `==` is
    False. That is Elm's tuple behaviour, and F3 is the other exception.
  * Records in code point order of the names (open point 1): fine; it must match A4c's `toString` and A4d's `encode`.
* **N7. Hash (point 6).**
  * For 10,000 keys of each family (Int 0..9999, multiples of 1024, "s0".."s9999", 100x100 tuples and records, Maybe Int, a
    custom type, singleton lists, Float i/10) all hashes are distinct. The low 10 bits fill all 1,024 buckets with at most 20 to
    23 per bucket (Poisson tail for a mean of 9.8), and the low 8 bits all 256 values (`hash-quality`).
  * The splitmix finalizer fixes 0, so `0`, `()`, `False`, `Nothing` and the first constructor of an enumeration all hash to
    0 (`[]`, `""` and a nullary constructor of a non-enumeration do not). Harmless (different types), but a later `HashDict` should seed at the map, as the note says.
  * Dict and Set hashes do not depend on insertion order. -0.0 hashes like 0. NaN from `0/0` hashes alike, and NaN payloads
    apart (no law issue: NaN /= NaN). Swapped tuples, records and lists differ.
  * `a has hash : a -> z` decides `z = Int` at Int, String and a derived type (`hash-z-free`); `a has hash : a -> String` is
    refused at the use (`hash-z`).
* **N8.** The unifier's refusal of an open record still says "I do not know how to compare records" when the gate is open (Elm's
  hint). A sentence saying that closed records compare in this module would help.
* **N9.** Array compare goes through `HArrAt` per index (O(n log n), notes open point 8). For 40,000 elements this is not
  measurable; a leaf walk can come later.
* **N10.** `phantom` shows a phantom parameter at a function type works as a Dict key, in a sort and in `hash` (open point 4).

## Answers to the open points of A4B-NOTES section 7

1. Bool False < True: keep (N2). Records in code point order of the names: keep, consistent with A4c/A4d.
2. Ownership: confirmed sound (N3).
3. No missing path; the `let` alias and the record field work (N4).
4. The policy is sound; it is incomplete for phantoms through another type (F5), and M1 is the one hole (non-regular through two
   types).
5. Closed records: the unifier is right; the obligation path is not (F1). The extensible-record *field* is M2/P1.
6. `a has hash : a -> z` works (N7).
7. Hash quality is good for a non-seeded hash (N7).
8. Array compare O(n log n): fine for now (N9).

## Proposed text for the shared files (for the user or the planning chat)

* `docs/Ficus-Design-Decisions.md`:
  > **NOTE (27 Nov) A4b review (`review/a4b`, docs/A4B-REVIEW.md):** merge after M1 (the compiler does not stop on derived
  > `compare`/`hash` over mutually non-regular types; bound `derivedAt` and extend the deriver's non-regular check to the mutual
  > group) and M2 (refuse `derive` over an extensible-record field: the helpers read the row-less record). F1 (`a has compare`
  > accepts open records in `Members.resolve`) is one guard; do it with them. A4c: F2 (shape of a written `hash` inside a derived
  > one), F3 (`derive compare/hash` beside a written `eq`: refuse?), F4 (a project's own `Vector`), F5 (phantoms through another
  > type), F6 (`comparable has compare`). **Open item P1 (pre-existing, Elm back-compat):** a custom type with a field
  > `{ r | x : Int }` loses the row in `==` and `Debug.toString` (`(True,T { x = 1 })` where Elm prints `(False,T { x = 1, y = 2
  > })`).
* `docs/PHASE1-CHECKLIST.md`: A4b-rev done (review), merge pending M1, M2 (+F1).
