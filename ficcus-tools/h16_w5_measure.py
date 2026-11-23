#!/usr/bin/env python3
"""H16 stage 2 experiments: P1 A2 (JsonCombV) parse time and counters for one compiler binary and one environment setting.
Like h16_known_bench.py (same harness: p1_bench.py of the bench/h16a worktree), but the mode is any set of environment variables.

  python3 ficcus-tools/h16_s2_measure.py --elm BIN --elm-home H --h16a DIR --out DIR [--sizes 7500] [--runs 5] [--env K=V ...] [--label X]"""
import argparse, json, os, shutil, subprocess, sys, time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--h16a", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--sizes", default="7500"); ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--mod", default="JsonCombV"); ap.add_argument("--env", action="append", default=[]); ap.add_argument("--label", default="run")
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(a.h16a, "ficcus-tools"))
    import p1_bench as pb
    from p1_bench import build_ficcus, counters, norm, timed, Ctx
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    for kv in a.env: k, v = kv.split("=", 1); os.environ[k] = v
    x = Ctx(); x.elm, x.elm_home = os.path.abspath(a.elm), os.path.abspath(a.elm_home)
    base = json.load(open(os.path.join(a.h16a, "..", "results", "p1", "p1_bench.json")))
    os.makedirs(a.out, exist_ok=True); res = {}
    for n in [int(s) for s in a.sizes.split(",")]:
        tag = "1mb" if n < 100000 else "50mb"; exp = base[tag]["expected"]
        work = os.path.join(a.out, "work_%s_%s" % (a.label, tag)); shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
        exes = {st: build_ficcus(x, a.mod, n, st, False, work) for st in (1, 2)}
        m = {}; ts = {}
        for st in (1, 2):
            t, rss, out = timed([exes[st]], a.runs)
            ok = (norm(out) == exp) if st == 2 else True
            ts[st] = t; m["stage%d" % st] = {"ms": t, "rss_mb": rss, "ok": ok}
        m["parse_ms"] = ts[2] - ts[1]
        cs = {}
        for st in (1, 2):
            p = subprocess.run([build_ficcus(x, a.mod, n, st, True, work)], capture_output=True, preexec_fn=pb.cap)
            cs[st] = counters((p.stdout + p.stderr).decode("utf-8", "replace"))
        m["counters_parse"] = {k: cs[2].get(k, 0) - cs[1].get(k, 0) for k in ("allocs", "dup", "drop", "closure", "pap", "vector", "string")}
        d = os.path.join(work, "fic_%s_%d_2" % (a.mod, n))
        m["c_bytes"] = os.path.getsize(os.path.join(d, "x.c"))
        m["text_bytes"] = int(subprocess.run(["size", exes[2]], capture_output=True, text=True).stdout.split("\n")[1].split()[0])
        res[tag] = m; print(a.label, tag, json.dumps(m), flush=True)
        shutil.rmtree(work, ignore_errors=True)
    json.dump(res, open(os.path.join(a.out, "s2_%s.json" % a.label), "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
