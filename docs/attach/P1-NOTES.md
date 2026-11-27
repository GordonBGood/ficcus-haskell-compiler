# P1: an extensible record held in a custom type loses its extra fields

Branch `fix/p1` from ficcus e9718157 (A4bf). Identity reference `bin/elmficA4bf`.

## The bug

```elm
type T r = T { r | x : Int }
Debug.toString ( T { x = 1, y = 2 } == T { x = 1, y = 3 }, T { x = 1, y = 2 } )
```

`bin/elmficA4bf` (and elmficA5c, A4b) print `(True,T { x = 1 })`; Elm (`bin/elm0193` + node) prints
`(False,T { x = 1, y = 2 })`. Reproduced with `ficcus-tests/a4br/run.py --only row-var-eq-show`, both `--no-rc` and `--rc`.

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
2. New module `Ficcus.Mono.RowShape` with `substShape :: [MType] -> MType -> MType`: the existing substitution of
   `#i`, plus: a `TyRecord` with a `#row` slot whose substituted type is a `TyRecord rs` becomes the record of both field
   lists sorted by name (the same `MType` as the expression's own type, so helper keys agree); any other row (`ref`, or
   an unsubstituted `#i`) drops the slot. The four local `subst` copies are replaced by it.
3. No change to layout, to the specialiser, or to programs without such a field.

M2 (refusal of `derive` over such a field) is left as is until the cases show how derive behaves with the fix.
