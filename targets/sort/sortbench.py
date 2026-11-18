#!/usr/bin/env python3
"""H21 Ficcus level sort benchmark. One program per (pattern, operation), data from the LCG of bench_kernel.c, 1e6 Int; the wall time of the
process is measured (median of 5) and the time of the program that only generates the list ("gen") is subtracted, so list generation is
excluded. Operations: fromList (List to Vector), toList (Vector to List, fromList subtracted), vsort (Vector.sort of a unique vector, in place;
fromList subtracted), lsort (List.sort), lsortWith (List.sortWith compare), lsortBy (List.sortBy (\\x -> x)).
Split of List.sort: in = fromList, sort = vsort - fromList, out = lsort - vsort.
  python3 targets/sort/sortbench.py --elm bin/elmficS2 --elm-home H [--runs 5]"""
import argparse, os, shutil, statistics, subprocess, sys, time
ap = argparse.ArgumentParser(); ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True)
ap.add_argument("--runs", type=int, default=5); ap.add_argument("--work", default="/home/gordon/claude-tmp/sortbench")
a = ap.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
env = dict(os.environ, ELM_HOME=os.path.abspath(a.elm_home)); elm = os.path.abspath(a.elm)
PAT = {"random": "lcg s", "sorted": "k", "reversed": "n - k", "swap10": "(if modBy 10 (lcg s) == 0 then lcg s else k)", "dups": "modBy 100 (lcg s)"}
OPS = {
 "gen": "sum xs",
 "fromList": "let v = Vector.fromList xs in Vector.length v + (Maybe.withDefault 0 (Vector.get 0 v))",
 "toList": "sum (Vector.toList (Vector.fromList xs))",
 "vsort": "let v = Vector.sort (Vector.fromList xs) in Vector.length v + (Maybe.withDefault 0 (Vector.get 0 v))",
 "lsort": "sum (List.sort xs)",
 "lsortWith": "sum (List.sortWith compare xs)",
 "lsortBy": "sum (List.sortBy (\\x -> x) xs)",
}
TEMPLATE = '''module Main exposing (main)

import Vector


lcg : Int -> Int
lcg s =
    modBy 2147483648 (s * 1103515245 + 12345)


gen : Int -> Int -> Int -> List Int -> List Int
gen n k s acc =
    if k >= n then
        List.reverse acc

    else
        let
            s2 =
                lcg s
        in
        gen n (k + 1) s2 (@PAT@ :: acc)


sum : List Int -> Int
sum xs =
    List.foldl (\\x a -> modBy 1000000007 (a * 31 + x)) 7 xs


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
                    n =
                        1000000

                    xs =
                        gen n 0 12345 []

                    _ =
                        Debug.log "r" (@OP@)
                in
                ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
'''
ELMJSON = open(os.path.join(HERE, "..", "..", "ficcus-tests", "ficc-exe-rc.sh")).read().split("<<'JSON'\n")[1].split("\nJSON")[0]
res = {}
shutil.rmtree(a.work, ignore_errors=True)
for pat, pe in PAT.items():
    for op, oe in OPS.items():
        d = f"{a.work}/{pat}_{op}"; os.makedirs(d + "/src")
        open(d + "/elm.json", "w").write(ELMJSON)
        src = TEMPLATE.replace("@PAT@", pe).replace("@OP@", oe)
        # the lcg values are used as the elements; "k" and "n" are the index and the size
        src = src.replace("(@", "(").replace("1000000\n", "1000000\n")
        src = src.replace("gen n (k + 1) s2 (", "gen n (k + 1) s2 (")
        open(d + "/src/Main.fic", "w").write(src)
        r = subprocess.run([elm, "make", "src/Main.fic", "--output=x.c", "--rc"], cwd=d, env=env, capture_output=True, text=True)
        if r.returncode: print("compile failed", pat, op, r.stdout[-400:], r.stderr[-400:]); sys.exit(1)
        r = subprocess.run(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-I", W + "/targets/c", "x.c", "-o", "x", "-lm"], cwd=d, capture_output=True, text=True)
        if r.returncode: print("cc failed", pat, op, r.stderr[-400:]); sys.exit(1)
        ts = []
        for _ in range(a.runs):
            t = time.perf_counter(); p = subprocess.run(["./x"], cwd=d, capture_output=True, text=True); ts.append((time.perf_counter() - t) * 1e3)
            if p.returncode: print("run failed", pat, op, p.stderr[-300:]); sys.exit(1)
        res[(pat, op)] = statistics.median(ts)
print("%-9s %7s %9s %9s %9s %9s %9s %9s %9s" % ("pattern", "gen", "fromList", "toList", "vsort", "lsort", "lsortWith", "lsortBy", "in/sort/out"))
for pat in PAT:
    g = res[(pat, "gen")]; f = res[(pat, "fromList")] - g; tl = res[(pat, "toList")] - res[(pat, "fromList")]
    vs = res[(pat, "vsort")] - res[(pat, "fromList")]; ls = res[(pat, "lsort")] - g
    out = res[(pat, "lsort")] - res[(pat, "vsort")]
    print("%-9s %7.1f %9.1f %9.1f %9.1f %9.1f %9.1f %9.1f %5.0f/%3.0f/%3.0f" % (pat, g, f, tl, vs, ls, res[(pat, "lsortWith")] - g, res[(pat, "lsortBy")] - g, f, vs, out))
