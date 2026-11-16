# ATTACH A2: constraints on type variables (design; stage A2 of docs/ABILITIES-PROPOSAL.md, sections 3.2, 4, 5)

Branch `feat/attach`, binary `bin/elmficA7`. Written before the implementation; section 9 lists what changed while implementing,
section 10 has worked examples (all are cases of `tests/attach`), section 11 the known limits.

```elm
sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs = List.foldl add zero xs
```

## 1. The one idea: a constrained function is a function with hidden leading parameters

The parser turns the definition above into an ordinary definition with one extra leading parameter per constraint, in the order
the constraints are written:

```elm
sum : a -> (a -> a -> a) -> List a -> a
sum (a$has$zero as zero) (a$has$add as add) xs = List.foldl add zero xs
```

`a$has$zero` (type variable, `$has$`, member name) is a name no program can write; the pattern `(a$has$zero as zero)` both marks the parameter
as a constraint (which variable, which member) and binds the name the body uses (`zero`, or the `as` name). Nothing else is added to
`AST.Source` or `AST.Canonical`: no new expression, definition or module field. Consequences:

- **Inside the body** `add` and `zero` are ordinary lambda bound variables with the types the constraint gives. The type checking of the
  body is Elm's, unchanged; Elm's no-shadowing rule applies to them as to any parameter.
- **For users of the function** its type is the *constrained scheme*: the real type plus the list of required members. It is kept as a
  `Can.Annotation` whose type is wrapped in a type constructor that cannot be written:
  `$where (List a -> a) ($has$zero a a) ($has$add a (a -> a -> a))`. Because this is an ordinary `Can.Type`, the interface
  (`Elm.Interface`, `.elmi`, `artifacts.dat`) carries it with **no change of the binary encoding**, and a module without constraints
  produces the same bytes as before.
- **A use** of a constrained function, local or imported, is `Can.VarForeign home name annotation` with that wrapped annotation (for a
  function of the same module the canonicalizer makes this node instead of `VarTopLevel`; the dependency is logged as before, so
  ordering and cycle detection are unchanged).

## 2. Solver: a side list of member obligations

The proposal says "a variable carries a set of required members". The implementation keeps that set **beside** the union-find
instead of inside it: `Type.Solve` gets a list of *obligations* in its state, and `Content`, `Descriptor`, `Type.Unify`, `Type.Occurs`
are not touched. An obligation is `(region, function, member name, subject variable, member type variable)`.

- **Created** when `CForeign` meets a wrapped annotation: the whole wrapped type is instantiated as usual (one set of fresh
  variables), the real type is unified with the expected type exactly as before, and each `$has$m subject type` becomes an obligation.
- **Discharged** (function `Type.Members.discharge`, called before every generalization, after the body of every `let`, and at the
  end of the module), by the content of the subject variable:
  - a custom type `T` (through aliases): look up the member `m` of `T` in the *member table* (below), instantiate its annotation and
    unify it with the member type of the obligation. No such member: error NO MEMBER. Types differ: error MEMBER TYPE MISMATCH.
    Discharging can make other subjects concrete, so the list is processed to a fixpoint.
  - a function, record, tuple or unit type: error NO MEMBER (only custom types have members; built-in types get theirs in A3).
  - a rigid variable `a` (of a signature): the definition must have the constraint itself. Its hidden parameter `a$has$m` is in the
    solver's environment while the body is solved; its type is unified with the member type of the obligation. This is "the given".
  - a flexible variable: stays pending.
- **After a generalization**, a pending obligation whose subject was generalized is an error: for a rigid variable MISSING CONSTRAINT
  ("the signature must say `a has add : ...`"); for a flexible one UNKNOWN MEMBER TYPE ("I cannot tell which type's `add` to use; a
  function that is to work for every such type needs a signature with a `where`"). This is the rule "a constrained function needs
  its signature": constraints are never inferred. What is left at the end of the module is reported the same way.
- **The member table** is built in `Compile` from what the module can see: for each imported interface, its values named `T$$m`
  (present only when `T` was exported with `(..)`, the A1 rule), and the members of the module's own types that have a signature.
  A member without a signature cannot satisfy a constraint in its own module (error says: add a signature).

**`number`, `comparable`, `appendable`, `compappend` are untouched.** They stay `FlexSuper`/`RigidSuper` contents handled by
`Type.Unify`; no obligation is ever created for them, and a program without a `where` signature never creates an obligation, so the
list is empty and each new check is one test of an empty list. (A3 will map the bundles onto members; nothing here prepares that
beyond keeping the two mechanisms apart.) A `number` variable that also has an obligation simply stays pending until it becomes a
concrete type.

## 3. Interface

`Compile` replaces, after type checking, the annotation of each constrained definition (`a -> (a -> a -> a) -> List a -> a`, which is
what the solver reads out for the hidden-parameter form) by the wrapped scheme of section 1. That map is what `Elm.Interface` stores,
so packages compile separately and a constrained function is exported and imported like any value.

## 4. Specialization (`Ficcus.Mono.Spec`), the C path

The specializer already clones every definition per key. For a constrained definition:

- every type variable that occurs in a constraint is keyed **by its exact type** (as `number` and `comparable` variables are); the
  marks fixpoint (`Ficcus.Mono.Marks`) gets these variables as extra roots, so callers that pass their own variables are keyed
  exactly too;
- at a use, the scheme is the hidden-parameter type and the instance is padded with the instantiated member types
  (`Type.Dump.schemeOf`), so the existing matching, numbering and facts work unchanged;
- when the clone is generated, each hidden parameter is not a parameter of the clone: from the exact type of its subject variable
  (`author/project:Main.Money`) the member's definition `author/project:Main.Money$$add` is found, a clone of it is requested for the
  instantiated member type, and every use of the local name `add` in the body is that clone. Calls are direct; a zero-argument member
  (`zero`) is the global value. Local functions and lambdas inside the body inherit the table.

Nothing changes in the IR, in CGen or in the runtime.

## 5. JavaScript path

A constrained function would need the members passed at run time (dictionary passing), which is the later JS decision. Until then
`Generate` (dev, prod, debug) refuses a program whose object graph contains a constrained function, naming the functions:
"CONSTRAINED FUNCTIONS ... not supported in the JavaScript output yet; use `--output=<name>.c`". The check is on the object graph
(a function whose body starts with the `a$has$m` destructuring), so it also sees packages. A program without constraints generates
byte-identical JavaScript.

## 6. Syntax and rules

- `where` follows the signature, indented; each constraint line is `var has member : type` or `var has member as local : type`, the
  lines aligned. `has` is a keyword only there. Only top level definitions and members in a `where` block of a type can have it
  (not `let` definitions in A2).
- A constrained definition needs the signature (there is nowhere else to write the constraint).
- The local name follows the no-shadowing rule: a clash with a top level definition (or a sibling member) is an error that suggests
  `as`; two constraints with one local name: the second needs `as`; the same `var has member` twice is an error.
- The subject variable must occur in the type of the signature (otherwise no use could ever determine it).
- Zero-argument members work: the subject is known at each specialization.

## 7. Errors (Elm's voice)

NO MEMBER (type has no such member; lists the members it has and the type needed), MEMBER TYPE MISMATCH (member exists with another
type), MISSING CONSTRAINT (generic code uses a constrained function at its own type variable without stating the constraint),
UNKNOWN MEMBER TYPE (constrained function used where the type is not determined, or by a function without a signature), NAME CLASH
suggesting `as`, UNUSED CONSTRAINT VARIABLE, PROBLEM IN CONSTRAINT (syntax).

## 8. Files

New: `AST.Constraints` (names, the hidden parameters, the wrapped scheme), `Parse.Constraints`, `Canonicalize.Constraints`,
`Type.Members` (obligations, table, discharge), `Ficcus.Mono.Members` (specializer helpers). Changed, small: `Parse.Declaration`
(signature), `Reporting.Error.Syntax`, `Canonicalize.Module`, `Canonicalize.Expression` (top level use), `Reporting.Error.Canonicalize`,
`Type.Solve` (state, `CForeign`, the three calls), `Reporting.Error.Type`, `Compile` (table, wrapped annotations), `Type.Dump`
(`schemeOf`), `Ficcus.Mono.Spec`, `Ficcus.Mono.Marks`, `Generate` and `Reporting.Exit` (JS refusal).

## 9. What changed while implementing

- The mark of a hidden parameter is `a$has$add` (not `a$add`), so it cannot be confused with the other names that use `$`
  (`Money$$add` for a member, `sum$where` for the scheme of a local definition in the canonicalizer's environment).
- One use, one error: the NO MEMBER, MISSING CONSTRAINT and UNKNOWN MEMBER TYPE errors of one use of a function are put together
  and list all the members (`Type.Members.merge`).
- Two more errors: MEMBER WITHOUT TYPE ANNOTATION (a member of the same module without a signature is needed for a constraint) and
  CONSTRAINTS ON A LOCAL DEFINITION (`where` on the signature of a `let` definition).
- The JS refusal lives in `Nitpick.Constraints` (an import cycle kept it out of `AST.Constraints`); it checks every function of the
  object graph, used or not, as the `Debug` check of `--optimize` does.
- The mark roots are passed to `Ficcus.Mono.Marks.computeWith` from `terminal/src/Make.hs` (two call sites).
- A member with constraints of its own (a `where` inside the `where` block of a type) works; it was not planned, it fell out.
- A soundness gap found by a test and closed: `let y = get t in ...` where `t` becomes a known type only later in the enclosing
  definition. Elm generalizes `y` at the `let`; the obligation is discharged later and would then change a variable that is
  already generalized (`y` could be used at two types). After each generalization the variables of the member type of an
  obligation that stays pending are made variables of the subject's level again (`Type.Members.sweep`, `pin`).
- `Type.Constrain.*` needed no change at all.

## 10. Worked examples (cases of tests/attach, all run through the C path with gcc and clang)

| program | what happens |
|---|---|
| `sum [ Money 1, Money 2 ]`, `sum [ V2 1 2, V2 3 4 ]` | two clones of `sum`; in each `add` and `zero` are `Money.add`/`Money.zero` or `V2.add`/`V2.zero`, called directly (`constraint-basic`) |
| `empty : a where a has zero : a`, `empty = zero`; `start : Money`, `start = empty` | a constrained value is a function without parameters, one clone per type; a zero-argument member is the global value (`constraint-zero-arg`) |
| `a has add as addA`, `b has add as addB`; a top level `add` in the module | `as` gives the member another name in the body (`constraint-as`) |
| `sumTwice xs = double (sum xs)` with the same constraints in its signature | the obligation of `sum` at the rigid `a` is met by the hidden parameter of `sumTwice`; in the clone it is the same member (`constraint-chain`, also recursion, a local function and a lambda) |
| `type Pair a = Pair a a where swap : Pair a -> Pair a`; `twice : t -> t where t has swap : t -> t` at `Pair String` | the member's scheme is matched with the exact member type; its own variable is keyed as usual (`constraint-poly-member`) |
| `x == zero` on a constrained variable; a `number` variable beside it | Elm's equality and `number` work as before (`constraint-equality`) |
| a constrained function in `Algebra`, types in `Types`, use in `Main`; the same with `Algebra` in a package | the scheme is in the interface (`constraint-modules`, `constraint-package`) |
| `sum [ T 1 ]`, `T` has `zero` and `mul` | NO MEMBER: "needs a type that has the member `add`", the members `T` has, `add : T -> T -> T` (`constraint-no-member`) |
| `T.add : T -> Int -> T` | MEMBER TYPE MISMATCH (`constraint-wrong-type`) |
| `total : List a -> a`, `total xs = sum xs` | MISSING CONSTRAINT with the `where` block to add (`constraint-missing`) |
| `total xs = sum xs` without a signature; `sum [ 1, 2 ]` | UNKNOWN MEMBER TYPE (`constraint-no-signature`, `constraint-no-members-at-all`) |
| `a has add` with a top level `add`; `a has add` and `b has add` | NAME CLASH with `a has add as add_ : ...` (`constraint-clash-top`, `constraint-clash-two`) |
| `--output=out.js` | CONSTRAINED FUNCTIONS, naming `Main.sum` (`constraint-js`) |

## 11. Known limits and open questions

1. No constraints on `let` definitions (clear error).
2. Only custom types have members. `sum [ 1, 2 ]` (a `number`), `String`, records, tuples and functions are NO MEMBER or UNKNOWN MEMBER
   TYPE until A3 gives the built-in types their members.
3. A member can satisfy a constraint only where it is visible: the module of the type must be imported by the module that uses the
   constrained function, and must export the type with `(..)`. A type that only flows through (a value of `M.T` obtained from a
   third module, `M` not imported) gives NO MEMBER with that hint. In its own module a member needs a signature to count.
4. A member is found by name and type only ("satisfied by accident", as the proposal says of Roc).
5. (closed while implementing, see section 9: a pending obligation keeps the variables of its member type at the level of its
   subject, cases `constraint-let-mono`, `constraint-let-poly`.) A rigid variable of an inner annotated `let` in such a member
   type cannot be kept back; I have no program that reaches this.
6. In messages about the body, the hidden parameters count: "the 2nd argument" of a constrained function with one constraint is
   the first written one (annotation arity errors and argument positions). Not fixed in A2.
7. `docs.json` (`elm make --docs`, `elm diff`, `elm publish`) would show the wrapped scheme of a constrained function; not handled.
8. The `.types` dump shows a constrained definition with its hidden parameters.
9. The JS refusal names every constrained function of the program and its packages, used or not.
