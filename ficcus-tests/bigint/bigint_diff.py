#!/usr/bin/env python3
"""Differential tests of BigInt against Python integers, in the modes plain, drop-all (FIC_DROP_ALL=1) and counted+ASan, and, with
--elm, the Elm package under node (same Main, same cases).

  python3 bigint_diff.py [--seed N] [--n CASES] [--maxbits B] [--big K] [--modes plain,dropall,san,elm] [--keep DIR]

Builds in a scratch directory (`--work`, default a temporary one); runs are capped by tools/safe (SAFE_MEM, SAFE_TIMEOUT)."""
import argparse, os, subprocess, sys, tempfile, shutil, re

here = os.path.dirname(os.path.abspath(__file__))
ws = os.path.abspath(os.path.join(here, "../../.."))
sys.path.insert(0, here)
import bigint_cases


def sh(cmd, env=None, timeout=900, cwd=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    return subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=timeout, cwd=cwd)


def safe(cmd, env=None, mem="3G", t="300"):
    e = {"SAFE_MEM": mem, "SAFE_TIMEOUT": t}
    if env:
        e.update(env)
    return sh([ws + "/tools/safe"] + cmd, env=e, timeout=int(t) + 30)


def parse_out(text):
    cases = failed = None
    fails = []
    for ln in text.splitlines():
        m = re.match(r"(cases|failed): (\d+)$", ln)
        if m:
            if m.group(1) == "cases":
                cases = int(m.group(2))
            else:
                failed = int(m.group(2))
        elif ln.startswith("FAIL:"):
            fails.append(ln)
    return cases, failed, fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=150)
    ap.add_argument("--maxbits", type=int, default=300)
    ap.add_argument("--big", type=int, default=6)
    ap.add_argument("--modes", default="plain,dropall,san")
    ap.add_argument("--work", default=None)
    ap.add_argument("--elm-home", default=None, help="copy of elm-home-difftest/0.19.3 (default: the workspace one)")
    a = ap.parse_args()
    work = a.work or tempfile.mkdtemp(prefix="bigint-diff-")
    os.makedirs(work, exist_ok=True)
    modes = a.modes.split(",")
    status = 0
    for mode in modes:
        elm = mode == "elm"
        L = bigint_cases.gen(a.seed, a.n, a.maxbits, a.big, elm=elm)
        data = bigint_cases.render(L)
        tpl = open(os.path.join(here, "t/main_template.fic")).read()
        src = tpl.replace("@DATA@", data)
        md = os.path.join(work, mode)
        os.makedirs(md, exist_ok=True)
        if elm:
            r = run_elm(src, md, a)
        else:
            r = run_ficcus(src, md, mode, a)
        if r is None:
            status = 1
            continue
        cases, failed, fails, extra = r
        ok = cases == len(L) and failed == 0 and extra == ""
        print("%-8s seed %d: %d cases sent, %s run, %s failed %s %s" % (mode, a.seed, len(L), cases, failed, "OK" if ok else "FAIL", extra))
        for f in fails[:10]:
            print("   ", f)
        if not ok:
            status = 1
    sys.exit(status)


def run_ficcus(src, md, mode, a):
    f = os.path.join(md, "Main.fic")
    open(f, "w").write(src)
    exe = os.path.join(md, "main")
    env = {}
    if a.elm_home:
        env["ELM_HOME"] = a.elm_home
    bmode = "san" if mode == "san" else "stats"
    r = sh([here + "/bbuild.sh", f, exe, bmode], env=env)
    if r.returncode != 0:
        print(mode, "BUILD FAILED\n", r.stdout[-3000:], r.stderr[-3000:])
        return None
    renv = {"FIC_DROP_ALL": "1"} if mode == "dropall" else {}
    if mode == "san":
        renv["ASAN_OPTIONS"] = "detect_leaks=1"
    p = safe([exe], env=renv, mem="6G" if mode == "san" else "3G")
    cases, failed, fails = parse_out(p.stdout)
    extra = ""
    if p.returncode != 0:
        extra = "exit %d: %s" % (p.returncode, (p.stderr.strip().splitlines() or [""])[-1][:200])
    stat = [l for l in p.stderr.splitlines() if l.startswith("FIC_STATS")]
    if stat:
        extra += " " + stat[0][:120]
    return cases, failed, fails, extra if (p.returncode != 0) else ""


def run_elm(src, md, a):
    pk = ws + "/corpus/pkgs/cmditch/elm-bigint/src"
    os.makedirs(md + "/src", exist_ok=True)
    open(md + "/src/Main.elm", "w").write(src)
    for fn in ("BigInt.elm", "Constants.elm"):
        shutil.copy(pk + "/" + fn, md + "/src/" + fn)
    open(md + "/elm.json", "w").write('''{"type":"application","source-directories":["src"],"elm-version":"0.19.3",
 "dependencies":{"direct":{"elm/core":"1.0.5","elm-community/list-extra":"8.7.0","elm-community/maybe-extra":"5.3.0","rtfeldman/elm-hex":"1.0.0"},"indirect":{"elm/json":"1.1.3"}},
 "test-dependencies":{"direct":{},"indirect":{}}}''')
    env = {"ELM_HOME": a.elm_home or ws + "/elm-home-difftest/0.19.3"}
    r = sh([ws + "/bin/elm0193", "make", "src/Main.elm", "--output=main.js"], env=env, cwd=md)
    if r.returncode != 0:
        print("elm BUILD FAILED\n", r.stdout[-3000:], r.stderr[-3000:])
        return None
    open(md + "/run.js", "w").write("const {Elm}=require('./main.js');Elm.Main.init();")
    p = safe(["node", md + "/run.js"], mem="6G", t="600")
    cases, failed, fails = parse_out(p.stdout + p.stderr)
    return cases, failed, fails, "" if p.returncode == 0 else "exit %d" % p.returncode


main()
