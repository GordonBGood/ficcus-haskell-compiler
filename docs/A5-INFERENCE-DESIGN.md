# A5: inferring what attached functions a type must have, let generalization, and the voice of the errors

Design note, read only. Branch `design/a5` from `ficcus` e364228a (G71 included), 2026-11-26. Sources: `docs/attach/G71-INFERENCE.md`
(L1 to L6), `A2-DESIGN.md`, `A3-NOTES.md`, review 1 (B2 to B4), `Type/Members.hs` (`relax`, `defaulting`, `hold`, `sweep`),
`Type/Solve.hs` (`CLet`), `Reporting/Error/Type.hs`, 56bb4fd0.

Terms: a *requirement* is `a has m : t` (the code says obligation or constraint). A *selector* is a bare member name such as
`add` that no variable binds (section 2).

## 1. Principal types

**Discipline.** A scheme is `forall vs. R => t`, where `R` maps each type variable to a finite map from member names to types,
for example `a ↦ { add : a -> a -> a, zero : a }`. Four rules:

1. **One type per name per variable.** `a has m : t1` and `a has m : t2` unify `t1 ~ t2`. When two variables unify, their maps
   merge and same-name entries unify. This is how Elm's record rows behave, and it is already how a `where` line behaves inside
   its body (there `add` is a lambda-bound, monomorphic hidden parameter). A polymorphic member (`pick : Q -> c -> c`) is used at
   one `c` per requirement. For any other `c`, call `Q.pick`.
2. **A concrete subject decides.** When the subject becomes `T args`, the member `T.m` is looked up (visibility as in G70), a
   fresh instance of it is made, and that instance is unified with `t`. A type has at most one member of each name, so the
   result is deterministic. Built-in subjects use `builtinHas`, as now.
3. **The subject determines the member type.** This is a functional dependency `subject, name → type`, and it follows from rule
   2. The *determined* variables of a scheme are the free variables of `t`, closed under: if a subject is determined, the
   variables of its member types are too.
4. **Resolution happens at specialization.** In each clone every determined variable has an exact type, so a selector or a call
   of a function with requirements becomes a direct call of the member's clone. Nothing remains at run time.

**Decidability.** Constraint generation is Elm's. Beyond unification the solver adds two steps:

- improvement (rule 1), which only unifies;
- discharge (rule 2), which is one table lookup and one unification.

A discharge creates new requirements only through the member's own `where` lines, or through the structural `compare`/`eq` of
lists and tuples. A `where` line's subject is always a type *variable* of the member's type; the syntax allows nothing else.
So each new requirement falls on a proper part of the discharged subject, or on a fresh variable that the context must
determine. The size of the concrete subjects goes down, and solving ends. Specialization can still loop on polymorphic
recursion, as it already can without members.

**Principality.** Requirements are predicates in the sense of qualified types (Jones 1994, HM(X)):

- Entailment is closed under substitution, because rule 2 looks only at the type constructor.
- The functional dependency gives consistency (one member per type and name) and coverage (rule 3).
- Under those conditions HM inference gives principal types.
- Rule 1 makes the predicates on one variable a record-like map, so "most general" means the same as for Elm's extensible
  records.

**Ambiguity (review 1 B2).** A requirement is ambiguous when its subject is not determined: nothing outside the function can
ever fix it.

- `describe : a -> String where a has f : a -> z` (B2) is **not** ambiguous, because `a` determines `z`.
  - Today this is the AMBIGUOUS CONSTRAINT error from 56bb4fd0. That error was a guard against a specializer crash, not a typing
    rule.
  - Proposed (D2): accept it. The specializer gets `z` by unifying the member's instance, which is the step that failed in B2.
  - `constraint-top-nosig-hidden` (`twice w = get (get w)`) needs the same rule.
- `size : List a -> Int where b has zero : b` stays an error, because `b` is undetermined.
- An inferred, undetermined subject is defaulted when it is a `number` variable (D3):
  - Try `Int`, then `Float`; try `Float` first when `div` is required. Take the first type whose built-in members meet every
    requirement.
  - This extends Elm's own rule: an unconstrained `number` is `Int`, which the specializer already applies (A3c).
  - It reverses A3c's "a literal whose variable has an obligation is not defaulted", so `total [ 1, 2, 3 ]` gives `6`.
  - Any other undetermined subject is the AMBIGUOUS TYPE error (section 4).

**Monomorphism restriction (MR).** A definition that is not a function is never generalized over requirements. A definition
is a function when it has arguments or its body is a lambda (D4).

- At the top level, the requirements of such a definition are defaulted or reported.
- In a `let`, they keep the context's rank, as today's `hold` does.
- Why: a constrained value would be a computation repeated per type and hidden from the reader.
- Why: `y = get t` has a type that is a function of `t`'s type, so `constraint-let-poly`, `constraint-order-bad-*` and B4 stay
  as they are.
- Why: `out = ( h 9, h (Cash 800) )` gets `9 : Int` by defaulting, which fixes L5.
- Elm's own generalization of `number`/`comparable` values is untouched (`x = 9` at Int and Float). The MR applies only to
  member requirements, and Elm programs have none.

**Generalization rule (replaces `hold` for functions).** At a `let`:

- The pending requirements with a young subject go into the scheme.
- The exception is a requirement whose subject is determined by an outer variable (the closure under rule 3 starting from the
  context's variables). Those variables keep the context's rank. This is the precise form of the 56bb4fd0 hold: it holds by
  determination, not every variable of every pending obligation.
- At the top level there is no outer variable. Determined requirements go into the scheme; undetermined ones are defaulted or
  rejected.

## 2. Name resolution: bare member names

**Rule.** Elm's lookup runs first and is unchanged: locals (including `where` hidden parameters), top-level names, exposed
imports, then the default imports (`Basics.compare` and the rest). An unqualified lowercase `m` becomes a selector only in the
case where Elm would report NAMING ERROR, and only if `m` names an attached function of at least one *candidate type*.

**Candidate types (D5).** Custom types with a `where` block that this module defines, or that an imported module exports by
name.

- Any import form counts (qualified only, `exposing (T)`, `(..)`), and opaque types count, as in G70.
- Types that only travel inside another interface (the `pkg:Module.T$$m` entries) still meet requirements at discharge, as
  today, but they are not candidates for naming. So a module's names never depend on a type it cannot name.

**The selector's type.**

- For a well-known name (`add`, `fromInt`, `div`, …; `zero` is not one) it is the A3 shape:
  `add : a -> a -> a where a has add : a -> a -> a`.
- For any other name, replace each owner type (with its parameters) by `a` in the candidates' annotations and anti-unify them:
  - `Money.zero : Money` and `Vec.zero : Vec` give `zero : a where a has zero : a`;
  - `T.f : T -> Int` and `W.f : W -> T` give `f : a -> b where a has f : a -> b`, which is B4's `get`.
- The candidates form a set, so the result does not depend on import order.
- If `a` does not survive the anti-unification (`scale : Money -> Int -> Money` beside `scale : Float -> Vec -> Vec`), the name
  is not a selector, and NAMING ERROR lists `Money.scale` and `Vec.scale`.
- Two types having a member of one name is not an ambiguity. It is the point of the feature: the type at each use picks the
  member.

**Shadowing.** A selector is never a binding, so it shadows nothing, and any binding wins over it.

- In `q1-nosig-bare-member`, `compare` resolves to `Basics.compare`. That is right, because `compare` already reaches the
  member through `comparable`.
- A top-level `add` hides the selector in the whole module. A2's `as` rule is unchanged.

**Typos.** `ad` is still NAMING ERROR, and the suggestions now include the selectors in scope. A typo that happens to be a
member name (`zero` written for a local `zeros`) now type checks as a requirement:

- with a signature, it is INCOMPLETE TYPE ANNOTATION, which names `zero`;
- without one, the problem shows at the first use that cannot meet it ("`List Int` does not have an attached `zero`").

This cost comes with D1, and it is limited to member names of types the module names.

**Representation.** No new `Can.Expr` constructor. A selector is `Can.VarForeign attachedHome m scheme`, where `attachedHome` is
a reserved module name and `scheme` is the `$where`-wrapped selector type.

- The solver's `CForeign` path then creates the requirement exactly as for a call of `sum` (A2, section 2).
- The specializer resolves `attachedHome` by the subject's instance type, as `wellKnownRef` does.
- `Nitpick.Constraints` refuses selectors for JavaScript.

**Elm 0.19.3.** An Elm program has no `where` block, so it has no candidate types and every name resolves as in Elm. A rejected
Elm program gets the same NAMING ERROR and the same suggestions.

## 3. Let generalization over requirements

**What goes:**

- F4, the hold of `/`, `//`, `modBy`, `remainderBy` in a `let`. A relaxed use still creates `a has div` (`idiv`, `mod`, `rem`),
  and it is generalized like any other requirement.
- `Members.defaulting` before a top-level generalization. It becomes the ambiguity default of section 1.
- The 56bb4fd0 hold, for functions. It stays only in its determination form, plus the MR for values.

**Mechanism (`Type.Solve`, `CLet`):**

- After `discharge`, the requirements that go into the scheme are packed with the definition's type into one *carrier*
  variable, `Pair1 type (Pair1 s1 (Pair1 t1 …))`. The carrier is built in the young pool and generalized with it.
- The environment maps the name to the carrier, and a side map `qualified : Map Name [(member, region)]` says how to read it.
- At `CLocal`, one `makeCopy` of the carrier copies the type and the requirement variables together, so variables they share
  stay shared. The type is unified with the expectation, and each pair becomes a fresh requirement at the use. This is
  `Members.use` for a foreign scheme.
- A recursive group shares one carrier. Recursive uses stay monomorphic, as in Elm.
- At the top level, `Compile` writes the requirements into the interface as the `$where` scheme, the same path as for a written
  `where`. A module without requirements produces the same bytes as today.

**Clones per use.** The specializer already lifts every local function to a clone per (definition, owner clone, key). Two
things are needed:

- The marks fixpoint keys the determined variables of an inferred scheme exactly; its roots come from the dump scheme.
- Selectors and constrained calls are resolved at the clone's exact types.

No hidden parameters are needed for inferred definitions.

**L1 to L6:**

| limitation | under A5 |
|---|---|
| L2 (a let function needing a member is not generalized) | gone |
| L3 (`/`, `//`, `modBy`, `remainderBy` in a let) | gone |
| L4 (a literal takes the member type of another use) | gone: every use instantiates its own variable, and `h 9` defaults to `Int` |
| L5 (a literal at a variable with a requirement) | gone through the MR and defaulting; only a literal that neither Int nor Float can satisfy (`total [ 1, 2 ]` with `has zero`) remains, as AMBIGUOUS TYPE with a better text |
| L1 (bare member name is a NAMING ERROR) | mostly gone (section 2) |
| L6 (`<` on an annotated `a`) | wording only (section 4) |

**Programs that change behaviour** (cases of `ficcus-tests/attach`):

| case | today | A5 |
|---|---|---|
| g71-q1-nosig-bare-member | NAMING ERROR ×2 | RUN `Money 3` |
| g71-q1-nosig-call, -call-one-use, g71-q3-lifted-nosig, g71-q4-two-locals-nosig, constraint-no-signature | MISSING CONSTRAINT | RUN |
| constraint-top-nosig-type, constraint-top-nosig-hidden (D2) | MISSING CONSTRAINT / UNKNOWN MEMBER TYPE | RUN `1` |
| g71-q2-missing-all, g71-q2-missing-one | NAMING ERROR | INCOMPLETE TYPE ANNOTATION, naming `add`/`zero` |
| g71-q3-let-two-types, constraint-let-fun-mono | TYPE MISMATCH | RUN `(Money 4,Vec 2 4)` / `(1,T 2)` |
| g71-q7-div-two, -idiv-typed-int, -idiv-lifted-nosig, -idiv-lifted-sig | TYPE MISMATCH / MISSING CONSTRAINT | RUN: the Float/Int use as in Elm, the Cash use through its member |
| g71-q7-idiv-two, g71-q7-modby-two | RUN `(Cash 200,Cash 200)` / `(Cash 100,Cash 100)` | RUN `(2,Cash 200)` / `(1,Cash 100)` |
| a3-err-ambiguous-literal, a3-f7-err-literal-obligation, constraint-no-members-at-all (D3) | UNKNOWN MEMBER TYPE | RUN `6`, `2`, `3` |
| constraint-ambiguous (D2) | AMBIGUOUS CONSTRAINT | RUN `"1"` |
| a3-f8-err-let-div-two-types | TYPE MISMATCH | still rejected, as NO ATTACHED FUNCTION (`Int` has no `div`; Elm rejects `/` on Int too) |

Unchanged: `constraint-let-poly` and `constraint-order-bad-*` (still rejected, by the MR), `q7-div-cash-only` and
`a3-known-let-div` (same output), and every other RUN case.

**None of these is an Elm program.** A requirement can only come from:

1. a signature with `where`;
2. a relaxed operator, which needs a type with `div`, `idiv`, `mod` or `rem` in a `where` block (`Members.relax`);
3. a selector, which needs a candidate type, which has a `where` block.

`where` after a type or a signature is a syntax error in Elm 0.19.3. So in an Elm program the pending list is empty at every
generalization: no carrier is built, and the MR, the defaulting and the hold do nothing. The solver runs step for step as it
does today, which is Elm's solver plus the A3c rank change that the gates already accept. Every case in the table above has a
`where` block. The gates check this claim (section 5).

## 4. The voice of the errors

Rules for every text:

- Speak in the first person.
- Show the code, and show the line to write.
- Say *attached function* and *has*. Never say constraint, member, obligation, instance or bundle.
- End with something the user can do.

**INCOMPLETE TYPE ANNOTATION** (was MISSING CONSTRAINT; it also covers L1 when there is an annotation):

```
This `plus` call needs `a` to have an attached `add` function:

14|     plus m m
        ^^^^
But the type annotation of `twice` does not say that `a` has one. Add this line under it:

    twice : a -> a
        where
            a has add : a -> a -> a

Or remove the type annotation: I can work out the `where` lines myself.
```

For a bare name (q2-missing-one), the first sentence is "`zero` here is the attached function of `a`, but the type annotation
of `total` does not say that `a` has one." When exactly one candidate type is in scope, add "If you mean the one of `Money`,
write `Money.zero`."

**NAMING ERROR for an attached function name.** This is what is left of L1: the name belongs only to types the module does not
name, or the shapes do not line up. After Elm's text: "`scale` is an attached function of `Money` and of `Vec`, but with types
that do not line up, so I cannot tell which one you mean. Write `Money.scale` or `Vec.scale`."

**AMBIGUOUS TYPE** (was UNKNOWN MEMBER TYPE):

```
I cannot tell which type's `zero` to use here:

9|     empty = zero
               ^^^^
Nothing around it settles the type. Add a type annotation that names it, for example:

    empty : Money
```

For a literal that no default fits (L5): "I cannot tell what type this `1` is. It must have an attached `zero` function, and
`Int` and `Float` do not have one. Write a value of the type you mean, for example `Money 1`." The old advice, "write
`(9 : Int)`", is not Elm syntax.

**NO ATTACHED FUNCTION** (was NO MEMBER):

```
This `sum` call needs `T` to have an attached `add` function, but `T` has only `zero` and `mul`.
Add it to the `where` block of `T`:

    add : T -> T -> T
```

- For `/` on Int: "The (/) operator needs a type that has an attached `div` function, and `Int` does not have one. Use (//)
  for integers, or `toFloat` first."
- The built-in note becomes "`Int`, `Float`, `String` … have only the attached functions that the operators use".

**TYPE MISMATCH hints:**

- L2, a `let` value used at two types (MR): "`y` is a value, not a function, so it has one type, and its `get` call needs `t`
  to settle it. Write `get t` at each place, or make `y` a function."
- L6, after Elm's `comparable` hint: "Or keep `a` and say that it can be compared: add `where a has compare : a -> a -> Order`
  under the annotation."

**Titles** (the words are D7):

| old | new |
|---|---|
| MISSING CONSTRAINT (both forms) | INCOMPLETE TYPE ANNOTATION |
| UNKNOWN MEMBER TYPE | AMBIGUOUS TYPE |
| NO MEMBER | NO ATTACHED FUNCTION |
| MEMBER TYPE MISMATCH | ATTACHED FUNCTION MISMATCH |
| MEMBER WITHOUT TYPE ANNOTATION | ATTACHED FUNCTION WITHOUT TYPE ANNOTATION |
| WELL KNOWN MEMBER WITH THE WRONG TYPE / WITHOUT TYPE ANNOTATION | OPERATOR FUNCTION WITH THE WRONG TYPE / WITHOUT TYPE ANNOTATION |
| AMBIGUOUS CONSTRAINT | UNUSED VARIABLE IN WHERE |
| CONSTRAINTS ON A LOCAL DEFINITION | WHERE ON A LOCAL DEFINITION ("remove it: I work these out for `let` definitions") |
| UNFINISHED CONSTRAINTS, PROBLEM IN CONSTRAINT | UNFINISHED WHERE, PROBLEM IN WHERE |
| CONSTRAINED FUNCTIONS (JS) | NOT AVAILABLE IN JAVASCRIPT YET |

**Updating the expectations mechanically:**

1. `ficcus-tests/attach/rename_titles.py` holds this table. It rewrites the titles in column 3 of `expected.tsv` (split on
   `;`), in `g71expect.py` and in `g70gen.py`. It then lists every REJECT line whose column 4 (the text that must be contained)
   uses a retired word.
2. After the texts change, a new flag `attach.py --print-reports` prints the first paragraph of each REJECT case. Column 4 is
   replaced by hand for the listed lines only, and the change is reviewed as one `expected.tsv` diff.
3. The cases in the section 3 table change outcome in the commit of the code that changes them, not in the rename commit.

## 5. Slicing for Sonnet

| slice | content | size |
|---|---|---|
| **A5a** | Solver: carrier, `qualified`, `CLocal` instantiation, improvement (rule 1), determined closure, MR, the new defaulting (replaces `defaulting`, F4, and the function half of `hold`), D2 (relax AMBIGUOUS CONSTRAINT). `Compile` writes inferred `$where` schemes. Specializer: marks roots from inferred schemes; determined variables keyed through the member instance (B2). | about 350 lines: `Type/Members.hs`, `Type/Solve.hs`, `Compile.hs`, `Canonicalize/Constraints.hs`, `Ficcus/Mono/Spec.hs`, `Marks.hs` |
| **A5b** | Selectors: candidate set (`Canonicalize.Environment`), fallback in `findVar`, anti-unification, `attachedHome` in Spec and Nitpick | about 200 |
| **A5c** | Texts, titles, NAMING ERROR suggestions, hints (MR, L6, `/` on Int), `rename_titles.py`, `--print-reports` | about 250, plus the script |

**Order:** A5a, then A5b, then A5c. Most of the old messages disappear in A5a and A5b, so A5c rewrites only what is left.
`g71expect.py` takes the section 3 outcomes in the slice that causes them.

**New cases:**

- a let function using a selector at two types;
- a polymorphic member at two instances (rejected by rule 1; the message is checked);
- a member-name typo;
- selector shapes that do not line up;
- an inferred constrained function used from another module;
- a top-level value with a defaulted literal;
- a let value at two types (MR).

**Gates, every slice:**

- attach `--rc` with ASan/UBSan, including the 56 G71 cases: 0 differ;
- types matrix: 267 PASS, 1 XFAIL;
- typed corpus: 568 SAME / 12 BOTH_REJECT_SAME / 1 VERDICT_DIFF;
- JS identity: 28/0;
- elmdiff: 1,175 SAME;
- suite: the C text of the 16 programs byte identical to `elmficA4b`, `--rc` and `--no-rc`, 32/32. This is the section 3
  proof in practice.

Heavy steps run one at a time (GHC `-j1`, `+RTS -M6g`, 8 GB free).

**Opus review after A5a**, read only, before A5b builds on it. It should check:

- that the carrier copy keeps sharing;
- that the hold is exactly the closure from outer variables (B3, B4, `constraint-let-poly`);
- the order of the MR, the defaulting and the A3c rank rule;
- that one subject type gives the same member in every module;
- that no requirement is quantified while its subject is held.

A5b and A5c are covered by the section 3 table and the gates, so they need no Opus review.

## 6. Open decisions (recommendation first)

- **D1. Infer requirements for top-level functions without a signature.** Yes. This removes MISSING CONSTRAINT for
  unannotated functions, and inferred schemes reach interfaces like written ones. Against: an exported type can change
  silently, as in Elm for unannotated exports.
- **D2. Determined variables.** Yes: a variable of a `where` line that its subject determines is allowed (B2, `get (get w)`).
  AMBIGUOUS CONSTRAINT stays for undetermined subjects.
- **D3. Defaulting.** Yes: an undetermined `number` subject becomes Int, or Float when `div` is needed, if that type meets every
  requirement. This reverses A3c's literal rule.
- **D4. What counts as a function for the MR.** Arguments, or a lambda body.
- **D5. Candidate types.** Types with a `where` block that the module defines or imports in any form. Well-known names count
  only when such a type defines them, so Elm programs never see a selector.
- **D6. JavaScript.** Recommended: refuse an inferred constrained function as a written one is refused, and suggest an
  annotation ("give `half` a type such as `half : Float -> Float`"). Today a module with a `div` type in sight defaults
  `half x = x / 2` to Float and emits JS. The alternative, defaulting relaxed operators at the top level and generalizing only
  in `let`, is less consistent and keeps L3 for top-level code.
- **D7. Title words** (section 4). As listed, but the user's wording matters most here.
- **D8. `where` on `let` definitions.** Keep it forbidden, with the new text: inference makes it unnecessary.
- **D9. One type per name per variable** (rule 1). Yes. It matches how `where` lines behave in a body, and it keeps types
  principal without higher-rank requirements.

## Worked examples

**1. An unannotated top-level function infers `a has add`.** `Money` and `Vec` both have `zero` and `add`.

```elm
total xs = List.foldl add zero xs
out = total [ Money 1, Money 2 ]
```

- `add` and `zero` are unbound, so both are selectors:
  - `add : a1 -> a1 -> a1 where a1 has add …` (the well-known shape);
  - `zero : a2 where a2 has zero : a2` (Money and Vec anti-unified).
- `List.foldl : (x -> acc -> acc) -> acc -> List x -> acc` gives `x = acc = a1` and `a2 = a1`.
- Both requirements have the young subject `a1`, which occurs in the type, so `total` generalizes to
  `total : List a -> a where a has add : a -> a -> a, a has zero : a`. This goes into the interface as `$where`.
- `out` instantiates `a := Money`, and the discharge finds `Money.add` and `Money.zero`.
- The specializer makes `total@Money`, where the selectors call the clones of `Money$$add` and `Money$$zero`.
- Output: `Money 3`. Today: NAMING ERROR ×2.
- `twice m = plus m m` (q1-nosig-call) infers its requirement the same way, through `plus`'s scheme.

**2. A let function used at two types** (g71-q3-let-two-types).

```elm
both : Money -> Vec -> ( Money, Vec )
both m v = let g x = plus x x in ( g m, g v )
```

- `plus` gives `b has add : b -> b -> b`, with `x : b` and `b` young.
- No outer variable reaches `b`, so the requirement goes into `g`'s carrier: `g : b -> b where b has add`.
- `g m` copies the carrier: `b1 := Money`, discharged by `Money.add`. `g v` gives `b2 := Vec`.
- The specializer lifts `g@Money` and `g@Vec`.
- Output: `(Money 4,Vec 2 4)`. Today: TYPE MISMATCH at `g v`.

**3. `h y = y // 4` from L4**, with `Cash` (which has `idiv`) in sight.

```elm
out = let h y = y // 4 in ( h 9, h (Cash 800) )
```

- `//` is relaxed: `c -> c -> c`, with `c has idiv`. The literal `4` makes `c` a `number` variable.
- `h : number -> number where number has idiv` is generalized. F4 used to hold it here.
- `h 9` gives a fresh `n1` (a `number` with `has idiv`).
- `h (Cash 800)` gives `n2 := Cash`, discharged by `Cash.idiv`. In that clone, `4` is `Cash.fromInt 4`.
- `out` is a value (MR), so its pending requirement on `n1` is defaulted: `Int` has `idiv`, so `n1 := Int`.
- Output: `(2,Cash 200)`. Today: `(Cash 200,Cash 200)`.
- `h 9` now means what it means in Elm, whatever the neighbouring uses are. Without `Cash` in sight nothing is relaxed and the
  program is plain Elm.
