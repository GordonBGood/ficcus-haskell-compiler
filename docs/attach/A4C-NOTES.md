# A4c: derived `toString` and the enumeration members

Branch `feat/a4c` (worktree `ficcus-haskell-compiler-a4c`, from `ficcus` af71a00e, which has A4b, A4bf, P1 and T1c), binary
`bin/elmficA4c`. Sources: `docs/A4-DERIVE-DESIGN.md` (section 2 `toString`, the enumeration members, the A4c slice row),
`docs/attach/A4B-NOTES.md`, `A4BF-NOTES.md`, `P1-NOTES.md`. Not merged.

## 1. Step 1: Elm's `Debug.toString`, verified

Verified on `bin/elm0193` + node (`Debug.log` of 45 values, the probe program kept as a case, `a4c-elm-format`), before any
code. The current C path (`elmficT1c`, `--rc`) printed the same 45 lines byte for byte, so the derived `toString` reuses it.

| kind | Elm's text | rule |
|---|---|---|
| record | `{ m = 4, aB = 1, ab = 2, age = 3, arr = 5, name = "Bo", zeta = 1.5 }` | fields in **Elm's `Name` order: shorter names first, then by code point** (uppercase before lowercase). Not alphabetical: the decisions file's L10 note ("field order is alphabetical") is wrong in that detail. The same order for a literal, an alias constructor (`Person "Al" ...`) and a record update. `{}` when empty; `{ x = 1 }` with spaces |
| custom type | `Circle 1.5`, `Rect -1 2`, `Named "a b" (Circle 0)`, `Node (Node Leaf 1 Leaf) 2 Leaf`, `Unit` | the constructor name only (no module); each argument after a space, in parentheses only when its own text has a space and does not start with `{ ( [ < "` |
| negative numbers | `Rect -1 2`, `Just -1.5`, `Just -Infinity`, `Node Leaf -2 Leaf`, `(-1,-1.5)` | never in parentheses (no space in the text) |
| record argument | `Pt { x = -1, y = 2 }`, `Just { a = 1 }` | no parentheses (starts with `{`) |
| Maybe, Result | `Just 1`, `Nothing`, `Just (Just -3)`, `Ok (Just [1])`, `Err "e"`, `[Ok (1,2)]` | ordinary constructors |
| list | `[[1,2],[],[3]]` | no spaces |
| tuple | `(1,"a",'c')`, `()` | no spaces |
| string | `"a\"b\\c\nd\te'f\r\v\0é😀"` | escapes `\" \\ \n \t \r \v \0` only; `'` not escaped; other control characters (U+0001, U+007F) and all non ASCII raw (L16) |
| char | `'a'`, `'\''`, `'"'`, `'\\'`, `'\n'`, `'\t'`, `'\0'`, `'\r'`, `'\v'`, `'é'`, `'😀'` | `'` escaped, `"` not; other controls raw |
| float | `1`, `0` (for -0), `0.1`, `1e+21`, `1e-7`, `123456789012345680`, `NaN`, `Infinity`, `-Infinity`, `-2.5` | JavaScript's Number toString; -0 prints `0` |
| containers | `Dict.fromList [(1,"a"),(2,"b")]`, `Set.fromList [1,3]`, `Array.fromList [1,2]`, `Just (Dict.fromList [(1,1)])`, `Just (Set.fromList [])` | as their ascending `toList` |
| function | `Just <function>` | |
| extensible record in a custom type | `Ext { x = 1, y = 2 }`, `[Ext { w = "s", x = 1 }]` | the whole record (row included), `Name` order |
| Bool, Order, unit | `(True,LT,Just GT)`, `Just ()` | |

Types Elm cannot show (the note: decisions L16, L29): `Vector.fromList [1,2]`; the sized types print their number
(section 3 has the measured forms).

## 2. What works now

```elm
type Color = Red | Green | Blue where derive toString, minValue, maxValue, succ, pred, enumerate, compare
type Tree a = Leaf | Node (Tree a) a (Tree a) where derive toString

Color.toString Red                          -- "Red"
Tree.toString (Node Leaf "a b" Leaf)        -- "Node Leaf \"a b\" Leaf": exactly Debug.toString
Color.enumerate                             -- [Red,Green,Blue]; Color.succ Blue == Nothing; Color.pred Green == Just Red
showIt : a -> String where a has toString : a -> String     -- any type Debug.toString shows, derived ones inside
bounds : a -> ( a, a ) where a has minValue : a, a has maxValue : a   -- Bool, Order, a derived enumeration, Int, Int8 .. Word64
walk : a -> List a where a has succ : a -> Maybe a                    -- Bool, Order, a derived enumeration
```

## 3. Design

| piece | where |
|---|---|
| the shapes `ToString` (`s -> String`), `Step` (`s -> Maybe s`), `Enumerate` (`List s`); `minValue`/`maxValue` reuse `Value`; built-in shapes, not well known names (as `hash`, `zero`) | `AST/WellKnown.hs` |
| `toString` a built-in member of Int, Float, String, Char, List, tuples, `()` and (behind A4b's gate) records, Maybe, Result, Array, Vector, Dict, Set; parts need it too. New kind `BBounded` = Bool and Order (A4b's members plus the five). Int: `minValue`, `maxValue`. The sized types: `toString`, and the integers `minValue`/`maxValue` | `AST/WellKnown.hs`, `Type/Members.hs` (`sizedBuiltin`) |
| `toString` at an exact type (built in, or a derived `T$$toString`, also as a value `List.map Shape.toString`) is the kernel `Debug.toString` at `[ByType t]`: `showStmt`. Not recorded in `mpDerived` (no helper of its own) | `Ficcus/Mono/BuiltinMembers.hs` (new), `Derived.derivedKernel`, `Spec.builtinMember`/`memberRef` |
| the enumeration members of Bool, Order, Int: definitions `ficBoolSucc` ... `ficIntMaxValue` in `overlay/FicOverlay.elm`; the sized integers: their modules' own top level `minValue`/`maxValue`. A clone at `Key []` | `BuiltinMembers.enumMemberDef`, `Spec.builtinMember` |
| derived `minValue` ... `enumerate` (group E): bodies written as **source** in `prepare` (constructors unqualified, `Maybe.Just`/`Maybe.Nothing` qualified), each node at its own region (the type recorder keys by region and kind); `finish` gives them no kernel stub | new `Canonicalize/DeriveEnum.hs`, `Derive.stub`, `Derive.finish` |

**Structural all the way down** (decision 4 of the note): a derived `toString` never calls a part's written `toString`
(`a4c-has-tostring`: `Wrap (Name "bob") [...]` prints `Name "bob"` although `Name.toString` gives `bob`). A part still needs
*some* `toString` (CANNOT DERIVE otherwise, as A4a checks). `a has toString` at `Name` itself calls the written one.

## 4. Fixes found on the way

1. **`Members.child` (pre-existing since A4b).** The obligation for a part of a container was made from a fresh instance of the
   shape, never unified with the part. A part whose member has `where` lines (a derived `Tree a`) then got its `a has m` at a
   fresh type: AMBIGUOUS TYPE for `a has toString` at `Maybe (Tree (Maybe Color))` or `{ t = Tree .. }`, and the same for
   `compare`/`hash` at `Maybe (Tree Int)`. Now the part is the shape's subject.
2. **The empty record** `{}` is a closed record behind the gate (was `BOther`): `Ext.toString (Ext { x = 3 })` for
   `type Ext r = Ext { r | x : Int }` needs the member at the row `{}`. Also gives `compare`/`hash` at `{}`.
3. **`(void)o;`** in a show helper's constructor case whose fields all print without being read (`Ok ()`, a function field):
   gcc `-Wall -Wextra` warned (pre-existing in `Debug.toString`). Only programs that warned before change.

## 5. The A4b review items

* **F4 (done, part):** in `unifyFlexSuperStructure` a `compare` of the type itself now wins over the core container rule, so a
  project's own `Vector` with a written `compare` is compared by it at `Vector (a -> a)` (`a4c-f4-own-vector-fn`; was TYPE
  MISMATCH). A project's own `Vector` *without* a member is still taken for the core one by the type checker and the deriver;
  the C generator refuses it loudly (`own-vector`, unchanged). Recognition by the marker constructor in the checker would need
  the union in the unifier's policy: not done.
* **F6 (done):** `RigidSuper Comparable`/`CompAppend` discharges `compare` with the built-in shape (`a4c-f6-value-at-comparable`;
  the review's `value-at-comparable` runs). 6 lines in `Members.resolve`.
* **F5 (not done, over the 30 lines):** `type W a = W (Id a) where derive compare` still constrains `a`. A precise answer needs
  the constrained positions of the inner type through a fixpoint over the module's types (and the interface for imported ones).

## 6. Cases

`ficcus-tests/attach/a4cgen.py` (standalone; helpers of a4bfgen.py; one source with markers gives both the Ficcus program and its
twin). 17 cases, attach is now 395. Twins in `a4c-twins/`: `elm` (bin/elm0193 + node; `Debug.toString` for each `toString`,
hand-written `nextIn`/`prevIn` over the declaration list for the enumeration members) or `oldc` (Debug.toString on elmficT1c).

| case | what | result |
|---|---|---|
| a4c-format | Step 1's kinds: records (Name order, alias constructor, update, empty, nested), parentheses rules, negatives, Maybe, Result, lists, tuples, unit, Bool, Order, Dict, Set, Array, strings and chars with every escape and Unicode, 15 floats, extensible record in a custom type (rows `{ y }`, `{ w, aa }`, `{}`) | RUN (elm) |
| a4c-cycles | Expr/Stmt referring to each other, a cycle A -> B -> C -> A of 900 constructors, 400 nested `Neg`, a sum of 300 | RUN (elm) |
| a4c-long | 10001 Ints, a 700-repeat string with escapes and Unicode, 1000 strings, 1800 chars; the text length in code points | RUN (elm) |
| a4c-has-tostring | `a has toString` at every built-in type and derived ones inside; structural vs written `Name.toString` | RUN (elm) |
| a4c-unshowable | Vector, Int8..Word64 (Word64 2^63), Float32, nested in List and Vector | RUN (oldc) |
| a4c-cross-module | an exposed union and an opaque type of another module (`Shapes.Shape.toString`), inside a derived type of Main | RUN (elm) |
| a4c-enum | the five members on an enumeration, a phantom type, one constructor, 40 constructors; laws (`walk succ minValue == enumerate`, the reverse with `pred`, sort by derived `compare`); Bool/Order/derived through `a has`; the bounds of Int and the 7 sized integers as text | RUN (elm) |
| a4c-f4-own-vector-fn, a4c-f6-value-at-comparable | the review items | RUN (elm / oldc) |
| a4c-err-tostring-function-arg, -has-tostring-function, -has-tostring-open-record, -succ-int, -min-float | | NO ATTACHED FUNCTION |
| a4c-err-define-tostring, a4c-err-enum-fields, a4c-js-tostring | | DERIVE AND DEFINE, DERIVE ON NON-ENUMERATION, DERIVED MEMBERS |

All RUN cases pass with gcc and clang (`-Wall -Wextra -pedantic`, no warning) and `--rc` under ASan+UBSan with 0 live objects
(attach `--rc`). **Derive matrix** (`derivegen.py`): `c-use-refused` now uses `Color.encode` (A4d); `c-enum-refused` became
`c-enum-use` (RUN), plus `c-tostring-use` (RUN): 57 cases.

## 7. Deviations and open points for review

1. **Field order:** Elm's `Debug.toString` uses Elm's `Name` order (shorter first), not alphabetical; L10's remark is wrong in
   that detail. Derived `toString` follows Elm (it must equal Debug.toString); A4b's `compare` and `hash` use code point order of
   the names. The two orders differ (`m` vs `aB`): fine for each member's own law, but worth a line in the decisions file.
2. **Built-in members are reachable only through `a has`** (as `hash`): `Basics.Bool.succ` is not a name.
3. **`Bool`/`Order` enumeration members are behind A4b's gate** (a module that sees a type with attached functions), like
   their `compare`/`hash`.
4. **Pre-existing, not fixed:** `Debug.toString ()` (or `toString` at `()`) leaves its parameter unused: gcc `-Wextra` warns
   (`unused parameter`). Fixing it in `showStmt` would change the C text of every program that prints a unit.
5. **Message:** "attached `toString` and `toString` functions" when one call needs the member twice (AMBIGUOUS TYPE merge);
   cosmetic, pre-existing.
6. `-9223372036854775808` as a literal is written `-9223372036854775807 - 1` in the overlay (the C text of a literal
   `INT64_C(-9223372036854775808)` would overflow).
7. `a has succ` at a `number` literal is AMBIGUOUS TYPE, not NO ATTACHED FUNCTION (the literal is not yet Int).

## 8. Gates

2026-11-27, targeted, on `elmficA4c` (19169bb2): `/home/gordon/claude-tmp/a4c/gates-a4c.sh` (the steps of `gates.sh` the slice asked
for; log /home/gordon/claude-tmp/gates-a4c.log, S kept). All green:
* runtime 0; attach 395/0 (`--rc`, ASan+UBSan, 0 live); derive 57/0; p1 13/0; sized-fuzz 40/0; stringdiff all agree;
* types 267 PASS + 1 XFAIL; JS identity 28/0; effects e1, e2, e3 all ok; e1p all ok;
* **a3b-identity against elmficT1c: 100 compiles, 0 differ** (programs without a derive line byte identical, `--rc`/`--no-rc`);
* rcgate-san ok; suite 16/16; typed 568 SAME + 12 BOTH_REJECT_SAME + 1 VERDICT_DIFF (salix-aws-spec, known).

## 9. Proposed text for the shared files (for the user or the planning chat)

* `docs/Ficcus-Design-Decisions.md`:
  > **DONE (27 Nov) A4c (`feat/a4c` 19169bb2, `elmficA4c`, not merged; docs/attach/A4C-NOTES.md):** derived `toString` (= Elm's
  > Debug.toString, verified on elm0193; structural all the way down), derived `minValue`, `maxValue`, `succ`, `pred`, `enumerate`;
  > built in `toString` of every showable type, the five enumeration members of Bool and Order, `minValue`/`maxValue` of Int and the
  > sized integers; A4b review F4 (own member wins over the core Vector rule) and F6 (`comparable` gives `compare`); a pre-existing
  > A4b bug (container part obligations not linked to the part) fixed. 17 a4c cases (attach 395), derive 57; targeted gates green,
  > a3b-identity vs elmficT1c 100/0. F5 open.
  > **NOTE:** Elm's `Debug.toString` orders record fields by Elm's `Name` order (shorter names first), not alphabetically (L10).
* `docs/PHASE1-CHECKLIST.md`: tick A4c; F4 (part) and F6 done, F5 open.
