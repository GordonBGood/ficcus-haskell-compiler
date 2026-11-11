#!/usr/bin/env python3
"""The no-RC output is the oracle of stage (iv): the C text that two compilers make WITHOUT --rc for the 16 suite programs must be
byte identical (so the no-RC programs, whose large builds never free and need gigabytes, need not be run again).

  python3 ficcus-tests/norc_identity.py --old bin/elmfic46 --new bin/elmficNN --elm-home H"""
import argparse, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True); ap.add_argument("--new", required=True); ap.add_argument("--elm-home", required=True)
    a = ap.parse_args()
    suite = json.load(open(os.path.join(HERE, "runall", "suite.json")))["tests"]
    bad = 0
    tmp = tempfile.mkdtemp()
    for t in suite:
        src = os.path.normpath(os.path.join(HERE, "runall", t["fic"]))
        texts = []
        for tag, elm in (("old", a.old), ("new", a.new)):
            out = os.path.join(tmp, "%s_%s.c" % (t["name"], tag))
            p = subprocess.run([os.path.join(HERE, "ficc"), src, "-o", out], env=dict(os.environ, FICCUS_ELM=os.path.abspath(elm), ELM_HOME=a.elm_home, FICCUS_FLAGS=""), capture_output=True, text=True)
            texts.append(open(out, "rb").read() if p.returncode == 0 and os.path.exists(out) else None)
        ok = texts[0] is not None and texts[0] == texts[1]
        bad += 0 if ok else 1
        print("%-22s %s" % (t["name"], "identical" if ok else "DIFFERENT"))
    print("no-RC C text: %d of %d identical" % (len(suite) - bad, len(suite)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
