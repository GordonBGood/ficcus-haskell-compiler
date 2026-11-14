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
    ("wordfreq",  "wordfreq.rs", "wordfreq.txt",   "wordfreq",   [], 1, {"hashmap": "hashmap", "owned": "owned"}),
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


CBUILDS = [("gcc", "-O2"), ("gcc", "-O3"), ("clang", "-O2"), ("clang", "-O3")]


def hand_flags(cfg, t):
    base = [f for f in cfg["c_flags"] if f not in ("-pedantic", "-Wall", "-Wextra", "-Wno-unused-function", "-O2")]
    return base + t["c"].get("flags", [])


def c_matrix(a, name, hand_src, extra_flags, fic_c, cap, runs, div=1):
    """times the hand written C and the Ficcus generated C under gcc/clang -O2/-O3 (other flags as s7_bench.py: -std=c99 -ffp-contract=off -w).
    -> {"hand": {"gcc -O2": ms per run, ...}, "ficcus": {...}}"""
    out = {"hand": {}, "ficcus": {}}
    for cc, opt in CBUILDS:
        key = "%s %s" % (cc, opt)
        for kind, src in (("hand", hand_src), ("ficcus", fic_c)):
            if src is None or not os.path.exists(src): out[kind][key] = None; continue
            exe = os.path.join(a.out, "c_%s_%s_%s_%s" % (name, kind, cc, opt[1:]))
            flags = (extra_flags if kind == "hand" else ["-std=c99", "-ffp-contract=off"]) + ["-w", "-I", s7.TESTS_C]
            flags = [f for f in flags if f != "-O2"]
            rc, msg = s7.sh([cc, opt] + flags + [src, "-o", exe, "-lm"])
            if rc != 0: out[kind][key] = None; print(name, kind, key, "build failed", msg[-200:]); continue
            ms, why = s7.median_runs([exe], runs, a.timeout, cap=cap)
            if ms is not None and kind == "hand":
                _, rc2, o = s7.run_timed([exe], timeout=a.timeout, cap=cap)
                one, _ = s7.parse_hand(o.decode("utf-8", "replace"), ms)
                ms = one if one is not None else ms
            out[kind][key] = ms
            print("%-9s %-6s %-9s %9.2f ms" % (name, kind, key, ms or -1), flush=True)
    return out


SCALED_DIR = os.path.join(os.path.dirname(HERE), "targets", "scaled")
# name, directory, Elm main, [(label, hand C file)], Rust file or None, Rust variants {label: cfg}
SCALED = [
    ("sieve",       "sieve",       "src/Sieve.elm",         [("hand C plain", "sieve_plain.c"), ("hand C unrolled", "primebench_unrolled.c")], "sieve.rs", {"unchecked": "unchecked"}),
    ("sievestream", "sievestream", "src/SieveStream.elm",   [("hand C", "sievestream.c")], "sievestream.rs", {}),
    ("sievepq",     "sievepq",     "src/SievePQ.elm",       [("hand C", "sievepq.c")], "sievepq.rs", {"binheap": "binheap"}),
    ("hamvec",      "hamvec",      "src/HammingVec.elm",    [("hand C", "hamvec.c")], "hamvec.rs", {}),
    ("hamheap",     "hamheap",     "src/HammingHeap.elm",   [("hand C", "hamheap.c")], "hamheap.rs", {}),
]


def answer_of(text):
    """the first two integers after `Found` (the count and the limit): what the programs of every language have in common"""
    m = re.search(r"Found (\d+)\D+?(\d+)", text)
    return (m.group(1), m.group(2)) if m else None


def gen_ficcus(a, src, outc):
    env = dict(os.environ, FICCUS_ELM=os.path.abspath(a.elm), FICCUS_FLAGS="--rc", ELM_HOME=os.path.abspath(a.elm_home))
    return s7.sh([os.path.join(s7.REPO, "ficcus-tests", "ficc"), src, "-o", outc], env=env)


def scaled_set(a, cap, only):
    res = {}
    for name, d, main_elm, hands, rust, rvars in SCALED:
        if only and name not in only: continue
        base = os.path.join(SCALED_DIR, d)
        r = res.setdefault(name, {"answers": {}})
        fc = os.path.join(a.out, "sc_%s_fic.c" % name)
        rc, msg = gen_ficcus(a, os.path.join(base, main_elm), fc)
        if rc != 0: r["error"] = "ficcus: " + msg[-300:]; print(name, r["error"]); continue
        fe = os.path.join(a.out, "sc_%s_fic" % name)
        rc, msg = s7.sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-I", s7.TESTS_C, fc, "-o", fe, "-lm"])
        if rc != 0: r["error"] = "gcc: " + msg[-300:]; print(name, r["error"]); continue
        _, rc, out = s7.run_timed([fe], timeout=a.timeout, cap=cap)
        r["answers"]["Ficcus"] = answer_of(out.decode("utf-8", "replace"))
        r["ficcus"] = s7.median_runs([fe], a.runs, a.timeout, cap=cap)[0]
        print("%-12s Ficcus %9.1f ms  %s" % (name, r["ficcus"] or -1, r["answers"]["Ficcus"]), flush=True)
        r["hands"] = {}
        for label, f in hands:
            m = c_matrix(a, name + "_" + f[:-2], os.path.join(base, f), ["-std=c99", "-ffp-contract=off"], fc, cap, a.runs)
            r["hands"][label] = m["hand"]
            r["ficcus_builds"] = m["ficcus"]
            exe = os.path.join(a.out, "c_%s_%s_gcc_O2" % (name + "_" + f[:-2], "hand"))
            _, rc, out = s7.run_timed([exe], timeout=a.timeout, cap=cap)
            r["answers"][label] = answer_of(out.decode("utf-8", "replace"))
        if rust:
            for lab, opt, cfg in [("safe_O3", "3", ""), ("safe_O2", "2", "")] + [("%s_O3" % k, "3", v) for k, v in rvars.items()]:
                exe = os.path.join(a.out, "sc_%s_%s" % (name, lab))
                err = build(os.path.join(base, rust), exe, opt, cfg)
                if err: r[lab] = None; print(name, lab, err); continue
                _, rc, out = s7.run_timed([exe], timeout=a.timeout, cap=cap)
                r["answers"]["Rust " + lab] = answer_of(out.decode("utf-8", "replace"))
                r[lab] = s7.median_runs([exe], a.runs, a.timeout, cap=cap)[0]
                print("%-12s Rust %-10s %9.1f ms" % (name, lab, r[lab] or -1), flush=True)
        # Elm under node, only if it finishes within 60 s
        work = os.path.join(a.out, "sc_elm_" + name)
        shutil.rmtree(work, ignore_errors=True)
        shutil.copytree(base, work, ignore=shutil.ignore_patterns("elm-stuff", "*.c", "*.rs"))
        env = dict(os.environ, ELM_HOME=os.path.abspath(a.elm_home))
        mod = os.path.basename(main_elm)[:-4]
        rc, msg = s7.sh([a.elm_ref, "make", main_elm, "--output=x.js"], cwd=work, env=env)
        if rc == 0:
            open(os.path.join(work, "runner.js"), "w").write("const { Elm } = require('./x.js'); Elm.%s.init();\n" % mod)
            ms, rc, out = run_timed_cwd(["node", "runner.js"], work, 60)
            if ms is None: r["elm"] = "over 60 s"
            else:
                r["elm"] = ms; r["answers"]["Elm"] = answer_of(out.decode("utf-8", "replace"))
        else: r["elm"] = "elm make failed"
        print("%-12s Elm %s" % (name, r["elm"]), flush=True)
        r["agree"] = len(set(v for v in r["answers"].values())) == 1 and None not in r["answers"].values()
        print("%-12s answers %s -> %s" % (name, r["answers"], "AGREE" if r["agree"] else "DISAGREE"), flush=True)
    json.dump(res, open(os.path.join(a.out, "rust_bench_scaled.json"), "w"), indent=1)
    print("\n| program | Ficcus ms (gcc -O2) | Ficcus best build | " + " | ".join("%s best (build)" % h for h in ("hand C", "hand C unrolled")) +
          " | Rust safe O3 | Rust safe O2 | Rust UNCHECKED O3 | Elm node ms | Ficcus/best hand | Rust O3/best hand | Rust O3/Ficcus | answers agree |")
    print("|" + "---|" * 13)
    def best(m):
        c = {k: v for k, v in m.items() if v}
        k = min(c, key=c.get) if c else None
        return (c[k], k) if k else (None, None)
    for name, r in res.items():
        if "hands" not in r: continue
        hb = [best(m) for m in r["hands"].values()]
        h1 = hb[0]; h2 = hb[1] if len(hb) > 1 else (None, None)
        fb = best(r["ficcus_builds"])
        f = r["ficcus"]
        def rt(x, y): return "-" if not x or not y else "%.2f" % (x / y)
        el = r.get("elm")
        print("| %s | %s | %s (%s) | %s (%s) | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            name, "%.1f" % f, "%.1f" % fb[0] if fb[0] else "-", fb[1], "%.1f" % h1[0], h1[1],
            "%.1f (%s)" % h2 if h2[0] else "-", "%.1f" % r["safe_O3"] if r.get("safe_O3") else "-", "%.1f" % r["safe_O2"] if r.get("safe_O2") else "-",
            "%.1f" % r["unchecked_O3"] if r.get("unchecked_O3") else "-", "%.0f" % el if isinstance(el, float) else el,
            rt(f, h1[0]), rt(r.get("safe_O3"), h1[0]), rt(r.get("safe_O3"), f), "yes" if r["agree"] else "NO"))
    print("\nlabelled Rust variants of the scaled programs (O3 ms):")
    for name, r in res.items():
        for k, v in r.items():
            if k.endswith("_O3") and k not in ("safe_O3", "unchecked_O3") and isinstance(v, float): print("  %s %s: %.1f" % (name, k[:-3], v))


def run_timed_cwd(cmd, cwd, timeout):
    return s7.run_timed(cmd, cwd=cwd, timeout=timeout)


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
    ap.add_argument("--cbuilds", action="store_true", help="also time hand C and Ficcus C under gcc/clang -O2/-O3")
    ap.add_argument("--set", default="base", choices=["base", "scaled"])
    ap.add_argument("--elm-ref", default=os.path.join(ROOT, "bin", "elm0193"))
    ap.add_argument("--min-gb", type=float, default=8.0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    avail = mem_available_gb()
    if avail < a.min_gb: sys.exit("only %.1f GB available, need %.1f: nothing run" % (avail, a.min_gb))
    only = [x for x in a.only.split(",") if x]
    if a.set == "scaled":
        a.elm_ref = os.path.abspath(a.elm_ref)
        scaled_set(a, s7.make_cap(a.cap_mb), only)
        return
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
        if a.cbuilds:
            cfg = json.load(open(os.path.join(ROOT, "targets", "suite.json")))
            t = [x for x in cfg["tests"] if x["name"] == s7n][0]
            r["cmat"] = c_matrix(a, name, os.path.join(ROOT, "targets", "c", t["c"]["file"]), hand_flags(cfg, t),
                                 os.path.join(os.path.dirname(s7json), s7n + "_fic.c"), cap, a.runs, div)
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

    if a.cbuilds:
        print("\n| program | " + " | ".join("hand %s %s" % b for b in CBUILDS) + " | best hand C | Ficcus gcc -O2 | Ficcus best build | Rust O3 | Rust O2 | O3/best C | O2/best C | Ficcus/best C | Rust O3/Ficcus |")
        print("|" + "---|" * (len(CBUILDS) + 10))
        for name, r in res.items():
            hm, fm = r["cmat"]["hand"], r["cmat"]["ficcus"]
            cand = {k: v for k, v in hm.items() if v}
            bk = min(cand, key=cand.get) if cand else None
            best = cand[bk] if bk else None
            fc = {k: v for k, v in fm.items() if v}
            fk = min(fc, key=fc.get) if fc else None
            f2 = fm.get("gcc -O2")
            o3, o2 = g(r, "safe_O3"), g(r, "safe_O2")
            sd = (best is not None and best < 10) or (f2 is not None and f2 < 10)
            br = lambda x, y: ratio(x, y, sd)
            print("| %s | %s | %s (%s) | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                name, " | ".join(fmt(hm.get("%s %s" % b)) for b in CBUILDS), fmt(best), bk, fmt(f2),
                "%s (%s)" % (fmt(fc[fk]), fk) if fk else "-", fmt(o3), fmt(o2), br(o3, best), br(o2, best), br(f2, best), br(o3, f2)))


if __name__ == "__main__":
    main()
