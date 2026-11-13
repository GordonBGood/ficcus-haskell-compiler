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
STATS = re.compile(r"FIC_STATS: allocs (\d+) live (\d+) peak (\d+) dup (\d+) drop (\d+) free_slow \d+ reuse_hit (\d+) reuse_miss (\d+) inplace (\d+) copied (\d+) pap_steal (\d+)")

HEAD = '''module Main exposing (main)

import Array exposing (Array)
import Dict exposing (Dict)


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
    print("%-20s %-5s %10s %10s %10s %10s %8s" % ("check", "", "allocs", "inplace", "copied", "pap_steal", "peak"))
    for name, decls, expr, want, bounds in CHECKS:
        if only and name not in only: continue
        d = os.path.join(work, name)
        shutil.rmtree(d, ignore_errors=True); os.makedirs(os.path.join(d, "src"))
        shutil.copy(os.path.join(HERE, "fbip", "elm.json"), d)
        open(os.path.join(d, "src", "Main.fic"), "w").write(HEAD % (decls, expr))
        rc, so, se = sh([safe, elm, "make", "src/Main.fic", "--output=x.c", "--rc"], cwd=d, env=dict(os.environ, ELM_HOME=a.elm_home, **({"FICCUS_STEAL_RULE": "1"} if name == "pap" else {})))  # the called-once rule is off by default since S7 part 2
        if rc != 0: print("FAIL %s: compile: %s" % (name, (so + se)[-400:])); bad += 1; continue
        rc, so, se = sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-DFIC_STATS", "-I", os.path.join(ROOT, "targets", "c"), "x.c", "-o", "x", "-lm"], cwd=d)
        if rc != 0: print("FAIL %s: C build: %s" % (name, se[-300:])); bad += 1; continue
        rc, so, se = sh([safe, "./x"], cwd=d)
        m = STATS.search(se)
        if rc != 0 or not m: print("FAIL %s: exit %d %s" % (name, rc, se[-300:])); bad += 1; continue
        allocs, live, peak, dup, drop, reuse_hit, reuse_miss, inplace, copied, pap_steal = map(int, m.groups())
        got = so.strip().split("result: ", 1)[-1]
        ok = live == 0 and eval(bounds) and (want is None or got == want)
        print("%-20s %-5s %10d %10d %10d %10d %8d   %s%s" % (name, "ok" if ok else "FAIL", allocs, inplace, copied, pap_steal, peak, bounds,
                                                         "" if want is None or got == want else "   output %s, expected %s" % (got, want)))
        bad += 0 if ok else 1
    print("%d failure(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
