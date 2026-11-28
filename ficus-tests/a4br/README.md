# A4b review scratch cases (docs/A4B-REVIEW.md)

    TMPDIR=/home/gordon/claude-tmp python3 ficus-tests/a4br/run.py [--elm ../bin/elmficA4bb] [--only a,b] [--js] [-v]

Each case is `cases/<id>/` with `Main.elm` (and other modules). With `twin/`, the twin is plain Elm compiled by `bin/elm0193` and
run by node, and both C runs (`--no-rc` gcc -O2; `--rc` gcc -O1 with ASan+UBSan, FIC_STATS, FIC_NO_POOL) must print the same and
end with 0 live objects. Without a twin the runner prints the output (or the compile report). `--js` also builds JavaScript.

**Do not run the `nonregular-mutual*` cases without a time limit:** `elmficA4bb` does not stop on them (finding M1). The runner's
own limit is 300 s per compile.

Verdicts at `elmficA4bb` (feat/a4b ae24c16f), 27 Nov:

| case | what | result |
|---|---|---|
| nonregular-mutual, nonregular-mutual-hash | derived `compare`/`hash` over `A a = A a (B (List a))`, `B a = B (A a)` | **M1: the compiler does not stop** (>124 s, RSS growing); elmficA5c: TYPE MISMATCH |
| nonregular-mutual-eq | the same types, plain `==` | A3's non-regular report (correct) |
| row-var-derive, row-var-derive-string-rev (twins) | derived over `type T r = T { r \| x : Int }` | **M2: wrong order and hash** (only the row-less record is read, from the wrong slot) |
| row-var-derive-string | same, field `name : String` | right by luck of the layout |
| row-var-derive-fn, row-var-derive-hash-fn | a function in the row | refused (TYPE MISMATCH, NO ATTACHED FUNCTION): correct |
| row-var-eq-show (twin) | plain Elm: `==` and `Debug.toString` on the same type | **P1: pre-existing**, also elmficA5c: `(True,T { x = 1 })`, Elm `(False,T { x = 1, y = 2 })` |
| open-record-obligation, -hash, -inferred, -let, -obligation-ok | `a has compare`/`a has hash` at `{ r \| x : Int }` | **F1: type checker accepts**; the specializer stops it (row variables: slice 5) |
| open-record-sortwith | `comparable` at an open record (unifier) | TYPE MISMATCH: correct |
| hash-shape, hash-shape-arity2 | written `hash : T -> String` / `T -> Int -> Int` inside a derived `hash` | **F2: accepted**, C generator fails ("another shape than the constraint") |
| hash-shape-list, hash-z | `a has hash` at a wrong shape | ATTACHED FUNCTION MISMATCH: correct |
| hash-z-free | `a has hash : a -> z` at Int, String, a derived type | runs, z = Int |
| derive-beside-eq | `derive compare, hash` beside a written `eq` | **F3: accepted, both laws broken** (`==` True, compare LT, hashes differ, Dict keeps 2 keys) |
| own-vector | a project module `Vector` (no members) | type checker takes it for the core one; C generator refuses (loud) |
| own-vector-member (twin) | the project's `Vector` with a written `compare` | runs, the user's member decides |
| own-vector-member-fn | same at `Vector (a -> a)` | **F4: wrong reject** (taken for the core container) |
| phantom | phantom parameter at a function type: Dict key, sort, hash | runs |
| phantom-wrapped | `type W a = W (Id a)`, `Id` phantom | **F5: wrong reject** (the deriver constrains every variable used) |
| value-at-comparable | `List.sortWith Tree.compare` at `Tree comparable`, no `where` line | **F6: INCOMPLETE TYPE ANNOTATION** (wrong reject) |
| value-poly-annotated, value-poly-inferred | the same with the `where` line / unannotated | runs |
| written-constrained-other-member, -append, -append-fn | written operator members with constraints | OPERATOR FUNCTION WITH THE WRONG TYPE (so only derived members reach the policy's positions) |
| own-stress (twin) | derived over a record of written-member `Ci` (owned parameters), `Maybe (Vector Int)`, `Set String`, `Result String (Array Float)`; Dict/Set keys, nested Dict keys, sorts, laws | ok, ASan 0 live |
| mutual, alias, values | mutually recursive derived types with Dict/Maybe/List; aliases; the member as a value (let alias, record field, partial, map2, higher order) | runs, outputs checked by hand |
| ops-paths (twin) | operators as values, max/min, maximum/minimum, Dict union/diff/intersect/merge/remove, Set map/diff, sortWith/sortBy, Vector sort/sortBy/sortWith | ok |
| array-long (twin) | Array of 40000 (depth 3) built by initialize, set, push, slice, append, fromList, foldl push, repeat | ok |
| float-ties-nonan (twin) | -0.0, 0, inf in a derived type: compare matrix, stable sortBy/sortWith, Dict/Set sizes, `==` | ok |
| float-ties (twin), float-ties-plain (twin) | the same with NaN | sort differs from Elm; **pre-existing** (the plain tuple program differs the same way on elmficA5c) |
| hash-quality | distinct hashes and bucket spread of typical keys; zero fixed point; order independence | measured (see the report) |
| bool-consistency, bool-direct | Bool, `{ b : Bool }`, `Maybe Order`, `()` through `a has compare` vs `List.sort` | obligation accepts, unifier refuses `{ b : Bool }` (note N2) |
| deep-derived-list | 1,000,000-deep derived recursive list: compare and hash | runs (ASan) |
| gate-js-cross, gate-js-generic, gate-js-written-cross, gate-js-import-opens, gate-js-hash-int | the JS refusal across modules, without `derive`, gate opened by an import | JS refused in every case |
| gate-plain-beside | a plain module beside a gated one | Elm's TYPE MISMATCH in the plain module |
| flip-plain (twin) | plain Elm comparing records, `Result` keys, `Maybe` | gated: TYPE MISMATCH; with the predicate flipped (`/home/gordon/claude-tmp/elmficA4b-flip`): C ok, JS refused |
