#!/usr/bin/env python3
"""Effects E1 step 3: the C text of the 16 suite programs made by the new compiler against a reference (default bin/elmficW7a), in two
modes (--no-rc, --rc). With the stepper on (the default) the text must change only by ADDING the update, subscriptions and stepper
functions and their call sites, plus the reviewed change of step 1 (init's pair type, Cmd.none, the box object of the pair).

Clone ids: update and subscriptions are cloned after the rest of the program (Spec.workerPhase), so the Spec clones keep their ids, but
the clones that the Known and Unbox passes (--rc) make get their ids above the highest Spec id: they shift by the number of new Spec
clones. The script maps every old name f<id>_x / val<id>_x / g<id>_x / code<id> / entry<id> / the c<id> of the comments with id >= the id of the new `update` clone to id + k
(k = the number of new Spec clones, from the text) before the diff, and reports that it did.

Every line the diff removes from the reference must be one of the step 1 lines; anything else is printed as a body change.
  python3 ficcus-tests/e1_additive.py --new bin/elmficE1c --elm-home H [--old bin/elmficW7a] [--keep DIR]     exit 1 on a body change"""
import argparse, difflib, json, os, re, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from norc_identity import c_text                      # noqa: E402

# step 1 (reviewed in its own commit): the pair (model, Cmd) of init gets a reference field, and Cmd.none is the static empty bag
STEP1 = [re.compile(p) for p in [r"typedef struct \{ uint8_t f0; uint8_t f1; \} fic_s_uu;", r"typedef struct \{ fic_hdr h; uint8_t s0; uint8_t s1; \} fic_o_SuuE;",
                                  r"static fic_s_uu f1_init\(uint8_t v__a0\)", r"return \(fic_s_uu\)\{ .*, 0 \};", r"\(void\)f1_init\(0\);"]]
NAME = re.compile(r"\b(?:(f|val|g)(\d+)(?=_)|(code|entry)(\d+)(?=_|\b))|(?<=/\* |m: )(c)(\d+)\b")


def renumber(text, first_new, k):
    def one(m):
        pre, num = next((m.group(i), m.group(i + 1)) for i in (1, 3, 5) if m.group(i))
        return pre + str(int(num) + k) if int(num) >= first_new else m.group(0)
    return NAME.sub(one, text)


def check(old, new):
    m = re.search(r"fic_r = f(\d+)_update\(fic_msg", new)          # the program's update: the stepper calls it
    shifted = ""
    if m:
        u = int(m.group(1))
        olds = {int(x) for x in re.findall(r"\bf(\d+)_", old)}
        news = {int(x) for x in re.findall(r"\bf(\d+)_", new)}
        # the new Spec clones: ids from u up to the first id that the old text also has (shifted Known/Unbox clones), at least 2
        above = sorted(i for i in olds if i >= u)
        if above:
            # k: the shift that puts the first old clone above `update` on the first new clone with the same name
            cands = sorted(j - above[0] for j in news if j > u and j - above[0] >= 1 and _same_suffix(old, above[0], new, j))
            k = cands[0] if cands else 0
            old = renumber(old, u, k); shifted = " (old ids >= %d shifted by %d)" % (u, k)
    removed = [l for l in difflib.unified_diff(old.splitlines(), new.splitlines(), lineterm="", n=0) if l.startswith("-") and not l.startswith("---")]
    bad = [l for l in removed if not any(p.search(l[1:]) for p in STEP1)]
    added = sum(1 for l in difflib.unified_diff(old.splitlines(), new.splitlines(), lineterm="", n=0) if l.startswith("+") and not l.startswith("+++"))
    return bad, len(removed), added, shifted


def _same_suffix(old, i, new, j):
    a = re.search(r"\bf%d_(\w+)" % i, old); b = re.search(r"\bf%d_(\w+)" % j, new)
    return bool(a and b and a.group(1) == b.group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--old", default=os.path.join(HERE, "..", "..", "bin", "elmficW7a")); ap.add_argument("--keep", default=None)
    a = ap.parse_args()
    suite = json.load(open(os.path.join(HERE, "runall", "suite.json")))["tests"]
    tmp = a.keep or tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR")); os.makedirs(tmp, exist_ok=True)
    nbad = 0; sizes = {}
    for flags in ("--no-rc", "--rc"):
        for t in suite:
            src = os.path.normpath(os.path.join(HERE, "runall", t["fic"]))
            o = c_text(a.old, a.elm_home, src, os.path.join(tmp, "o.c"), flags); n = c_text(a.new, a.elm_home, src, os.path.join(tmp, "n.c"), flags)
            if o is None or n is None:
                print("%-6s %-22s DOES NOT COMPILE" % (flags, t["name"])); nbad += 1; continue
            sizes.setdefault(flags, [0, 0]); sizes[flags][0] += len(o); sizes[flags][1] += len(n)
            bad, nrem, nadd, shifted = check(o.decode("utf-8", "replace"), n.decode("utf-8", "replace"))
            print("%-6s %-22s %s: +%d lines, -%d (all step 1)%s" % (flags, t["name"], "BODY CHANGE" if bad else "additive", nadd, nrem, shifted))
            for l in bad[:12]: print("        " + l)
            if bad: nbad += 1
    for flags, (o, n) in sizes.items():
        print("%s C text: %.1f KB -> %.1f KB (+%.1f KB, %+.2f%%) over the 16 programs" % (flags, o / 1024, n / 1024, (n - o) / 1024, 100.0 * (n - o) / o))
    print("e1_additive: %s" % ("%d programs change existing bodies" % nbad if nbad else "all additive"))
    return 1 if nbad else 0


if __name__ == "__main__":
    sys.exit(main())
