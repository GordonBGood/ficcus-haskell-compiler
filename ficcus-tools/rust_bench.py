#!/usr/bin/env python3
"""Rust comparison: time the safe Rust versions of the benchmark programs (targets/rust) next to the Ficcus build and the hand written C.

  python3 ficcus-tools/rust_bench.py --out DIR [--runs 5] [--only a,b] [--s7-json FILE] [--elm bin/elmfic67] [--cap-mb 6144]

Method (the one of docs/STAGE4-S7.md part 1, via ficcus-tools/s7_bench.py, which is imported for its timing helpers and run for the
Ficcus and hand C columns unless --s7-json names an existing s7_bench.json): serial, one process at a time, median wall time of --runs runs
(default 5), address space cap (default 6 GB, ulimit -v), a Rust program under about 10 ms is start-up dominated and its ratios are shown in
brackets. Refuses to run with less than 8 GB of MemAvailable. Rust: `rustc --edition 2021 -C opt-level=3` and `-C opt-level=2`, no target-cpu,
no panic=abort, default allocator; variants by --cfg: unchecked (get_unchecked, upper bound only), rc (bintree), hashmap (wordfreq).
Every build's output is compared with targets/golden before it is timed; a mismatch stops the program.
The sieve of one run takes well under 1 ms, so it is timed with 1000 repeats (argument) and divided by 1000 (like the hand C `loops`).
Prints the tables and writes DIR/rust_bench.json."""
import argparse, json, os, re, shutil, statistics, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import s7_bench as s7

ROOT = s7.ROOT
SRC = os.path.join(os.path.dirname(HERE), "targets", "rust")
GOLDEN = os.path.join(ROOT, "targets", "golden")

# name, rust file, golden file, name in s7_bench.json, timing args, divisor, variants (label -> cfg)
PROGRAMS = [
    ("sieve",     "sieve.rs",    "sieve_user.txt", "sieve_user", ["1000"], 1000, {"unchecked": "unchecked"}),
    ("fannkuch",  "fannkuch.rs", "fannkuch.txt",   "fannkuch",   [], 1, {"unchecked": "unchecked"}),
    ("spectral",  "spectral.rs", "spectral.txt",   "spectral",   [], 1, {"unchecked": "unchecked"}),
    ("nbody",     "nbody.rs",    "nbody.txt",      "nbody",      [], 1, {"unchecked": "unchecked"}),
    ("mandel",    "mandel.rs",   "mandel.txt",     "mandel",     [], 1, {}),
    ("bintree",   "bintree.rs",  "bintree.txt",    "bintree",    [], 1, {"rc": "rc"}),
    ("wordfreq",  "wordfreq.rs", "wordfreq.txt",   "wordfreq",   [], 1, {"hashmap": "hashmap"}),
]


def mem_available_gb():
    for l in open("/proc/meminfo"):
        if l.startswith("MemAvailable:"): return int(l.split()[1]) / 1048576.0
    return 0.0


def build(src, exe, opt, cfg):
    cmd = ["rustc", "--edition", "2021", "-C", "opt-level=%s" % opt, src, "-o", exe]
    if cfg: cmd += ["--cfg", cfg]
    rc, msg = s7.sh(cmd)
    return None if rc == 0 else "rustc failed: " + msg[-300:]


def check(exe, golden, cap):
    p = subprocess.run([exe], capture_output=True, preexec_fn=cap)
    return p.returncode == 0 and p.stdout == open(os.path.join(GOLDEN, golden), "rb").read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--only", default="")
    ap.add_argument("--s7-json", default="")
    ap.add_argument("--elm", default=os.path.join(ROOT, "bin", "elmfic67"))
    ap.add_argument("--elm-home", default=os.path.join(ROOT, "elm-home-difftest"))
    ap.add_argument("--cap-mb", type=int, default=6144)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--min-gb", type=float, default=8.0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    avail = mem_available_gb()
    if avail < a.min_gb: sys.exit("only %.1f GB available, need %.1f: nothing run" % (avail, a.min_gb))
    only = [x for x in a.only.split(",") if x]
    progs = [p for p in PROGRAMS if not only or p[0] in only]
    cap = s7.make_cap(a.cap_mb)
    print("rustc: %s\ncargo: %s\nload average: %s; MemAvailable %.1f GB" % (
        s7.sh(["rustc", "--version"])[1].strip(), s7.sh(["cargo", "--version"])[1].strip(), os.getloadavg(), avail), flush=True)
    # Ficcus and hand C numbers
    s7json = a.s7_json
    if not s7json:
        d = os.path.join(a.out, "s7")
        rc, out = s7.sh([sys.executable, os.path.join(HERE, "s7_bench.py"), "--elm", a.elm, "--elm-home", a.elm_home, "--out", d, "--no-elm",
                         "--only", ",".join(p[3] for p in progs), "--runs", str(a.runs), "--cap-mb", str(a.cap_mb)], timeout=7200)
        print(out[-3000:], flush=True)
        s7json = os.path.join(d, "s7_bench.json")
    rows7 = json.load(open(s7json))["rows"]
    res = {}
    for name, f, golden, s7n, args, div, variants in progs:
        r = res.setdefault(name, {})
        jobs = [("safe_O3", "3", ""), ("safe_O2", "2", "")]
        for lab, cfg in variants.items():
            jobs += [("%s_O3" % lab, "3", cfg), ("%s_O2" % lab, "2", cfg)]
        for lab, opt, cfg in jobs:
            exe = os.path.join(a.out, "%s_%s" % (name, lab))
            err = build(os.path.join(SRC, f), exe, opt, cfg)
            if err: r[lab] = {"error": err}; print(name, lab, err); continue
            if not check(exe, golden, cap): r[lab] = {"error": "OUTPUT DIFFERS from golden"}; sys.exit("%s %s: output differs from %s" % (name, lab, golden))
            ms, why = s7.median_runs([exe] + args, a.runs, a.timeout, cap=cap)
            r[lab] = {"ms": None if ms is None else ms / div, "error": why}
            print("%-9s %-14s %9.2f ms" % (name, lab, ms / div if ms else -1), flush=True)
        r["ficcus"] = (rows7.get(s7n, {}).get("ficcus") or {}).get("ms")
        r["hand"] = (rows7.get(s7n, {}).get("hand") or {}).get("ms")
    json.dump(dict(runs=a.runs, rustc=s7.sh(["rustc", "--version"])[1].strip(), rows=res), open(os.path.join(a.out, "rust_bench.json"), "w"), indent=1)

    def g(r, k):
        x = r.get(k); return x.get("ms") if isinstance(x, dict) else x
    def fmt(x): return "-" if x is None else ("%.1f" % x if x >= 10 else "%.2f" % x)
    def ratio(x, y, start):
        if not x or not y: return "-"
        s = "%.2f" % (x / y)
        return "(%s)" % s if start else s
    print("\n| program | Ficcus ms | hand C ms | Rust safe O3 | Rust safe O2 | Rust UNCHECKED O3 | O3/C | O2/C | O3/Ficcus | O2/Ficcus | UNCH/C | UNCH/Ficcus |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for name, r in res.items():
        f, h, o3, o2, u = r["ficcus"], r["hand"], g(r, "safe_O3"), g(r, "safe_O2"), g(r, "unchecked_O3")
        sd = lambda x: x is not None and x < 10          # Rust time under 10 ms
        fd = f is not None and f < 10                    # Ficcus under 10 ms
        print("| %s | %s%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            name, fmt(f), "*" if fd else "", fmt(h), fmt(o3), fmt(o2), fmt(u),
            ratio(o3, h, sd(o3)), ratio(o2, h, sd(o2)), ratio(o3, f, sd(o3) or fd), ratio(o2, f, sd(o2) or fd), ratio(u, h, sd(u)), ratio(u, f, sd(u) or fd)))
    print("\nbrackets / *: a time under 10 ms, start-up dominated; the sieve is 1000 repeats divided by 1000 for Rust and hand C, one run for Ficcus")
    print("\n| labelled variant | O3 ms | O2 ms |\n|---|---|---|")
    for name, r in res.items():
        for k in r:
            if k not in ("safe_O3", "safe_O2", "ficcus", "hand") and k.endswith("_O3") and not k.startswith("unchecked"):
                print("| %s %s | %s | %s |" % (name, k[:-3], fmt(g(r, k)), fmt(g(r, k[:-3] + "_O2"))))


if __name__ == "__main__":
    main()
