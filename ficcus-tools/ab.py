#!/usr/bin/env python3
"""Alternating A/B timing of two builds of the same program: DIR/before_<name> against DIR/after_<name>.

  python3 tools/ab.py DIR name [name ...]      (each executable is run 5 times, alternately)
Prints the medians and minima and the ratio after/before."""
import statistics, subprocess, sys, time, resource, os

# a program that never frees (the no-RC build of a large program) must fail cleanly, not be OOM-killed: cap of 6 GB (BENCH_CAP_MB)
def _cap():
    c = int(os.environ.get("BENCH_CAP_MB", "6144")) * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (c, c))


def wall(exe):
    t = time.perf_counter(); subprocess.run([exe], capture_output=True, preexec_fn=_cap); return (time.perf_counter() - t) * 1000

d, names = sys.argv[1], sys.argv[2:]
for n in names:
    a, b = [], []
    for _ in range(5):
        a.append(wall("%s/before_%s" % (d, n))); b.append(wall("%s/after_%s" % (d, n)))
    print("%-18s before median %9.2f min %9.2f   after median %9.2f min %9.2f   ratio(median) %.3f  ratio(min) %.3f"
          % (n, statistics.median(a), min(a), statistics.median(b), min(b), statistics.median(b) / statistics.median(a), min(b) / min(a)), flush=True)
