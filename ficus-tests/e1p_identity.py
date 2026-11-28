#!/usr/bin/env python3
"""E1p identity (docs/E1P-DESIGN.md section 4, step 5 of the slice): the C text may change only where a leaf split happens.

  1. FICUS_NO_LEAFSPLIT=1: the --rc and --no-rc C text of every program is byte identical to the reference binary's (elmficG70a).
  2. The split on, --no-rc: identical too (the split is in the Rc pass only).
  3. The split on, --rc: the C is cut at the `/* cNN name key */` markers; every function that differs must have at least one split
     in FICUS_SPLIT_STATS (the separate `_spN` counter, and Rc's `fresh` counter set after a split clone to its value without the
     split, keep every other function's text; CGen's temporaries are renumbered per function first), and the static number of
     `fic_dup(` + `fic_drop(` per changed function is reported (it should not grow; the report lists any that does).
Programs: the 16 of ficus-tests/runall/suite.json; with --more also ficus-tests/{e1p,effects,effects2}/src/*.fic.
  python3 ficus-tests/e1p_identity.py --elm bin/elmficNN --ref bin/elmficG70a --elm-home H [--more] [--verbose]
Each compile runs in a fresh copy of the program's project (no elm-stuff shared between the binaries). Exit 1 on a violation."""
import argparse, glob, json, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
MARK = re.compile(r"^/\* c(\d+) (\S+)", re.M)


def programs(more):
    suite = json.load(open(os.path.join(HERE, "runall", "suite.json")))
    out = [(t["name"], os.path.normpath(os.path.join(HERE, "runall", t["fic"]))) for t in suite["tests"]]
    if more:
        for d in ("e1p", "effects", "effects2"):
            out += [(os.path.basename(f)[:-4], f) for f in sorted(glob.glob(os.path.join(HERE, d, "src", "*.fic")))]
    return out


def project_of(src):
    d = os.path.dirname(src)
    while not os.path.exists(os.path.join(d, "elm.json")) and d != "/":
        d = os.path.dirname(d)
    return d


def compile_c(elm, home, src, flags, env_extra, tmp):
    proj = project_of(src)
    work = tempfile.mkdtemp(dir=tmp)
    w = os.path.join(work, "p")
    shutil.copytree(proj, w, ignore=shutil.ignore_patterns("elm-stuff"))
    out = os.path.join(work, "out.c")
    p = subprocess.run([elm, "make", os.path.relpath(src, proj), "--output=" + out] + flags, cwd=w, capture_output=True,
                       env=dict(os.environ, ELM_HOME=home, **env_extra))
    text = open(out).read() if p.returncode == 0 and os.path.exists(out) else None
    shutil.rmtree(work, ignore_errors=True)
    return text, p.stderr.decode()


def sections(text):
    """{clone id: (name, text)} of the functions, plus None: the text before the first marker"""
    ms = list(MARK.finditer(text))
    out = {None: ("(prelude)", text[: ms[0].start()] if ms else text)}
    for k, m in enumerate(ms):
        end = ms[k + 1].start() if k + 1 < len(ms) else len(text)
        out[int(m.group(1))] = (m.group(2), text[m.start():end])
    return out


# CGen's temporaries (CGen.fresh: one counter for the whole file, so a split function that needs fewer of them renumbers every later
# function): renumbered by first appearance in each function before the comparison. Not struct members (`.f0`, `->r0`).
TEMP = re.compile(r"(?<![.>\w])(old_upd|arr|bf|bo|bp|cv|fv|iv|ix|jr|ok|po|pv|pw|rest|rn|rp|rv|sb|sh|tail|todo|upd|uv|vg|vx|a|c|h|k|l|m|o|s|t|u)(\d+)\b")


def normal(t):
    seen = {}
    return TEMP.sub(lambda m: m.group(1) + "#" + str(seen.setdefault(m.group(0), len(seen))), t)


def counts(t):
    return t.count("fic_dup(") + t.count("fic_drop(")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--ref", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--more", action="store_true"); ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    elm, ref = os.path.abspath(a.elm), os.path.abspath(a.ref)
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    bad = 0
    changed_programs = []
    for name, src in programs(a.more):
        line = []
        # 1 and 2: byte identity
        for label, env, flags in (("nosplit --rc", {"FICUS_NO_LEAFSPLIT": "1"}, ["--rc"]), ("nosplit --no-rc", {"FICUS_NO_LEAFSPLIT": "1"}, ["--no-rc"]),
                                  ("split --no-rc", {}, ["--no-rc"])):
            new, err = compile_c(elm, a.elm_home, src, flags, env, tmp)
            old, err2 = compile_c(ref, a.elm_home, src, flags, {}, tmp)
            if new is None or old is None:
                print("FAIL %s %s: does not compile  %s" % (name, label, (err + err2)[-300:])); bad += 1; continue
            same = new == old
            line.append("%s %s" % (label, "identical" if same else "DIFFERS"))
            bad += 0 if same else 1
        # 3: the split on, --rc: per function
        new, err = compile_c(elm, a.elm_home, src, ["--rc"], {"FICUS_SPLIT_STATS": "1"}, tmp)
        old, err2 = compile_c(ref, a.elm_home, src, ["--rc"], {}, tmp)
        if new is None or old is None:
            print("FAIL %s split --rc: does not compile  %s" % (name, (err + err2)[-300:])); bad += 1; continue
        split = {}
        for m in re.finditer(r"FICUS_SPLIT_STATS: c(\d+) (\S+) (\d+)", err):
            split[int(m.group(1))] = int(m.group(3))
        sn, so = sections(new), sections(old)
        diff = sorted((k for k in set(sn) | set(so) if normal(sn.get(k, ("", ""))[1]) != normal(so.get(k, ("", ""))[1])),
                      key=lambda k: -1 if k is None else k)          # None: the prelude (the runtime), which E3a changes in port programs
        unexplained = [k for k in diff if k not in split]
        grown = [k for k in diff if k in sn and k in so and counts(sn[k][1]) > counts(so[k][1])]
        nosplitdiff = [k for k in split if k not in diff]
        status = "ok  " if not unexplained else "FAIL"
        bad += 1 if unexplained else 0
        line.append("split --rc: %d functions differ, %d split clones%s%s" % (
            len(diff), len(split), "" if not unexplained else ", UNEXPLAINED " + ",".join("c%s %s" % (k, (sn.get(k) or so.get(k))[0]) for k in unexplained),
            "" if not nosplitdiff else ", split but same text: " + ",".join("c%d" % k for k in nosplitdiff)))
        print("%s %s: %s" % (status, name, "; ".join(line)))
        if diff:
            changed_programs.append(name)
        for k in diff:
            nm = (sn.get(k) or so.get(k))[0]
            cn, co = counts(sn.get(k, ("", ""))[1]), counts(so.get(k, ("", ""))[1])
            if a.verbose or k in grown:
                print("       c%s %s: splits %d, static dup+drop %d -> %d%s" % (k, nm, split.get(k, 0), co, cn, "  (GROWS)" if k in grown else ""))
    shutil.rmtree(tmp, ignore_errors=True)
    print("e1p_identity: programs whose --rc text changes: %s" % (", ".join(changed_programs) or "none"))
    print("e1p_identity: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
