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
