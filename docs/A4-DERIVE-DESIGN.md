# A4: derivation of well known members (design note)

Branch `design/a4` from `ficcus` `43e2bb04`. Read only: no compiler change. Inputs: rev 128 (point 4), the A4 scope (rev 171),
A2-DESIGN, A3-NOTES, G70 (rev 181), the Vector report and the SPA count as summarized in the decisions file (`docs/SPA-COUNT.md`
itself is not in any worktree; the numbers below come from the decisions entry of 24 Nov).

## 0. Summary

`derive m1, m2, ...` inside the `where` block of a custom type generates ordinary members `T$$m`, one per type, in the type's home
module, with a normal annotation (plus `a has m` for each type parameter that needs it). The type checker, the interface, G70
visibility and A2 specialization then treat them like hand-written members: static dispatch, one clone per exact type, direct calls.
Two generation styles, chosen per member by what already exists:

| group | members | body | where the work is |
|---|---|---|---|
| **S** (structural) | `compare`, `hash`, `toString`, `fromString` | a stub calling a kernel (`FicDerive.structCompare` etc.) | CGen helper per exact type, beside the existing `HEq`, `HCmp` and `showStmt` (Debug.toString) |
| **E** (Elm code) | `encode`, `decode`, `minValue`, `maxValue`, `succ`, `pred`, `enumerate`, `map` | generated Canonical Elm code | a deriver in canonicalization; helpers in an overlay module `FicDerive` (Ficcus source) |

Group S shares its C code with A3b (members inside containers): one structural walker that calls a member clone whenever the type
at hand has one, and the structural code otherwise. Records, tuples, `List`, `Maybe`, `Result`, `Array`, `Vector`, `Dict`, `Set`
have group S members automatically (built in table, recursive "has `m` if all parts have `m`"); custom types only through `derive`.

## 1. Mechanism

**Syntax** (rev 128, unchanged): one `derive` line in the `where` block, any position, members separated by commas; `derive` is a
keyword only at the start of a line of a `where` block of a type. There is no automatic rule for custom types (Elm's "custom types
are not comparable" stays unless the type opts in) and no `derive` on a type alias (G70 open item: aliases carry no members).

**What is generated.** After the type is canonicalized (field types resolved to their home modules) and before type checking,
`Canonicalize.Derive` (new) produces, for each listed member, a `Can.Def` named `T$$m` with an annotation built from the shape
table (`AST.WellKnown` gains the shapes `Hash s -> Int`, `ToString s -> String`, `FromString String -> Maybe s`, `Encode s -> Value`,
`Decode Decoder s`, `Bound s`, `Step s -> Maybe s`, `Enumerate List s`, `Map (a -> b) -> T .. a -> T .. b`). The bodies are type
checked like user code; a type error in a derived body is a compiler bug and is reported as such ("please report"), never shown as
the user's mistake. User errors come from a check before generation:

- **CANNOT DERIVE**: a field type lacks the member (a function, `Json.Value` for `compare`, a custom type without the member), with
  the path (`Contact > email : Email`) and the hint "derive or write `Email.compare`, or write `Contact.compare` yourself";
- **DERIVE ON NON-ENUMERATION**: `minValue` ... `enumerate` on a type with a constructor that has fields;
- **DERIVE AND DEFINE**: the member is both listed and written (pick one).

**Per type, per use.** One definition per type; the specializer clones it per exact instance (A2 section 4), so dispatch is static
and calls are direct. Only used members reach C (Mono reachability), so `derive` costs nothing when unused.

**Parameters and constraints.** For `type Tree a`, each member gets one `a has m` constraint per parameter that occurs in a field
where `m` is needed: `compare : Tree a -> Tree a -> Order where a has compare as compareA : a -> a -> Order`. Phantom parameters
get none. The derived body does not need the hidden parameter in group S (the C helper calls the element's member by exact type),
but the constraint must stay so that `Tree (Int -> Int)` is rejected at the use with the A2 NO MEMBER error.

**Recursive types.** Group E bodies are ordinary recursive functions (one `Can.DeclareRec` group per type; mutually recursive types
of one module get one group). A recursive decoder is a value, so every recursive reference is wrapped in `Json.Decode.lazy`.
Group S helpers are C functions that call themselves. **Non-regular recursion** (`type Nest a = Nil | Cons a (Nest (List a))`) would
need infinitely many clones: CANNOT DERIVE ("the type is used at another argument inside itself").

**Opaque types (G70).** Members follow the type name, so a derived member of an opaque type is visible wherever the name is
exported. Derivation can therefore expose the representation (`toString`, `encode`, `map`); that is the owner's choice, made by
listing the member, as with a written member.

**User override.** Writing the member in the `where` block instead of listing it is the override; there is no per member option.
Other derived members of the *same* type do not call each other (`max` is from `compare`, as today). Derived members of *other*
types call whatever member the field type has, written or derived, for `compare`, `hash`, `encode`, `decode`, `map`. Exception:
`toString`/`fromString` are structural all the way down (section 2), so they ignore a written `toString` inside.

**Operators, `Dict`, `Set`.** A derived `compare` is an A3 member: `<`, `<=`, `>`, `>=`, `max`, `min`, `clamp`, `List.sort`,
`Vector.sort`, and `Dict`/`Set` keys use it, and so does a key `(Color, Int)` or `List Color` once A3b is in (A4b depends on A3b).
`==` stays structural (or the `eq` member when one is written); since every derived `compare` returns `EQ` exactly when all parts
compare `EQ`, derived `compare` agrees with structural `==` provided each written `compare` inside agrees with its type's `==`.
A written `compare` without a written `eq` that disagrees with `==` is the user's law break; I recommend a later lint, not an error.

## 2. The members

**`compare`.** Constructors in declaration order (`Red < Green < Blue`); same constructor: fields left to right, lexicographic.
Records: fields in **alphabetical** order (records are structural: `{x,y}` and `{y,x}` written in two aliases are one type, so order
cannot depend on a declaration). Tuples, `List`, `Array`, `Vector`: lexicographic (shorter prefix first). `Maybe`: **`Nothing < Just`**
(an explicit table entry; elm/core declares `Just` first, and declaration order would surprise everyone coming from Haskell, Rust or
SQL). `Result`: declaration order, `Ok < Err` (as Rust). `Dict`, `Set`: as their ascending `toList`. `Word64`: unsigned (A3b).
`Float`: Elm's `compare` (NaN is whatever Elm gives; no total order promised).

**`hash : T -> Int`.** Law: `a == b` implies `hash a == hash b`. Constructor index and fields folded with a fixed 64 bit mixer
(splitmix64 finalizer; `FicDerive.mix`, `combine h x = mix (h * 0x9E3779B97F4A7C15 + x)`); strings by a fixed byte hash (wyhash or
FNV-1a 64; pick one in A4b). **Stable**: no per run seed, the same on every platform and run; **not promised across compiler
versions** (do not persist it). Not DoS resistant; a future hash map seeds at the map, not in `hash`. `Float`: `-0` and `0` hash
alike (they are `==`); NaN anything. Nothing in elm/core uses `hash` today; it is there for a later `HashDict` and for user code.

**`toString : T -> String`.** Exactly `Debug.toString`'s format (decisions L16, L29: `Circle 1.5`, `Node (Node Leaf 1 Leaf) 2 Leaf`,
`{ age = 3, name = "Bo" }`, `Vector.fromList [1,2]`), produced by the existing `showStmt`. So it is Elm's `Debug.toString` available
under `--optimize` and in packages. Strings inside are quoted. Rationale for structural (ignoring a written `toString` inside): a
display string such as `Username.toString u == "bob"` cannot be parsed back inside a larger value, so the round trip would be lost;
a type that wants a display form writes its own `toString`. The built in `toString` of `String` used through `a has toString` is
then also the quoted form (recorded as open decision 4).

**`fromString : String -> Maybe T`.** Law: `fromString (toString x) == Just x` for every `x` (with `Float` this needs JS shortest
round trip printing, which Ficcus has). Accepts exactly the `toString` grammar (no extra spaces, no `-0` normalization beyond what
`toString` emits); returns `Nothing` otherwise, no error text (as `String.toInt`). Implemented as a C helper per exact type
mirroring `showStmt` (`HParse t`) over a byte cursor, plus a few runtime functions (`fic_parse_int`, `_float`, `_string`, `_char`,
`_ctor`). It is the most work of all members and the least asked for: last but one slice.

**`encode : T -> Json.Encode.Value` and `decode : Json.Decode.Decoder T`.** The same `Value` and `Decoder` types as elm/json, so
derived and hand written codecs mix freely (`Json.Decode.list Color.decode`, `field "c" Color.decode`). Recommended minimal scheme:

| Ficcus value | JSON | decode accepts |
|---|---|---|
| `Int`, sized ints, `Float` | number (`Encode.int` writes 64 bits; NaN, inf as `null`, L20) | `Decode.int` rules (L21); `Word64` above 2^63 needs a small kernel decoder |
| `String`, `Char`, `Bool` | string, 1 character string, `true`/`false` | same |
| `()` | `null` | `null` |
| tuple, `List`, `Array`, `Vector`, `Set` | array | array of the right length for tuples |
| `Maybe a` | `null` or the value | in a record field: missing **or** `null` gives `Nothing`; elsewhere `null` |
| `Result e a` | `{"Ok": v}` / `{"Err": e}` | same |
| `Dict String v` | object | object |
| `Dict k v`, other `k` | array of `[k, v]` pairs | same |
| record | object, keys = field names as written, alphabetical order | any order, extra keys ignored |
| `Json.Encode.Value` field | itself | `Decode.value` |
| nullary constructor `Red` | `"Red"` | `"Red"` |
| constructor with fields `Node l v r` | `{"Node": [l, v, r]}` (always an array) | exactly one key, array of the arity |
| one constructor, one field (`Email String`, `Author {..}`) | the field alone (transparent, like W1) | the field alone |

Names are the source names, case unchanged; no options in A4 (renaming, defaults, skipping fields, snake case) because each option is
syntax, and the override (write the member) covers the rare case. Error texts are elm/json's `Error` with `Failure` messages from
`FicDerive.union`: ``Expecting a `Color`: one of "Red", "Green", "Blue", but got "Purple"``, ``Expecting a `Tree`: a string or an object
with exactly one key`` and ```Node` takes 3 arguments, got 2``. Field errors are elm/json's own (`Expecting an OBJECT with a field named
`email``). Format notes: this is Rust serde's default ("externally tagged") and close to Roc's; it differs from Haskell aeson's default
(`{"tag":..,"contents":..}`). Adding a constructor to a one constructor type changes its format (transparent to tagged): stated in the
docs.

**`minValue`, `maxValue : T`; `succ`, `pred : T -> Maybe T`; `enumerate : List T`.** Only for enumeration types (all constructors
nullary; phantom parameters allowed). Declaration order, consistent with `compare`. `succ maxValue == Nothing` (total, no crash and no
wrap, unlike Haskell's `succ`). `enumerate` is a static constant list (compile time constant, H22 static data). Built in types:
`Bool` and `Order` get all five in the built in table (cheap, consistent); `Int` and sized ints get only `minValue`/`maxValue`
(useful for generic code with `a has minValue : a`); `Char` and `Float` get none.

**`map : (a -> b) -> T .. a -> T .. b`** (the last parameter, DeriveFunctor). **Sound** when that parameter occurs only covariantly:
as a field directly; inside tuples, records, `List`, `Array`, `Vector`, `Maybe`, `Result e _` (value side), `Dict k _` (values), a
function result (`x -> a`, composed); inside another custom type only in its last position when that type has `map`. Refused (CANNOT
DERIVE) under `Set` (needs `comparable b`), in a function argument, in a non-last position of a type, under a `Dict` key. Laws `map
identity == identity`, `map (f << g) == map f << map g` hold by construction. **Useful** for user containers (`Tree.map`,
`Validated.map`, `Remote.map`), but not generic (no `f has map`, HKT stays out), and the SPA count found no saving from it. Recommend:
include, last slice; it is about a day of deriver code and needs no C.

### Examples (source, then the generated form as Elm; `T$$m` is written `T.m`)

**Enumeration.**

```elm
type Color = Red | Green | Blue
    where
        derive compare, hash, toString, encode, decode, minValue, maxValue, succ, pred, enumerate
```
```elm
Color.compare : Color -> Color -> Order
Color.compare = FicDerive.structCompare        -- C: static int cmp_Color(a, b) { return tag(a) - tag(b) } (switch on tags)
Color.hash = FicDerive.structHash              -- C: mix(tag)
Color.toString = FicDerive.structToString      -- C: showStmt at Color: "Red"
Color.encode c = Json.Encode.string (case c of Red -> "Red"; Green -> "Green"; Blue -> "Blue")
Color.decode = FicDerive.enumDecoder "Color" [ ( "Red", Red ), ( "Green", Green ), ( "Blue", Blue ) ]
Color.minValue = Red
Color.maxValue = Blue
Color.succ c = case c of Red -> Just Green; Green -> Just Blue; Blue -> Nothing
Color.pred c = case c of Red -> Nothing; Green -> Just Red; Blue -> Just Green
Color.enumerate = [ Red, Green, Blue ]
```

**Record (behind a transparent constructor, the elm-spa-example pattern).**

```elm
type Email = Email String where derive compare, encode, decode
type User = User { name : String, email : Email, bio : Maybe String }
    where
        derive compare, encode, decode
```
```elm
User.compare = FicDerive.structCompare
-- C: cmp(a.bio, b.bio) [Nothing < Just, then cmp_String], then Email.compare clone (here: cmp_String, W1), then cmp_String(name)
User.encode (User r) =
    Json.Encode.object
        [ ( "bio", FicDerive.encodeMaybe Json.Encode.string r.bio )   -- null or "..."
        , ( "email", Email.encode r.email )                           -- "a@b" (transparent)
        , ( "name", Json.Encode.string r.name )
        ]
User.decode =
    Json.Decode.map3 (\bio email name -> User { bio = bio, email = email, name = name })
        (FicDerive.optionalField "bio" Json.Decode.string)           -- missing or null -> Nothing
        (Json.Decode.field "email" Email.decode)
        (Json.Decode.field "name" Json.Decode.string)
-- more than 8 fields: FicDerive.andMap chains (map2 (|>)), same order of evaluation and first error as mapN
```

**Recursive, parametric custom type.**

```elm
type Tree a = Leaf | Node (Tree a) a (Tree a)
    where
        derive compare, hash, toString, encode, decode, map
```
```elm
Tree.compare : Tree a -> Tree a -> Order
    where a has compare as compareA : a -> a -> Order
Tree.compare = FicDerive.structCompare
-- C, clone at Tree Money: Leaf < Node; Node: cmp_Tree_Money(l1,l2), then Money$$compare clone(v1,v2), then cmp_Tree_Money(r1,r2)

Tree.encode : Tree a -> Json.Encode.Value
    where a has encode as encodeA : a -> Json.Encode.Value
Tree.encode t =
    case t of
        Leaf -> Json.Encode.string "Leaf"
        Node l v r -> FicDerive.tagged "Node" [ Tree.encode l, encodeA v, Tree.encode r ]      -- {"Node":[l,v,r]}

Tree.decode : Json.Decode.Decoder (Tree a)
    where a has decode as decodeA : Json.Decode.Decoder a
Tree.decode =
    FicDerive.union "Tree"
        [ ( "Leaf", Json.Decode.succeed Leaf ) ]
        [ ( "Node", 3, Json.Decode.map3 Node
                          (Json.Decode.index 0 (Json.Decode.lazy (\_ -> Tree.decode)))
                          (Json.Decode.index 1 decodeA)
                          (Json.Decode.index 2 (Json.Decode.lazy (\_ -> Tree.decode))) ) ]

Tree.map : (a -> b) -> Tree a -> Tree b
Tree.map f t =
    case t of
        Leaf -> Leaf
        Node l v r -> Node (Tree.map f l) (f v) (Tree.map f r)
```

`Tree.toString (Node Leaf 3 Leaf)` is `"Node Leaf 3 Leaf"`; `Tree.encode` of it is `{"Node":["Leaf",3,"Leaf"]}`.

## 3. Other languages: what to copy, what to avoid

| | Roc | Rust | Haskell | Ficcus A4 |
|---|---|---|---|---|
| opt in | auto for records, tags, lists; `implements [Eq, Hash, Inspect, Encoding, Decoding]` for opaque types | `#[derive(...)]` | `deriving (...)` | `derive` in `where` |
| format | format generic (`Encoding` over an `EncoderFormatting`); JSON is a package (`roc-json`) with `fieldNameMapping` | serde data model, many formats; attributes `rename`, `rename_all`, `default`, `skip`, `flatten`, `tag`, `untagged` | aeson via `Generic`, `Options` (`fieldLabelModifier`, `sumEncoding`, `omitNothingFields`) | JSON only, on elm/json's `Value`/`Decoder`; no options |
| print | `Inspect` (replaced `toStr`) | `Debug` (not parseable), `Display` by hand | `Show`/`Read` (parseable, precedence) | `toString` = `Debug.toString`, `fromString` its inverse |
| enum | none | none in std (`strum` crate) | `Enum`, `Bounded` (`succ` crashes at the end) | `minValue`, `maxValue`, total `succ`/`pred`, `enumerate` |
| map | no (no HKT) | no | `DeriveFunctor` | `map` per type, no HKT |

**Copy:** Roc's "structural types derive automatically, nominal types opt in" (we already decided it); serde's externally tagged
default and transparent newtypes (`#[serde(transparent)]` as the rule for one field); Haskell's `Bounded`/`Enum` and `Functor`
rules (but total `succ`); Rust's rule that derive needs every field to have the trait (our CANNOT DERIVE). **Avoid:** format generic
encoding (needs a formatter abstraction we would have to express without HKT, and doubles the work for one format in use); serde's
attribute language (each attribute is syntax, and the long tail is better written by hand); aeson's `Generic` route (compile time cost
and opaque errors); Haskell's orphan instances (G70 already rules them out); Haskell `Read`'s precedence parsing (our `toString` is
one fixed format).

## 4. Elm compatibility

- **No Elm program changes meaning**: `derive` is a new line in a `where` block, which Elm cannot parse; programs without it produce
  byte identical C and JS (gated).
- **JS output**: refuse a program whose object graph contains a type with a `derive` line, through a `$derived` marker checked in
  `Nitpick.Constraints` beside `$customOperators`: "DERIVED MEMBERS ... `Main.Color` derives `compare`, `encode`; the JavaScript output
  does not support derivation yet; use `--output=<name>.c`". Reason: group S bodies are C helpers; group E bodies of parametric types
  are constrained functions (already refused). Group E members of monomorphic types are plain elm/json code and could be allowed in JS
  later at no cost (open decision 6).
- **Existing functions of the same names.** Elm code commonly has `module Username exposing (Username, toString, encode, decoder)`.
  A1 resolves `Username.toString` module first, so the module's function keeps its Elm meaning and the member is reachable only as
  `Username.Username.toString` and through operators and constraints. Two different `Username.toString` is a trap, so the deriver
  rejects it: **DERIVE SHADOWED** when the home module whose name equals the type name (or which exposes a top level function of the
  member's name) also derives that member; hint "remove `toString` from the module and the derived member answers to the same name".
  This makes migration a deletion: call sites `Username.toString` stay unchanged. For that to also hold for decoders, the member
  should be called `decoder`, the Elm convention, not `decode` (open decision 1).
- **Dependencies**: `derive encode`/`decode` need `elm/json` as a direct dependency; the parser adds `Json.Encode`/`Json.Decode` to the
  module's implicit imports when the `derive` line lists them (so `Build` orders modules correctly); otherwise a clear error.

## 5. Cost and risk

**SPA count.** JSON codecs are 449 of 3,726 lines (12.1 percent) of `elm-spa-example`; derivation would save about 150 to 190 of
them plus 45 to 60 lines of wrapper conversions, about 200 to 250 lines, **6 percent of the program**. So line count does not justify
the JSON half on its own; its case is that derived codecs cannot drift from the types, plus the Roc JSON benchmark. Priority follows:
`compare` and `hash` first (they close A3b and give `Dict`/`Set` keys on custom types, the most visible gain), the enumeration members
and `toString` next (cheap), JSON after, `fromString` and `map` last.

**Code size.** One C helper or clone per member per exact type actually used. `compare` and `hash` are a switch over tags with one
call per field. Decoders are elm/json interpreter nodes (closures per field): allocation heavy at run time; a direct C decoder per
type is a later optimization if the Roc benchmark asks for it (not in A4). **Compile time:** linear in the size of the type
declarations; negligible beside specialization.

**Risks.** (1) Group S helpers in CGen must get `dup`/`drop` right on fields (soundness; same pattern as `HEq`/`HCmp`, but `HParse`
allocates): Opus review after A4b and after A4e. (2) The decode error texts become a format users match on: fix them in tests now.
(3) Record field order rules (alphabetical) must be the same in `compare`, `toString` (Debug.toString's order: check against Elm
before A4c) and `encode`. (4) `Vector` fields need the Vector parity slice for `compare`; until then CANNOT DERIVE with "not yet".
(5) Opaque types leak through `encode`/`toString`: documented, the owner's choice.

**Gates per slice.** (a) A derive matrix in `ficcus-tests/attach/` (or `tests/derive`): 3 type shapes (enumeration, record behind a
constructor, recursive parametric) times each member times {works, CANNOT DERIVE, DERIVE AND DEFINE, DERIVE SHADOWED, JS refusal}, with
`--rc` plus ASan/UBSan and 0 live objects. (b) Law tests over generated values (as the sized fuzz): `fromString (toString x) == Just x`,
`decodeValue decode (encode x) == Ok x`, `compare` antisymmetric, transitive and `EQ` iff `==`, `hash` agrees with `==`, `enumerate ==
iterate succ minValue`, `map` identity and composition. (c) Differential against Elm: for each JSON case a hand written Elm codec of
the documented format, run under `elm0193` + node and under the C path; outputs byte equal; `toString` against Elm's `Debug.toString`
the same way. (d) Regression: suite C text byte identical (`--rc`, `--no-rc`), JS identity 28, elmdiff 1175 SAME, attach 196, types 267
+ 1 XFAIL, typed 568/12/1.

**Slices** (Sonnet sized, in order; one heavy build at a time):

1. **A4a: syntax and checking.** `derive` line, the new shapes, signature synthesis with constraints, CANNOT DERIVE, DERIVE AND DEFINE,
   DERIVE SHADOWED, non-regular recursion, `$derived` JS refusal, implicit elm/json imports; bodies are stubs the C generator refuses.
   Test: the error half of the matrix.
2. **A4b: `compare` and `hash`** (with or right after A3b, sharing the structural walker; needs Vector parity or refuses `Vector`):
   `HHash`, the `structCompare`/`structHash` stubs, built in table entries (`Maybe` order, `Word64`), `Dict`/`Set` keys. Opus review.
3. **A4c: `toString` and the enumeration members** (`showStmt` reuse; group E for the enum members; `Bool`/`Order` table entries).
4. **A4d: `encode` and `decode`**: the deriver's JSON half, `FicDerive` overlay helpers, error texts, the Elm differential cases.
5. **A4e: `fromString`**: `HParse` and the runtime parse functions, round trip fuzz. Opus review.
6. **A4f: `map`**: variance check and generation.
7. Then A4s (already planned): the SPA rewrite and the Roc JSON benchmark.

## 6. Open decisions (with my recommendation)

1. **Name of the decoder member: `decode` (as scoped) or `decoder` (Elm's convention: `Username.decoder`, `Article.decoder`).**
   Recommend `decoder`: migration becomes "delete the function, add `derive`", call sites unchanged.
2. **`Maybe` order: `Nothing < Just` by a table entry, or declaration order (`Just < Nothing`).** Recommend `Nothing < Just`.
3. **Record field order for `compare`, `encode`: alphabetical or declaration order of the alias.** Recommend alphabetical (records are
   structural; an alias does not fix an order).
4. **`toString` structural (= `Debug.toString`, ignores a written inner `toString`, round trips) or honoring inner members (display
   oriented, no `fromString`).** Recommend structural; the built in `toString` of `String` through `a has toString` is then quoted.
5. **JSON options (rename, snake case, defaults, skip).** Recommend none in A4; override by writing the member; revisit after the SPA
   rewrite if a pattern repeats.
6. **JS output: refuse every `derive` (A4) or allow the group E members of monomorphic types.** Recommend refuse in A4 (one marker,
   one message), allow later with the JS target decision (G10).
7. **Record subjects without a wrapper (`Derive.encode user` for a record alias):** needs Mono level synthesis for records. Recommend
   defer: use `type User = User {...}` (transparent, zero cost by W1); revisit with the open alias item of G70.
8. **`map` in A4:** recommend yes, as the last slice (sound, cheap, no C), knowing it is not generic.
9. **Built in enum members:** recommend `Bool` and `Order` get all five, `Int` and sized ints only `minValue`/`maxValue`.
