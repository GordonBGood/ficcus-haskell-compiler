#!/usr/bin/env python3
"""H16 stage 1 measurement (docs/H16-DESIGN.md 3.3): P1 A2 (JsonCombV) with the Known pass off (FICCUS_NO_KNOWN=1) and on, in one session.
parse = stage 2 - stage 1 (median of --runs); counters from -DFIC_STATS builds; C text size, .text size, compile time of the Ficcus compiler.
Uses p1_bench.py of the bench/h16a worktree (the module JsonCombV and the P1 harness live there).

  python3 ficcus-tools/h16_known_bench.py --elm bin/elmficK3 --elm-home H --h16a DIR_OF_h16a_WORKTREE --out DIR [--sizes 7500,375000] [--runs 5]"""
import argparse, json, os, shutil, subprocess, sys, time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--h16a", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--sizes", default="7500,375000"); ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--mod", default="JsonCombV"); ap.add_argument("--modes", default="off,on")
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(a.h16a, "ficcus-tools"))
    import p1_bench as pb
    from p1_bench import build_ficcus, counters, norm, timed, Ctx
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    x = Ctx(); x.elm, x.elm_home = os.path.abspath(a.elm), os.path.abspath(a.elm_home)
    base = json.load(open(os.path.join(a.h16a, "..", "results", "p1", "p1_bench.json")))
    os.makedirs(a.out, exist_ok=True); res = {}
    for n in [int(s) for s in a.sizes.split(",")]:
        tag = "1mb" if n < 100000 else "50mb"; exp = base[tag]["expected"]; r = res.setdefault(tag, {"expected": exp})
        for mode in a.modes.split(","):
            if mode == "off": os.environ["FICCUS_NO_KNOWN"] = "1"
            else: os.environ.pop("FICCUS_NO_KNOWN", None)
            work = os.path.join(a.out, "work_%s_%s" % (tag, mode)); shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
            t0 = time.time(); exes = {st: build_ficcus(x, a.mod, n, st, False, work) for st in (1, 2)}; build_s = time.time() - t0
            m = {"build_s": build_s}
            ts = {}
            for st in (1, 2):
                t, rss, out = timed([exes[st]], a.runs)
                line = norm(out); ok = (line == exp) if st == 2 else True
                ts[st] = t; m["stage%d" % st] = {"ms": t, "rss_mb": rss, "ok": ok, "line": line}
            m["parse_ms"] = ts[2] - ts[1]
            cs = {}
            for st in (1, 2):
                p = subprocess.run([build_ficcus(x, a.mod, n, st, True, work)], capture_output=True, preexec_fn=pb.cap)
                cs[st] = counters((p.stdout + p.stderr).decode("utf-8", "replace"))
            m["counters_parse"] = {k: cs[2].get(k, 0) - cs[1].get(k, 0) for k in ("allocs", "dup", "drop", "closure", "pap", "vector", "string")}
            d = os.path.join(work, "fic_%s_%d_2" % (a.mod, n))
            m["c_bytes"] = os.path.getsize(os.path.join(d, "x.c"))
            sz = subprocess.run(["size", exes[2]], capture_output=True, text=True).stdout.split("\n")[1].split()
            m["text_bytes"] = int(sz[0])
            r[mode] = m; print(tag, mode, json.dumps(m), flush=True)
            shutil.rmtree(work, ignore_errors=True)
        if "off" in r and "on" in r:
            r["speedup"] = r["off"]["parse_ms"] / r["on"]["parse_ms"]; print(tag, "speedup %.2f" % r["speedup"], flush=True)
        json.dump(res, open(os.path.join(a.out, "h16_known_bench.json"), "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
