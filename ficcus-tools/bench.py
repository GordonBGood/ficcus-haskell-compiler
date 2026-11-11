#!/usr/bin/env python3
"""Time the Ficcus builds of the four numeric programs (nbody, mandel, spectral, fannkuch) with gcc and clang.

  python3 tools/bench.py --elm bin/elmficNN --tag before --out DIR [--elm-home H] [--rc] [--runs 5]

Compiles ficcus-haskell-compiler/ficcus-tests/<test>/src/*.fic to DIR/<tag>_<test>.c (with --rc when asked), builds it with
both C compilers (-O2 -ffp-contract=off) and prints the median and minimum wall time of --runs runs. Compare two tags with
tools/ab.py (alternating runs, which cancels machine noise)."""
import argparse, os, statistics, subprocess, time, resource

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = {"nbody": "nbody/src/NBody.fic", "mandel": "mandel/src/Mandelbrot.fic", "spectral": "spectral/src/Spectral.fic",
         "fannkuch": "fannkuch/src/Fannkuch.fic"}

# a program that never frees (the no-RC build of a large program) must fail cleanly, not be OOM-killed: cap of 6 GB (BENCH_CAP_MB)
def _cap():
    c = int(os.environ.get("BENCH_CAP_MB", "6144")) * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (c, c))


def wall(exe):
    t = time.perf_counter(); subprocess.run([exe], capture_output=True, preexec_fn=_cap); return (time.perf_counter() - t) * 1000

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--tag", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--elm-home", default=os.environ.get("ELM_HOME")); ap.add_argument("--rc", action="store_true")
    ap.add_argument("--runs", type=int, default=5); ap.add_argument("--only", default="")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    env = dict(os.environ, FICCUS_ELM=os.path.abspath(a.elm))
    if a.elm_home: env["ELM_HOME"] = a.elm_home
    if a.rc: env["FICCUS_FLAGS"] = "--rc"
    only = [x for x in a.only.split(",") if x]
    for cc in ("gcc", "clang"):
        for n, f in TESTS.items():
            if only and n not in only: continue
            c = os.path.join(a.out, "%s_%s.c" % (a.tag, n)); exe = os.path.join(a.out, "%s_%s_%s" % (a.tag, n, cc))
            subprocess.run([os.path.join(ROOT, "ficcus-haskell-compiler/ficcus-tests/ficc"),
                            os.path.join(ROOT, "ficcus-haskell-compiler/ficcus-tests", f), "-o", c], check=True, env=env, capture_output=True)
            subprocess.run([cc, "-std=c99", "-O2", "-ffp-contract=off", "-w", c, "-o", exe, "-lm"], check=True)
            t = [wall(exe) for _ in range(a.runs)]
            print("%-5s %-9s ficcus %9.2f ms  min %9.2f" % (cc, n, statistics.median(t), min(t)), flush=True)

if __name__ == "__main__":
    main()
