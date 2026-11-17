#!/usr/bin/env python3
"""Karatsuba threshold sweep: patched copies of the package with karatsubaLimbs = T, benchmarks mulbig and pow3 (and a mid size
product), median of N runs.   python3 kara_sweep.py [--thresholds 16,24,...] [--runs 5] [--work DIR]"""
import argparse, os, re, shutil, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--thresholds", default="12,16,24,32,40,48,64,96,128,100000")
ap.add_argument("--runs", type=int, default=5)
ap.add_argument("--only", default="mulbig,pow3,fact")
ap.add_argument("--work", default=None)
a = ap.parse_args()
work = a.work or tempfile.mkdtemp(prefix="kara-")
src = open(here + "/../src/BigInt.fic").read()
for t in a.thresholds.split(","):
    d = "%s/k%s/src" % (work, t)
    os.makedirs(d, exist_ok=True)
    s2 = re.sub(r"(karatsubaLimbs _ =\n    )\d+", r"\g<1>%s" % t, src)
    assert s2 != src or t == "40"
    open(d + "/BigInt.fic", "w").write(s2)
    print("threshold", t, flush=True)
    subprocess.run([sys.executable, here + "/bench.py", "--runs", str(a.runs), "--impls", "ficcus", "--only", a.only, "--work", "%s/k%s/w" % (work, t)],
                   env=dict(os.environ, BB_SRC=d))
