#!/usr/bin/env python3
"""H16 W7a (rule 2) tests beyond known_tests.py: for each of known14..known17 the rule is on (FICCUS_S2_UNBOX_ACYCLIC=1 with FICCUS_UNBOX_CHECK=1) and off
(FICCUS_S2_NO_UNBOX=1); both builds (AddressSanitizer + UBSan, -DFIC_STATS -DFIC_UNBOX_CHECK) must print the Elm 0.19.3 golden and end with 0 live objects,
the number of in place and copied updates (`inplace`, `copied`, `vec_copy` of FIC_STATS) must be equal in both (the vector shapes V1 to V5 of the design note
do not change behaviour), the rule must make workers in known14, known15, known16 and none in known17 (FICCUS_UNBOX_STATS), and the `--no-rc` text must be
identical in both settings.

  python3 ficcus-tests/unbox_tests.py --elm bin/elmficNN --elm-home H [--only known14,known16]"""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "..", "..", "targets", "c")
SAFE = os.path.join(HERE, "..", "ficcus-tools", "safe")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
EXPECT_WORKERS = {"known14": True, "known15": True, "known16": True, "known17": False}


def build(a, d, mod, env, extra, tag):
    p = subprocess.run([SAFE, os.path.abspath(a.elm), "make", "src/" + mod, "--output=x_%s.c" % tag] + extra, cwd=d, capture_output=True, env=dict(os.environ, ELM_HOME=a.elm_home, **env))
    return p


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--only", default="")
    a = ap.parse_args()
    names = [n for n in sorted(EXPECT_WORKERS) if not a.only or n in a.only.split(",")]
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR")); bad = 0
    for n in names:
        want = open(os.path.join(HERE, "expected", n + ".out"), encoding="utf-8").read()
        d = os.path.join(tmp, n); shutil.copytree(os.path.join(HERE, n), d, ignore=shutil.ignore_patterns("elm-stuff"))
        mod = sorted(f for f in os.listdir(os.path.join(d, "src")) if f.endswith(".fic"))[0]
        stats = {}
        for tag, env in (("on", {"FICCUS_S2_UNBOX_ACYCLIC": "1", "FICCUS_UNBOX_CHECK": "1", "FICCUS_UNBOX_STATS": "1"}), ("off", {"FICCUS_S2_NO_UNBOX": "1", "FICCUS_UNBOX_STATS": "1"})):
            p = build(a, d, mod, env, ["--rc"], tag)
            if p.returncode != 0: print("FAIL %s [%s]: compiler exit %d\n%s" % (n, tag, p.returncode, (p.stdout + p.stderr).decode()[-600:])); bad += 1; continue
            workers = int((re.search(r"FICCUS_UNBOX_STATS: workers (\d+)", p.stderr.decode()) or [0, "0"])[1]) if tag == "on" else 0
            exe = os.path.join(d, "x_" + tag)
            b = subprocess.run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *SAN, "-DFIC_STATS", "-DFIC_UNBOX_CHECK", "-I", RT, os.path.join(d, "x_%s.c" % tag), "-o", exe, "-lm"], capture_output=True)
            if b.returncode != 0: print("FAIL %s [%s]: gcc %s" % (n, tag, b.stderr.decode()[-300:])); bad += 1; continue
            r = subprocess.run([exe], capture_output=True); got = r.stdout.decode("utf-8", "replace"); err = r.stderr.decode("utf-8", "replace")
            m = re.search(r"FIC_STATS: .* live (\d+) .*inplace (\d+) copied (\d+) .*vec_copy (\d+)", err)
            stats[tag] = (m.groups() if m else None, workers)
            if r.returncode != 0 or got != want or not m or m.group(1) != "0":
                print("FAIL %s [%s]: exit %d, output %s, stats %s\n%s" % (n, tag, r.returncode, "same" if got == want else "DIFFERS", m and m.groups(), err[-300:])); bad += 1
        if "on" in stats and "off" in stats:
            if stats["on"][0] is not None and stats["on"][0][1:] != stats["off"][0][1:]:
                print("FAIL %s: in place / copied / vec_copy differ: on %s, off %s" % (n, stats["on"][0][1:], stats["off"][0][1:])); bad += 1
            if (stats["on"][1] > 0) != EXPECT_WORKERS[n]:
                print("FAIL %s: %d workers, expected %s" % (n, stats["on"][1], "some" if EXPECT_WORKERS[n] else "none")); bad += 1
            # --no-rc text identical with the rule on and off
            t = {}
            for tag, env in (("on", {"FICCUS_S2_UNBOX_ACYCLIC": "1"}), ("off", {"FICCUS_S2_NO_UNBOX": "1"})):
                p = build(a, d, mod, env, ["--no-rc"], "norc_" + tag)
                t[tag] = open(os.path.join(d, "x_norc_%s.c" % tag), "rb").read() if p.returncode == 0 else None
            if t["on"] is None or t["on"] != t["off"]: print("FAIL %s: the --no-rc text differs"); bad += 1
            else: print("ok   %s: workers %d, inplace/copied %s, no-rc identical" % (n, stats["on"][1], stats["on"][0][1:] if stats["on"][0] else None))
        shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    print("unbox_tests: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
