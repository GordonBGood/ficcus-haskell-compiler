#!/usr/bin/env python3
"""H16 W7a (from w6_identity.py): the C text of the 16 suite programs made by a new compiler against a reference compiler (default bin/elmficW6), for each setting:
`norc` (--no-rc), `rc-off` (--rc, FICCUS_NO_KNOWN=1), `rc-allstage2off` (--rc, all four stage 2 switches), `rc-w5` (--rc, the W6 switches off) and `rc` (--rc, the defaults). Whole text compared. The first five must be identical; the others list the programs whose text changes (information).

  python3 ficcus-tests/w6_identity.py --new bin/elmficW6 --elm-home H [--old bin/elmficM1]        exit 1 when a required setting differs"""
import argparse, hashlib, json, os, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from norc_identity import c_text                      # noqa: E402

SETTINGS = [("norc", "--no-rc", {}, True), ("norc-unbox", "--no-rc", {"FICCUS_S2_UNBOX_ACYCLIC": "1"}, True), ("rc-off", "--rc", {"FICCUS_NO_KNOWN": "1"}, True),
            ("rc-nounbox", "--rc", {"FICCUS_S2_NO_UNBOX": "1"}, True), ("rc-allstage2off", "--rc", {"FICCUS_NO_LIFTED_INLINE": "1", "FICCUS_NO_IDENT": "1", "FICCUS_S2_NO_SPINE": "1", "FICCUS_NO_INLINE2": "1", "FICCUS_S2_NO_UNBOX": "1"}, True),
            ("rc-unbox", "--rc", {"FICCUS_S2_UNBOX_ACYCLIC": "1"}, False), ("rc", "--rc", {}, False)]


def digest(t): return None if t is None else hashlib.sha256(t).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--old", default=os.path.join(HERE, "..", "..", "bin", "elmficM1"))
    a = ap.parse_args()
    suite = json.load(open(os.path.join(HERE, "runall", "suite.json")))["tests"]
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR")); bad = 0
    for label, flags, env, must in SETTINGS:
        diff = []
        for t in suite:
            src = os.path.normpath(os.path.join(HERE, "runall", t["fic"]))
            saved = dict(os.environ); os.environ.update(env)
            try:
                o = digest(c_text(a.old, a.elm_home, src, os.path.join(tmp, "o.c"), flags)); n = digest(c_text(a.new, a.elm_home, src, os.path.join(tmp, "n.c"), flags))
            finally:
                os.environ.clear(); os.environ.update(saved)
            if o is None or o != n: diff.append(t["name"])
        print("%-12s %2d of %d identical to %s%s" % (label, len(suite) - len(diff), len(suite), os.path.basename(a.old), ("; differ: " + ",".join(diff)) if diff else ""))
        if must and diff: bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
