# P1: an extensible record held in a custom type loses its extra fields

Branch `fix/p1` from ficcus e9718157 (A4bf). Identity reference `bin/elmficA4bf`.

## The bug

```elm
type T r = T { r | x : Int }
Debug.toString ( T { x = 1, y = 2 } == T { x = 1, y = 3 }, T { x = 1, y = 2 } )
```

`bin/elmficA4bf` (and elmficA5c, A4b) print `(True,T { x = 1 })`; Elm (`bin/elm0193` + node) prints
`(False,T { x = 1, y = 2 })`. Reproduced with `ficus-tests/a4br/run.py --only row-var-eq-show`, both `--no-rc` and `--rc`.

## Findings (step 1)

* **The data is right, the shape is wrong.** The object built for `T { x = 1, y = 2 }` is `fic_o_SiiE` (both ints flattened):
  the class of a constructor argument comes from the expression's type, and `Spec.classOf` already merges a row
  (`rowFieldsT`). Only the per-type *shape* (`Ir.UnionShape`, `mpUnions`) loses `y`.
* **Where.** `Modules.canToM` turns a constructor field's `Can.TRecord fields ext` into `TyRecord fields` and ignores
  `ext` (`Modules.hs:99`). So the shape of `T` has a single field `{ x : #0? }` with no trace of the parameter `r`.
* **Who reads the shape.** The shape's field types, with the type's arguments put in for `#i`, drive the structural
  `==`/`compare`/`hash`/`Debug.toString` helpers (`CGen.ctorsOf`), the derived member closure (`Derived.fieldTypes`), the
  member reachability of A3b (`ContainerMembers`) and `Spec.holdsMember`. Each of the four has its own copy of the same
  `subst`. `Borrow.recursiveTypes`, `Unbox` and `Sized` read the shape without substituting and only look at type names.
* **How a row is instantiated.** At a use site the type argument for `r` is an exact type: `Spec.mtypeOf` refuses an
  open record there, so the argument is a closed `TyRecord` (sorted by name, `{}` when nothing extra was written), or
  `TyCon "ref"` for an unconstrained variable. The specialiser itself never sees the union's field types: it keys
  clones by the exact type `T { y : Int }`, which already carries the row. Nothing has to be re-specialised.

## Proposed fix (local, about 60 lines)

1. `Modules.canToM`: for `Can.TRecord fields (Just v)` add a slot `("#row", <v looked up in env>)` to the field list
   (a field name no Elm program can write). Only fields with a row variable change, so the shape of every other type,
   and so every program without an extensible record in a custom type, is unchanged.
2. New module `Ficus.Mono.RowShape` with `substShape :: [MType] -> MType -> MType`: the existing substitution of
   `#i`, plus: a `TyRecord` with a `#row` slot whose substituted type is a `TyRecord rs` becomes the record of both field
   lists sorted by name (the same `MType` as the expression's own type, so helper keys agree); any other row (`ref`, or
   an unsubstituted `#i`) drops the slot. The four local `subst` copies are replaced by it.
3. No change to layout, to the specialiser, or to programs without such a field.

M2 (refusal of `derive` over such a field) is left as is until the cases show how derive behaves with the fix.

## What was done (steps 2 and 3)

The fix is local, as proposed: commits 7747e4b6 and b13a5e69, binary `bin/elmficP1`. Code: +50 lines (new module
`Ficus.Mono.RowShape`), -35 lines (the four `subst` copies), 3 lines in `Modules.canToM`.

* **Field order (found by the cases).** The merged fields must be in Elm's `Name` order (`AST.Prim.Name`'s `Ord`: shorter
  names first, then bytes), not `String` order. That order is both the C struct layout of the record (`Map.toList` of the
  canonical fields) and the order Elm's `Debug.toString` prints (`{ x = 1, mid = .., zeta = .., alpha = .. }`). With a
  plain `sortOn fst` the helpers read the wrong slots (`alpha = ''`, a garbage `x`); `p1-show` catches it.
* **Cases** `ficus-tests/p1` (`p1gen.py` writes them, `run.py` runs them; each Main.elm is plain Elm and its own twin on
  `bin/elm0193` + node): `p1-eq` (`==`/`/=` with Int, String, List, nested record and custom-type extra fields),
  `p1-show`, `p1-match` (case on the record, on extra fields, `T { x, y }`), `p1-update` (`{ r | .. }` then `==`/show),
  `p1-two-rows` (three rows of one `T` through polymorphic `showT : T r -> String` and `same : T r -> T r -> Bool`),
  `p1-containers` (the record in `List`/`Maybe` inside the type; `T` inside `List`/`Maybe`), `p1-nested` (`T` in the
  row of `T`, a recursive type with a row, three levels). All 7 equal Elm with `--no-rc` (gcc -O2) and with `--rc`
  (gcc -O1, ASan+UBSan, FIC_NO_POOL), live 0. On `elmficA4bf`, 6 of them differ (all but `p1-match`, whose fields are read
  by pattern, not by the shape).
* **Not P1 (pre-existing limit), case `p1-poly-row-limit`:** a field access or a record update on a row-polymorphic
  record (`getX : T r -> Int` with `r.x`, `bump : T r -> T r`) is refused, "row polymorphism: slice 5", the same on
  `elmficA4bf`. `p1-match` and `p1-update` use monomorphic rows for that reason.

## M2 (refusal of derive over such a field): the facts

A scratch build with the refusal replaced by a check of the record's own fields (`/home/gordon/claude-tmp/elmficP1-noM2`,
source reverted, not committed) on the review cases `ficus-tests/a4br`:

* `row-var-derive` (`<` and `compare` with the row deciding) and `row-var-derive-string-rev`: equal their Elm twins,
  `--no-rc` and `--rc`, live 0.
* `row-var-derive-string`: `(LT,False)`, correct by hand (age 5 < 7; different hashes).
* `row-var-derive-fn`, `row-var-derive-hash-fn` (a function in the row): refused at the use site by the type checker
  (`<` on `T { f : a -> a }`; `a -> a` has no `hash`), as wanted.

So with P1 fixed the derive over an extensible-record field appears to work, and the refusal could be lifted (a 2-line
change in `Canonicalize/Derive.hs`, plus the derive matrix rows that expect the refusal). Kept as is here: a decision
for the user.

## Gates (2026-11-27, once, `KEEP=1 S=/home/gordon/claude-tmp/gates-p1 BIN=elmficP1 A3B_REF=bin/elmficA4bf`, log `/home/gordon/claude-tmp/gates-p1.log`)

All green: runtime 0; attach 378/0 `--rc`; derive 56/0; sized fuzz 40/0; stringdiff all agree; types 267 PASS + 1 XFAIL;
JS identity 28/0; examples 298 x3; fbip 0; effects e1/e2 ok; e1review, e1p, e1pr (2 target rows), e1p-identity ok;
a3b-identity against elmficA4bf 100 compiles, 0 differ (byte identical C); e2review gates ok (info 3, as before);
rcfaults 2403/0, rcfaults-big 239/0; rcgate-san ok; suite 16/16; typed 568/12/1; lib 108 PASS + 59 FIXED;
elmdiff 1175 SAME. The P1 cases are not in `gates.sh` / attach yet (run `ficus-tests/p1/run.py`).

## P1b: M2 lifted (binary `bin/elmficP1b`)

* fix/p1 merged with ficcus d62aa4f1 (E3b head), no conflicts.
* `Canonicalize/Derive.hs`: an extensible-record field is checked by its own fields, like a closed one; the row is
  filled at the exact type (above), and a row field without the member is refused where the type is used (the
  obligation reaches the row): `p1-derive-fn-reject` (TYPE MISMATCH on `<`), `p1-derive-hash-fn-reject` (NO ATTACHED
  FUNCTION for `hash`).
* The derived order over such a record is Elm's `Name` order of all its fields (shorter names first), the same order as
  for a closed record.
* Attach: `a4bf-err-row-field` and `a4bf-err-row-field-hash` (ids kept) are now RUN rows with Elm twins
  (`a4bf-twins/`, tuples of the same fields); hashes are tested only by equality. The derive matrix had no M2 row.
* `ficus-tests/p1`: 13 cases. New: `p1-derive-compare` (also `List.sort`), `p1-derive-string` (now with an Elm twin, no
  hand check), `p1-derive-string-rev`, the two `-reject` cases, and `expected.err` for `p1-poly-row-limit`. `run.py`
  checks `expected.err` (each line in the compiler output) and ends with `p1: N cases, M failed` (exit 1 on a failure).
* `gates.sh`: a `p1` step after `derive`, and a lock (`flock` on `$CLAUDE_CODE_TMPDIR/ficcus-gates.lock`, else `/tmp`):
  a second gate run prints `=== waiting for the gate lock ...` and starts when the first ends.
* Targeted gates 2026-11-27 (log `/home/gordon/claude-tmp/gates-p1b.log`), all green: runtime 0, attach 378/0 `--rc`,
  derive 56/0, p1 13/0, types 267 PASS + 1 XFAIL, JS identity 28, effects e1/e2/e3 all ok, e1p ok, a3b-identity
  against elmficE3b 100/0, rcgate-san ok, suite 16/16. Not run: sized, stringdiff, examples, fbip, e1review, e1pr,
  e1p-identity, e2review, rcfaults, typed, lib, elmdiff (all green on elmficP1).
