#!/usr/bin/env python3
"""V3 step 4: the hamnth benchmark (targets/hamnth: Ficus, hand C, Rust).

  python3 ficus-tools/hamnth_bench.py --elm bin/elmficNN --elm-home H --out DIR [--sizes 1000000,100000000,1000000000] [--runs 5] [--big-runs 3]
                                       [--experiments] [--check]

Serial; one process at a time under `ulimit -v` 6 GB; median wall time of --runs runs (--big-runs for a size of 10^9), the maximum resident
set size (GNU time) of one more run. Ficus: --rc, gcc -O2 -ffp-contract=off (+ with --experiments gcc -O3, clang -O3).
Hand C: gcc and clang at -O2 and -O3, the best is reported. Rust: -C opt-level=3, safe. The printed lines of all versions must be equal
(Debug.log's ': ()' removed); with --check the answer is also checked by ficus-tools/hamnth_check.py (exact integers). Writes DIR/hamnth_bench.json."""
import argparse, json, os, re, resource, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.path.dirname(REPO)
RT = os.path.join(ROOT, "targets", "c")
HN = os.path.join(REPO, "targets", "hamnth")


def cap():
    resource.setrlimit(resource.RLIMIT_AS, (6 << 30, 6 << 30))


def sh(cmd, env=None):
    p = subprocess.run(cmd, capture_output=True, env=env)
    return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")


def timed(cmd, runs):
    ts, out = [], ""
    for _ in range(runs):
        t0 = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True, preexec_fn=cap)
        ts.append((time.perf_counter() - t0) * 1000)
        if p.returncode != 0: return None, None, "exit %d" % p.returncode
        out = (p.stdout + p.stderr).decode("utf-8", "replace")
    p = subprocess.run(["/usr/bin/time", "-f", "RSS %M"] + cmd, capture_output=True, preexec_fn=cap)
    rss = int(re.search(r"RSS (\d+)", p.stderr.decode()).group(1)) / 1024.0
    return statistics.median(ts), rss, out


def lines(text):
    return [re.sub(r": \(\)$", "", l.strip()) for l in text.replace("\r", "").splitlines()
            if l.strip() and l.startswith(("Hamming number", "1", "2", "3", "4", "5", "6", "7", "8", "9")) ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--sizes", default="1000000,100000000,1000000000"); ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--big-runs", type=int, default=3); ap.add_argument("--experiments", action="store_true"); ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    os.makedirs(a.out, exist_ok=True)
    res = {}
    for n in [int(x) for x in a.sizes.split(",")]:
        runs = a.big_runs if n >= 10**9 else a.runs
        d = os.path.join(a.out, "n%d" % n)
        os.makedirs(os.path.join(d, "src"), exist_ok=True)
        open(os.path.join(d, "elm.json"), "w").write(open(os.path.join(HN, "elm.json")).read())
        src = os.path.join(d, "src", "HamNth.fic")
        text = open(os.path.join(HN, "src", "HamNth.fic")).read()
        assert "\n    1000000\n" in text
        open(src, "w").write(text.replace("\n    1000000\n", "\n    %d\n" % n, 1))
        r = res.setdefault(str(n), {})
        variants = [({}, "gcc", "-O2")]
        if a.experiments:
            variants += [({}, "gcc", "-O3"), ({}, "clang", "-O2"), ({}, "clang", "-O3")]
        cf = {}
        for cenv, cc, opt in variants:
            tag = "default"
            if tag not in cf:
                c = os.path.join(d, "ficus_%s.c" % tag)
                env = dict(os.environ, FICUS_ELM=os.path.abspath(a.elm), FICUS_FLAGS="--rc", ELM_HOME=os.path.abspath(a.elm_home), **cenv)
                rc, msg = sh([os.path.join(REPO, "ficus-tests", "fic"), src, "-o", c], env=env)
                if rc != 0: print("FAIL", msg[-300:]); return 1
                cf[tag] = c
            exe = cf[tag][:-2] + "_" + cc + opt.replace("-", "")
            rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w", "-I", RT, cf[tag], "-o", exe, "-lm"])
            if rc != 0: print("FAIL", cc, msg[-300:]); return 1
            r["Ficus %s (%s %s)" % (tag, cc, opt)] = timed([exe], runs)
            print(n, "Ficus", tag, cc, opt, r["Ficus %s (%s %s)" % (tag, cc, opt)][:2], flush=True)
        best = None
        for cc in ("gcc", "clang"):
            for opt in ("-O2", "-O3"):
                exe = os.path.join(d, "hand_%s%s" % (cc, opt))
                rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w", "-DTARGET=%d" % n, os.path.join(HN, "hamnth.c"), "-o", exe])
                if rc != 0: print("FAIL", cc, msg[-300:]); return 1
                t = timed([exe], runs)
                r["hand C (%s %s)" % (cc, opt)] = t
                print(n, "hand C", cc, opt, t[:2], flush=True)
                if t[0] is not None and (best is None or t[0] < best[0]): best = t + ("%s %s" % (cc, opt),)
        r["hand C best"] = best
        exe = os.path.join(d, "rust")
        rc, msg = sh(["rustc", "--edition", "2021", "-C", "opt-level=3", os.path.join(HN, "hamnth.rs"), "-o", exe])
        if rc != 0: print("FAIL rustc", msg[-300:]); return 1
        r["Rust safe O3"] = timed([exe, str(n)], runs)
        print(n, "Rust", r["Rust safe O3"][:2], flush=True)
        ref = lines(r["Ficus default (gcc -O2)"][2])
        bad = [k for k, v in r.items() if isinstance(v, (tuple, list)) and v[0] is not None and lines(v[2]) != ref]
        r["agree"] = not bad
        print("n=%d answers agree: %s" % (n, "yes" if not bad else "NO %s" % bad), flush=True)
        if a.check:
            m = re.search(r"= 2\^(\d+) \* 3\^(\d+) \* 5\^(\d+)", ref[0])
            rc, msg = sh([sys.executable, os.path.join(HERE, "hamnth_check.py"), str(n), m.group(1), m.group(2), m.group(3)] + (["--merge"] if n <= 2000000 else []))
            r["exact check"] = msg.strip()
            print(msg.strip(), flush=True)
        json.dump(res, open(os.path.join(a.out, "hamnth_bench.json"), "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
