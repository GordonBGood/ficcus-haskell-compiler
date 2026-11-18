# H16 design: known function specialization with inlining (stage 1), outline of stage 2

Written for: the user and the Sonnet sessions that will implement it. Branch `design/h16-survey`. Read `docs/H16-SURVEY.md` first; line
numbers below are those of the survey (branch `ficcus` at 2e5f3b16). `M.` = `compiler/src/Ficcus/Mono/`. Benchmark facts are from
`docs/H16A.md` on branch `bench/h16a` (A2 = `targets/p1/src/JsonCombV.elm`, 50 MB parse 7,895 ms, 832 M allocations, 170 M closures; hand S1
1,951 ms, 158 M allocations, 1.9 M closures). Target: A2 at 50 MB <= 2.6 s with the pass on, without `oneOf` unrolling.

## 1. Where the pass lives, and the rules that bound it

### 1.1 Decision: a separate pass `M.Known`, run before `Inline`, only with `--rc`

```
Make.hs:208   if rcMode then Rc.rcProgram (Twin.twinProgram (Inline.inlineProgram (Known.knownProgram program))) ...
```

Options considered:

| option | for | against |
|---|---|---|
| (a) extend `Inline` so that `hasLam` functions are inlinable once their lambda arguments are known | `instantiate`/`freshen` exist; one pass | Inline copies one body with `freshen`; a combinator's work is in its **lifted children**, separate `MDef`s that use the owner's names *by name* (survey 5). Freshening the owner without copying the children breaks the captures; that is exactly why `table` rejects `hasLam` and references to lifted clones (Inline.hs:97-99). Inline's eligibility, size rule and rules A/B/T are built for constructor producers/consumers; mixing in clone creation, memo tables and recursion makes the one pass hard to switch off or measure per part. |
| (b) a specialization key on closure identity inside `Spec` | Spec already clones per `Key` and has `keyLimit` | Spec works on Canonical with types; lambdas are lifted *during* Spec, so a known closure is only known after its lifting; captured variables are not computed yet; and Spec also feeds the `--no-rc` oracle, so any change risks the norc identity. Rejected. |
| (c) **a separate Mono -> Mono pass before Inline** | sees the whole `MProgram` with lifted clones as `MDef`s and `MGlobal` heads, no counts, `mdOwn = []` (survey 5, hook 1); Inline's rules A/B/T then run on the expanded bodies (that is where stage 2 hooks in); own switch and own counters; nothing in the no-RC path | needs its own body-copying kit that copies an owner **together with its lifted family** (Inline's `freshen` cannot: it does not remap `MGlobal` ids of lifted children). About 60 lines. |

Chosen: **(c)**. Inline changes only in one eligibility detail (1.5); Spec, Free, Twin, Borrow, Rc, CGen are unchanged. CGen already makes a
direct call whenever the head is `MGlobal c` of a Function clone with matching arity (CGen.hs:557) and prepends the captured variables of a lifted
callee by name (`caps ++ vals`); so the pass only has to put `MGlobal` heads where today there are `MLocal` heads, and keep the names right.

Switches (the project's pattern, survey 6): `FICCUS_NO_KNOWN=1` turns the pass off (the program is returned unchanged, so the RC text equals
today's byte for byte); `FICCUS_KNOWN_STATS=1` prints counters (expansions, specializations, calls made direct, aliases, floated constants,
refusals by reason, nodes added); `FICCUS_KNOWN_CHECK=1` runs the scope checker of 1.2 and fails the compile on a violation;
`FICCUS_KNOWN_BUDGET=<n>` overrides the program budget (experiments). The pass is called only inside the `rcMode` branch, so `--no-rc` output
cannot change (checked by `norc_identity.py`, no `--update`).

### 1.2 Captured variables: keep "capture by name", copy families, never compute captures by hand

`Free.captures` (Free.hs:32) is a pure function of the clone list: for every clone with `mdLifted /= Nothing` it returns the free names of its body
(plus, by fixpoint, those of the lifted clones it refers to). `mdLifted` is read only by Free (`/= Nothing`), Inline's table and Twin (eligibility);
nothing checks that a lifted clone is referenced only from its owner. So the rule for the pass is:

* **Invariant S (scope)**: wherever a lifted clone `l` is referenced (call head or value), every name in `captures l` is bound at that point to the
  value the closure must see. CGen and Rc then do the right thing (they pass/store the captured names found in scope).
* The pass never builds capture lists into the IR. When it needs to know whether a closure captures anything (aliases, constant closures, value
  position cost), it calls `Free.captures` on the current clone list once per round (1.4) and keeps the map for the round.
* **Copying an owner copies its family.** The primitive `copyFamily :: Subst -> CloneId -> K (MExpr, [MDef])` copies a body *and* every lifted
  clone reachable from it whose `mdLifted` chain leads back to the copied clone, with one consistent renaming: every binder gets a fresh name
  (`stem ++ "@k" ++ n`, distinct from Inline's `@@n`), every free name is mapped by the substitution, and every `MGlobal` of a copied lifted clone is
  remapped to its copy. Copies get `mdLifted = Just <clone in whose body they are referenced>` (the caller for an expansion, the new clone for a
  specialization), the origin's `mdName`, `mdKey`, `mdParams` classes, `mdKind`, `mdResult`, and `mdOwn = []`, `mdTwin = Nothing`,
  `mdCapsOwned = False`, `mdInit = Nothing`, `mdNeeds = []`, a fresh `CloneId` (`1 + maximum`, as Twin).
* A substitution maps a name to an **atom** (`MLocal`, `MLit`, `MGlobal` of a Value) or to a **known function** (below). Because every name that
  a copy captures is either substituted away or renamed to a name bound in the new scope, invariant S holds by construction; the checker of
  `FICCUS_KNOWN_CHECK` verifies it (for every reference to a lifted clone: `captures l` is a subset of the names bound there).

A **known function value** is `Known { kCode :: CloneId, kCaps :: [MExpr] }`: the code (a top level Function clone with arity >= 1, or a lifted
clone) and, positionally for `captures kCode`, the atoms that hold the captured values in the current scope. Materialising it at a use:
if `kCaps` are exactly `MLocal` of the capture names of `kCode`, the use is `MGlobal kCode`; otherwise a *renamed copy* of `kCode` (captures
renamed to the `kCaps` names, memoised on `(kCode, names)`) is made and referenced. A capture-free known is just `MGlobal kCode` anywhere: a
direct call in head position, the static immortal closure `fic_clo` in value position (CGen.hs:767).

Where knowns come from (the environment of a body): a parameter of a specialized clone (1.3), `MLetVal x (MGlobal l)`, a `MGlobal` of a
top level Function used as a value (`isDigit` passed to `chompWhile`), a value alias (1.3), a call of a constant-closure function (1.3), and the
result of an expansion (2.x).

### 1.3 Value clones of function type

`item = \s -> ...` is a `Value` clone whose body is `MGlobal itemLam` (survey (E)); `pair = map2 f item item` is a Value whose body is a call.
Rule **V (alias)**: after its body has been rewritten, a Value clone whose body is `MGlobal l` with `captures l = []` is an **alias** of the known
`Known l []`. Every `MGlobal v` elsewhere is then treated as that known: a call `v s` becomes a direct call of `l`, a use as value becomes the static
closure of `l` (no global load, no `fic_dup` of `g_v`). `pair` becomes an alias as soon as the expansion of `map2` has made its body a capture-free
closure (section 2). Values are processed in `mpClones` order (init order), so the aliases of earlier values are known when later ones are rewritten.

Rule **C (constant-closure function)**: a Function clone whose rewritten body is `MGlobal l` with `captures l = []` (JsonComb's `jarray _`, `member _`,
the thunk `\_ -> oneOf [...]` once its list is floated) returns the same closure for every argument and has no effect: a call of it with atomic
arguments is replaced by `Known l []`. This removes the per-use rebuilding of whole parser trees that the `()` workaround of JsonComb causes.

Rule **F (closed data floating)**: an argument of a closure-builder call (2.1) that is a list, tuple, record or constructor literal whose leaves
are literals, capture-free knowns or global Values is moved to a new top level Value clone (placed at the front of `mpClones`: its leaves need no
initialised value except Values already before every user, see 1.4) and replaced by `MGlobal` of it, which is an atom. This is what lets
`oneOf [ jarray (), jobject (), jstring, ... ]` expand into a capture-free closure (its list becomes one global built once) instead of building
seven list cells and a closure at every `value` parse. No `oneOf` unrolling: the list stays a list and `oneOfHelp` still applies its elements
through `fic_ap1`; those are the closures that remain at the recursion.

Values are never deleted when they have an effect; an alias Value whose uses are all replaced, and Functions no longer referenced, are removed
by a final reachability sweep from `mpMain` (code size).

### 1.4 What makes a call known, termination, size

**Known call**: `MCall h args` where `h` is (after the environment) `MGlobal c` of a Function clone with `length args == length (mdParams c)`,
and at least one argument is a known function whose parameter in `c` is *used as a function* in `c`'s family (a call head, or an argument in a
position of another call that is itself known-relevant; computed once per original clone as a parameter mask `fnUse :: Map CloneId [Bool]`).
Two treatments:

* **Expansion** (closure builders): `c`'s body, after its lets, is `MGlobal l` with `l` lifted from `c` (every `combinator args = \s -> ...`).
  Expanded at the call site (copy of `c`'s family, section 2) when at least one argument is a known function, or when every argument is
  static (literal, global Value, floated constant, capture-free known: `succeed 7`, `symbol 44`, `word nullWord`). Never for a recursive builder.
* **Specialization** (all other functions, including recursive ones such as `sepByHelp`, `loopHelp`, `chompWhileHelp`): a new clone for the key
  `(c, [Fun code | Dyn])`, where `code` is the *origin* code of each known function argument (copies map back to their origin). The new clone
  has the `Dyn` parameters in their order, followed by one parameter per captured value of each known (fresh names); the call passes the
  `kCaps` atoms for them. Literal and Value arguments are not part of the key (no specialization per constant of a recursive function).

**Termination.**
1. Memo with knot tying: the `CloneId` of a specialization (and of a fully static expansion) is entered in the memo *before* its body is copied
   and rewritten, so a recursive call with the same key inside it becomes a direct self call (then CGen's tail call `continue` applies).
2. Keys are built from origin codes, of which there are finitely many per program before the pass; copies do not create new key material
   (a copy's origin is its original). Specialization keys are therefore finite.
3. Expansion is never applied to a builder in its own strongly connected component of the reference graph (computed on the original
   program), nor to a builder already on the current expansion stack. Inside an SCC the call stays a call (and may be specialized by key).
4. Clones are rewritten bottom-up over the SCCs (callees first). The facts V and C only grow; a body is rewritten again only if a clone it
   references gained a fact, at most **3 rounds** per program (the thunk of `value` needs round 2: it is in the same SCC as `jarray`).
5. Budgets (below) make every rule refusable: a refused rule leaves the call as it was, which is always correct.

**Size budget** (node counts by `Inline.size`):
* expansion: copied family size <= **200** nodes (`map2`'s lambda is about 40); specialization: callee family size <= **300**;
* per origin clone: at most **32** expansions + specializations (a parser library uses `map2` maybe 30 times in a grammar; JsonCombV's 60 uses
  of all combinators are spread over a dozen origins);
* per program: nodes added <= max(**20,000**, **1.0 x** the program's size before the pass); after that only cache hits are allowed.
  These are first values to be fixed by measurement (questions, section 7).

**Never specialized or expanded**: `main`; kernels (`MKernel` heads, and `MKernel` as a function value); clones without a body; a call whose
arity does not match (partial or over application are handled in 2.x by splitting, never by guessing); a function whose known parameter is not
used as a function (no gain); a Value in an init cycle of `Spec.ordered` (FIX2 groups) as an *alias source* unless its body is already a
capture-free `MGlobal` (it then needs no initialisation order); `Vector.update` (rule U keeps it; same `mdName` is kept on copies, so rule U still
recognises it); bodies containing `Debug.*` kernels are expanded only with all non-atomic arguments `let`-bound first in order (Inline's `atom`
convention), so the order of effects cannot change.

## 2. The algorithm

### 2.1 Worked example (Mini.elm of the survey, section 4, plus `sepBy`)

```elm
map2 f pa pb = \s -> case pa s of                      -- c9, its lambda c13 captures f pa pb
                       Good c1 a s1 -> case pb s1 of
                                         Good c2 b s2 -> Good (c1 || c2) (f a b) s2
                                         Bad c2 m -> Bad (c1 || c2) m
                       Bad c m -> Bad c m
succeed a = \s -> Good False a s                       -- c6, lambda captures a
oneOf ps  = \s -> oneOfHelp s ps                       -- c4, lambda captures ps
item      = \s -> Good True s.off { off = s.off + 1 }  -- Value c11, body MGlobal itemLam
pair      = map2 (\a b -> a + b) item item             -- Value c5
top       = oneOf [ pair, succeed 7 ]                  -- Value c2
sepBy p sep = \s -> sepByHelp p sep False [] s         -- builder; sepByHelp recursive, calls `p s` and `sep s`
list      = sepBy item (succeed ())
```

Steps, in the order the pass does them:

1. **Prepare.** Build `byId`, the reference graph and its SCCs (on the original clones), `fnUse` per parameter (c9: f, pa, pb all used as call
   heads in c13; c4: ps not used as a function; sepByHelp: p, sep used as heads), `builder c` (body after lets is `MGlobal l` with `mdLifted l ==
   Just c`: c9, c6, c4, sepBy), `caps = Free.captures clones`, `origin = id`.
2. **Bottom-up order**: SCCs callees first, inside an SCC by `mpClones` order. Here: itemLam, c10 (`\a b -> a+b`), c13, c9, c11 `item`, c5 `pair`,
   c6, c4, c2 `top`, sepByHelp, sepBy, `list`.
3. **`item`**: body `MGlobal itemLam`, `caps itemLam = []` -> rule V: `alias[c11] = Known itemLam []`.
4. **`pair`**: `MCall (MGlobal c9) [MGlobal c10, MGlobal c11, MGlobal c11]`. Environment: `c10` is a lifted Function used as a value -> `Known c10 []`;
   `c11` -> alias `Known itemLam []`. c9 is a builder, args are known functions, family size of c9 ~45 <= 200: **expand**.
   `copyFamily {f -> Known c10 [], pa -> Known itemLam [], pb -> Known itemLam []} c9` gives body `MGlobal c13'` and clone `c13'` (owner c5) in
   which `MCall (MLocal pa) [s]` became `MCall (MGlobal itemLam) [s]` (direct), `f a b` became `MCall (MGlobal c10) [a, b]` (direct). Memo
   `(c9, [Fun c10, Fun itemLam, Fun itemLam]) -> c13'` (fully static expansion). `pair`'s body is `MGlobal c13'`, `caps c13' = []` -> rule V:
   `alias[c5] = Known c13' []`. In C: `pair` needs no initialisation code beyond a static closure, `c13'` takes `fic_s_i` by value (no box (B)),
   `pa s` is `f_itemLam(s)` (no `fic_ap1` (C)).
5. **`top`**: `oneOf [pair, succeed 7]`. First the argument: `succeed 7` is a builder call with all arguments static -> expand: `c6'` with `a -> 7`,
   capture-free, memo `(c6, [Lit 7])`; the list `[Known c13' [], Known c6' []]` is closed data -> rule F: new Value `k1 = [<static clo c13'>, <static clo c6'>]`
   at the front of `mpClones`. Then `oneOf (MGlobal k1)`: builder with all arguments static -> expand: `c4'` = `\s -> oneOfHelp s k1`, capture-free;
   `alias[c2] = Known c4' []`. `oneOfHelp` keeps its `fic_ap1` on the list elements (no unrolling).
6. **`list`**: `sepBy item (succeed ())`: `succeed ()` -> `c6''` (memo `(c6, [Lit ()])`); expand sepBy with `p -> Known itemLam []`, `sep -> Known c6'' []`:
   its lambda copy contains `sepByHelp p sep False [] s` = a call of a non-builder with known function arguments -> **specialize**: key
   `(sepByHelp, [Fun itemLam, Fun c6'', Dyn, Dyn, Dyn])`; allocate `sbh'`, enter it in the memo, copy sepByHelp's family with
   `p -> Known itemLam [], sep -> Known c6'' []`, params `[p', acc, s]`; inside, the recursive call `sepByHelp p sep (..) (..) s1` has the same key ->
   `MCall (MGlobal sbh') [..]`: a direct self (tail) call. If `p` had captures, `sbh'` would get one extra parameter per captured value and every
   call would pass them (1.4).
7. **Round 2** for clones that refer to one that gained a fact in round 1 (here none; in JsonCombV the thunk of `value`, whose `jarray ()` becomes
   a constant closure (rule C) after `jarray` is rewritten in the same SCC).
8. **Sweep**: remove Functions and alias Values not reachable from `mpMain` (c13, c9's original lambda, c11, c5, ...), then **check**: with
   `FICCUS_KNOWN_CHECK=1` verify invariant S and that every Value refers eagerly only to Values before it in `mpClones`.

Partial and over application. A known function `k` whose code has arity `n` called with `m` arguments: `m == n` direct; `m > n`
(`loopHelp`'s `f st s` with `f = \st -> ...`) is split to `MCall (MCall (MGlobal k) first-n) rest`, and the inner call is treated again (it may be
a constant closure, or an expandable builder); `m < n` is left alone (Spec already made partial applications lifted lambdas, which are knowns
with captures once bound by `let`).

Value position of a known with captures: materialising it re-creates the closure where it is used. That is one allocation per use instead
of one per creation; it is allowed only when the use is the argument of a known call that is itself expanded or specialized (so the closure
disappears) or in tail position; otherwise the original variable is kept for value uses (the known is still used for calls). This keeps the
pass from ever adding allocations.

### 2.2 Data structures (all in `M.Known`)

```haskell
data Known = Known { kCode :: CloneId, kCaps :: [MExpr] }        -- kCaps: atoms, positional to captures of kCode
data Arg   = AFun Known | AAtom MExpr | ADyn MExpr                -- classification of a call argument
data Shape = SFun CloneId | SLit MLit | SGlob CloneId | SDyn      -- memo key part; SFun holds the ORIGIN code
type Key   = (CloneId, [Shape])

data St = St
  { sFresh    :: Int                                  -- names "x@kN"; clone ids from 1 + maximum
  , sNext     :: Int
  , sDefs     :: Map.Map CloneId MDef                 -- current clones (originals + copies)
  , sNew      :: [MDef]                               -- copies made, in creation order
  , sFloated  :: [MDef]                               -- rule F Values (front of mpClones)
  , sOrigin   :: Map.Map CloneId CloneId              -- copy -> original
  , sMemo     :: Map.Map Key CloneId                  -- specializations and fully static expansions
  , sAlias    :: Map.Map CloneId Known                -- rule V (Value clone -> capture-free known)
  , sConstFn  :: Map.Map CloneId CloneId              -- rule C (Function clone -> capture-free code)
  , sCaps     :: Map.Map CloneId [(String, Class)]    -- Free.captures of the round
  , sPerOrig  :: Map.Map CloneId Int                  -- budget used per origin
  , sAdded    :: Int                                  -- nodes added (program budget)
  , sStack    :: [CloneId]                            -- builders being expanded (rule 3 of 1.4)
  , sStats    :: Stats                                -- counters for FICCUS_KNOWN_STATS, refusals by reason
  }
type K = State St

data Info = Info                                      -- read only, built in step 1
  { iScc :: Map.Map CloneId Int, iBuilder :: Map.Map CloneId CloneId   -- builder -> its returned lambda
  , iFnUse :: Map.Map CloneId [Bool], iSize :: Map.Map CloneId Int     -- family size per original
  , iRecursive :: Set.Set CloneId, iCycleValues :: Set.Set CloneId }
type Env = Map.Map String Known                       -- locals known in the current body
```

Functions: `knownProgram :: MProgram -> MProgram` (switch, rounds, sweep, check, stats), `rewriteDef :: Info -> MDef -> K MDef`,
`rw :: Info -> CloneId -> Env -> MExpr -> K MExpr` (bottom-up over the body, the cases of 2.1), `classify :: Env -> MExpr -> K Arg`,
`expand :: Info -> CloneId -> MDef -> [Arg] -> K (Maybe MExpr)`, `specialize :: Info -> MDef -> [Arg] -> K (Maybe MExpr)`,
`copyFamily :: Subst -> CloneId -> CloneId -> K (MExpr, [MDef])` (origin, new owner), `materialise :: Known -> K MExpr`,
`floatData :: MExpr -> K (Maybe MExpr)`, `sweep`, `checkScope`. Estimated 700 to 900 lines.

### 2.3 Changes per module

| module | change |
|---|---|
| `M.Known` (new) | the pass above |
| `terminal/src/Make.hs:208` | `Inline.inlineProgram program` -> `Inline.inlineProgram (Known.knownProgram program)`, inside the `rcMode` branch only; import. `FICCUS_KNOWN_STATS` printing next to the existing debug aids (Make.hs:~212) |
| the compiler's `.cabal` file | add `Ficcus.Mono.Known` to the module list |
| `M.Inline` | export `size` (:136) and `atom` (:183) for reuse; eligibility in `table` (:95-99): a reference to a **capture-free** lifted clone no longer disqualifies a body (it needs no scope), so the small specialized copies (`symbol 44`'s lambda, `succeed`'s) can be inlined and reached by rules A/B in stage 2. Behind the same `FICCUS_NO_KNOWN` switch, so with the pass off Inline is byte-identical. `canCallDirect` (:260) unchanged |
| `M.Free`, `M.Twin`, `M.Borrow`, `M.Rc`, `M.RcCheck`, `M.CGen`, `M.Spec`, `M.Ir` | unchanged. CGen makes the direct calls because the heads are now `MGlobal` with matching arity (CGen.hs:557); copies are ordinary lifted clones for Free/Twin/Borrow |
| `ficcus-tests/rcfuzz.py:27-33` | a setting `noknown` (`FICCUS_NO_KNOWN=1`) |
| `ficcus-tests/gates.sh` | one variant row: examples and suite with `FICCUS_NO_KNOWN=1` |
| workspace `docs/FLAGS.md` section 4 | the four environment variables (proposed text for the user, not edited by the implementing session if it is a shared file) |

### 2.4 What stays out of the no-RC path

Everything. `Known.knownProgram` is only called in the `rcMode` branch of Make.hs:208; Spec is unchanged, so the `--no-rc` C text is unchanged
(`norc_identity.py` must pass without `--update`). The Inline eligibility change is only active when the pass is on; Inline itself never runs
with `--no-rc`. `v2fuzz.py` (no-RC against RC under ASan) therefore compares the old semantics with the new pass for free.
