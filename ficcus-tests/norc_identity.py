#!/usr/bin/env python3
"""The no-RC output is the oracle of stage (iv): the C text that a compiler makes WITHOUT --rc for the 16 suite programs must not
change (so the no-RC programs, whose large builds never free and need gigabytes, need not be run again).

The reference is a file in the repository, ficcus-tests/expected/norc_identity.sha256 (one SHA-256 per program, and the binary
that made it). Check (default, exit 1 on any difference):

  python3 ficcus-tests/norc_identity.py --new bin/elmficNN --elm-home H

Refresh (only when a slice changes the no-RC C text ON PURPOSE; it never happens as a side effect of a check):

  python3 ficcus-tests/norc_identity.py --new bin/elmficNN --elm-home H --update --reason "why the text changes"

--update needs --reason, prints every program whose hash changes, rewrites the reference file and appends a line (date, binary,
reason, changed programs) to ficcus-tests/expected/norc_identity.log. Both files are tracked, so the refresh is a visible diff in
the commit. A program that does not compile, or is missing from the reference, is never written silently: --update refuses.

  --old bin/elmficOLD   compares two binaries directly instead of the reference file (the S3 way)."""
import argparse, datetime, hashlib, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "expected", "norc_identity.sha256")
LOG = os.path.join(HERE, "expected", "norc_identity.log")


def c_text(elm, home, src, out):
    p = subprocess.run([os.path.join(HERE, "ficc"), src, "-o", out],
                       env=dict(os.environ, FICCUS_ELM=os.path.abspath(elm), ELM_HOME=home, FICCUS_FLAGS=""), capture_output=True, text=True)
    return open(out, "rb").read() if p.returncode == 0 and os.path.exists(out) else None


def read_ref():
    ref, binary = {}, "?"
    if os.path.exists(REF):
        for l in open(REF):
            if l.startswith("# binary:"): binary = l.split(":", 1)[1].strip()
            elif l.strip() and not l.startswith("#"):
                h, n = l.split(); ref[n] = h
    return ref, binary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--old", default=None, help="compare with this binary instead of the reference file")
    ap.add_argument("--update", action="store_true"); ap.add_argument("--reason", default=None)
    a = ap.parse_args()
    if a.update and (not a.reason or a.old): ap.error("--update needs --reason \"...\" (and no --old)")
    suite = json.load(open(os.path.join(HERE, "runall", "suite.json")))["tests"]
    ref, ref_bin = read_ref()
    tmp = tempfile.mkdtemp()
    bad, new = 0, {}
    for t in suite:
        n = t["name"]
        src = os.path.normpath(os.path.join(HERE, "runall", t["fic"]))
        text = c_text(a.new, a.elm_home, src, os.path.join(tmp, n + "_new.c"))
        new[n] = hashlib.sha256(text).hexdigest() if text is not None else None
        if a.old:
            old = c_text(a.old, a.elm_home, src, os.path.join(tmp, n + "_old.c"))
            ok = text is not None and text == old
        else:
            ok = new[n] is not None and ref.get(n) == new[n]
        bad += 0 if ok else 1
        print("%-22s %s" % (n, "identical" if ok else ("DIFFERENT" if new[n] and n in ref or a.old else "NOT IN REFERENCE / COMPILE FAIL")))
    print("no-RC C text: %d of %d identical to %s" % (len(suite) - bad, len(suite), a.old or "the reference (%s)" % ref_bin))
    if not a.update: return 1 if bad else 0
    if any(v is None for v in new.values()): print("refusing to update: a program does not compile"); return 1
    changed = [n for n in new if ref.get(n) != new[n]]
    with open(REF, "w") as f:
        f.write("# SHA-256 of the no-RC C text of the 16 suite programs (ficcus-tests/norc_identity.py). Refresh only with --update --reason.\n")
        f.write("# binary: %s\n" % os.path.basename(a.new))
        for n in new: f.write("%s %s\n" % (new[n], n))
    with open(LOG, "a") as f:
        f.write("%s  %s  changed: %s  reason: %s\n" % (datetime.date.today().isoformat(), os.path.basename(a.new), ",".join(changed) or "none (first entry)", a.reason))
    print("reference updated (%d programs changed): %s" % (len(changed), ",".join(changed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
