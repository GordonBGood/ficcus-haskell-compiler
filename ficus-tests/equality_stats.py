#!/usr/bin/env python3
"""equality_stats.py -- count ==, /=, compare used at a type that contains a function.

Runs the compiler once per project with --output=x.types (through tools/safe) and reads the
`-- equality-uses` / `-- equality-at-function` lines of the dump. A package that is a dependency
is counted once however many projects use it (first occurrence wins; versions are not told apart).
Only direct uses are seen: equality inside a polymorphic library function (List.member, Dict) at a
function type needs the specialized typed IR.

  equality_stats.py --elm BIN --safe tools/safe --elm-home DIR --out DIR [--jobs 3] [--app DIR:entry] PKGDIR...
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typed_check as tc


def one(job):
    proj, files, a, tmproot, label = job
    work = tempfile.mkdtemp(dir=tmproot)
    dst = os.path.join(work, "p")
    shutil.copytree(proj, dst, ignore=shutil.ignore_patterns("elm-stuff", ".git", "node_modules"))
    env = dict(os.environ, ELM_HOME=a.elm_home)
    rc, text = tc.run(a.safe, a.elm, ["make"] + files + ["--output=x.types"], dst, env, a.timeout)
    res = {"label": label, "rc": rc, "packages": {}}
    path = os.path.join(dst, "x.types")
    if rc == 0 and os.path.exists(path):
        pkg = label  # modules before the first `-- package` line belong to the project itself
        for line in open(path, encoding="utf-8"):
            if line.startswith("-- package "):
                pkg = line[len("-- package "):].strip()
            elif line.startswith("-- equality-uses:"):
                m = re.match(r"-- equality-uses: total=(\d+) at-function=(\d+)", line)
                d = res["packages"].setdefault(pkg, {"total": 0, "at_function": 0, "cases": []})
                d["total"] += int(m.group(1)); d["at_function"] += int(m.group(2))
            elif line.startswith("-- equality-at-function:"):
                res["packages"].setdefault(pkg, {"total": 0, "at_function": 0, "cases": []})["cases"].append(line.split(":", 1)[1].strip())
    shutil.rmtree(work, ignore_errors=True)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--safe", required=True)
    ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--jobs", type=int, default=3); ap.add_argument("--timeout", type=int, default=200)
    ap.add_argument("--app", action="append", default=[]); ap.add_argument("paths", nargs="*")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    tmproot = tempfile.mkdtemp(prefix="eq_", dir=a.out)
    jobs = []
    for p in tc.find_projects(a.paths):
        f = tc.exposed_files(p)
        if f:
            jobs.append((p, f, a, tmproot, "project:" + os.path.basename(os.path.dirname(p)) + "/" + os.path.basename(p)))
    for x in a.app:
        d, e = x.split(":", 1)
        jobs.append((d, [e], a, tmproot, "app:" + os.path.basename(d)))
    seen, proj, failed = {}, {}, 0
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for r in ex.map(one, jobs):
            if r["rc"] != 0:
                failed += 1
            for pkg, d in r["packages"].items():
                if pkg.startswith(("project:", "app:")):
                    proj[pkg] = d
                elif pkg not in seen:
                    seen[pkg] = d
    out = {"failed_projects": failed, "dependency_packages": seen, "projects": proj}
    json.dump(out, open(os.path.join(a.out, "equality.json"), "w"), indent=1)
    def tot(ds): return sum(d["total"] for d in ds), sum(d["at_function"] for d in ds)
    print("failed projects (no dump):", failed)
    print("dependency packages: %d  uses=%d at-function=%d" % ((len(seen),) + tot(seen.values())))
    print("corpus projects/apps: %d  uses=%d at-function=%d" % ((len(proj),) + tot(proj.values())))
    print("\nper package with at-function > 0:")
    for k, d in sorted({**seen, **proj}.items(), key=lambda kv: -kv[1]["at_function"]):
        if d["at_function"]:
            print("  %-60s total=%-5d at-function=%d  %s" % (k, d["total"], d["at_function"], "; ".join(d["cases"][:2])[:80]))
    shutil.rmtree(tmproot, ignore_errors=True)

main()
