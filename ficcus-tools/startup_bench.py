#!/usr/bin/env python3
"""H15 part 1: the fixed start-up cost of a Ficcus program against hand C and Rust.

  python3 ficcus-tools/startup_bench.py --elm bin/elmficNN --elm-home H --out DIR [--runs 200] [--big-runs 50] [--work W]

Programs: a trivial one (prints 0) and hamnth with n = 1 and n = 10^6 (targets/hamnth). Ficcus: --rc, gcc -O2 -ffp-contract=off, in four
runtime variants (default: 1 GB stack thread and pool; -DFIC_STACK_MB=8; -DFIC_NO_BIG_STACK; -DFIC_NO_POOL; both of the last two). Floors: a
bare C `main` that prints 0 and the same with `#include "ficrt.h"`. Hand C: gcc/clang -O2, the faster at n = 10^6. Rust: -C opt-level=3.
The runs of all variants of a program are interleaved (round robin), serial, wall time of subprocess.run (fork, exec and exit included, the
same for every variant), median and minimum. Writes DIR/startup_bench.json."""
import argparse, json, os, shutil, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.path.dirname(REPO)
RT = os.path.join(ROOT, "targets", "c")
HN = os.path.join(REPO, "targets", "hamnth")
SAFE = os.path.join(HERE, "safe")

TRIV_FIC = """module Triv exposing (main)


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
                    _ =
                        Debug.log "0" ()
                in
                ( (), Cmd.none )
        , update = \\_ _ -> ( (), Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
"""
BARE_C = '#include <stdio.h>\nint main(void) { puts("0"); return 0; }\n'
FICRT_C = '#include <stdio.h>\n#include "ficrt.h"\nint main(void) { puts("0"); return 0; }\n'
TRIV_RS = 'fn main() { println!("0"); }\n'


def sh(cmd, env=None, cwd=None):
    p = subprocess.run(cmd, capture_output=True, env=env, cwd=cwd)
    if p.returncode != 0: raise SystemExit("failed: %s\n%s" % (" ".join(cmd), (p.stdout + p.stderr).decode()[-600:]))


def measure(cmds, runs):
    """cmds: {name: argv}; interleaved; returns {name: (median ms, min ms)}"""
    ts = {k: [] for k in cmds}
    for _ in range(runs):
        for k, c in cmds.items():
            t0 = time.perf_counter()
            subprocess.run(c, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ts[k].append((time.perf_counter() - t0) * 1000)
    return {k: (statistics.median(v), min(v)) for k, v in ts.items()}


def ficcus_c(elm, elm_home, d, name, text, target=None):
    os.makedirs(os.path.join(d, "src"), exist_ok=True)
    shutil.copy(os.path.join(HN, "elm.json"), d)
    src = os.path.join(d, "src", name + ".fic")
    if target is not None:
        text = text.replace("\n    1000000\n", "\n    %d\n" % target, 1)
    open(src, "w").write(text)
    env = dict(os.environ, ELM_HOME=os.path.abspath(elm_home))
    sh([SAFE, os.path.abspath(elm), "make", "src/%s.fic" % name, "--output=x.c", "--rc"], env=env, cwd=d)
    return os.path.join(d, "x.c")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=200); ap.add_argument("--big-runs", type=int, default=50); ap.add_argument("--work", default="")
    a = ap.parse_args()
    if os.getloadavg()[0] > 1.5: print("WARNING: load %.2f" % os.getloadavg()[0])
    work = a.work or os.path.join(a.out, "work"); os.makedirs(work, exist_ok=True); os.makedirs(a.out, exist_ok=True)
    variants = {"default (1 GB stack, pool)": [], "stack 8 MB": ["-DFIC_STACK_MB=8"], "no big stack": ["-DFIC_NO_BIG_STACK"],
                "no pool": ["-DFIC_NO_POOL"], "no big stack, no pool": ["-DFIC_NO_BIG_STACK", "-DFIC_NO_POOL"]}
    res = {}
    # ---- trivial
    cmds = {}
    p = os.path.join(work, "bare.c"); open(p, "w").write(BARE_C); sh(["gcc", "-std=c99", "-O2", p, "-o", os.path.join(work, "bare")]); cmds["bare C"] = [os.path.join(work, "bare")]
    p = os.path.join(work, "ficrt.c"); open(p, "w").write(FICRT_C); sh(["gcc", "-std=c99", "-O2", "-w", "-I", RT, p, "-o", os.path.join(work, "ficrt_triv"), "-lm"]); cmds["hand C with ficrt.h"] = [os.path.join(work, "ficrt_triv")]
    p = os.path.join(work, "triv.rs"); open(p, "w").write(TRIV_RS); sh(["rustc", "--edition", "2021", "-C", "opt-level=3", p, "-o", os.path.join(work, "triv_rs")]); cmds["Rust"] = [os.path.join(work, "triv_rs")]
    c = ficcus_c(a.elm, a.elm_home, os.path.join(work, "triv"), "Triv", TRIV_FIC)
    for vn, fl in variants.items():
        exe = os.path.join(work, "triv_" + str(abs(hash(vn))))
        sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w"] + fl + ["-I", RT, c, "-o", exe, "-lm", "-lpthread"]); cmds["Ficcus " + vn] = [exe]
    res["trivial"] = measure(cmds, a.runs); print("trivial", json.dumps(res["trivial"], indent=1), flush=True)
    # ---- hamnth
    for n, runs in ((1, a.runs), (1000000, a.big_runs)):
        cmds = {}
        c = ficcus_c(a.elm, a.elm_home, os.path.join(work, "hn%d" % n), "HamNth", open(os.path.join(HN, "src", "HamNth.fic")).read(), n)
        for vn, fl in variants.items():
            exe = os.path.join(work, "hn%d_%d" % (n, abs(hash(vn))))
            sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w"] + fl + ["-I", RT, c, "-o", exe, "-lm", "-lpthread"]); cmds["Ficcus " + vn] = [exe]
        best = None
        for cc in ("gcc", "clang"):
            exe = os.path.join(work, "hand_%s_%d" % (cc, n))
            sh([cc, "-std=c99", "-O2", "-ffp-contract=off", "-w", "-DTARGET=%d" % n, os.path.join(HN, "hamnth.c"), "-o", exe, "-lm"])
            cmds["hand C " + cc + " -O2"] = [exe]
        exe = os.path.join(work, "hn_rs"); sh(["rustc", "--edition", "2021", "-C", "opt-level=3", "-C", "debug-assertions=no", os.path.join(HN, "hamnth.rs"), "-o", exe])
        cmds["Rust"] = [exe, str(n)]
        res["hamnth_%d" % n] = measure(cmds, runs); print("hamnth", n, json.dumps(res["hamnth_%d" % n], indent=1), flush=True)
        json.dump(res, open(os.path.join(a.out, "startup_bench.json"), "w"), indent=1)
    json.dump(res, open(os.path.join(a.out, "startup_bench.json"), "w"), indent=1)
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
