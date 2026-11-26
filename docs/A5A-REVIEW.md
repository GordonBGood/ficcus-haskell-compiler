# A5a review: soundness of inferred requirements, let generalization, defaulting and the monomorphism restriction

Read-only review of `feat/a5a` a03a8f3b (binary `bin/elmficA5a`), branch `review/a5a`, 2026-11-26. Sources:
`docs/A5-INFERENCE-DESIGN.md`, `docs/attach/A5A-NOTES.md`, `docs/attach/G71-INFERENCE.md`, and the code: `Type/Requirements.hs`,
`Type/Solve.hs` (`CLet`, `CLocal`, `discharge`), `Type/Members.hs`, `Ficcus/Mono/Determined.hs`, `Ficcus/Mono/Spec.hs`
(`deadByMembers`, `determinedByMembers`), `Canonicalize/Constraints.hs` (`checkVars`, D2), `AST/Constraints.hs`, `Compile.hs`,
`Nitpick/Constraints.hs`, `builder/Generate.hs` (D6).

The counterexamples are in `ficcus-tests/a5ar/` (54 cases, all written by `gen.py`; runner `run.py`; expected results in the
README). Each was compiled to C with `--no-rc` and with `--rc` under ASan+UBSan (0 live required), and compared with an Elm twin
(`bin/elm0193` + node) where one exists, otherwise with a hand-checked `expected.out`. No full gates were run (the A5a notes
record them green). Every case that compiles and runs is clean under `--rc` and the sanitizers.

## Recommendation

**Do not merge as is. Merge after M1 and M2**, which are small and local. B1 to B4 can go into A5b and A5c. The rest of the
design holds up under the probes:

- the carrier copy keeps sharing;
- holding by determination is exact in every case I could build;
- the defaulting and deviation 2 give Elm's results;
- Elm programs are unchanged;
- the step 3 and step 4 specialization gives one correct copy per type.

## Findings

### Must fix before merge

**M1. A built-in member that decides a variable gives a wrong program: silent wrong output, or invalid C.**

Reproducer: `builtin-decides-append`, compared with an Elm twin.

```elm
appz : a -> a -> z
    where
        a has append : a -> a -> z
appz x y = append x y

app2 x y = Debug.toString (appz x y)          -- inferred: a has append : a -> a -> z
lenOf x y = String.length (app2 x y)
out = ( app2 "a" "b", app2 [ 1 ] [ 2 ], lenOf "ab" "cd" )
```

- A5a prints `("{}","{}",2)` in both modes, clean under ASan.
- Elm prints `("\"ab\"","[1,2]",6)`.
- `builtin-decides-inferred` is the same shape with `compare : a -> a -> z` at Int and String. There the generated C returns
  an `int` from a function typed `fic_ref`. gcc rejects it (`-Wint-conversion`); TinyC only warns, so the program would run
  wrong.

Cause:

- In the clone of `app2`, `z` is a dead variable that only the member of `a` decides.
- `Spec.deadByMembers` calls `determinedByMembers` (`Spec.hs:1697`). That function looks up `tid ++ "$$" ++ member` in
  `sTops` (`Spec.hs:1725`), and only a custom type has such an entry.
- For Int, String or List the lookup fails, and `z` stays a `ref`. The clone `appz@(String, ref)` is generated, and
  `Debug.toString` at `ref` prints `{}`.
- The notes list this as an open point. It is a wrong program, not a refusal.

Two more facts:

- The written D2 path works (`builtin-decides-written`, `builtin-decides-compare`): only the inferred caller goes wrong.
- The trigger needs a `where` line that gives a well-known name a type other than its well-known shape. The canonicalizer
  accepts this in a signature; only the `where` block of a type checks shapes. With the right shapes, a built-in member
  never decides another variable: every built-in shape mentions only the subject and fixed types.

Fix, smallest first:

1. Check the well-known shapes in signature `where` lines, as in type `where` blocks. This makes the case impossible.
2. Make `deadByMembers` and `determinedByMembers` refuse, with a FICCUS error, a dead variable they cannot decide, rather
   than leave it at `ref`. This is a guard for anything else that reaches here.

**M2. A recursive group drops a requirement that is ambiguous for one of its names (deviation 3).**

Reproducer: `share-recursive-ambiguous`. `share-recursive-top` is the same with `Debug.todo`.

```elm
fa x n = if n <= 0 then ( plus x x, gb n ) else fa x (n - 1)
gb n = if n <= 0 then 0 else Tuple.second ( fa (sum []) 0, gb (n - 1) )
out = ( fa (Vec 1 2) 2, gb 2 )
```

- The type checker accepts the program. The specializer then fails with "cannot specialize the constraint `a has zero` of
  Main.sum: the type ref has no member `zero`" (`share-recursive-top`: "+ at ref").
- Without the recursion (`share-nonrec-ambiguous`), A5a correctly reports UNKNOWN MEMBER TYPE at `sum`.

Cause:

- Recursive uses are monomorphic, so `gb`'s call of `fa` uses `fa`'s own `a`. `gb`'s body therefore needs `a has add, zero`
  at a variable that `gb`'s type does not determine: the requirement is ambiguous for `gb`.
- `settle` classifies by the closure from *all* header types (`byType`), so the requirement goes into the scheme and leaves
  the pending list.
- `carrier` (`Requirements.hs:380`) then gives each name only the requirements its own type determines. `fa`'s carrier has
  them, `gb`'s has none, and nothing reports the ambiguity.
- In qualified types, a group shares one context, and a requirement not determined by some name's type is ambiguous for that
  name.

Fix: for a recursive group, compute "by type" as the intersection of the per-name closures. A requirement outside the
intersection is undetermined: held in a `let`, defaulted or reported at the top level. With that rule, one carrier for the
whole group (as the note had it) is also correct.

Severity: the result is an internal error, not wrong code. I still rank it "must fix", because the solver accepts an
ill-typed program and the fix is a few lines in `settle`.

### Fix in A5b or A5c

**B1. Rule 1 (D9) runs at every discharge, so acceptance depends on the names of `let` definitions. This is a regression
from A3b.**

Reproducers: `order-rule1-*`. `choose : a -> c -> c where a has pick : a -> c -> c`, where `Q.pick : Q -> c -> c` is
polymorphic.

| case | body of `both q` | A3b | A5a |
|---|---|---|---|
| order-rule1-nolet | `( ( choose q 1, choose q "s" ), q == Q 1 )` | RUN | RUN `((1,"s"),True)` |
| order-rule1-let | `let p = ( choose q 1, choose q "s" ) in ( p, q == Q 1 )` | RUN | MEMBER TYPE MISMATCH |
| order-rule1-let-after | `let k = q == Q 1` then `p = …` | RUN | MEMBER TYPE MISMATCH |
| order-rule1-let-swapped | `p` written before `k` | | MEMBER TYPE MISMATCH |
| order-rule1-let-renamed | as -let-after, with `k` renamed `zk` | | RUN `((1,"s"),True)` |

Cause and consequences:

- `Requirements.improve` is called from `Solve.discharge` (`Solve.hs:461`), at every `let` boundary. It unifies the two
  `pick` types while `q` is still a variable.
- Whether `q` is already `Q` there depends on the order Elm gives to independent `let` definitions, and that order follows
  their names.
- No wrong program is accepted: an accepted program is correct.
- But valid programs that A3b ran are now rejected, depending on a name. The text also says "of this type annotation" where
  there is none (known, A5c).

Fix: improve only the obligations that `settle` puts into a scheme, plus the top-level Settle class, at the generalization.
Leave held and pending obligations to their discharge. The scheme stays principal, because it is improved when it is formed.

**B2. Fixed fuel in the specializer: an inferred chain of 10 member calls fails.**

Reproducers: `spec-deep-inferred-N`. `deep w = get (get (… w))` with N+1 calls, through types `T0 … TN`.

- N = 7 and 8 run. N = 9 and 12 fail with "cannot specialize the constraint `a has f` of Main.get: the type ref has no member
  `f`".
- The written versions run at every depth tried, up to 13 levels (`spec-deep-written-*`).

Cause:

- `deadByMembers` and `determinedByMembers` stop after `loop (8 :: Int)` (`Spec.hs:1657`, `1699`).
- `deadByMembers` decides one more nesting level per round. Its last round is also discarded when the fuel runs out.

Fix: loop until nothing changes. Each round adds at least one binding, so the number of variables bounds it.

**B3. D6 text.** The refusal always proposes "such as `half : Float -> Float`", for example:

- `h y = y // 4`, which should be `Int -> Int`;
- `f c = let k = 8 // 2 in ( k, c )`, whose inferred type is `c -> ( number, c )`.

Use the defaulted type when there is one, and a neutral sentence otherwise (A5c).

**B4. A latent gap in demotion.**

- In `settle`, `schemeFlags` (`Requirements.hs:214`) is computed once, before the demoted obligations are raised.
- So a scheme obligation whose subject is reached *only* through a demoted obligation's member type stays in `scheme`.
- `carrier` takes the closure over `scheme` only (`Requirements.hs:384`), so such an obligation lands in no carrier and is
  lost.
- I could not reach this without an earlier error. It needs a held, undetermined subject whose member type mentions the
  function's type variable and that then defaults, and built-in shapes cannot do that (once M1 fix 1 is in, nothing can).
- Fix: run the demotion to a fixpoint, and add an internal check that every scheme obligation lands in some carrier.

### Notes (no change needed, or by design)

**1. Sharing.** Every probe runs or is rejected as it should:

- The carrier copy keeps outer variables shared: `share-outer-reject` (`f "s"` where the scheme's `addTo : a -> n -> a`
  shares `n` with the outer `f`) is a TYPE MISMATCH String/Int, and `share-outer-ok` runs.
- Nested lets (`share-nested`) run, and so does an inner function generalized inside one use of the outer one and used at
  three types (`share-nested-two`).
- Mutually recursive let functions run (`share-recursive-let`).
- An inferred function from another module runs when used in a let at two types (`cross-module-let`; A3b rejects it with
  MISSING CONSTRAINT).
- A recursive group with a value in it cannot arise: Elm rejects cyclic values, so a group is always functions, and the MR
  for groups only matters for lambda-bodied definitions.

**2. Holding.**

- These run or are rejected as expected: `hold-structure` and `-reject` (`sum ms` decides `x`), `hold-b4-let-fun`
  (`( get x, get w )` at two types), `hold-member-body-let` (a let function inside a member's body), `hold-case-lambda`.
- A young subject inside an older structure gets the older rank from `adjustRanks`: Elm's `adjustRankContent` gives a
  `FlexVar` the group rank of its older parent.
- I found no requirement generalized too early (B4 is the only path to an unchecked one).
- I found no hold that rejects a program Haskell-style qualified types would accept, apart from B1 and the MR.
- The MR rejects an eta-reduced `let g = plus` used at two types (`hold-eta-value`, D4 as approved). The error points at
  the caller's argument, not at `g` (the MR hint of A5c).

**3. Order.**

- Apart from B1, nothing depended on order.
- The top-level defaulting groups subjects in list order. Order could only matter when one defaulted subject decides
  another, which built-in shapes rule out once M1 fix 1 is in.
- A typed member of a top-level recursive group with an undetermined `//` defaults like a non-recursive one
  (`hold-rec-typed-literal`, `hold-nonrec-typed-literal`).

**4. Subjects in records, record updates, lambdas, case branches, and settled after a later let definition.** All run
(`subj-record`, `subj-lambda-case`, `subj-later-settled`, `subj-let-literal`). `subj-undetermined-let` is rightly rejected:
`sum []` is in `g`'s type, so it is in the scheme and is ambiguous only at `out`. Its message is the old "I never infer
constraints" text (A5c).

**5. Built-in and sized subjects.**

- Sized types are custom types in the overlay (`Float32` has `div`, `fromFloat`, …), so D2 and step 3 handle them like any
  custom type. `spec-div-structures` runs `/` at Float, Cash and Float32 through `List.map`, a let, a record update and
  `Maybe.map`.
- Built-in subjects: M1.
- `builtin-decides-float32` fails ("the type of `a` is not known here") on A3b and A5a alike: a pre-existing bug, not from
  A5a.

**6. Elm programs.**

- Code: an obligation is created only by `Members.use` (a `$where` scheme), a relaxed operator (a type in the table with
  `div`, `idiv`, `mod` or `rem`), or a Float literal (a type in the table with `fromFloat`). An Elm program has none.
  - So `pending00` is always empty for it.
  - `settle`, the carriers and the second rank walk (`adjustRanks`) are unreachable; only `CLocal`'s extra `UF.get` runs.
  - `Type.Solve.run` (empty `Kinds`, which would make every definition a value) has no caller.
- Test: the 13 programs of `targets/elm` give byte-identical JavaScript and C on elmficA3b and elmficA5a.
- `elm-let-numbers` (let values at Int and Float, `/`, `//`, `modBy` in let functions) equals elm0193 in JavaScript and C.
- `dev2-elm-semantics` is an Elm program plus an unused `Cash`, so every relaxed operator is inferred, held and defaulted.
  Its C output equals elm0193's.

**7. Specializer.**

- These run with the right values at every type: `spec-div-chain` (an inferred function calling an inferred function at
  Float, Cash and Ratio), `spec-modby-two`, `spec-lambda-top` (`half = \x -> x / 2`), `spec-outer-relaxed` (`/` on an
  outer variable inside a let function generalized over another).
- No two types shared a copy. Apart from M1 and B2, no variable kept a wrong type.

**8. D6.**

- Refusal is consistent with written constraints: `Generate.checkForConstraints` scans every node of every loaded module.
  So a module that imports an inferred function and never calls it is refused (`d6-import-only`), as for a written one.
  So is an unused local one (`d6-unused-local`).
- In a mutual group, the marker is added even though the group's names are `Link` nodes (`d6-mutual` lists both names).
- An inferred let function inside an annotated function, used only at Float and Int, has no marker. It compiles to
  JavaScript with Elm's result (`d6-let-js`), which is correct.

**9. Deviation 2 is benign.**

- An undetermined subject of a let function is reachable only through its own obligations, because the functional
  dependency goes from subject to member type. So nothing outside the let can unify it.
- Holding it to the top level and defaulting there gives the same type as defaulting at the let; only the error location
  differs.
- The MR for let *values* is the note's own rule and takes the context's type, not a default. `dev2-let-literal-later`:
  `let k = 8 // 2 in k + c` at `Cash 300` gives `Cash 700`. `dev2-let-float-later` gives `(Cash 750,5)`.
- No case turned an error into a silent default.

**10. A consequence of D1 and D3 to record.** In a module that sees a type with `idiv`, the Elm-looking
`f c = let k = 8 // 2 in ( k, c )` gets the inferred type `c -> ( number, c ) where number has idiv`, not Elm's
`c -> ( Int, c )`. A use defaults it to Int, so the result is Elm's, but D6 refuses the module in JavaScript. Programs
without such a type are unaffected.

**11. Performance.** No change seen: a top-level list of 2000 Float-literal pairs with Float32 in sight compiles in 1.37 s on
A5a and 1.39 s on A3b. `improve` is quadratic in the number of pending obligations on distinct flexible subjects; I did not
find an input where that shows.

## Proposed entries for the shared docs (for the user to apply)

`docs/Ficcus-Design-Decisions.md`, a NOTE:

> 2026-11-26 A5a review (review/a5a, docs/A5A-REVIEW.md): merge after M1 (built-in member deciding a variable: check
> well-known shapes in signature `where` lines; guard in Spec) and M2 (recursive group: "determined by type" is the
> intersection over the group's names). A5b: B1 (rule 1 only at generalization), B2 (specializer fixpoint without fuel),
> B4 (demotion fixpoint). A5c: B3 (D6 text).

`docs/PHASE1-CHECKLIST.md`: tick "Opus review of A5a" with the same pointer.
