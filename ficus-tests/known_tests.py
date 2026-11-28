#!/usr/bin/env python3
"""H16 tests of M.Known (K3, K4 of docs/H16-DESIGN.md section 3.1): every program in ficus-tests/known*/ (expected output = Elm 0.19.3
`expected/<name>.out`) is compiled with --rc in four settings - pass on with FICUS_KNOWN_CHECK=1 (scope checker), pass off
(FICUS_NO_KNOWN=1), pass on without expansion (FICUS_KNOWN_NO_EXPAND=1), pass on with a tiny budget (FICUS_KNOWN_BUDGET=20, FICUS_KNOWN_SPEC_BUDGET=20), pass on without specialization (FICUS_KNOWN_NO_SPEC=1) - and each result is
built with gcc under AddressSanitizer + UBSan (no pool) and with -O2, run, and compared with the expected output; a counted run must end with 0
live objects.

  python3 ficus-tests/known_tests.py --elm bin/elmficNN --elm-home H [--only known3,known4]   exit 1 on any failure"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "..", "..", "targets", "c")
SAFE = os.path.join(HERE, "..", "ficus-tools", "safe")
SETTINGS = [("on+check", {"FICUS_KNOWN_CHECK": "1"}), ("off", {"FICUS_NO_KNOWN": "1"}),
            ("no-expand", {"FICUS_KNOWN_NO_EXPAND": "1"}), ("budget20", {"FICUS_KNOWN_BUDGET": "20", "FICUS_KNOWN_SPEC_BUDGET": "20", "FICUS_KNOWN_CHECK": "1"}),
            ("no-spec", {"FICUS_KNOWN_NO_SPEC": "1", "FICUS_KNOWN_CHECK": "1"}),
            ("no-lifted", {"FICUS_NO_LIFTED_INLINE": "1", "FICUS_KNOWN_CHECK": "1"}),
            ("no-ident", {"FICUS_NO_IDENT": "1", "FICUS_KNOWN_CHECK": "1"}),
            ("no-spine", {"FICUS_S2_NO_SPINE": "1", "FICUS_KNOWN_CHECK": "1"}),
            ("no-inline2", {"FICUS_NO_INLINE2": "1", "FICUS_KNOWN_CHECK": "1"}),
            # H16 W7a (rule 2): the rule on with its checks, off, without filler forwarding, without Vector leaves (the rule is on by default after the gates)
            ("unbox", {"FICUS_S2_UNBOX_ACYCLIC": "1", "FICUS_UNBOX_CHECK": "1", "FICUS_KNOWN_CHECK": "1"}),
            ("no-unbox", {"FICUS_S2_NO_UNBOX": "1", "FICUS_KNOWN_CHECK": "1"}),
            ("no-unbox-ident", {"FICUS_S2_UNBOX_ACYCLIC": "1", "FICUS_S2_NO_UNBOX_IDENT": "1", "FICUS_UNBOX_CHECK": "1"}),
            ("unbox-novec", {"FICUS_S2_UNBOX_ACYCLIC": "1", "FICUS_S2_UNBOX_NOVEC": "1", "FICUS_UNBOX_CHECK": "1"})]
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
CHECK = ["-DFIC_UNBOX_CHECK"]                          # W7a: the sentinel count must be back at FIC_IMMORTAL at the end of a program that has workers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--only", default=""); ap.add_argument("--settings", default="")
    a = ap.parse_args()
    names = [n for n in sorted(os.listdir(HERE)) if n.startswith("known") and os.path.isdir(os.path.join(HERE, n, "src"))]
    if a.only: names = [n for n in names if n in a.only.split(",")]
    bad = 0
    settings = [x for x in SETTINGS if not a.settings or x[0] in a.settings.split(",")]
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    for n in names:
        want = open(os.path.join(HERE, "expected", n + ".out"), encoding="utf-8").read()
        mod = sorted(f for f in os.listdir(os.path.join(HERE, n, "src")) if f.endswith(".fic"))[0]
        for label, env in settings:
            d = os.path.join(tmp, n + "_" + label); shutil.copytree(os.path.join(HERE, n), d, ignore=shutil.ignore_patterns("elm-stuff"))
            p = subprocess.run([SAFE, os.path.abspath(a.elm), "make", "src/" + mod, "--output=x.c", "--rc"], cwd=d, capture_output=True,
                               env=dict(os.environ, ELM_HOME=a.elm_home, **env))
            if p.returncode != 0:
                print("FAIL %s [%s]: compiler exit %d\n%s" % (n, label, p.returncode, (p.stdout + p.stderr).decode()[-500:])); bad += 1; continue
            for tag, flags in (("san", SAN + ["-DFIC_STATS"] + CHECK), ("O2", ["-O2", "-DFIC_STATS"] + CHECK)):
                exe = os.path.join(d, "x_" + tag)
                b = subprocess.run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *flags, "-I", RT, os.path.join(d, "x.c"), "-o", exe, "-lm"], capture_output=True)
                if b.returncode != 0: print("FAIL %s [%s] %s: gcc %s" % (n, label, tag, b.stderr.decode()[-300:])); bad += 1; continue
                r = subprocess.run([exe], capture_output=True); got = r.stdout.decode("utf-8", "replace"); err = r.stderr.decode("utf-8", "replace")
                live0 = any(" live 0 " in l and l.startswith("FIC_STATS") for l in err.splitlines())
                if r.returncode != 0 or got != want or not live0:
                    print("FAIL %s [%s] %s: exit %d, output %s, live0 %s\n%s" % (n, label, tag, r.returncode, "same" if got == want else "DIFFERS", live0, err[-300:])); bad += 1
                else: print("ok   %s [%s] %s" % (n, label, tag))
            shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    print("known_tests: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
