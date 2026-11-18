# 2. Vector: a flat array that updates in place

State: binary `elmficA16`. Examples are in `ficcus-tests/guide/v-*`; "FIC_STATS" lines come from a run built with
`-DFIC_STATS` (see 2.4). Source: `overlay/Vector.elm`, `runtime/fic_vector.h`; design notes `docs/STAGE4-V1.md`, `V2`, `V3`.

`Vector a` is a new type of the core library: a sequence of values stored side by side in one block of memory.
It has the API of `Array`, and it is **updated in place when nobody else holds the vector**; otherwise the update
copies it. `import Vector exposing (Vector)` works in `.elm` and `.fic` files, **in C builds only**: there is no
`Vector` in the JavaScript output (the same line gives Elm's MODULE NOT FOUND there):

<!-- guide-out: v-js err -->
```text
-- MODULE NOT FOUND ----------------------------------------------- src/Main.fic

You are trying to import a `Vector` module:
```

## 2.1 Vector against Array

| | `Array` | `Vector` |
|---|---|---|
| Representation | Elm's tree of 32 element nodes (as in Elm) | one flat block: header, length, capacity, elements |
| Element storage | every element is a boxed word | by layout: `Int`, `Float` (8 bytes), `Char` (4), `Bool` (1), records and tuples of those inline; other values as one pointer |
| `get` | walks the tree | one bounds test and a load |
| `set`, `push` on a unique value | in place, through the tree | in place, O(1); `push` grows by doubling |
| `set`, `push` on a shared value | copies | copies the whole vector, O(n) |
| Printed as | `Array.fromList [1,2]` | `Vector.fromList [1,2]` |
| `==` | by length and elements | by length and elements |
| `comparable` | no | no |
| Available in JS output | yes | no |

Measured on five benchmark programs, the `Vector` version is 1.7 to 10.5 times faster than the `Array` version
(`docs/STAGE4-V3.md`: nbody 1.7, spectral 2.7, fannkuch 3.6, hamvec 6.1, sieve 10.5), because it avoids the tree, the boxing
and the per-update allocation. See 4.4 for the numbers against C and Rust. Use `Array` when the program must also
build as Elm; use `Vector` when you want speed in a C build. The same steps on both, with the same results:

<!-- guide: v-array-same/Main.fic -->
```elm
fillArray : Int -> Array Int -> Array Int
fillArray n acc =
    if n == 0 then
        acc

    else
        fillArray (n - 1) (Array.push (n * 3) acc)


fillVector : Int -> Vector Int -> Vector Int
fillVector n acc =
    if n == 0 then
        acc

    else
        fillVector (n - 1) (Vector.push (n * 3) acc)
```

<!-- guide-out: v-array-same -->
```text
array: [15,0,9,6,3]
vector: [15,0,9,6,3]
same get: (True,True)
Array prints as: Array.fromList [15,12,9,6,3]
Vector prints as: Vector.fromList [15,12,9,6,3]
```

## 2.2 The API

```text
empty  singleton  initialize  repeat  withCapacity  fromList  toList
isEmpty  length  get  set  update  swap  push  append  slice
map  indexedMap  foldl  foldr  filter  toIndexedList
```

The meaning is that of the `Array` function of the same name, plus `swap` and `withCapacity`.
There is no `pop` and no `sort` (use `toList`, `List.sort`, `fromList`).
An index out of range never crashes:

<!-- guide: v-basic/Main.fic -->
```elm
        _ =
            Debug.log "get 3 / get 9" ( Vector.get 3 squares, Vector.get 9 squares )

        _ =
            Debug.log "set 0 / set 9" ( Vector.toList (Vector.set 0 -1 squares), Vector.toList (Vector.set 9 -1 squares) )
```

<!-- guide-out: v-basic -->
```text
squares: Vector.fromList [0,1,4,9,16,25]
length: 6
get 3 / get 9: (Just 9,Nothing)
set 0 / set 9: ([-1,1,4,9,16,25],[0,1,4,9,16,25])
push: [0,1,4,9,16,25,36]
slice 1 3 / slice -2 6: ([1,4],[16,25])
append: [0,1,4,9,16,25,100,101]
map / foldl: ([1,2,5,10,17,26],55)
filter: [0,4,16]
equal: (True,False)
initialize 0 / repeat -3: (0,0)
```

(`squares` is `Vector.initialize 6 (\i -> i * i)`.) In words:

- `get i v`: `Nothing` when out of range. `set i x v` and `swap i j v`: the vector unchanged when an index is out of range.
  `update i f v`: unchanged when out of range, else `set i (f x)`.
- `slice from to v`: the index rule of `Array.slice` (negative counts from the end).
- `initialize n f`, `repeat n x`: the empty vector when `n <= 0`.
- `foldl` goes first to last, `foldr` last to first, `map` and `indexedMap` first to last, and **`filter` calls its
  predicate from the last element to the first**, as `Array.filter` does; this shows only through `Debug.log`.
- `withCapacity n` makes an empty vector with room for `n` elements, so a loop of `push` never regrows. The name is provisional.
- `Vector.map` builds a new vector (the element type may change); it does not reuse the old storage.
- Writing `Vector.fromList [ a, b, c ]` with a literal list builds the vector directly, without the list.
- Equality `==` on vectors compares length and elements; a vector is not `comparable`.

## 2.3 In place when unique

A vector is an immutable value: `Vector.set 0 99 v` never changes what other holders of `v` see. The runtime counts
the holders. If the count is 1 the update writes into the existing block; if the vector is still used afterwards,
it copies the whole block first. You never write anything different; you only have to keep the vector from being
shared when you want speed. Below, `v` is read after the update, so the update must copy it. Run with
`FIC_WARN_COPY=1` and the program says so, once, naming the function:

<!-- guide: v-warn/Main.fic -->
```elm
-- `v` is still used after the update, so the update has to copy it
bump : Vector Int -> ( List Int, List Int )
bump v =
    ( Vector.toList (Vector.set 0 99 v), Vector.toList v )
```

<!-- guide-out: v-warn -->
```text
bump: ([99,2,3],[1,2,3])
```

<!-- guide-out: v-warn stderr -->
```text
FIC_WARN_COPY: Vector.set copies a shared vector of 3 elements (2 references to it) in Main.bump; later copies are not reported
```

Only counted builds (the default) can tell; `--no-rc` builds never free and copy on every update, so a `push` loop
is quadratic there (use `--no-rc` only for small programs, as the oracle).

## 2.4 Counters: FIC_STATS and FIC_WARN_COPY

- **`FIC_STATS`** is a C macro of the generated program: build with `gcc -DFIC_STATS`. At exit the program prints one
  line on stderr: `FIC_STATS: allocs live peak dup drop free_slow reuse_hit reuse_miss inplace copied pap_steal clo_steal vec_copy`.
  `inplace` counts updates done in place (arrays and vectors), `copied` the copies of an array or vector (also growth),
  and **`vec_copy`** the vector updates that had to copy because the vector was shared: the number to watch.
  `live` is the number of objects still alive at exit; a counted program with `FIC_STATS` exits with a nonzero
  status if it is not 0 (a leak check). `peak` is the largest number of live objects.
- **`FIC_WARN_COPY=1`** is an environment variable of the running program (counted builds; no macro needed).
  The first copy of a shared vector prints the line shown above; later copies are not reported.
  Planned: a compiler lint for the same thing.

## 2.5 Writing fast code

**Pass the vector on, and do not use the old name again.** A loop that threads its accumulator keeps it unique:

<!-- guide: v-fast/Main.fic -->
```elm
fill : Int -> Int -> Vector Int -> Vector Int
fill i n acc =
    if i >= n then
        acc

    else
        fill (i + 1) n (Vector.push (i * i) acc)


bump : Int -> Int -> Vector Int -> Vector Int
bump i n v =
    if i >= n then
        v

    else
        bump (i + 1) n (Vector.update i (\x -> x + 1) v)
```

<!-- guide-out: v-fast stderr -->
```text
FIC_STATS: allocs 6 live 0 peak 2 dup 1 drop 3 free_slow 2 reuse_hit 0 reuse_miss 0 inplace 1991 copied 9 pap_steal 0 clo_steal 0 vec_copy 0
```

2000 updates, 0 copies (the 9 `copied` are the growth by doubling of `fill`; `Vector.withCapacity n` avoids them).
The same loop where the old vector is still read after the update (here `Vector.length v` after `Vector.update i ... v`)
copies each time:

<!-- guide: v-slow/Main.fic -->
```elm
        let
            w =
                Vector.update i (\x -> x + 1) v
        in
        if Vector.length v < 0 then
            w

        else
            bump (i + 1) n w
```

<!-- guide-out: v-slow stderr -->
```text
FIC_STATS: allocs 1006 live 0 peak 2 dup 1001 drop 2003 free_slow 1002 reuse_hit 0 reuse_miss 0 inplace 991 copied 1009 pap_steal 0 clo_steal 0 vec_copy 1000
```

1000 whole-vector copies for 1000 updates. Fix: read what you need (`Vector.length v`) before the update, or from `w`.

Rules of thumb:

1. **One owner.** Update the vector you were handed and return it. Do not store it in two places, and do not read the
   old value after the update. A vector held in a record field, a closure or a second variable counts as another holder.
2. **No sharing in loops.** `Vector.repeat n x` puts the *same* `x` in every slot. For a vector of vectors the first update of
   each row copies the shared row (`v-repeat-shared`: `vec_copy 99`). Build with `Vector.initialize n (\_ -> ...)` and each row
   is its own (`v-nested`: `vec_copy 0`, 10,300 in-place writes). Then `Vector.update y (Vector.set x v)` is in place on both levels:

<!-- guide: v-nested/Main.fic -->
```elm
grid : Int -> Vector (Vector Int)
grid n =
    Vector.initialize n (\_ -> Vector.repeat n 0)


paint : Int -> Int -> Vector (Vector Int) -> Vector (Vector Int)
paint i n g =
    if i >= n then
        g

    else
        paint (i + 1) n (Vector.update i (Vector.set i 1) g)
```

3. **`update` with a lambda or a partial application** (as above) is the fastest way to change an element: the compiler writes
   the function out, so a record element is changed with no allocation. `Vector.get` followed by `set` also works.
4. **Prefer the library loops** (`foldl`, `initialize`, `map`, `filter`): they build their result with in-place pushes.
5. **Size the vector.** `Vector.withCapacity n` plus `push` avoids regrowth; `initialize n f` and `repeat n x` allocate once.
6. **`slice` of a unique vector cuts in place**, so a queue read from the front is cheap: 900 `slice 1 n v` steps on
   1000 elements copy nothing (`v-slice`: `vec_copy 0`). `append a b` extends `a` in place when it is unique and has room.
7. **Layout.** `Vector Int` uses 8 bytes per element, `Vector Float` 8, `Vector Char` 4, `Vector Bool` 1; a record of
   scalars is stored inline (a flat struct per element). A record with a `String` or `List` field is stored inline with a pointer
   map. A `Vector Int` of a million elements is 8 MB. There are no `Word8` vectors yet (planned with the sized integers), so a
   byte buffer costs 8 bytes per byte.
8. **Out of range is a silent no-op** for `set`, `swap`, `update`: a wrong index shows as a wrong answer, not a crash.
   Test with `FIC_CHECK` (a build macro: `-DFIC_CHECK` tests every index read).

## 2.6 The module rule

`Vector` is a module of the core overlay, not a package. **A module named `Vector` in your project, or in a package you depend
on, wins over it.** Then `import Vector` means yours, and the core one is unreachable under that name. Nothing else changes:

<!-- guide: v-local/Main.fic -->
```elm
import Vector exposing (Vector)


-- this is the project's own `Vector` (a 2D vector), not the flat array type of the core library
v : Vector
v =
    Vector.make 3 4
```

<!-- guide-out: v-local -->
```text
length: 5
```

A package that itself imports the core `Vector` builds (the overlay is passed to packages). The same rule holds for `Bitwise64`.

## 2.7 Not there yet

- No literal syntax (`[| 1, 2, 3 |]` or similar) and no `Vector` in the default imports: planned.
- No `Word8`, `Int32`, ... element types; `Vector Int` is always 64 bit per element (planned).
- No JavaScript output (planned with the later JS target decision).
- Two cheaper checks inside updates (the uniqueness test hoisted out of loops) are not done: measured upper bound 14 % on the sieve.
