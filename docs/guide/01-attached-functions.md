# 1. Functions attached to a type, and constrained type variables

State: binary `elmficA16` (branch `ficcus`, 17 Nov 2026). Every example below is a program in
`ficcus-tests/guide/<name>/`, built with the compiler and run in three modes (`python3 ficcus-tests/guide/run.py`).
The examples print with `Debug.log`; the `main` that calls `report` is the same in all of them and left out here
(see `a-money/Main.fic`). Output lines are what a run prints on stdout.

A custom type can carry its own functions, called *members*. A function can also say "my type variable `a` must
have a member `add` of this type". This replaces the "abilities" of the early proposals (`docs/ABILITIES-PROPOSAL.md`).
Everything is decided at compile time: every call is a direct call, nothing is looked up at run time.
The syntax is new, so it only adds programs: no Elm 0.19 program changes meaning. It is accepted in `.elm` and `.fic`
files alike (`a-elm-file` is `a-money` as `Main.elm`). A program that uses it is no longer valid Elm.

## 1.1 Members: the `where` block of a type

<!-- guide: a-money/Main.fic -->
```elm
type Money
    = Money Int
    where
        zero : Money
        zero =
            Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)

        toInt : Money -> Int
        toInt (Money a) =
            a
```

- `where` comes after the last variant, on a later line, indented. The members are aligned under it.
  A member is an ordinary definition, with or without a signature. It can use the constructors of the type.
- A member is called with the type name in front: `Money.add`, `Money.zero`. Currying, `|>` and `<<` work as
  for any function.

<!-- guide: a-money/Main.fic -->
```elm
total : List Money -> Money
total =
    List.foldl Money.add Money.zero
```

<!-- guide-out: a-money -->
```text
total: 42
piped: 11
```

(`total` of `[ Money 1, Money 2, Money 39 ]`, and `Money 5 |> Money.add (Money 6) |> Money.toInt`.)

- Two types of one module may both have a member `zero`. A member may have the name of a top level function:
  the names live in different places, and `zero` alone still means the top level one.

<!-- guide: a-two-types/Main.fic -->
```elm
-- a top level function may have the name of a member
zero : Int
zero =
    7
```

<!-- guide-out: a-two-types -->
```text
Money.zero: Money 0
Count.zero: Count 101
zero: 7
```

- **Inside the `where` block** the members of that type are visible by their plain names (also recursively), and
  there they win over a top level function of the same name. Outside the block you must write `Money.add`.

<!-- guide: a-inside/Main.fic -->
```elm
        -- inside the block the members are visible by their plain names
        sum : List Money -> Money
        sum ms =
            List.foldl add zero ms
```

- A type alias cannot have members (two names for one type would share them). Wrap the type instead:
  `type Meters = Meters Float where ...`. The error is shown in 1.6.

How `P.f` is resolved, in this order: (1) `P` is a module or an import alias that exposes `f`, exactly as in Elm;
(2) `P` is a type declared in this module that has the member `f`; (3) `P` is an imported type in scope that has it,
or `Alias.Type.f` / `Module.Type.f`; (4) otherwise Elm's own "cannot find" error, except that for a type with members
you get the list of its members (1.6). A local type hides an imported one of the same name.
Two imported types with one name that both have `f` give an AMBIGUOUS NAME error naming both modules.

## 1.2 Modules: export and import

`module M exposing (Money(..))` exports the type, its constructors **and its members**. `exposing (Money)` exports
the type only, with no members for the importers, just as it hides the constructors. Members cannot be exported
one by one.

<!-- guide: a-export/Finance/Money.fic -->
```elm
module Finance.Money exposing (Money(..), fromInt)
```

An importer reaches the members through the type name, or through the module name and the type name:

<!-- guide: a-export/Main.fic -->
```elm
import Finance.Money as Fm
import Finance.Money exposing (Money(..))
```

<!-- guide-out: a-export -->
```text
Money.add: Money 3
Fm.Money.add: Money 3
```

(`Money.add (Money 1) (Money 2)` and `Fm.Money.add (Fm.fromInt 3) Money.zero`.)
`Finance.Money.add` would mean the function `add` of the module `Finance.Money`, not the member:
there is no shortcut for a module that is named like its type.

The members come with the type, so `exposing (Money)` on the import (no constructors) is enough to write `Money.add`:

<!-- guide: a-import-type/Main.fic -->
```elm
import Finance.Money exposing (Money, fromInt)
```

<!-- guide-out: a-import-type -->
```text
sum: Money 6
```

**A type exported closed has no members outside its module.** The module itself and its own functions use them
freely, but they must write `Money.add`: the plain name `add` is not in scope outside the `where` block.

<!-- guide: a-plain-name/Finance/Money.fic -->
```elm
total : List Money -> Money
total =
    List.foldl add (Money 0)
```

<!-- guide-out: a-plain-name err -->
```text
I cannot find a `add` variable:

19|     List.foldl add (Money 0)
                   ^^^
```

Fix: `List.foldl Money.add (Money 0)`. And the importer of a closed type, calling `Money.add`:

<!-- guide-out: a-closed err -->
```text
I cannot find a `Money.add` variable:

13|             Debug.log "add" (Money.add (fromInt 1) (fromInt 2))
                                 ^^^^^^^^^
I cannot find a `Money` import. These names seem close though:
```

Fix: export `Money(..)`, or give the module a function (`total`, `fromInt`) that the importer can call.
Members also work across packages (the `.elmi` interface carries them), and a constrained function (next section)
finds the members of a type wherever the type is known, as long as its module exported it with `(..)`.

## 1.3 Constraints: `where` after a signature

<!-- guide: c-sum/Main.fic -->
```elm
sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs
```

Read: "`sum` works for every type `a` that has a member `zero : a` and a member `add : a -> a -> a`."
Inside the body `add` and `zero` are plain names. Each use is checked against the type it is used with,
and the compiler makes one copy of `sum` per type, calling that type's members directly (no run time cost).

<!-- guide-out: c-sum -->
```text
money: Money 6
vectors: V2 4 6
empty: Money 0
```

(`sum` of three `Money`, of two `V2 Float Float`, and of an empty `List Money`.)

Rules:

- **A constrained function needs its signature.** Constraints are never inferred. A function without a signature
  that calls `sum` gets an error (1.6). A function with plain members and no constraint needs no signature:
  `twice x = Money.add x x` is fine.
- `has` is a keyword only on these lines. Each line is `var has member : type`; the lines are aligned under `where`.
- The variable must occur in the signature's type. Zero-argument members (`zero`) work.
- A function that calls a constrained function with its own type variable must repeat the constraints it needs:

<!-- guide: c-chain/Main.fic -->
```elm
sumPlusZero : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sumPlusZero xs =
    sum [ sum xs, zero ]
```

- **Name clashes and `as`.** Elm does not allow shadowing, so a constraint whose member name is already a top level
  name (or two constraints with one name) must rename it with `as`. The type of the member is unchanged:

<!-- guide: c-as/Main.fic -->
```elm
twice : a -> a
    where
        a has add as plus : a -> a -> a
twice x =
    plus x x
```

<!-- guide-out: c-as -->
```text
twice: Money 42
add: 42
```

- A constrained function can live in another module or package; the constraint is part of its type in the
  interface (`c-modules`: `Algebra.sum` used on `Types.Money`).
- Elm's `number`, `comparable`, `appendable`, `compappend` are untouched and keep their Elm meaning.

## 1.4 Errors and their fixes

NO MEMBER: the type has no member of that name. The message lists the members it has.

<!-- guide-out: e-no-member err -->
```text
-- NO MEMBER ------------------------------------------------------ src/Main.fic

This use of `sum` needs a type that has the member `add`, but it is used with:

26|     Debug.log "r" (sum [ T 1 ]) |> always ()
                       ^^^
    T

That type has these members:

    mul
    zero

`sum` needs:

    add : T -> T -> T
```

Fix: add the member to the type's `where` block (and export the type with `(..)` if it lives in another module).
MEMBER TYPE MISMATCH is the same with a member of the wrong type (`e-wrong-type`: `T.add : T -> Int -> T`
where `T -> T -> T` is needed).

MISSING CONSTRAINT: generic code uses a constrained function at its own type variable without saying so.

<!-- guide-out: e-missing err -->
```text
-- MISSING CONSTRAINT --------------------------------------------- src/Main.fic

This use of `sum` needs the type `a` to have the members `zero` and `add`, but
the type annotation of this definition does not say so.

14|     sum xs
        ^^^
`a` can be any type here. If every such type must have these members, say it in
a `where` block after the type annotation:

    where
        a has zero : a
        a has add : a -> a -> a
```

The same title appears when the calling function has **no signature** at all; the message then prints the signature
to write (`e-no-signature`). Fix: copy the `where` block it shows.

NAME CLASH: the constraint name is already a top level name.

<!-- guide-out: e-clash err -->
```text
-- NAME CLASH ----------------------------------------------------- src/Main.fic

The constraint gives the name `add`, but that is already the name of a
definition. The name is first defined here:

5| add a b =
   ^^^
And the constraint is here:

11|         a has add : a -> a -> a
                  ^^^
Inside the definition the name could mean either one, so give the member another
name here with `as`:

    a has add as add_ : ...
```

UNKNOWN MEMBER TYPE: a constrained function is used where its type is not settled, for example on `[ 1, 2, 3 ]`
(`e-builtin`, see 1.5). A member name that does not exist, written as `Money.plus`:

<!-- guide-out: n-unknown-member err -->
```text
I cannot find a `Money.plus` member:

18|     Debug.log "r" (Money.plus (Money 1) Money.zero) |> always ()
                       ^^^^^^^^^^
The `Money` type has these members:

    Money.add
    Money.zero
```

AMBIGUOUS CONSTRAINT: a type variable of a constraint is not in the signature's type, so no use could ever say which type it is.

<!-- guide-out: e-unused-var err -->
```text
-- AMBIGUOUS CONSTRAINT ------------------------------------------- src/Main.fic

The constraint `b has zero` mentions the type variable `b`, but `b` does not
occur in the type of `size`:

14|         b has zero : b
            ^^^^^^^^^^
```

Fix: use `b` in the type of the function, or remove the constraint.

NAME CLASH is also the error for two members of one type with one name ("The `T` type has multiple `zero` members",
`e-dup-member`). Other titles seen in the tests: PROBLEM IN CONSTRAINT (a syntax error in a `has` line),
MEMBER WITHOUT TYPE ANNOTATION (a member that has to satisfy a constraint inside its own module needs a signature),
CYCLIC DEFINITION (two members defined by each other; it names `T.a` and `T.b`, never the internal `T$$a`).

## 1.5 What is not there yet

**Operators for your own types.** `+`, `==`-with-your-own-rule, `<`, `++` do not use members. `Money 1 + Money 2`
is a type error, today and until the planned "well known members" (`add`, `compare`, `append`, ...) are wired in:

<!-- guide-out: n-operator err -->
```text
Addition does not work with this value:

14|     Debug.log "r" (Money 1 + Money 2) |> always ()
                       ^^^^^^^
This `Money` call produces:

    Money

But (+) only works with Int and Float values.
```

Write `Money.add`. `==` keeps working structurally on any type without functions.

**Built-in types have no members.** `sum [ 1, 2, 3 ]` is an error (UNKNOWN MEMBER TYPE, with the text "The built-in
types ... do not have members yet"). Wrap the type in a custom type to give it members. A single field wrapper is
planned to cost nothing.

**`derive`.** `where derive compare` is planned, not implemented; today it is a syntax error:

<!-- guide-out: n-derive err -->
```text
I got stuck while parsing the `derive` definition:

8|         derive compare
                         ^
```

**Constraints on local definitions.** Only top level functions and members can have a `where` after the signature.

<!-- guide-out: n-local err -->
```text
-- CONSTRAINTS ON A LOCAL DEFINITION ------------------------------ src/Main.fic

The type annotation of `twice` is in a `let`, but I got stuck at this `where`:
```

**JavaScript output.** A program that contains a constrained function does not compile to JavaScript yet
(the member functions would have to be passed at run time; that design is not decided). The C output has no such
limit. Members themselves (without constraints) are ordinary top level functions in the JS output and work
(`a-js`: the program of 1.1 compiled to JavaScript and run under node prints the same two lines).

<!-- guide-out: e-js err -->
```text
-- CONSTRAINED FUNCTIONS -------------------------------------------------------

This program has functions whose type annotation has a `where` block of
constraints:

    Main.sum
```

Also not there: members in `elm make --docs` output (a doc comment on a member is ignored), inferred constraints, exporting
single members. Not planned: method syntax `x.add(y)`, instances for types you do not own (wrap the type), higher-kinded
constraints (`Functor`, `Monad`). In the `.types` and `.mono` dumps a member shows as `Money$$add`; error messages never do.
