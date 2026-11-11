#!/usr/bin/env python3
"""Time the Ficcus builds of the four numeric programs (nbody, mandel, spectral, fannkuch) with gcc and clang.

  python3 tools/bench.py --elm bin/elmficNN --tag before --out DIR [--elm-home H] [--rc] [--runs 5]

Compiles ficcus-haskell-compiler/ficcus-tests/<test>/src/*.fic to DIR/<tag>_<test>.c (with --rc when asked), builds it with
both C compilers (-O2 -ffp-contract=off) and prints the median and minimum wall time of --runs runs. Compare two tags with
tools/ab.py (alternating runs, which cancels machine noise)."""
import argparse, json, os, re, statistics, subprocess, time, resource

ROOT = os.environ.get("FICCUS_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))      # the workspace (tools/ is a symlink to this directory)
if not os.path.isdir(os.path.join(ROOT, "bin")): ROOT = os.path.dirname(ROOT)                        # run by its real path: the repository is one level down
TESTS = {"nbody": "nbody/src/NBody.fic", "mandel": "mandel/src/Mandelbrot.fic", "spectral": "spectral/src/Spectral.fic",
         "fannkuch": "fannkuch/src/Fannkuch.fic"}

# a program that never frees (the no-RC build of a large program) must fail cleanly, not be OOM-killed: cap of 6 GB (BENCH_CAP_MB)
def _cap():
    c = int(os.environ.get("BENCH_CAP_MB", "6144")) * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (c, c))


def wall(exe):
    t = time.perf_counter(); subprocess.run([exe], capture_output=True, preexec_fn=_cap); return (time.perf_counter() - t) * 1000

# the S4 ownership rules (docs/STAGE4-S4.md): environment of the compiler run
SETTINGS = {"default": {}, "s3rule": {"FICCUS_BORROW_S3": "1"}, "proj": {"FICCUS_BORROW_PROJ": "1"}, "hybrid": {}, "reuse": {"FICCUS_BORROW_REUSE": "1"}, "nospec": {"FICCUS_NO_SPEC": "1"}, "noreuse": {"FICCUS_NO_REUSE": "1"}}
STATS = re.compile(r"FIC_STATS: allocs (\d+) live (\d+) peak (\d+) dup (\d+) drop (\d+) free_slow \d+ reuse_hit (\d+) reuse_miss (\d+)")


def suite_mode(a):
    """All 16 programs of ficcus-tests/runall/suite.json, serial, capped: counters (a -DFIC_STATS build, one run) and the time (a plain build,
    median of --runs) for each setting. The setting `s3` is the S3 compiler (--s3-elm). Prints one table and writes DIR/suite_bench.json."""
    suite = json.load(open(os.path.join(ROOT, "ficcus-haskell-compiler", "ficcus-tests", "runall", "suite.json")))["tests"]
    only = [x for x in a.only.split(",") if x]
    settings = [x for x in a.settings.split(",") if x]
    ficc = os.path.join(ROOT, "ficcus-haskell-compiler", "ficcus-tests", "ficc")
    rows = {}
    print("%-22s %-8s %11s %11s %11s %11s %10s %9s" % ("program", "setting", "dups", "drops", "allocs", "reuses", "peak live", "ms"), flush=True)
    for t in suite:
        n = t["name"]
        if only and n not in only: continue
        for st in settings:
            elm = a.s3_elm if st == "s3" else a.elm
            env = dict(os.environ, FICCUS_ELM=os.path.abspath(elm), FICCUS_FLAGS="--rc", **({} if st == "s3" else SETTINGS[st]))
            if a.elm_home: env["ELM_HOME"] = a.elm_home
            src = os.path.normpath(os.path.join(ROOT, "ficcus-haskell-compiler", "ficcus-tests", "runall", t["fic"]))
            c = os.path.join(a.out, "%s_%s.c" % (n, st))
            subprocess.run([ficc, src, "-o", c], check=True, env=env, capture_output=True)
            flags = ["-std=c99", "-O2", "-ffp-contract=off", "-w", "-I", os.path.join(ROOT, "targets", "c")]
            exe_s, exe_t = os.path.join(a.out, "%s_%s_stats" % (n, st)), os.path.join(a.out, "%s_%s_time" % (n, st))
            subprocess.run([a.cc] + flags + ["-DFIC_STATS", c, "-o", exe_s, "-lm"], check=True)
            subprocess.run([a.cc] + flags + [c, "-o", exe_t, "-lm"], check=True)
            p = subprocess.run([exe_s], capture_output=True, text=True, preexec_fn=_cap)
            m = STATS.search(p.stderr)
            if p.returncode != 0 or not m: print("%-22s %-8s FAILED (exit %d) %s" % (n, st, p.returncode, p.stderr[-120:]), flush=True); continue
            allocs, live, peak, dup, drop, hit, miss = (int(x) for x in m.groups())
            times = [wall(exe_t) for _ in range(a.runs)]
            rows.setdefault(n, {})[st] = dict(dups=dup, drops=drop, allocs=allocs, reuses=hit, reuse_miss=miss, peak=peak, live=live, ms=statistics.median(times), ms_min=min(times))
            print("%-22s %-8s %11d %11d %11d %11d %10d %9.1f" % (n, st, dup, drop, allocs, hit, peak, statistics.median(times)), flush=True)
    json.dump(rows, open(os.path.join(a.out, "suite_bench.json"), "w"), indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--tag", default="x"); ap.add_argument("--out", required=True)
    ap.add_argument("--elm-home", default=os.environ.get("ELM_HOME")); ap.add_argument("--rc", action="store_true")
    ap.add_argument("--runs", type=int, default=5); ap.add_argument("--only", default="")
    ap.add_argument("--suite", action="store_true", help="all 16 suite programs, counters and time, for each of --settings")
    ap.add_argument("--settings", default="default,proj,reuse"); ap.add_argument("--s3-elm", default=None, help="the S3 compiler for the setting s3"); ap.add_argument("--cc", default="gcc")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.suite: return suite_mode(a)
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
