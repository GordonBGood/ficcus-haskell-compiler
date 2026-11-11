# TYPEFIX notes (branch fix/d10-kind-check)

## Known gap: extension variable used as an ordinary type in an annotation

    f : a -> { a | x : Int }

is accepted at its declaration (as in Elm 0.19.3) and fails only where it is used, because `a` is both an
ordinary type and the extension of a record. The kind check merges the two uses (KRow dominates KType) on
purpose: case 2029 (`X2 t = X1 t t`, expected accept) needs it. Decision of the planning chat: leave as is.

## Duplicate fields (option B)

A field given twice through an extension (`Named { name : String }`, `Tricky r` unified with itself) is one
field when the two types can be one type; if not, DUPLICATE FIELD names the field and shows both types.
Static check: `Canonicalize.Kind` with `AST.Utils.Row.mergeField`; solver: `Type.Unify.mergeDuplicates`.
1550 rejects because the types differ (Int and String).

## Constrained alias parameters

`type alias A appendable = ...` used as `A Int`: BAD TYPE ARGUMENT. A type variable is accepted, so the
packages that name an alias parameter `comparable` keep compiling. 2097 (crash in 0.19.3) is rejected by the
kind check: its argument `()` is not a record; with `{}` instead of `()` 0.19.3 and this compiler accept.

## E4 prime

`x'` is one name; a quote that starts a character literal (`f'a'`, `f'\n'`, `f'\u{0041}'`, `f'\''`)
ends the name, as in 0.19.3. Corpus scan (40796 .elm files, 581 projects): 0 files change their Elm tokens
(the only primes after a name are inside GLSL blocks). Test: docs/typefix/e4-prime/run.sh.
