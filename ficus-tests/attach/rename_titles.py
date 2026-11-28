#!/usr/bin/env python3
"""rename_titles.py -- the title renames of A5c (docs/A5-INFERENCE-DESIGN.md section 4, decision D7).  Standard library only.

  python3 ficus-tests/attach/rename_titles.py [--dry]

1. Rewrites the titles in column 3 of expected.tsv (split on `;`).
2. Rewrites the quoted titles ("..." or '...') in the generators that write rows (g71expect.py, g70gen.py, g71gen.py,
   a3bgen.py, a5agen.py, a5bgen.py, a5fgen.py), so that a later --write gives the same rows.
3. Lists every REJECT row whose column 4 (the text the output must contain) uses a retired word: those are replaced by
   hand after the texts change (attach.py --print-reports shows the new first paragraphs)."""
import argparse, os, re

HERE = os.path.dirname(os.path.abspath(__file__))

TITLES = [
    ("MISSING CONSTRAINT", "INCOMPLETE TYPE ANNOTATION"),
    ("UNKNOWN MEMBER TYPE", "AMBIGUOUS TYPE"),
    ("NO MEMBER", "NO ATTACHED FUNCTION"),
    ("MEMBER TYPE MISMATCH", "ATTACHED FUNCTION MISMATCH"),
    ("MEMBER WITHOUT TYPE ANNOTATION", "ATTACHED FUNCTION WITHOUT TYPE ANNOTATION"),
    ("WELL KNOWN MEMBER WITH THE WRONG TYPE", "OPERATOR FUNCTION WITH THE WRONG TYPE"),
    ("WELL KNOWN MEMBER WITHOUT TYPE ANNOTATION", "OPERATOR FUNCTION WITHOUT TYPE ANNOTATION"),
    ("AMBIGUOUS CONSTRAINT", "UNUSED VARIABLE IN WHERE"),
    ("CONSTRAINTS ON A LOCAL DEFINITION", "WHERE ON A LOCAL DEFINITION"),
    ("UNFINISHED CONSTRAINTS", "UNFINISHED WHERE"),
    ("PROBLEM IN CONSTRAINT", "PROBLEM IN WHERE"),
    ("CONSTRAINED FUNCTIONS", "NOT AVAILABLE IN JAVASCRIPT YET"),
]
OLD = dict(TITLES)

GENERATORS = ["g71expect.py", "g70gen.py", "g71gen.py", "a3bgen.py", "a5agen.py", "a5bgen.py", "a5fgen.py"]

RETIRED = re.compile(r"\b(constraints?|constrained|members?|obligations?|instances?|bundles?)\b", re.I)


def rename_tsv(path, dry):
    out, changed = [], 0
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if not line.startswith("#") and len(f) >= 3 and f[1].startswith("REJECT"):
            titles = [OLD.get(t, t) for t in f[2].split(";")]
            if ";".join(titles) != f[2]:
                f[2] = ";".join(titles); changed += 1
                line = "\t".join(f) + "\n"
        out.append(line)
    if not dry: open(path, "w", encoding="utf-8").writelines(out)
    return changed


def rename_py(path, dry):
    src = open(path, encoding="utf-8").read()
    new = src
    for old, title in TITLES:
        new = new.replace('"%s"' % old, '"%s"' % title).replace("'%s'" % old, "'%s'" % title)
    if new != src and not dry: open(path, "w", encoding="utf-8").write(new)
    return new != src


def retired_texts(path):
    rows = []
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if not line.startswith("#") and len(f) >= 4 and f[1].startswith("REJECT") and RETIRED.search(f[3]):
            rows.append((f[0], f[2], f[3]))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    tsv = os.path.join(HERE, "expected.tsv")
    print("expected.tsv: %d rows renamed" % rename_tsv(tsv, a.dry))
    for g in GENERATORS:
        p = os.path.join(HERE, g)
        if os.path.exists(p) and rename_py(p, a.dry): print("%s: renamed" % g)
    rows = retired_texts(tsv)
    print("%d REJECT rows whose text uses a retired word:" % len(rows))
    for cid, titles, text in rows:
        print("  %-36s %-40s %s" % (cid, titles, text))


if __name__ == "__main__":
    main()
