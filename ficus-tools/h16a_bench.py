#!/usr/bin/env python3
"""H16a: S1/S2/S3 hand specializations of P1 version A2 (derived from p1b_bench.py).\nOld doc:  Versions, all on the documents of results/p1 (1 MB and 50 MB), the expected line from
results/p1/p1_bench.json:
  Ficus A (JsonComb, the Elm sepBy: oneOf + loop, cons list), A2a (JsonCombS: only sepBy changed: a direct loop, cons list reversed at the end),
  A2 (JsonCombV: sepBy as in the Roc version, a direct loop carrying a Vector, strings as byte vectors, Vector arrays);
  Rust impl Fn (json_comb_impl.rs, loop_once combinator) and impl Fn A2 (json_comb_impl2.rs, sepBy loop), Rust Rc<dyn Fn> (json_comb_dyn.rs) and A2 (json_comb_dyn2.rs);
  Roc: the user's prebuilt binary JsonComb run as `JsonComb x FILE` (it reads the file; its own timer covers the parse only).
Ficus parse = stage 2 - stage 1 (stages as in p1_bench.py), Rust too; counters (FIC_STATS + tag counts) of stage 1 and 2. Serial, `ulimit -v` 6 GB, median of --runs.
  python3 ficus-tools/p1b_bench.py --elm bin/elmficNN --elm-home H --out DIR --p1 results/p1 [--sizes 7500,375000] [--runs 5] [--only a,b]"""
import argparse, json, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import p1_bench as pb  # noqa: E402
from p1_bench import timed, norm, counters, cap, sh, build_ficus, Ctx  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True); ap.add_argument("--p1", required=True)
    ap.add_argument("--sizes", default="7500,375000"); ap.add_argument("--runs", type=int, default=5); ap.add_argument("--only", default="")
    ap.add_argument("--roc", default=os.path.expanduser("~/Documents/RocStuff/JsonComb"))
    a = ap.parse_args()
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    x = Ctx(); x.elm, x.elm_home = a.elm, a.elm_home
    only = set(filter(None, a.only.split(",")))
    os.makedirs(a.out, exist_ok=True); work = os.path.join(a.out, "work"); rf = os.path.join(a.out, "h16a_bench.json")
    res = json.load(open(rf)) if os.path.exists(rf) else {}
    base = json.load(open(os.path.join(a.p1, "p1_bench.json")))
    save = lambda: json.dump(res, open(rf, "w"), indent=1)
    for n in [int(s) for s in a.sizes.split(",")]:
        tag = "1mb" if n < 100000 else "50mb"; exp = base[tag]["expected"]; inp = os.path.abspath(os.path.join(a.p1, "json_%s.json" % tag))
        r = res.setdefault(tag, {"records": n, "expected": exp}); os.makedirs(work, exist_ok=True)

        def measure(name, mk, stages=(0, 1, 2)):
            if only and name not in only: return
            e = r.setdefault(name, {})
            for st in stages:
                t, rss, out = timed(mk(st), a.runs)
                if t is None: e["stage%d" % st] = {"error": out}; print(tag, name, st, "FAILED", out, flush=True); continue
                line = norm(out); ok = (line == exp) if st == 2 else line.endswith(str(base[tag]["bytes"]))
                e["stage%d" % st] = {"ms": t, "rss_mb": rss, "ok": ok, "line": line}
                print(tag, name, "stage", st, "%.1f ms" % t, "%.1f MB" % rss, "OK" if ok else "MISMATCH " + line, flush=True)
            if "stage1" in e and "stage2" in e and "ms" in e["stage1"] and "ms" in e["stage2"]: e["parse_ms"] = e["stage2"]["ms"] - e["stage1"]["ms"]
            save()

        for mod, name in (("JsonCombV", "ficus_A2"), ("JsonS1", "ficus_S1"), ("JsonS2", "ficus_S2"), ("JsonS3", "ficus_S3"), ("JsonHand", "ficus_C")):
            if only and name not in only: continue
            exes = {st: build_ficus(x, mod, n, st, False, work) for st in (0, 1, 2)}
            measure(name, lambda st: [exes[st]])
            cs = {}
            for st in (1, 2):
                p = subprocess.run([build_ficus(x, mod, n, st, True, work)], capture_output=True, preexec_fn=cap)
                cs[st] = counters((p.stdout + p.stderr).decode("utf-8", "replace"))
            r[name]["counters"] = cs; save(); print(tag, name, "counters stage 2:", cs[2], flush=True)
            shutil.rmtree(work, ignore_errors=True); os.makedirs(work, exist_ok=True)
        for name, src in (("rust_impl", "json_comb_impl.rs"),):
            if only and name not in only: continue
            exe = os.path.join(work, name)
            rc, msg = sh(["rustc", "--edition", "2021", "-C", "opt-level=3", "-A", "warnings", os.path.join(pb.RS, src), "-o", exe])
            if rc != 0: raise SystemExit("rustc " + src + ": " + msg[-500:])
            measure(name, lambda st: [exe, str(n), str(st)])
        if False:
            t, rss, out = timed([a.roc, "x", inp], a.runs)   # whole process (reads the file) ...
            ms = []
            for _ in range(a.runs):
                p = subprocess.run([a.roc, "x", inp], capture_output=True, preexec_fn=cap); m = re.search(r"\(parse (\d+) ms\)", p.stdout.decode())
                ms.append(int(m.group(1))); line = norm(p.stdout.decode().replace(" (parse", "\n(parse"))
            import statistics
            r["roc"] = {"wall_ms": t, "rss_mb": rss, "parse_ms": statistics.median(ms), "parse_ms_runs": ms, "ok": line == exp, "line": line}
            save(); print(tag, "roc", r["roc"], flush=True)
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
