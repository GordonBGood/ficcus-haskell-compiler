#!/usr/bin/env python3
"""run.py -- checks the examples of the user guide (docs/guide/*.md).  Standard library only; needs gcc (clang optional).

  python3 ficus-tests/guide/run.py [--elm bin/elmficA16] [--modes norc,rc,san] [--only a,b] [-v]
  python3 ficus-tests/guide/run.py --docs        # also check that every code block of the guide is a tested example

An example is a directory ficus-tests/guide/<name>/ with its sources (Main.fic and other modules, optional extra
source files in src/ layout: the directory itself is src/), and one of
  expect.out    standard output of the run (Debug.log lines); the three modes must all give it
  expect.err    the compiler's error report (from the first "-- TITLE ---" line on): the compile must fail with exactly this text
optional
  expect.stderr text the run writes on stderr that must appear (FIC_STATS / FIC_WARN_COPY examples)
  env.json      {"FIC_WARN_COPY": "1"}: environment of the run
  exit          expected exit status of the program (default 0; -6 = abort)
  cflags        extra C compiler flags (one line)
  vs-elm        `same` or `differs`: the example also runs as Elm 0.19.3 under node (Main.fic as Main.elm; node needed); `differs` keeps
                Elm's output in elm.out
  deps          packages the example needs besides elm/core and elm/json (elm/regex elm/parser elm/bytes elm/random elm/time)
  target        `js`: compile with --output=x.js, it must fail (an error example about the JavaScript output);
                `jsrun`: compile to JavaScript and run it with node (the output must equal expect.out)
Modes: norc  `--no-rc`, the oracle (never frees; the output is the reference)
       rc    `--rc`, built with -DFIC_STATS: the program must end with no live object
       san   `--rc` under AddressSanitizer + UBSan (-DFIC_NO_POOL, leaks reported)
A compile error example is compiled once (the error does not depend on the mode)."""
import argparse, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def find_root():
    d = HERE
    while d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, "bin")) and os.path.isdir(os.path.join(d, "targets", "c")): return d
        d = os.path.dirname(d)
    sys.exit("workspace root (with bin/ and targets/c) not found")


ROOT = find_root()
REF = ""
ELM_JSON = {"type": "application", "source-directories": ["src"], "elm-version": "0.19.3",
            "dependencies": {"direct": {"elm/core": "1.0.5"}, "indirect": {"elm/json": "1.1.3"}},
            "test-dependencies": {"direct": {}, "indirect": {}}}
TITLE = re.compile(r"^-- .+ -{10,}$", re.M)


VERSIONS = {"elm/json": "1.1.3", "elm/parser": "1.1.0", "elm/bytes": "1.0.8", "elm/regex": "1.0.0", "elm/random": "1.0.0", "elm/time": "1.0.0"}


def elm_json(name):
    """elm.json of the example: core and json, plus the packages named in the file `deps` (one per line)"""
    j = json.loads(json.dumps(ELM_JSON))
    for p in (read(os.path.join(HERE, name, "deps")) or "").split():
        j["dependencies"]["direct"][p] = VERSIONS[p]
        j["dependencies"]["indirect"].pop(p, None)
    if "elm/random" in j["dependencies"]["direct"]: j["dependencies"]["direct"]["elm/time"] = "1.0.0"
    return j


def sh(cmd, cwd, env=None, limit=120):
    e = dict(os.environ, **(env or {}))
    try:
        p = subprocess.run(cmd, cwd=cwd, env=e, capture_output=True, text=True, errors="replace", timeout=limit)
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    return p.returncode, p.stdout, p.stderr


def read(p):
    return open(p, encoding="utf-8").read() if os.path.exists(p) else None


def build(name, elm, mode, work):
    """compile example `name` in mode; returns (ok, text) where text is the compiler output on failure"""
    src = os.path.join(HERE, name)
    proj = os.path.join(work, "proj")
    shutil.rmtree(proj, ignore_errors=True)
    shutil.copytree(src, os.path.join(proj, "src"), ignore=shutil.ignore_patterns("expect.*", "env.json", "cflags", "target", "deps", "exit"))
    json.dump(elm_json(name), open(os.path.join(proj, "elm.json"), "w"))
    main = "src/Main.fic" if os.path.exists(os.path.join(proj, "src", "Main.fic")) else "src/Main.elm"
    flag = "--no-rc" if mode == "norc" else "--rc"
    target = (read(os.path.join(src, "target")) or "").strip()
    if target in ("js", "jsrun"):      # js: an example about the JavaScript output, it must fail to compile; jsrun: compile to JS and run with node
        rc, so, se = sh([elm, "make", main, "--output=" + os.path.join(work, "x.js")], proj)
        if target == "js" or rc != 0: return rc == 0, so + se
        return True, ["node", os.path.join(HERE, "elm-run.js"), os.path.join(work, "x.js")]
    out_c = os.path.join(work, "x.c")
    rc, so, se = sh([elm, "make", main, "--output=" + out_c, flag], proj)
    if rc != 0: return False, so + se
    cc = os.environ.get("CC", "gcc")
    extra = (read(os.path.join(src, "cflags")) or "").split()
    flags = ["-std=c99", "-O1", "-ffp-contract=off", "-w"]
    if mode in ("rc", "san"): flags.append("-DFIC_STATS")
    if mode == "san": flags += ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"]
    exe = os.path.join(work, "x")
    rc, so, se = sh([cc] + flags + extra + ["-I", os.path.join(ROOT, "targets", "c"), out_c, "-o", exe, "-lm"], work)
    if rc != 0: return False, "C COMPILER FAILED\n" + so + se
    return True, exe


def elm_run(name, work, ref):
    """the example as Elm 0.19.3 under node (Main.fic copied to Main.elm): stdout of the run, or the compile error text"""
    proj = os.path.join(work, "elmproj")
    shutil.rmtree(proj, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, name), os.path.join(proj, "src"), ignore=shutil.ignore_patterns("expect.*", "env.json", "cflags", "target", "deps", "exit", "elm.out", "vs-elm"))
    os.rename(os.path.join(proj, "src", "Main.fic"), os.path.join(proj, "src", "Main.elm"))
    json.dump(elm_json(name), open(os.path.join(proj, "elm.json"), "w"))
    rc, so, se = sh([ref, "make", "src/Main.elm", "--output=main.js"], proj)
    if rc != 0: return "COMPILE ERROR\n" + error_text(so + se)
    rc, so, se = sh(["node", os.path.join(HERE, "elm-run.js"), "main.js"], proj)
    if rc == 0: return so
    err = [l for l in se.split("\n") if l.startswith(("Error:", "RangeError:", "TypeError:"))]
    return so + "RUN ERROR: " + (err[0] if err else se.strip()[-200:]) + "\n"


def error_text(out):
    m = TITLE.search(out)
    return (out[m.start():] if m else out).rstrip("\n") + "\n"


def check_elm(name, ref, exp_out):
    """vs-elm: `same` = Elm 0.19.3 gives expect.out too; `differs` = Elm gives elm.out (kept so the guide can quote it)"""
    kind = (read(os.path.join(HERE, name, "vs-elm")) or "").strip()
    if not kind: return []
    with tempfile.TemporaryDirectory(prefix="guide-elm-") as work:
        got = elm_run(name, work, ref)
    if kind == "same": return [] if got == exp_out else ["Elm 0.19.3 differs, but vs-elm says same:\n--- ficus\n%s--- elm\n%s" % (exp_out, got)]
    want = read(os.path.join(HERE, name, "elm.out"))
    if want is None: return ["no elm.out (Elm gives:\n%s)" % got]
    if got != want: return ["Elm 0.19.3 output changed:\n--- elm.out\n%s--- now\n%s" % (want, got)]
    return [] if got != exp_out else ["vs-elm says differs, but Elm gives the same"]


def check(name, elm, modes, verbose):
    src = os.path.join(HERE, name)
    exp_out, exp_err, exp_stderr = (read(os.path.join(src, f)) for f in ("expect.out", "expect.err", "expect.stderr"))
    env = json.loads(read(os.path.join(src, "env.json")) or "{}")
    problems, runs = [], 0
    with tempfile.TemporaryDirectory(prefix="guide-") as work:
        if exp_err is not None:
            ok, text = build(name, elm, "rc", work)
            runs += 1
            if ok: problems.append("compiled, but an error was expected")
            elif error_text(text) != exp_err:
                problems.append("error text differs:\n--- expected\n%s--- got\n%s" % (exp_err, error_text(text)))
            return problems, runs
        for mode in (["rc"] if (read(os.path.join(src, "target")) or "").strip() == "jsrun" else modes):
            ok, text = build(name, elm, mode, work)
            runs += 1
            if not ok:
                problems.append("[%s] build failed:\n%s" % (mode, text[-1500:])); continue
            rc, so, se = sh(text if isinstance(text, list) else [text], work, env, limit=60)
            want = int((read(os.path.join(src, "exit")) or "0").strip())      # exit status of the program (-6: abort)
            if rc != want: problems.append("[%s] exit status %d, expected %d\n%s" % (mode, rc, want, (so + se)[-800:]))
            if so != exp_out: problems.append("[%s] output differs:\n--- expected\n%s--- got\n%s" % (mode, exp_out, so))
            if exp_stderr is not None and mode == "rc":
                for line in exp_stderr.strip().split("\n"):
                    if line not in se: problems.append("[%s] stderr lacks: %s\n--- stderr\n%s" % (mode, line, se))
    if REF and exp_out is not None: problems += check_elm(name, REF, exp_out); runs += 1
    return problems, runs


def check_docs(names):
    """every ```elm block of docs/guide/*.md preceded by <!-- guide: NAME/FILE --> must occur in that file; a block preceded by
    <!-- guide-out: NAME [err|stderr] --> must equal expect.out (expect.err, expect.stderr); a block without a marker is an error
    unless it is fenced as ```text or ```sh"""
    gd = os.path.join(os.path.dirname(os.path.dirname(HERE)), "docs", "guide")
    bad, n = [], 0
    for f in sorted(os.listdir(gd)):
        if not f.endswith(".md"): continue
        lines = open(os.path.join(gd, f), encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            if lines[i].startswith("```"):
                lang = lines[i][3:].strip()
                j = i + 1
                while not lines[j].startswith("```"): j += 1
                body = "\n".join(lines[i + 1:j]).strip("\n")
                marker = lines[i - 1].strip() if i else ""
                m = re.match(r"<!-- guide: (\S+)/(\S+) -->$", marker)
                o = re.match(r"<!-- guide-out: (\S+)(?: (err|stderr|elm))? -->$", marker)
                if m:
                    n += 1
                    text = read(os.path.join(HERE, m.group(1), m.group(2)))
                    if text is None: bad.append("%s:%d no file %s" % (f, i + 1, m.group(0)))
                    elif body.strip() not in text.strip().replace("\r", ""):
                        # allow blank-line differences: compare line lists with blank lines removed
                        a = [l.rstrip() for l in body.split("\n") if l.strip()]
                        t = [l.rstrip() for l in text.split("\n") if l.strip()]
                        if not any(t[k:k + len(a)] == a for k in range(len(t) - len(a) + 1)):
                            bad.append("%s:%d block is not in %s/%s" % (f, i + 1, m.group(1), m.group(2)))
                elif o:
                    n += 1
                    kind = {None: "expect.out", "err": "expect.err", "stderr": "expect.stderr", "elm": "elm.out"}[o.group(2)]
                    text = read(os.path.join(HERE, o.group(1), kind))
                    if text is None: bad.append("%s:%d no %s/%s" % (f, i + 1, o.group(1), kind))
                    else:
                        a = [l.rstrip() for l in body.split("\n")]
                        t = [l.rstrip() for l in text.strip("\n").split("\n")]
                        if kind == "expect.stderr": ok = all(l in t for l in a)
                        elif kind == "expect.err": ok = any(t[k:k + len(a)] == a for k in range(len(t) - len(a) + 1))      # a contiguous excerpt
                        else: ok = a == t
                        if not ok: bad.append("%s:%d block differs from %s/%s" % (f, i + 1, o.group(1), kind))
                elif lang in ("elm", "fic"):
                    bad.append("%s:%d code block without a guide marker" % (f, i + 1))
                i = j
            i += 1
    return bad, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", default=os.path.join(ROOT, "bin", "elmficA16"))
    ap.add_argument("--modes", default="norc,rc,san")
    ap.add_argument("--only", default="")
    ap.add_argument("--elm-ref", default=os.path.join(ROOT, "bin", "elm0193"), help="the official Elm 0.19.3 for the vs-elm comparisons (empty: skip)")
    ap.add_argument("--docs", action="store_true")
    ap.add_argument("-v", action="store_true")
    ap.add_argument("--show", default="", help="build the named examples in rc mode and print what they give (to write expect files)")
    ap.add_argument("--write", action="store_true", help="with --show: write expect.out / expect.err from what was printed (check it first)")
    a = ap.parse_args()
    global REF
    REF = a.elm_ref
    for n in [x for x in a.show.split(",") if x]:
        with tempfile.TemporaryDirectory(prefix="guide-") as work:
            ok, text = build(n, a.elm, "rc", work)
            if not ok:
                print("=== %s: compile failed\n%s" % (n, error_text(text)))
                if a.write: open(os.path.join(HERE, n, "expect.err"), "w").write(error_text(text))
                continue
            rc, so, se = sh(text if isinstance(text, list) else [text], work, json.loads(read(os.path.join(HERE, n, "env.json")) or "{}"))
            print("=== %s: exit %d\n--- stdout\n%s--- stderr\n%s" % (n, rc, so, se))
            if a.write and (rc == 0 or not os.path.exists(os.path.join(HERE, n, "expect.out"))): open(os.path.join(HERE, n, "expect.out"), "w").write(so)
            if REF and os.path.exists(os.path.join(HERE, n, "vs-elm")):
                with tempfile.TemporaryDirectory(prefix="guide-elm-") as w2:
                    eo = elm_run(n, w2, REF)
                print("--- Elm 0.19.3\n" + eo)
                if a.write and (read(os.path.join(HERE, n, "vs-elm")) or "").strip() == "differs": open(os.path.join(HERE, n, "elm.out"), "w").write(eo)
    if a.show: return
    names = sorted(d for d in os.listdir(HERE) if os.path.isdir(os.path.join(HERE, d)) and not d.startswith((".", "_")))
    if a.only: names = [n for n in names if n in a.only.split(",")]
    modes = a.modes.split(",")
    fail = total = 0
    for n in names:
        problems, runs = check(n, a.elm, modes, a.v)
        total += 1
        print("%-4s %s%s" % ("FAIL" if problems else "ok", n, "" if not problems else "\n" + "\n".join("  " + p.replace("\n", "\n  ") for p in problems)))
        fail += bool(problems)
    print("%d examples, %d failed (modes %s, compiler %s)" % (total, fail, a.modes, os.path.basename(a.elm)))
    if a.docs:
        bad, n = check_docs(names)
        for b in bad: print("DOC", b)
        print("%d guide blocks checked, %d problems" % (n, len(bad)))
        fail += len(bad)
    sys.exit(1 if fail else 0)


main()
