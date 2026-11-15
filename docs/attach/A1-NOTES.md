# ATTACH A1: functions attached to custom types (stage A1 of docs/ABILITIES-PROPOSAL.md)

Branch `feat/attach` (worktree `ficcus-haskell-compiler-attach`), binary `bin/elmficA3` (and later). Tests: `tests/attach/` in the workspace
(`python3 tests/attach/attach.py --elm bin/elmficA3`, table `tests/attach/expected.tsv`). Not in A1: `where` after signatures, constraints,
well known members, `derive`, operators.

The rules below are what the compiler does now. Items marked **(review)** are choices the user should confirm before A2.

## 1. Representation: a member is a top level function with a mangled name

The member `add` of the type `Money` is the top level definition `Money$$add` of the module that declares `Money`. `$` cannot occur in an
Elm name, so no program can write such a name or clash with it. Everything after the parser sees an ordinary top level function: the type
checker, the optimizer, the JavaScript generator (`$author$project$Main$Money$$add`), the C path (`sanitize` turns `$` into `_`), the
interfaces and the `.elmi` encoding (no change of the encoding: an interface is `Map Name Annotation`, a member is one more entry).
Error messages show `Money.add` (`Reporting.Doc.fromName` and `Reporting.Error.Type` print through `AST.Members.displayName`).

## 2. Declaration

```elm
type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)
```

- `where` follows the last variant, on a later line, indented. The members are indented under it, aligned with each other; each is an
  ordinary definition (function or value, optional signature). A doc comment or a line comment before a member is accepted (a doc
  comment is ignored: members are not in `docs.json` in A1).
- A body continues on lines indented more than the member. The block ends at the first line that is not aligned with the members.
- `where` after a type alias: **MEMBERS ON A TYPE ALIAS** (a parse error), with a wrapper type as the suggestion.
- `where` with no member: UNFINISHED CUSTOM TYPE. A signature without its definition: Elm's EXPECTING DEFINITION (last member) or NAME MISMATCH.
- Two members of one type with one name: NAME CLASH, "The `T` type has multiple `f` members." Two types of a module may both define
  `add`; a member may have the name of a top level function. The names live in different places.
- In the module: the members see everything the module sees, including the constructors of the type. A member is called as `Money.add`
  also inside its own module and inside the `where` block (recursion between members: `Nat.isOdd m`); an unqualified `add` means what it
  always meant. **(review)** Unqualified calls of siblings inside the block are not supported.

## 3. Name resolution of a qualified name `P.f` (P is the dotted part, `f` a lower case name)

In this order, the first that applies:

1. `P` is a module name or an alias, as exactly in Elm, and it exposes `f`: that function. (A module that does not expose `f` does
   not stop the search, see 2.)
2. `P` is a single name, a type declared in this module, and it has the member `f`: that member.
3. An imported type, found by the key under which the import registered it (section 4): `P` is a type in scope under its own name
   (`Money.add`); or `Alias.Type` / `Module.Type` (`Fm.Money.add`, `Finance.Money.Money.add`); or `P` is an import prefix and the
   module's last name part is the type's name (`import Finance.Money` makes `Finance.Money.add` reach `Money.add`; so does
   `import Finance.Money as Fm` with `Fm.add`). **(review)** The last rule is my reading of the proposal's "`Finance.Money.add` for a
   clash"; the form that always works is `Finance.Money.Money.add`.
4. Otherwise Elm's own error (NAMING ERROR, "I cannot find a `P` module"); except that when `P` names a type in scope and is not
   a module, the error is the member error: "I cannot find a `Money.foo` member", followed by the members the type has (or "has no
   members that I can see here" with the `Money(..)` hint).

Two imported types of one name that both have `f`, both in scope as `T`: AMBIGUOUS NAME (the text says "import A as T / import B as T",
it names the modules). **(review)** wording.

Local before imported: a type declared in the module hides an imported type of the same name, as for types.

## 4. Export and import

- `module M exposing (Money(..))` exports the constructors **and the members**; `exposing (Money)` the type only (no members, as no
  constructors); `exposing (..)` everything. Members cannot be exported one by one (their names cannot be written). `Money(..)` on an
  alias is still an error.
- In the interface the members are the values `Money$$add` with their annotations, present exactly when the union is exported open or the
  module exports everything (`Elm.Interface.restrictValues`). Nothing else changed in `.elmi`/`artifacts.dat`; a module without members
  produces the same interface as before.
- Import: the interface values that are members are taken out of the plain values (they are never reachable as plain names) and entered
  in the table of qualified variables under the key `Money$` for each way the type is reachable: `Alias.Money$` (`Alias` is the import
  prefix: the module name or the `as` name), `Money$` when the type is exposed (`import M exposing (Money)`, `(Money(..))` or `(..)`),
  and `Alias$` when the type is named like the last part of the module name. `$` is not allowed in a module name, so a key never clashes.
- So: `import M exposing (Money)` gives `Money.add` (the members need no `(..)` on the import; the module must have exported them with
  `Money(..)`). A type exported closed (`Money`) has no members for importers (cross-package case `cross-package-closed`), but the
  functions of its own module use them freely (`cross-package-closed-ok`).

## 5. Worked examples (all are cases in tests/attach)

| program | meaning |
|---|---|
| `type Money = Money Int where add ...` in Main; `Money.add a b` | rule 2, local member (`attach-call`) |
| `Money.zero`, `Count.zero` in one module | each type has its own `zero` (`same-name-member`) |
| `module Finance.Money exposing (Money(..))`; Main: `import Finance.Money as Fm` and `import Finance.Money exposing (Money(..))`; `Money.add`, `Fm.Money.add`, `Finance.Money.add` | rule 3 three ways (`export-import`) |
| the same from a package built separately | `.elmi`/interface carries the members (`cross-package`) |
| module `Money` exposing `add : Int -> Int -> Int` and imported type `Money` with members `add`, `only`: `Money.add 1 2`, `Money.only 7`, `Types.Money.add a b` | rule 1 wins for `add`; `only` falls to the type (rule 3); the full name reaches the type's `add` (`qualified-clash`) |
| local module `Money` with `double`, local type `Money` with `add`: `Money.double 4`, `Money.add a b` | rule 1 for `double`, rule 2 for `add` (`local-module-shadow`) |
| `T.fop` where `T` has `foo`, `bar` | NAMING ERROR, "The `T` type has these members: T.bar, T.foo" (`unknown-member`) |
| `type alias Meters = Float where ...` | MEMBERS ON A TYPE ALIAS (`alias-where`) |

## 6. Changes to upstream files (all small; new logic is in the new modules)

New: `AST.Members` (mangling, keys), `Parse.Members` (the `where` block, the alias check), `Canonicalize.Members` (import tables, resolution).
Changed: `Parse.Declaration` (`UnionWith`, `memberDecl`, `valueDeclWith`), `Parse.Module` (`categorizeDecls`, `toDocs`), `Reporting.Error.Syntax`
(`AliasWhere`, `CT_Member`, `CT_IndentMember` and their reports), `Canonicalize.Expression` (`findVarQual` asks `Members.resolve` first; possible
names without members), `Canonicalize.Environment.Foreign` (import tables), `Reporting.Error.Canonicalize` (`NotFoundMember`, DuplicateDecl text),
`Elm.Interface` (`restrictValues`), `Reporting.Doc` (`fromName`), `Reporting.Error.Type` (names printed through `displayName`), `terminal/src/Repl.hs`
(one more constructor), `elm.cabal` (3 modules).

## 7. Known limits and open questions

1. Members are not in `docs.json`; a doc comment on a member is ignored.
2. No unqualified call of a sibling inside the `where` block **(review)**.
3. The "module last name equals the type" rule **(review)**, section 3.
4. The `.types`/`.mono` dumps and the JS/C identifiers show the mangled name `Money$$add`.
5. The REPL accepts a `type ... where` declaration (it is passed on as text); not tested.
6. A type exported closed hides its members from importers; there is no way to export only some members.
