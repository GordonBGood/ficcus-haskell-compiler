#!/usr/bin/env python3
"""H16 pass-off identity: with FICUS_NO_KNOWN=1 the --rc C text of the 16 suite programs made by a new compiler (the one with M.Known)
must be byte identical to the --rc text of the compiler before the pass (default bin/elmficA16). The whole text is compared (runtime and
generated part). Without FICUS_NO_KNOWN the pass is on: the programs whose text then differs are listed (information only).

  python3 ficus-tests/known_off_identity.py --new bin/elmficK1 --elm-home H [--old bin/elmficA16]        exit 1 on any difference"""
import argparse, hashlib, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from norc_identity import c_text                      # noqa: E402


def digest(t): return None if t is None else hashlib.sha256(t).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--old", default=os.path.join(HERE, "..", "..", "bin", "elmficA16"))
    a = ap.parse_args()
    suite = json.load(open(os.path.join(HERE, "runall", "suite.json")))["tests"]
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    bad, changed_on = 0, []
    for t in suite:
        n = t["name"]
        src = os.path.normpath(os.path.join(HERE, "runall", t["fic"]))
        old = digest(c_text(a.old, a.elm_home, src, os.path.join(tmp, n + "_old.c"), "--rc"))
        os.environ["FICUS_NO_KNOWN"] = "1"
        off = digest(c_text(a.new, a.elm_home, src, os.path.join(tmp, n + "_off.c"), "--rc"))
        del os.environ["FICUS_NO_KNOWN"]
        on = digest(c_text(a.new, a.elm_home, src, os.path.join(tmp, n + "_on.c"), "--rc"))
        ok = old is not None and old == off
        bad += 0 if ok else 1
        if on != old: changed_on.append(n)
        print("%-22s %s" % (n, "identical" if ok else "DIFFERENT (pass off) or compile failure"))
        for s in ("old", "off", "on"): os.remove(os.path.join(tmp, "%s_%s.c" % (n, s))) if os.path.exists(os.path.join(tmp, "%s_%s.c" % (n, s))) else None
    print("--rc C text with FICUS_NO_KNOWN=1: %d of %d identical to %s" % (len(suite) - bad, len(suite), os.path.basename(a.old)))
    print("pass ON changes the text of %d programs: %s" % (len(changed_on), ",".join(changed_on) or "none"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
