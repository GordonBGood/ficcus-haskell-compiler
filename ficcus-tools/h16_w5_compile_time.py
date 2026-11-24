#!/usr/bin/env python3
"""H16 W5: compile time (wall, --rc, median of N) of the 16 suite programs and of P1 A2 (1 MB config), pass off (FICCUS_NO_KNOWN=1), 1a only
(FICCUS_NO_IDENT=1) and the defaults (1a + 1c).   python3 h16_w5_compile_time.py --elm BIN --elm-home H --h16a DIR [--runs 5]"""
import argparse, json, os, shutil, statistics, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__)); TESTS = os.path.join(HERE, "..", "ficcus-tests")
MODES = [("off", {"FICCUS_NO_KNOWN": "1"}), ("w5", {"FICCUS_S2_NO_SPINE": "1", "FICCUS_NO_INLINE2": "1"}), ("on", {})]   # W6: w5 = the W6 switches off

def timeit(cmd, cwd, env, runs):
    ts = []
    for _ in range(runs):
        t = time.perf_counter(); p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True); ts.append(time.perf_counter() - t)
        if p.returncode != 0: raise SystemExit("compile failed: %s" % p.stderr[-300:])
    return statistics.median(ts)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--h16a", required=True)
    ap.add_argument("--runs", type=int, default=5); a = ap.parse_args()
    sys.path.insert(0, os.path.join(a.h16a, "ficcus-tools")); import p1_bench as pb
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR")); out = os.path.join(tmp, "x.c")
    base = dict(os.environ, ELM_HOME=os.path.abspath(a.elm_home)); elm = os.path.abspath(a.elm)
    suite = json.load(open(os.path.join(TESTS, "runall", "suite.json")))["tests"]
    res = {}
    for t in suite:
        src = os.path.normpath(os.path.join(TESTS, "runall", t["fic"])); d = os.path.dirname(src)
        while not os.path.exists(os.path.join(d, "elm.json")): d = os.path.dirname(d)
        res[t["name"]] = {m: timeit([elm, "make", os.path.relpath(src, d), "--output=" + out, "--rc"], d, dict(base, **e), a.runs) for m, e in MODES}
    d = os.path.join(tmp, "a2"); shutil.copytree(pb.P1, d); pb.set_config(d, 7500, 2)
    res["A2"] = {m: timeit([elm, "make", "src/JsonCombV.elm", "--output=" + out, "--rc"], d, dict(base, **e), a.runs) for m, e in MODES}
    for n, r in res.items(): print("%-22s off %6.3f s   w5 %6.3f s (%.2fx)   on %6.3f s (%.2fx)" % (n, r["off"], r["w5"], r["w5"] / r["off"], r["on"], r["on"] / r["off"]))
    s = {m: sum(r[m] for n, r in res.items() if n != "A2") for m, _ in MODES}
    print("suite total            off %6.3f s   w5 %6.3f s (%.2fx)   on %6.3f s (%.2fx)" % (s["off"], s["w5"], s["w5"] / s["off"], s["on"], s["on"] / s["off"]))
    shutil.rmtree(tmp)
main()
