#!/usr/bin/env python3
"""hamnth with the BigInt package: whole programs (digit vector multiply of the target vs the package) at the millionth and the
billionth Hamming number, and the final conversion alone (the exponent triple to decimal, N times).  Median of --runs."""
import argparse, os, re, statistics, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import bench

ap = argparse.ArgumentParser()
ap.add_argument("--runs", type=int, default=5)
ap.add_argument("--work", default=None)
ap.add_argument("--json", default=None)
a = ap.parse_args()
work = a.work or tempfile.mkdtemp(prefix="ham-")
os.makedirs(work, exist_ok=True)
bb = here + "/../bbuild.sh"
out = {}


def build(src, name):
    r = subprocess.run([bb, src, work + "/" + name, "fast"], capture_output=True, text=True)
    if r.returncode:
        print("build failed", name, r.stdout[-1500:], r.stderr[-1500:])
        sys.exit(1)
    return work + "/" + name


def run(name, exe, text_ok):
    ts, rss = [], []
    for _ in range(a.runs):
        m = bench.timed([exe], timeout=200)
        assert m["code"] == 0 and text_ok in m["out"], (name, m["out"][:300], m["err"][:300])
        ts.append(m["sec"]); rss.append(m["rss"])
    out[name] = dict(median=statistics.median(ts), min=min(ts), max=max(ts), rss_kb=max(rss))
    print("%-22s median %.3fs (min %.3f max %.3f) rss %d MB" % (name, out[name]["median"], min(ts), max(ts), max(rss) // 1024), flush=True)


print("load average at start:", open("/proc/loadavg").read().strip())
for tgt, label, ndig in ((1000000, "1e6", 84), (1000000000, "1e9", 0)):
    for v in ("ham_old", "ham_big"):
        s = open("%s/ham/%s.fic" % (here, v)).read()
        s = re.sub(r"(?m)^    1000000$", "    %d" % tgt, s)
        p = "%s/%s_%s.fic" % (work, v, label)
        open(p, "w").write(s)
        run("%s_%s" % (v, label), build(p, "%s_%s" % (v, label)), "Hamming number %d" % tgt)
N = 20000
for label, (i, j, k) in (("1e6", (55, 47, 64)), ("1e9", (1334, 335, 404))):
    n = N if label == "1e6" else 2000
    for v in ("conv_old", "conv_big"):
        s = open("%s/ham/%s.fic" % (here, v)).read()
        for key, val in (("@N@", n), ("@I@", i), ("@J@", j), ("@K@", k)):
            s = s.replace(key, str(val))
        p = "%s/%s_%s.fic" % (work, v, label)
        open(p, "w").write(s)
        run("%s_%s_x%d" % (v, label, n), build(p, "%s_%s" % (v, label)), "conv:")
if a.json:
    import json
    json.dump(out, open(a.json, "w"), indent=1)
