#!/usr/bin/env python3
"""The reference counting gate on the 16 programs of the acceptance suite (STAGE4-PLAN section 10, S2).

  python3 ficcus-tests/rc_gate.py --elm bin/elmficNN --elm-home H [--only a,b] [--san] [--out DIR]

For every test of ficcus-tests/runall/suite.json: the .fic program is compiled twice (without and with --rc), both are built with
-DFIC_STATS and gcc -O2, run, and their output (normalized as run_all.py does) is compared with the golden output from Elm. With
--rc the run must end with 0 live objects. With --san the --rc program is also built with AddressSanitizer + UBSan (malloc, no
pool, leak detection on) and run: no leak, no use after free, no double free.
Prints one line per test with the counters (allocations, peak live objects, dups, drops) of both builds. Exit status 1 on any FAIL."""
import argparse, os, re, resource, subprocess, sys, json, tempfile, shutil

# Memory cap of every program run (STAGE4 rev 119, after a no-RC fannkuch of 22 GB was OOM-killed): a program that never frees must
# fail cleanly. Plain builds get RLIMIT_AS; sanitizer builds (which reserve huge address ranges) run in a cgroup scope (tools/safe).
CAP = int(os.environ.get("RC_GATE_CAP_MB", "6144")) * 1024 * 1024


def cap_memory():
    resource.setrlimit(resource.RLIMIT_AS, (CAP, CAP))

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RUNALL = os.path.join(HERE, "runall")
sys.path.insert(0, RUNALL)
import run_all  # noqa: E402   (normalize_c, the output normalization of the suite)

STATS = re.compile(r"FIC_STATS: allocs (\d+) live (\d+) peak (\d+) dup (\d+) drop (\d+)")
FLAGS = ["-std=c99", "-ffp-contract=off", "-w", "-DFIC_STATS", "-I", os.path.join(ROOT, "targets", "c")]


def sh(cmd, env=None, timeout=900, capped=False):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout, preexec_fn=cap_memory if capped else None)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--only", default="")
    ap.add_argument("--san", action="store_true"); ap.add_argument("--out", default=None)
    ap.add_argument("--cc", default="gcc")
    ap.add_argument("--norc", action="store_true", help="also build and run the no-RC variant (capped at RC_GATE_CAP_MB, default 6144; a program that "
                    "needs more is reported as SKIP with the reason, not failed). Default off: compare with the recorded counters instead")
    ap.add_argument("--baseline", default=None, help="a recorded output of this script (the S2 --rc counters): dup, drop and peak are shown next to the new ones")
    a = ap.parse_args()
    out = a.out or tempfile.mkdtemp(prefix="rcgate")
    os.makedirs(out, exist_ok=True)
    suite = json.load(open(os.path.join(RUNALL, "suite.json")))["tests"]
    only = [x for x in a.only.split(",") if x]
    env = dict(os.environ, FICCUS_ELM=os.path.abspath(a.elm), ELM_HOME=a.elm_home)
    ficc = os.path.join(HERE, "ficc")
    bad = 0
    base = {}
    if a.baseline:
        for l in open(a.baseline):
            f = l.split()
            if len(f) >= 10 and f[0] != "test" and f[1] == "ok": base[f[0]] = (int(f[6]), int(f[7]), int(f[8]))     # rc peak, dup, drop
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
            if mode == "norc" and not a.norc: continue
            cfile = os.path.join(out, "%s_%s.c" % (name, "rc" if mode == "san" else mode))
            if mode != "san":
                e = dict(env, FICCUS_FLAGS="--rc" if mode == "rc" else "")
                rc, so, se = sh([ficc, fsrc, "-o", cfile], env=e, timeout=300)
                if rc != 0: status = "COMPILE-FAIL"; print(name, mode, (se or so)[-300:]); break
            exe = os.path.join(out, "%s_%s" % (name, mode))
            flags = FLAGS + (["-O2"] if mode != "san" else ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"])
            rc, so, se = sh([a.cc] + flags + [cfile, "-o", exe, "-lm"])
            if rc != 0: status = "BUILD-FAIL"; print(name, mode, se[-300:]); break
            if mode == "san":
                rc, so, se = sh([os.path.join(ROOT, "tools", "safe"), exe], env=dict(os.environ, ASAN_OPTIONS="detect_leaks=1", SAFE_MEM="6G", SAFE_TIMEOUT="900"))
            else:
                rc, so, se = sh([exe], env=dict(os.environ), capped=True)
            if rc != 0 and mode == "norc":
                status = "SKIP(norc: exit %d under the %d MB cap: %s)" % (rc, CAP >> 20, (se.strip().splitlines() or ["no message"])[-1][:60]); print(name, mode, "skipped:", status); break
            if rc != 0: status = "FAIL(exit %d)" % rc; print(name, mode, se[-600:]); break
            if run_all.normalize_c(so, subs) != want: status = "FAIL(output)"; print(name, mode, "output differs from the golden file"); break
            m = STATS.search(se)
            if mode != "san" and m: res[mode] = tuple(int(x) for x in m.groups())
            if mode == "rc" and m and int(m.group(2)) != 0: status = "FAIL(live %s)" % m.group(2); break
        if status != "ok" and not status.startswith("SKIP"): bad += 1
        n, r = res.get("norc", (0, 0, 0, 0, 0)), res.get("rc", (0, 0, 0, 0, 0))
        print("%-22s %-6s %10d %10d | %10d %10d %10d %10d %6d" % (name, status, n[0], n[2], r[0], r[2], r[3], r[4], r[1]), flush=True)
        if name in base and r[0]: print("%-22s %-6s %10s %10s | %10s %10d %10d %10d   (recorded baseline)" % ("", "", "", "", "", base[name][0], base[name][1], base[name][2]), flush=True)
    if not a.out: shutil.rmtree(out, ignore_errors=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
