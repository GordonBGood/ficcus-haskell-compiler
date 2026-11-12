#!/usr/bin/env python3
"""S7 part 1: time every benchmark of the acceptance suite three ways and print the counters of the Ficcus build.

  python3 tools/s7_bench.py --elm bin/elmficNN --elm-home H --out DIR [--runs 5] [--only a,b] [--cc gcc] [--elm-modes optimize,dev]
                            [--no-elm] [--elm-ref bin/elm0193] [--timeout 300] [--cap-mb 6144]

For each program of ficcus-tests/runall/suite.json (16 programs), serially (one process at a time, nothing else of ours running):
  * Ficcus: the .fic source compiled with --rc, built with `gcc -O2 -ffp-contract=off` twice: plain (timed) and -DFIC_STATS (one run,
    the counters: allocations, dups, drops, reuses, uniqueness checks, peak live objects);
  * hand written C: targets/c/<file> with the flags of targets/suite.json (the programs of the plan, section 10.6);
  * Elm under node: `optimize` = the 13 fixtures of ficcus-tests/jsid (Debug.log replaced by a local function, so that --optimize accepts
    them; no output to compare) compiled with the reference compiler 0.19.3 with --optimize; `dev` = the sources of targets/elm as
    run_all.py builds them (dev mode, with the Debug.log lines). The time of an empty `node` process is measured too and subtracted.
Every executable is run --runs times (default 5), alternating nothing, serially; the median wall time is reported. A run that exceeds
--timeout seconds is killed; the C programs run under an address space cap (--cap-mb, a program that never frees must fail cleanly).
Writes DIR/s7_bench.json and prints two tables (times, counters). Uniqueness checks executed = reuse_hit + reuse_miss (every
`MReset` tests the count of the cell) + inplace + copied (every checked array update tests the count of the array)."""
import argparse, json, os, re, resource, shutil, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("FICCUS_ROOT") or os.path.dirname(HERE)
if not os.path.isdir(os.path.join(ROOT, "bin")): ROOT = os.path.dirname(ROOT)
REPO = os.path.join(ROOT, "ficcus-haskell-compiler")
TESTS_C = os.path.join(ROOT, "targets", "c")

STATS = re.compile(r"FIC_STATS: allocs (\d+) live (\d+) peak (\d+) dup (\d+) drop (\d+) free_slow (\d+) reuse_hit (\d+) reuse_miss (\d+)"
                   r"(?: inplace (\d+) copied (\d+) pap_steal (\d+))?")
HAND_TOTAL = re.compile(r"\(total (\d+) allocations, (\d+) objects still live")
HAND_RUN = re.compile(r"\((\d+) (?:loops|runs) in (\d+) milliseconds.*?(\d+) allocations per run")


def make_cap(mb):
    def cap():
        c = mb * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (c, c))
    return cap


def run_timed(cmd, cwd=None, timeout=300, cap=None):
    t = time.perf_counter()
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout, preexec_fn=cap)
    except subprocess.TimeoutExpired:
        return None, 124, b""
    return (time.perf_counter() - t) * 1000.0, p.returncode, p.stdout + p.stderr


def median_runs(cmd, runs, timeout, cwd=None, cap=None):
    """median wall time in ms of `runs` runs, or (None, reason) when a run fails or times out"""
    times = []
    for _ in range(runs):
        ms, rc, out = run_timed(cmd, cwd=cwd, timeout=timeout, cap=cap)
        if ms is None: return None, "timeout %ds" % timeout
        if rc != 0: return None, "exit %d %s" % (rc, out[-100:].decode("utf-8", "replace").strip())
        times.append(ms)
    return statistics.median(times), None


def sh(cmd, cwd=None, env=None, timeout=900):
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def build_ficcus(a, t, out):
    n = t["name"]
    src = os.path.normpath(os.path.join(REPO, "ficcus-tests", "runall", t["fic"]))
    env = dict(os.environ, FICCUS_ELM=os.path.abspath(a.elm), FICCUS_FLAGS="--rc", ELM_HOME=a.elm_home)
    c = os.path.join(out, n + "_fic.c")
    rc, msg = sh([os.path.join(REPO, "ficcus-tests", "ficc"), src, "-o", c], env=env)
    if rc != 0: return None, None, None, "ficcus compile failed: " + msg[-200:]
    flags = ["-std=c99", "-O2", "-ffp-contract=off", "-w", "-I", TESTS_C]
    exe, exe_s = os.path.join(out, n + "_fic"), os.path.join(out, n + "_fic_stats")
    for dst, extra in ((exe, []), (exe_s, ["-DFIC_STATS"])):
        rc, msg = sh([a.cc] + flags + extra + [c, "-o", dst, "-lm"])
        if rc != 0: return None, None, None, "C build failed: " + msg[-200:]
    return c, exe, exe_s, None


def build_hand(a, cfg, t, out):
    n = t["name"]
    exe = os.path.join(out, n + "_hand")
    flags = [f for f in cfg["c_flags"] if f not in ("-pedantic", "-Wall", "-Wextra", "-Wno-unused-function")] + t["c"].get("flags", [])
    rc, msg = sh([a.cc] + flags + ["-w", "-I", TESTS_C, os.path.join(ROOT, "targets", "c", t["c"]["file"]), "-o", exe, "-lm"])
    return (exe, None) if rc == 0 else (None, "C build failed: " + msg[-200:])


def build_elm(a, t, mode, out, cache):
    """-> (command, error) for `node runner.js` in a work copy; one copy per (directory, mode)"""
    e = t["elm"]
    key = (e["dir"], mode)
    if key in cache: return cache[key]
    work = os.path.join(out, "elm_%s_%s" % (mode, e["dir"]))
    shutil.rmtree(work, ignore_errors=True)
    if mode == "optimize":
        src = os.path.join(REPO, "ficcus-tests", "jsid", e["dir"])
        if not os.path.isdir(src): cache[key] = (None, "no fixture in ficcus-tests/jsid"); return cache[key]
        shutil.copytree(src, work, ignore=shutil.ignore_patterns("elm-stuff"))
        shutil.copy(os.path.join(ROOT, "targets", "elm", e["dir"], "runner.js"), work)
        extra = ["--optimize"]
    else:
        shutil.copytree(os.path.join(ROOT, "targets", "elm", e["dir"]), work, ignore=shutil.ignore_patterns("elm-stuff", "optimized", e["js"]))
        extra = []
    ej = os.path.join(work, "elm.json")
    txt = open(ej, encoding="utf-8").read()
    open(ej, "w", encoding="utf-8").write(re.sub(r'("elm-version"\s*:\s*")[^"]*(")', lambda m: m.group(1) + "0.19.3" + m.group(2), txt))
    env = dict(os.environ, ELM_HOME=a.elm_home)
    rc, msg = sh([a.elm_ref, "make", e["main"], "--output=" + e["js"]] + extra, cwd=work, env=env)
    cache[key] = ((["node", "runner.js"], work), None) if rc == 0 else (None, "elm make failed: " + msg[-200:])
    return cache[key]


def node_baseline(runs):
    ts = []
    for _ in range(max(runs, 5)):
        ms, rc, _ = run_timed(["node", "-e", "0"], timeout=60)
        if ms is not None and rc == 0: ts.append(ms)
    return statistics.median(ts) if ts else 0.0


def parse_hand(text, wall_ms):
    """the hand written programs repeat the work N times and print `(N loops|runs in M milliseconds ...; A allocations per run ...)`:
    -> (ms of ONE run, allocations of one run). The wall time of the whole process is shared between the lines in proportion to
    the (coarse) milliseconds they print; a program that prints `(total A allocations ..., M milliseconds)` ran once."""
    lines = []
    for l in text.replace("\r", "").split("\n"):
        m = HAND_TOTAL.search(l)
        if m: lines.append((1, 1, int(m.group(1))))                     # (runs, printed ms, allocations per run)
            
        else:
            m = re.search(r"(\d+) (?:loops|runs) in (\d+) milliseconds", l)
            if m:
                al = re.search(r"(\d+) allocations per run", l)
                lines.append((int(m.group(1)), int(m.group(2)), int(al.group(1)) if al else None))
    if not lines: return wall_ms, None
    if len(lines) == 1 and lines[0][0] == 1: return wall_ms, lines[0][2]
    tot = sum(ms for _, ms, _ in lines) or 1
    scale = wall_ms / tot
    allocs = [x for _, _, x in lines if x is not None]
    return sum(ms * scale / n for n, ms, _ in lines), (sum(allocs) if allocs else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True, help="the Ficcus compiler binary")
    ap.add_argument("--elm-ref", default=os.path.join(ROOT, "bin", "elm0193"), help="the reference Elm 0.19.3 compiler")
    ap.add_argument("--elm-home", default=os.environ.get("ELM_HOME") or os.path.join(ROOT, "elm-home-difftest"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--only", default="")
    ap.add_argument("--cc", default="gcc")
    ap.add_argument("--elm-modes", default="optimize,dev")
    ap.add_argument("--no-elm", action="store_true")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--cap-mb", type=int, default=6144)
    a = ap.parse_args()
    a.elm_home = os.path.abspath(a.elm_home); a.elm = os.path.abspath(a.elm); a.elm_ref = os.path.abspath(a.elm_ref)
    os.makedirs(a.out, exist_ok=True)
    cfg = json.load(open(os.path.join(ROOT, "targets", "suite.json")))
    suite = json.load(open(os.path.join(REPO, "ficcus-tests", "runall", "suite.json")))["tests"]
    only = [x for x in a.only.split(",") if x]
    modes = [] if a.no_elm else [m for m in a.elm_modes.split(",") if m]
    cap = make_cap(a.cap_mb)
    base = node_baseline(a.runs) if modes else 0.0
    print("node start-up (empty program): %.1f ms; compiler %s; %d runs, median; gcc -O2" % (base, os.path.basename(a.elm), a.runs), flush=True)
    rows, elm_cache = {}, {}
    for t in suite:
        n = t["name"]
        if only and n not in only: continue
        r = rows.setdefault(n, {})
        # Ficcus --rc
        c, exe, exe_s, err = build_ficcus(a, t, a.out)
        if err: r["ficcus"] = {"error": err}; print("%-22s FICCUS %s" % (n, err), flush=True)
        else:
            _, rc, out = run_timed([exe_s], timeout=a.timeout, cap=cap)
            m = STATS.search(out.decode("utf-8", "replace"))
            if rc != 0 or not m: r["ficcus"] = {"error": "stats run failed (exit %s)" % rc}
            else:
                g = [int(x) if x else 0 for x in m.groups()]
                r["ficcus"] = dict(allocs=g[0], live=g[1], peak=g[2], dups=g[3], drops=g[4], free_slow=g[5], reuse_hit=g[6], reuse_miss=g[7],
                                   inplace=g[8], copied=g[9], pap_steal=g[10], checks=g[6] + g[7] + g[8] + g[9])
                ms, why = median_runs([exe], a.runs, a.timeout, cap=cap)
                r["ficcus"].update(ms=ms, error=why)
        # hand written C
        hexe, err = build_hand(a, cfg, t, a.out)
        if err: r["hand"] = {"error": err}
        else:
            _, rc, out = run_timed([hexe], timeout=a.timeout, cap=cap)
            ms, why = median_runs([hexe], a.runs, a.timeout, cap=cap)
            one, allocs = (None, None) if ms is None else parse_hand(out.decode("utf-8", "replace"), ms)
            r["hand"] = dict(ms=one, wall_ms=ms, error=why, allocs=allocs)
        # Elm under node
        for mode in modes:
            cmd_dir, err = build_elm(a, t, mode, a.out, elm_cache)
            if err: r["elm_" + mode] = {"error": err}; continue
            cmd, work = cmd_dir
            ms, why = median_runs(cmd, a.runs, a.timeout, cwd=work)
            r["elm_" + mode] = dict(ms=ms, error=why, net=None if ms is None else max(ms - base, 0.1))
        f, h = r.get("ficcus", {}), r.get("hand", {})
        e = r.get("elm_optimize") or r.get("elm_dev") or {}
        print("%-22s ficcus %9s ms   hand %9s ms   elm %9s ms   allocs %s peak %s" % (
            n, "%.1f" % f["ms"] if f.get("ms") else "-", "%.1f" % h["ms"] if h.get("ms") else "-", "%.1f" % e["ms"] if e.get("ms") else "-",
            f.get("allocs", "-"), f.get("peak", "-")), flush=True)
    json.dump(dict(node_baseline_ms=base, runs=a.runs, compiler=os.path.basename(a.elm), rows=rows), open(os.path.join(a.out, "s7_bench.json"), "w"), indent=1)
    # the tables
    def ratio(x, y): return "%.2f" % (x / y) if x and y else "-"
    print("\n| program | Ficcus ms | hand C ms | Elm ms (optimize) | Elm ms (dev) | /C | /Elm opt | /Elm dev |")
    print("|---|---|---|---|---|---|---|---|")
    for n, r in rows.items():
        f, h, eo, ed = r.get("ficcus", {}), r.get("hand", {}), r.get("elm_optimize", {}), r.get("elm_dev", {})
        print("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            n, "%.1f" % f["ms"] if f.get("ms") else "-", "%.1f" % h["ms"] if h.get("ms") else "-",
            "%.0f" % eo["net"] if eo.get("net") else "-", "%.0f" % ed["net"] if ed.get("net") else "-",
            ratio(f.get("ms"), h.get("ms")), ratio(f.get("ms"), eo.get("net")), ratio(f.get("ms"), ed.get("net"))))
    print("\n| program | allocs | hand allocs | dups | drops | reuses | checks | peak live |")
    print("|---|---|---|---|---|---|---|---|")
    for n, r in rows.items():
        f, h = r.get("ficcus", {}), r.get("hand", {})
        if "allocs" in f:
            print("| %s | %d | %s | %d | %d | %d | %d | %d |" % (n, f["allocs"], h.get("allocs") if h.get("allocs") is not None else "-", f["dups"], f["drops"], f["reuse_hit"], f["checks"], f["peak"]))
        else: print("| %s | %s |" % (n, f.get("error")))


if __name__ == "__main__":
    main()
