#!/usr/bin/env python3
"""H15b: the Roc algorithm for the nth Hamming number (targets/hamroc: two circular buffer queues + a running value) in Ficus, Rust and C,
against our algorithm (targets/hamnth, targets/hamnthstream) and the user's prebuilt Roc binaries.

  python3 ficus-tools/h15b_bench.py --elm bin/elmficNN --elm-home H --out DIR [--sizes 1000000,100000000,1000000000] [--runs 5] [--only a,b]
                                     [--roc-dir ~/Documents/RocStuff]

Ficus: --rc, gcc -O2 -ffp-contract=off; counters from a second build with -DFIC_STATS (+ per tag allocation counts, as h15_bench). C: best of
gcc/clang -O2/-O3. Rust: -C opt-level=3. Roc: the user's binaries NthHamming and NthHammingCIS, run as `BIN x N` (read only). Serial, `ulimit -v` 6 GB,
median wall time of --runs runs, max RSS (GNU time) of one more run. Every printed (twos, threes, fives) must equal that of hamnth.c. DIR/h15b_bench.json."""
import argparse, json, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
from p1_bench import timed, counters, cap, sh  # noqa: E402
from h15_bench import build_fic  # noqa: E402

REPO = os.path.dirname(HERE)
T = os.path.join(REPO, "targets"); HN = os.path.join(T, "hamnth"); HS = os.path.join(T, "hamnthstream"); HR = os.path.join(T, "hamroc")


def triple(text):
    m = re.search(r"2\^(\d+) \* 3\^(\d+) \* 5\^(\d+)", text) or re.search(r"twos: (\d+), threes: (\d+), fives: (\d+)", text)
    return "%s %s %s" % m.groups() if m else "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--sizes", default="1000000,100000000,1000000000"); ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--only", default=""); ap.add_argument("--roc-dir", default=os.path.expanduser("~/Documents/RocStuff"))
    a = ap.parse_args()
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    os.makedirs(a.out, exist_ok=True); work = os.path.join(a.out, "work")
    rf = os.path.join(a.out, "h15b_bench.json"); res = json.load(open(rf)) if os.path.exists(rf) else {}
    only = set(filter(None, a.only.split(",")))
    for n in [int(x) for x in a.sizes.split(",")]:
        r = res.setdefault(str(n), {}); shutil.rmtree(work, ignore_errors=True); os.makedirs(work)

        def meas(name, cmd, stats=None):
            if only and name not in only: return
            t = timed(cmd, a.runs); r[name] = {"ms": t[0], "rss_mb": t[1], "answer": triple(t[2]) if t[0] else t[2]}
            if stats:
                p = subprocess.run([stats], capture_output=True, preexec_fn=cap)
                r[name]["counters"] = counters((p.stdout + p.stderr).decode("utf-8", "replace"))
            print(n, name, "%s ms" % (round(t[0], 1) if t[0] else None), "%.1f MB" % t[1] if t[1] else "", r[name]["answer"], r[name].get("counters", ""), flush=True)
            json.dump(res, open(rf, "w"), indent=1)

        fic = [("fic_hamnth_direct", "HamNth", HN), ("fic_hamnth_stream", "HamNthStream", HS),
               ("fic_roc_direct", "HamRoc", HR), ("fic_roc_stream", "HamRocStream", HR),
               ("fic_roc_flat", "HamRocFlat", HR), ("fic_roc_flat_stream", "HamRocFlatStream", HR)] + ([("fic_roc_rec", "HamRocRec", HR)] if n <= 1000000 else [])
        for key, mod, sd in fic:
            if only and key not in only: continue
            run, stats = build_fic(a, os.path.join(work, key), mod, sd, n)
            meas(key, [run], stats)
        # hand C (best of gcc/clang -O2/-O3 by the median time)
        for key, src, extra in (("c_hamnth", "hamnth/hamnth.c", []), ("c_roc16", "hamroc/hamroc.c", []), ("c_roc32", "hamroc/hamroc.c", ["-DWIDE"])):
            if only and key not in only: continue
            best = None
            for cc in ("gcc", "clang"):
                for opt in ("-O2", "-O3"):
                    exe = os.path.join(work, "%s_%s%s" % (key, cc, opt))
                    rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w", "-DTARGET=%d" % n] + extra + [os.path.join(T, src), "-o", exe, "-lm"])
                    if rc != 0: raise SystemExit("C: " + msg[-300:])
                    t = timed([exe], 3 if n >= 10**9 else a.runs)
                    if best is None or t[0] < best[0]: best = (t[0], exe, "%s %s" % (cc, opt))
            meas(key, [best[1]]); r[key]["build"] = best[2]
        # Rust
        rs = lambda src, out, extra=(): sh(["rustc", "--edition", "2021", "-C", "opt-level=3", "-C", "debug-assertions=no", "-A", "warnings"] + list(extra) + [src, "-o", out])
        built = {}
        for key, src, extra in (("hamnth", "hamnth/hamnth.rs", ()), ("hamnthstream", "hamnthstream/hamnthstream.rs", ()), ("hamroc16", "hamroc/hamroc.rs", ()), ("hamroc32", "hamroc/hamroc.rs", ("--cfg", "wide"))):
            built[key] = os.path.join(work, "rs_" + key); rc, msg = rs(os.path.join(T, src), built[key], extra)
            if rc != 0: raise SystemExit("rustc: " + msg[-300:])
        meas("rs_hamnth_direct", [built["hamnth"], str(n)]); meas("rs_hamnth_iter", [built["hamnthstream"], str(n), "iter"])
        for w in ("16", "32"):
            meas("rs_roc%s_direct" % w, [built["hamroc" + w], str(n), "direct"]); meas("rs_roc%s_iter" % w, [built["hamroc" + w], str(n), "iter"])
        # Roc (the user's binaries)
        meas("roc_direct", [os.path.join(a.roc_dir, "NthHamming"), "x", str(n)]); meas("roc_cis", [os.path.join(a.roc_dir, "NthHammingCIS"), "x", str(n)])
        ref = r.get("c_hamnth", {}).get("answer")
        r["agree"] = all(v.get("answer") == ref for v in r.values() if isinstance(v, dict) and "answer" in v)
        print(n, "reference", ref, "all answers agree:", r["agree"], flush=True)
        json.dump(res, open(rf, "w"), indent=1)
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
