#!/usr/bin/env python3
"""FBIP checks (STAGE4-PLAN S6, docs/STAGE4-S6.md): the counters of small update loops.

  python3 ficcus-tests/fbip_check.py --elm bin/elmficNN --elm-home H --safe tools/safe [--only a,b] [--out DIR]

Each check is a small program compiled with `--rc` and built with -DFIC_STATS (gcc -O2). Its counters (allocations, array updates in
place and copied, partial applications taken apart, peak of live objects) must satisfy the bounds given with the check, and it must end
with 0 live objects. The bounds say what "in place" means for the loop: an `Array.set` loop on an array that nobody else holds
allocates nothing per update and copies nothing; a loop that keeps the old array copies every time. The bounds of `push` and of
`Dict.insert` record what is NOT in place yet (see the S6 note): a later improvement lowers them here. Exit status 1 on any failure."""
import argparse, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
STATS = re.compile(r"FIC_STATS: allocs (\d+) live (\d+) peak (\d+) dup (\d+) drop (\d+) free_slow \d+ reuse_hit (\d+) reuse_miss (\d+) inplace (\d+) copied (\d+) pap_steal (\d+)(?: clo_steal (\d+))?(?: vec_copy (\d+))?")

HEAD = '''module Main exposing (main)

import Array exposing (Array)
import Dict exposing (Dict)
import Vector exposing (Vector)


%s


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
                    _ =
                        Debug.log "result" (%s)
                in
                ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
'''

FILL = '''fill : Int -> Int -> Array Int -> Array Int
fill i n a =
    if i >= n then
        a

    else
        fill (i + 1) n (Array.set (modBy (Array.length a) (i * 7)) i a)
'''

VFILL = '''fill : Int -> Int -> Vector Int -> Vector Int
fill i n v =
    if i >= n then
        v

    else
        fill (i + 1) n (Vector.set (modBy (Vector.length v) (i * 7)) i v)


grow : Int -> Int -> Vector Int -> Vector Int
grow i n v =
    if i >= n then
        v

    else
        grow (i + 1) n (Vector.push i v)


sumV : Int -> Int -> Vector Int -> Int
sumV i acc v =
    case Vector.get i v of
        Just x ->
            sumV (i + 1) (acc + x) v

        Nothing ->
            acc
'''

N = 100000
# name, declarations, expression, expected output of Debug.log, bounds (a function of the counters; the text is printed)
CHECKS = [
    ("set-tail", FILL, "Array.foldl (+) 0 (fill 0 %d (Array.repeat 20 0))" % N, None,
     "allocs <= 40 and copied == 0 and inplace >= %d" % N),
    ("set-one-level", FILL, "Array.foldl (+) 0 (fill 0 %d (Array.repeat 700 0))" % N, None,
     "allocs <= 120 and copied == 0 and inplace >= %d" % (2 * N * 0.9)),
    ("set-three-levels", FILL, "Array.foldl (+) 0 (fill 0 %d (Array.initialize 40000 identity))" % N, None,
     "allocs <= 4200 and copied == 0 and inplace >= %d" % (3 * N)),
    ("set-strings", '''fill : Int -> Int -> Array String -> Array String
fill i n a =
    if i >= n then
        a

    else
        fill (i + 1) n (Array.set (modBy (Array.length a) (i * 7)) (String.fromInt i) a)
''', "Array.foldl (\\s n -> n + String.length s) 0 (fill 0 %d (Array.initialize 1100 String.fromInt))" % N, None,
     "allocs <= %d + 1300 and copied == 0" % N),
    ("set-shared", '''keep : Int -> Int -> Array Int -> Int -> Int
keep i n a acc =
    if i >= n then
        acc

    else
        let
            b =
                Array.set (modBy 20 i) i a
        in
        keep (i + 1) n b (acc + Array.length a)
''', "keep 0 1000 (Array.repeat 20 0) 0", "20000", "copied == 1000 and inplace == 0"),
    ("set-global", FILL + '''

table : Array Int
table =
    Array.repeat 20 5
''', "( Array.foldl (+) 0 (fill 0 1000 table), Array.foldl (+) 0 table )", None, "copied == 1 and inplace == 999"),
    ("push", '''grow : Int -> Int -> Array Int -> Array Int
grow i n a =
    if i >= n then
        a

    else
        grow (i + 1) n (Array.push i a)
''', "Array.length (grow 0 %d Array.empty)" % N, str(N),
     "allocs <= %d and copied <= %d" % (N * 1.1, N * 1.05)),       # NOT in place yet: Array.push holds its tail twice (one copy of at most 32 words per push)
    ("pap", FILL.replace("fill", "unused") + '''

put : Array Int -> Int -> Int -> Array Int
put a i v =
    Array.set i v a


bind : (Array Int -> Int -> Int -> Array Int) -> Array Int -> (Int -> Int -> Array Int)
bind g a =
    g a


once : Int -> (Int -> Int -> Array Int) -> Array Int
once i f =
    f (modBy 20 i) i


loop : Int -> Int -> Array Int -> Array Int
loop i n a =
    if i >= n then
        a

    else
        loop (i + 1) n (once i (bind put a))
''', "Array.foldl (+) 0 (loop 0 %d (Array.repeat 20 0))" % N, None,
     "pap_steal == %d and copied == 0 and allocs <= %d + 40" % (N, N)),     # one partial application object per round
    # S7 part 3 (Ficcus.Mono.Twin): a closure object that nobody else holds gives its captured values to the call that consumes it
    ("clo-lambda", FILL.replace("fill", "unused") + """

put : Array Int -> (Int -> Int -> Array Int)
put a =
    \\i v -> Array.set i v a


once : Int -> (Int -> Int -> Array Int) -> Array Int
once i f =
    f (modBy 20 i) i


loop : Int -> Int -> Array Int -> Array Int
loop i n a =
    if i >= n then
        a

    else
        loop (i + 1) n (once i (put a))
""", "Array.foldl (+) 0 (loop 0 %d (Array.repeat 20 0))" % N, None,
     "clo_steal == %d and copied == 0 and inplace == %d and allocs <= %d + 40" % (N, N, N)),     # one closure object per round, the array is never copied
    ("clo-known-pap", FILL.replace("fill", "unused") + """

put : Array Int -> Int -> Int -> Array Int
put a i v =
    Array.set i v a


once : Int -> (Int -> Int -> Array Int) -> Array Int
once i f =
    f (modBy 20 i) i


loop : Int -> Int -> Array Int -> Array Int
loop i n a =
    if i >= n then
        a

    else
        loop (i + 1) n (once i (put a))
""", "Array.foldl (+) 0 (loop 0 %d (Array.repeat 20 0))" % N, None,
     "clo_steal + pap_steal == %d and copied == 0 and inplace == %d and allocs <= %d + 40" % (N, N, N)),     # a partial application of a known function
    ("clo-thunks", """type Stream
    = Stream Int (List Int) (() -> Stream)


from : Int -> List Int -> Stream
from n seen =
    Stream n seen (\\() -> from (n + 1) (n :: List.take 3 seen))


walk : Int -> Int -> Stream -> Int
walk k acc s =
    case s of
        Stream h seen rest ->
            if k <= 0 then
                acc + List.sum seen

            else
                walk (k - 1) (acc + h) (rest ())
""", "walk %d 0 (from 0 [])" % N, str(N * (N - 1) // 2 + (N - 1) + (N - 2) + (N - 3) + (N - 4)),
     "clo_steal == %d and peak <= 40" % N),       # every thunk is called once, by its only holder
    ("clo-shared", FILL.replace("fill", "unused") + """

put : Array Int -> (Int -> Int -> Array Int)
put a =
    \\i v -> Array.set i v a


loop : Int -> Int -> Array Int -> Array Int
loop i n a =
    if i >= n then
        a

    else
        let
            f =
                put a
        in
        loop (i + 1) n (if Array.length (f 0 i) > 0 then f 1 i else a)
""", "Array.foldl (+) 0 (loop 0 %d (Array.repeat 20 0))" % (N // 100), str(N // 100 - 1),
     "copied >= %d and clo_steal <= %d" % (N // 100, N // 100)),     # a closure called twice: the first call must not take the array
    # V1 (docs/STAGE4-V1.md): the flat Vector. `vec_copy` counts the updates that copied a SHARED vector (the diagnostic of decision D3);
    # `copied` also counts the moves of a growing unique vector (about log2 n of them)
    ("vec-set", VFILL, "sumV 0 0 (fill 0 %d (grow 0 1000 (Vector.withCapacity 1000)))" % N, None,
     "allocs <= 4 and copied == 0 and vec_copy == 0 and inplace == %d + 1000" % N),
    ("vec-set-shared", VFILL + '''

keep : Int -> Int -> Vector Int -> Int -> Int
keep i n v acc =
    if i >= n then
        acc

    else
        let
            w =
                Vector.set (modBy 20 i) i v
        in
        keep (i + 1) n w (acc + Vector.length v)
''', "keep 0 1000 (grow 0 20 Vector.empty) 0", "20000", "vec_copy == 1000 and copied >= 1000"),
    ("vec-set-global", VFILL + '''

table : Vector Int
table =
    grow 0 20 Vector.empty
''', "( sumV 0 0 (fill 0 1000 table), sumV 0 0 table )", None, "vec_copy == 1 and inplace >= 999"),
    ("vec-push", VFILL, "Vector.length (grow 0 %d Vector.empty)" % N, str(N),
     "allocs <= 24 and vec_copy == 0 and copied <= 20 and inplace >= %d - 20" % N),       # amortized: 16 moves for 100,000 pushes
    ("vec-swap", VFILL + '''

rev : Int -> Int -> Vector Int -> Vector Int
rev i j v =
    if i >= j then
        v

    else
        rev (i + 1) (j - 1) (Vector.swap i j v)


many : Int -> Vector Int -> Vector Int
many k v =
    if k <= 0 then
        v

    else
        many (k - 1) (rev 0 (Vector.length v - 1) v)
''', "sumV 0 0 (many 200 (grow 0 1000 Vector.empty))", None, "vec_copy == 0 and inplace >= %d" % N),
    ("vec-update-strings", '''bump : Int -> Int -> Vector String -> Vector String
bump i n v =
    if i >= n then
        v

    else
        bump (i + 1) n (Vector.update (modBy (Vector.length v) (i * 7)) (\\s -> String.fromInt (String.length s + i)) v)
''', "String.length (String.concat (Vector.toList (bump 0 %d (Vector.fromList (List.map String.fromInt (List.range 1 100))))))" % N, None,
     "vec_copy == 0 and copied == 0 and inplace == %d and peak <= 420" % N),
    ("vec-update-records", '''type alias R =
    { name : String, n : Int, tags : List Int }


bump : Int -> Int -> Vector R -> Vector R
bump i n v =
    if i >= n then
        v

    else
        bump (i + 1) n (Vector.update (modBy (Vector.length v) (i * 7)) (\\r -> { r | n = r.n + i }) v)
''', "List.sum (List.map .n (Vector.toList (bump 0 %d (Vector.fromList (List.map (\\i -> R (String.fromInt i) i [ i ]) (List.range 1 100))))))" % N, None,
     "vec_copy == 0 and copied == 0 and inplace == %d and peak <= 620 and allocs <= 1000" % N),       # the element is taken out, changed and put back: the vector is never copied
    ("vec-of-vectors", VFILL + '''

rows : Int -> Vector (Vector Int) -> Vector (Vector Int)
rows k vv =
    if k <= 0 then
        vv

    else
        rows (k - 1) (Vector.push (grow 0 50 Vector.empty) vv)


poke : Int -> Int -> Vector (Vector Int) -> Vector (Vector Int)
poke i n vv =
    if i >= n then
        vv

    else
        poke (i + 1) n (Vector.update (modBy 40 i) (Vector.set (modBy 50 (i * 3)) i) vv)
''', "List.sum (List.map (sumV 0 0) (Vector.toList (poke 0 %d (rows 40 Vector.empty))))" % N, None,
     "vec_copy == 0 and inplace >= %d * 2 and allocs <= %d + 400" % (N, N)),       # the inner vector is unique while it is out of the outer one; one closure (the partial application of Vector.set) per round
    # V2: the functions written in Elm on the primitives build their result by `push` into a vector with room, so they allocate the result only
    ("vec-initialize", "", "Vector.length (Vector.initialize %d (\\i -> i * 2))" % N, str(N), "allocs <= 10 and vec_copy == 0 and copied == 0 and inplace >= %d" % N),
    ("vec-repeat-fold", "", "( Vector.foldl (+) 0 (Vector.indexedMap (\\i x -> i + x) (Vector.repeat %d 1)), Vector.foldr (\\x acc -> x + acc) 0 (Vector.repeat 10 2) )" % N,
     "(5000050000,20)", "allocs <= 20 and vec_copy == 0 and copied == 0 and inplace >= %d" % N),
    ("vec-map-rounds", VFILL + '''

rounds : Int -> Vector Int -> Vector Int
rounds k v =
    if k <= 0 then
        v

    else
        rounds (k - 1) (Vector.map (\\x -> x + 1) v)
''', "sumV 0 0 (rounds 100 (grow 0 1000 Vector.empty))", "599500", "allocs <= 140 and vec_copy == 0 and copied <= 12 and inplace >= 100 * 1000"),       # one new vector per map, never a copy
    ("vec-filter", VFILL, "Vector.length (Vector.filter (\\x -> modBy 3 x == 0) (grow 0 %d Vector.empty))" % N, "33334", "allocs <= 60 and vec_copy == 0 and inplace >= %d" % N),
    ("vec-append-loop", VFILL + '''

app : Int -> Int -> Vector Int -> Vector Int
app i n v =
    if i >= n then
        v

    else
        app (i + 1) n (Vector.append v (Vector.singleton i))
''', "Vector.length (app 0 %d Vector.empty)" % 20000, "20000", "vec_copy == 0 and inplace >= 20000"),       # the singletons are the allocations
    ("vec-update-kept", '''keep : Int -> Int -> Vector Int -> Int -> Int
keep i n v acc =
    if i >= n then
        acc

    else
        let
            w =
                Vector.update (modBy 20 i) (\\x -> x + i) v
        in
        keep (i + 1) n w (acc + Vector.length v)
''', "keep 0 1000 (Vector.repeat 20 0) 0", "20000", "vec_copy == 1000 and copied >= 1000"),       # the old vector is used again: every update copies
    ("vec-update-unique", '''bump : Int -> Int -> Vector Int -> Vector Int
bump i n v =
    if i >= n then
        v

    else
        bump (i + 1) n (Vector.update (modBy (Vector.length v) (i * 7)) (\\x -> x + i) v)
''', "Vector.foldl (+) 0 (bump 0 %d (Vector.repeat 100 0))" % N, "4999950000", "allocs <= 20 and vec_copy == 0 and copied == 0 and inplace >= %d" % N),
    ("dict-insert", '''fill : Int -> Int -> Dict Int Int -> Dict Int Int
fill i n d =
    if i >= n then
        d

    else
        fill (i + 1) n (Dict.insert (modBy 1000 (i * 7919)) i d)
''', "Dict.size (fill 0 %d Dict.empty)" % N, "1000",
     "peak <= 1010 and allocs <= %d" % (N * 12)),       # NOT allocation free: `balance` builds a node per level (the cell freed by insertHelp is not passed on)
    ("dict-insert-shared", '''fill : Int -> Int -> Dict Int Int -> Int -> Int
fill i n d acc =
    if i >= n then
        acc

    else
        fill (i + 1) n (Dict.insert (modBy 50 i) i d) (acc + Dict.size d)
''', "fill 0 2000 Dict.empty 0", None, "peak <= 200"),
]


def sh(cmd, cwd=None, env=None):
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, timeout=600)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--safe", required=True)
    ap.add_argument("--only", default=""); ap.add_argument("--out", default=None)
    a = ap.parse_args()
    only = [x for x in a.only.split(",") if x]
    work = a.out or tempfile.mkdtemp(prefix="fbip")
    elm, safe = os.path.abspath(a.elm), os.path.abspath(a.safe)
    bad = 0
    print("%-20s %-5s %10s %10s %10s %10s %10s %9s %8s" % ("check", "", "allocs", "inplace", "copied", "pap_steal", "clo_steal", "vec_copy", "peak"))
    for name, decls, expr, want, bounds in CHECKS:
        if only and name not in only: continue
        d = os.path.join(work, name)
        shutil.rmtree(d, ignore_errors=True); os.makedirs(os.path.join(d, "src"))
        shutil.copy(os.path.join(HERE, "fbip", "elm.json"), d)
        open(os.path.join(d, "src", "Main.fic"), "w").write(HEAD % (decls, expr))
        rc, so, se = sh([safe, elm, "make", "src/Main.fic", "--output=x.c", "--rc"], cwd=d, env=dict(os.environ, ELM_HOME=a.elm_home))
        if rc != 0: print("FAIL %s: compile: %s" % (name, (so + se)[-400:])); bad += 1; continue
        rc, so, se = sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-DFIC_STATS", "-I", os.path.join(ROOT, "targets", "c"), "x.c", "-o", "x", "-lm"], cwd=d)
        if rc != 0: print("FAIL %s: C build: %s" % (name, se[-300:])); bad += 1; continue
        rc, so, se = sh([safe, "./x"], cwd=d)
        m = STATS.search(se)
        if rc != 0 or not m: print("FAIL %s: exit %d %s" % (name, rc, se[-300:])); bad += 1; continue
        allocs, live, peak, dup, drop, reuse_hit, reuse_miss, inplace, copied, pap_steal, clo_steal, vec_copy = [ int(g or 0) for g in m.groups() ]
        got = so.strip().split("result: ", 1)[-1]
        ok = live == 0 and eval(bounds) and (want is None or got == want)
        print("%-20s %-5s %10d %10d %10d %10d %10d %9d %8d   %s%s" % (name, "ok" if ok else "FAIL", allocs, inplace, copied, pap_steal, clo_steal, vec_copy, peak, bounds,
                                                         "" if want is None or got == want else "   output %s, expected %s" % (got, want)))
        bad += 0 if ok else 1
    print("%d failure(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
