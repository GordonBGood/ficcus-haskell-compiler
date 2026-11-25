#!/usr/bin/env python3
"""E1 review (docs/E1-REVIEW.md): soundness of the model protocol beyond G17b. Programs in ficcus-tests/effects/src/R*.fic, Elm 0.19.3
goldens in expected/e1r_*.out (made from effects/ref/src/R*Ref.elm, where `init` folds `update` N times, as G17bRef does).

  R1Partial  `{ m | a = Array.set .. m.a, n = .. }` keeping a field (`d`): the common idiom; copies every step at ce4bdbf9
  R2Alias    two fields share one array (`b = m.a`) every third step; the set must copy exactly then
  R3History  old arrays kept in a list field of the model
  R4Lambda   fields read inside a lambda, a field read on one branch only, the whole model returned or logged on others
  R5Capture  a closure stored in the model captures the old array (a second owner, like a tagger); the set must copy every step

Each program runs N steps of the typed stepper (-DFIC_STEP_TEST=N), built with gcc -O2 and under ASan + UBSan (no pool), and with each
of the switches FICCUS_NO_MODEL_UNPACK=1 and FICCUS_NO_MODEL_SEED=1. Pass: output = Elm, live 0, no sanitizer report. The model copies
are printed; with --targets a program with a target also fails when it copies more (the targets hold after fix 1 of the review).
  python3 ficcus-tests/e1_review.py --elm bin/elmficNN --elm-home H [--targets]        exit 1 on any failure"""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "..", "..", "targets", "c")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
# (program, steps, model copies at ce4bdbf9, target after fix 1 or None)
PROGRAMS = [("R1Partial", 1000, 1960, 5), ("R2Alias", 30, 30, None), ("R3History", 40, 6, None), ("R4Lambda", 20, 0, 0),
            ("R5Capture", 12, 12, None)]
SWITCHES = [{}, {"FICCUS_NO_MODEL_UNPACK": "1"}, {"FICCUS_NO_MODEL_SEED": "1"}]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--targets", action="store_true")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    d = os.path.join(tmp, "effects"); shutil.copytree(os.path.join(HERE, "effects"), d, ignore=shutil.ignore_patterns("elm-stuff", "ref"))
    bad = 0
    for mod, n, now, target in PROGRAMS:
        want = open(os.path.join(HERE, "expected", "e1r_%s.out" % mod.lower())).read()
        for env in SWITCHES:
            label = mod + (" [" + ",".join("%s=%s" % kv for kv in env.items()) + "]" if env else "")
            c = os.path.join(tmp, mod + ".c")
            p = subprocess.run([os.path.abspath(a.elm), "make", "src/%s.fic" % mod, "--output=" + c, "--rc"], cwd=d, capture_output=True,
                               env=dict(os.environ, ELM_HOME=a.elm_home, **env))
            if p.returncode != 0:
                print("FAIL %s compiles  %s" % (label, (p.stdout + p.stderr).decode()[-300:])); bad += 1; continue
            for tag, cf in (("O2", ["-O2"]), ("san", SAN)):
                exe = os.path.join(tmp, mod + "_" + tag)
                b = subprocess.run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *cf, "-DFIC_STATS", "-DFIC_STEP_TEST=%d" % n, "-I", RT, c,
                                    "-o", exe, "-lm"], capture_output=True)
                if b.returncode != 0:
                    print("FAIL %s %s gcc  %s" % (label, tag, b.stderr.decode()[-300:])); bad += 1; continue
                r = subprocess.run([exe], capture_output=True)
                e = r.stderr.decode()
                m = re.search(r"FIC_STATS model: steps (\d+) .* model_copies (\d+)", e)
                copies = int(m.group(2)) if m else -1
                ok = r.returncode == 0 and r.stdout.decode() == want and " live 0 " in e and m is not None and int(m.group(1)) == n
                over = a.targets and not env and target is not None and copies > target
                note = "model copies %d (ce4bdbf9: %s, target: %s)" % (copies, now if not env else "-", target if target is not None and not env else "-")
                print(("ok   " if ok and not over else "FAIL ") + "%s %s: output = Elm, live 0, %s" % (label, tag, note)
                      + ("" if ok else "  " + (r.stdout.decode() + e)[-300:]))
                bad += 0 if ok and not over else 1
    shutil.rmtree(tmp, ignore_errors=True)
    print("e1_review: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
