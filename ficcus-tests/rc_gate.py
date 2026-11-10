#!/usr/bin/env python3
"""The reference counting gate on the 16 programs of the acceptance suite (STAGE4-PLAN section 10, S2).

  python3 ficcus-tests/rc_gate.py --elm bin/elmficNN --elm-home H [--only a,b] [--san] [--out DIR]

For every test of ficcus-tests/runall/suite.json: the .fic program is compiled twice (without and with --rc), both are built with
-DFIC_STATS and gcc -O2, run, and their output (normalized as run_all.py does) is compared with the golden output from Elm. With
--rc the run must end with 0 live objects. With --san the --rc program is also built with AddressSanitizer + UBSan (malloc, no
pool, leak detection on) and run: no leak, no use after free, no double free.
Prints one line per test with the counters (allocations, peak live objects, dups, drops) of both builds. Exit status 1 on any FAIL."""
import argparse, os, re, subprocess, sys, json, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RUNALL = os.path.join(HERE, "runall")
sys.path.insert(0, RUNALL)
import run_all  # noqa: E402   (normalize_c, the output normalization of the suite)

STATS = re.compile(r"FIC_STATS: allocs (\d+) live (\d+) peak (\d+) dup (\d+) drop (\d+)")
FLAGS = ["-std=c99", "-ffp-contract=off", "-w", "-DFIC_STATS", "-I", os.path.join(ROOT, "targets", "c")]


def sh(cmd, env=None, timeout=900):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--only", default="")
    ap.add_argument("--san", action="store_true"); ap.add_argument("--out", default=None)
    ap.add_argument("--cc", default="gcc")
    a = ap.parse_args()
    out = a.out or tempfile.mkdtemp(prefix="rcgate")
    os.makedirs(out, exist_ok=True)
    suite = json.load(open(os.path.join(RUNALL, "suite.json")))["tests"]
    only = [x for x in a.only.split(",") if x]
    env = dict(os.environ, FICCUS_ELM=os.path.abspath(a.elm), ELM_HOME=a.elm_home)
    ficc = os.path.join(HERE, "ficc")
    bad = 0
    print("%-22s %-6s %10s %10s | %10s %10s %10s %10s %6s" % ("test", "status", "allocs", "peak", "rc allocs", "rc peak", "dup", "drop", "live"))
    for t in suite:
        name = t["name"]
        if only and name not in only: continue
        fsrc = os.path.normpath(os.path.join(RUNALL, t["fic"]))
        want = open(os.path.join(ROOT, "targets", "golden", name + ".txt"), encoding="utf-8").read().split("\n")[:-1]
        subs = t["c"].get("sub", [])
        res = {}
        status = "ok"
        for mode in ("norc", "rc", "san"):
            if mode == "san" and not a.san: continue
            cfile = os.path.join(out, "%s_%s.c" % (name, "rc" if mode == "san" else mode))
            if mode != "san":
                e = dict(env, FICCUS_FLAGS="--rc" if mode == "rc" else "")
                rc, so, se = sh([ficc, fsrc, "-o", cfile], env=e, timeout=300)
                if rc != 0: status = "COMPILE-FAIL"; print(name, mode, (se or so)[-300:]); break
            exe = os.path.join(out, "%s_%s" % (name, mode))
            flags = FLAGS + (["-O2"] if mode != "san" else ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"])
            rc, so, se = sh([a.cc] + flags + [cfile, "-o", exe, "-lm"])
            if rc != 0: status = "BUILD-FAIL"; print(name, mode, se[-300:]); break
            rc, so, se = sh([exe], env=dict(os.environ, ASAN_OPTIONS="detect_leaks=1"))
            if rc != 0: status = "FAIL(exit %d)" % rc; print(name, mode, se[-600:]); break
            if run_all.normalize_c(so, subs) != want: status = "FAIL(output)"; print(name, mode, "output differs from the golden file"); break
            m = STATS.search(se)
            if mode != "san" and m: res[mode] = tuple(int(x) for x in m.groups())
            if mode == "rc" and m and int(m.group(2)) != 0: status = "FAIL(live %s)" % m.group(2); break
        if status != "ok": bad += 1
        n, r = res.get("norc", (0, 0, 0, 0, 0)), res.get("rc", (0, 0, 0, 0, 0))
        print("%-22s %-6s %10d %10d | %10d %10d %10d %10d %6d" % (name, status, n[0], n[2], r[0], r[2], r[3], r[4], r[1]), flush=True)
    if not a.out: shutil.rmtree(out, ignore_errors=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
