#!/usr/bin/env python3
"""Expected-file test of the small example projects (fib, poly, rec, init, marks).

For each ficcus-tests/<name>/ (elm.json, src/<Name>.fic) runs `elm make src/<Name>.fic --output=x.mono` in a copy,
which writes x.mono and x.types, and compares the project part of both (the package modules are left out; the `-- program` section of .mono is kept)
with ficcus-tests/expected/<name>.types and <name>.mono.

  python3 ficcus-tests/examples.py --elm bin/elmfic16 --safe tools/safe --elm-home H [--update] [--only rec,init]
Exit status 1 on any difference.
"""
import argparse, os, shutil, subprocess, sys, tempfile, difflib

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = ["fib", "poly", "rec", "init", "marks", "log", "num", "poly3a", "groups", "clo", "lists", "bits", "order", "eqcmp", "dict", "nan", "eqfun", "ovl", "arr", "upd", "str", "rows", "acc", "letnum", "str2", "init2", "silly", "grow1", "grow2", "grow3", "lit", "dbg", "parse", "unres", "rand", "synt", "evo"]
RUN = ["fib", "log", "num", "poly3a", "groups", "clo", "lists", "bits", "order", "eqcmp", "dict", "nan", "eqfun", "ovl", "arr", "upd", "str", "rows", "acc", "letnum", "str2", "init2", "silly", "grow3", "lit", "dbg", "parse", "unres", "rand", "synt", "evo"]      # also compiled to C (--output=x.c), built with gcc and clang and run: expected/<name>.out


CRASH = {"eqfun": "Trying to use `(==)` on functions."}      # programs that end with a run time error: exit status 1 and this text on stderr


def project_part(text, kind):
    out, skipping = [], False
    for line in text.split("\n"):
        if kind == "types" and line.startswith("-- package"): break
        if kind == "mono":                       # the package modules are left out, the program section stays
            if line.startswith("-- module ") and line.endswith("(package)"): skipping = True
            elif line.startswith("-- module ") or line.startswith("-- program"): skipping = False
            if skipping: continue
        out.append(line)
    return "\n".join(out).rstrip("\n") + "\n"


def clone_counts(mono_text):
    """plan risk R1: the number of clones of each definition in the `-- program` section (lifted local functions count
    by their definition id, which includes the source position)"""
    counts, inside = {}, False
    for line in mono_text.split("\n"):
        if line.startswith("-- program"): inside = True; continue
        if line.startswith("-- module "): inside = False
        if inside and line.startswith("clone c"):
            d = line.split("   def: ", 1)[1].split("   key: ", 1)[0]
            counts[d] = counts.get(d, 0) + 1
    return counts


# FIC_DROP_ALL=1: build every example with -DFIC_DROP_ALL (STAGE4-PLAN S0: the layout check and the free of every object at exit);
# FIC_CFLAGS adds other C flags (e.g. -DFIC_STATS)
DROP_ALL = bool(os.environ.get("FIC_DROP_ALL"))
EXTRA = (["-DFIC_DROP_ALL"] if DROP_ALL else []) + os.environ.get("FIC_CFLAGS", "").split()


def run_c(a, dst, name, mod):
    """--output=x.c, build with gcc and clang (the flags of targets/suite.json), run, compare with expected/<name>.out"""
    env = dict(os.environ, ELM_HOME=a.elm_home)
    p = subprocess.run([a.safe, a.elm, "make", "src/" + mod, "--output=x.c"], cwd=dst, env=env, capture_output=True)
    if p.returncode != 0:
        print("FAIL %s.c: compiler exit %d\n%s" % (name, p.returncode, (p.stdout + p.stderr).decode()[-400:])); return 1
    pre = "".join(open(os.path.join(HERE, "..", "runtime", f), encoding="utf-8").read()
                  for f in ("fic_rt.h", "fic_base.h", "fic_string.h", "fic_num.h", "fic_format.h", "fic_debug.h"))
    if not open(os.path.join(dst, "x.c"), encoding="utf-8").read().startswith(pre):
        print("FAIL %s.c: the file does not start with the runtime/ files" % name); return 1
    want = open(os.path.join(HERE, "expected", name + ".out"), encoding="utf-8").read()
    rt = os.path.join(HERE, "..", "..", "targets", "c")
    bad = 0
    if name == "lit":       # the UTF-8 bytes of the literals in the generated C (octal escapes), for every length boundary
        c_text = open(os.path.join(dst, "x.c"), encoding="utf-8", errors="replace").read()
        for cp in (0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFD, 0xFFFF, 0x10000, 0x1F623, 0x10FFFF):
            lit = "".join("\\%03o" % b for b in chr(cp).encode("utf-8"))
            if ('"' + lit + '"') not in c_text: print("FAIL lit.c: bytes of U+%X (%s) not found as a literal" % (cp, lit)); bad += 1
            else: print("ok   lit.c bytes of U+%X" % cp)
    for cc in ("gcc", "clang"):
        if shutil.which(cc) is None: continue
        exe = os.path.join(dst, "x_" + cc)
        b = subprocess.run([cc, "-std=c99", "-pedantic", "-Wall", "-Wextra", "-Wno-unused-function", "-ffp-contract=off", "-O2",
                            *EXTRA, "-I", rt, os.path.join(dst, "x.c"), "-o", exe, "-lm"], capture_output=True)
        if b.returncode != 0 or b.stderr:
            print("FAIL %s.c %s: %s" % (name, cc, b.stderr.decode()[-300:])); bad += 1; continue
        r = subprocess.run([exe], capture_output=True)
        got = r.stdout.decode("utf-8", "replace")
        crash = CRASH.get(name)
        if (r.returncode != (1 if crash else 0)) or got != want or (crash and crash not in r.stderr.decode("utf-8", "replace")):
            print("FAIL %s.c %s: exit %d, output differs" % (name, cc, r.returncode))
            sys.stdout.writelines(list(difflib.unified_diff(want.splitlines(True), got.splitlines(True), "expected", "got"))[:20]); bad += 1
        elif DROP_ALL and not crash and ("FIC_DROP_ALL: " not in r.stderr.decode("utf-8", "replace") or " 0 bad, 0 live" not in r.stderr.decode("utf-8", "replace")):
            print("FAIL %s.c %s: FIC_DROP_ALL check: %s" % (name, cc, r.stderr.decode("utf-8", "replace")[-300:])); bad += 1
        else: print("ok   %s.c (%s)%s" % (name, cc, " " + r.stderr.decode("utf-8", "replace").strip().splitlines()[-1] if DROP_ALL and not crash else ""))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--safe", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--update", action="store_true"); ap.add_argument("--only")
    a = ap.parse_args()
    bad = 0
    R1.clear()
    if not a.update and not a.only:       # the runtime C files, compiled and tested standalone
        t = subprocess.run([os.path.join(HERE, "..", "runtime", "test.sh")], capture_output=True, text=True)
        print(t.stdout.strip() if t.returncode == 0 else "FAIL runtime/test.sh\n" + t.stdout + t.stderr); bad += 1 if t.returncode else 0
    if not a.update and not a.only:       # the compile time checks of the C back end (decisions L2, L9)
        r = subprocess.run([sys.executable, os.path.join(HERE, "rejects.py"), "--elm", a.elm, "--safe", a.safe, "--elm-home", a.elm_home], capture_output=True, text=True)
        print(r.stdout.strip()); bad += 1 if r.returncode else 0
    for name in (a.only.split(",") if a.only else NAMES):
        src = os.path.join(HERE, name)
        mod = sorted(f for f in os.listdir(os.path.join(src, "src")) if f.endswith(".fic"))[0]
        work = tempfile.mkdtemp()
        dst = os.path.join(work, name)
        shutil.copytree(src, dst, ignore=shutil.ignore_patterns("elm-stuff"))
        p = subprocess.run([a.safe, a.elm, "make", "src/" + mod, "--output=x.mono"], cwd=dst,
                           env=dict(os.environ, ELM_HOME=a.elm_home), capture_output=True)
        if p.returncode != 0:
            print("FAIL %s: compiler exit %d\n%s" % (name, p.returncode, (p.stdout + p.stderr).decode()[-400:])); bad += 1; continue
        counts = clone_counts(open(os.path.join(dst, "x.mono"), encoding="utf-8").read())
        if counts:
            top = max(counts.values())
            many = sorted([(n, d) for d, n in counts.items() if n > 1], reverse=True)
            print("R1   %s: %d clones of %d definitions, most clones of one definition: %d (%s)%s" % (
                name, sum(counts.values()), len(counts), top, ", ".join(d.split(":", 1)[-1] for n, d in many if n == top),
                "; " + ", ".join("%s %d" % (d.split(":", 1)[-1], n) for n, d in many) if many else ""))
            R1[name] = top
        for kind in ("types", "mono"):
            got = project_part(open(os.path.join(dst, "x." + kind), encoding="utf-8").read(), kind)
            path = os.path.join(HERE, "expected", name + "." + kind)
            if a.update:
                open(path, "w", encoding="utf-8").write(got); print("updated", path); continue
            want = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if got == want: print("ok   %s.%s" % (name, kind))
            else:
                bad += 1; print("DIFF %s.%s" % (name, kind))
                sys.stdout.writelines(list(difflib.unified_diff(want.splitlines(True), got.splitlines(True), "expected", "got"))[:40])
        if name in RUN and not a.update:
            bad += run_c(a, dst, name, mod)
            if name == "num" and shutil.which("node"):       # the float formatting routine against node (also: float_format.py alone)
                f = subprocess.run([sys.executable, os.path.join(HERE, "float_format.py"), "--c", os.path.join(dst, "x.c"), "--n", "20000"], capture_output=True, text=True)
                print(("ok   float format: " if f.returncode == 0 else "FAIL float format: ") + f.stdout.strip()); bad += 1 if f.returncode else 0
        shutil.rmtree(work, ignore_errors=True)
    if R1:
        worst = max(R1, key=R1.get)
        print("R1   largest number of clones of one definition in any project: %d (%s)" % (R1[worst], worst))
    return 1 if bad else 0


R1 = {}


if __name__ == "__main__":
    sys.exit(main())
