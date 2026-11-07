#!/usr/bin/env python3
"""typed_check.py -- milestone 2 corpus check.

For every project it runs the compiler twice in a private copy of the project:
  A  elm make <files> --output=/dev/null     (recorder off)
  B  elm make <files> --output=x.types       (recorder on, type dump)
and requires
  * the same verdict (exit status, and for failures the same error text),
  * for accepted projects: every module dump says problems=0 and instance-failures=0
    (problems covers a missing node key, a node that was not visited, a missing
    scheme; the recorder itself aborts on two nodes with the same key).

Every compiler call goes through tools/safe (3 GB, timeout). Usage:

  typed_check.py --elm BIN --safe tools/safe --elm-home DIR --out DIR \
      [--jobs 2] [--limit N] [--timeout 120] [--app DIR:src/Main.elm ...] PKGDIR...

PKGDIR is a directory that contains projects (searched one level down) or a
project itself (it has an elm.json).
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor


def find_projects(paths):
    found = []
    for p in paths:
        if os.path.exists(os.path.join(p, "elm.json")):
            found.append(p)
        else:
            for d in sorted(os.listdir(p)):
                q = os.path.join(p, d)
                if os.path.isdir(q) and os.path.exists(os.path.join(q, "elm.json")):
                    found.append(q)
                elif os.path.isdir(q):  # author/name layout
                    for e in sorted(os.listdir(q)):
                        r = os.path.join(q, e)
                        if os.path.isdir(r) and os.path.exists(os.path.join(r, "elm.json")):
                            found.append(r)
    return found


def exposed_files(proj):
    with open(os.path.join(proj, "elm.json"), encoding="utf-8") as f:
        j = json.load(f)
    if j.get("type") != "package":
        return None
    ex = j.get("exposed-modules", [])
    if isinstance(ex, dict):
        ex = [m for ms in ex.values() for m in ms]
    files = []
    for m in ex:
        rel = os.path.join("src", *m.split(".")) + ".elm"
        if os.path.exists(os.path.join(proj, rel)):
            files.append(rel)
    return files


def run(safe, elm, args, cwd, env, timeout):
    env = dict(env, SAFE_TIMEOUT=str(timeout))
    # one automatic retry when the process was killed (rc -9 / 137: memory pressure under load)
    for attempt in (0, 1):
        try:
            p = subprocess.run([safe, elm] + args, cwd=cwd, env=env, capture_output=True, timeout=timeout + 30)
        except subprocess.TimeoutExpired:
            return 124, "timeout"
        if p.returncode in (-9, 137) and attempt == 0:
            continue
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")


NOISE = re.compile(r"(Success!|───>|Dependencies ready|Verifying dependencies|Compiling|Starting downloads|Downloading|Finished|Dependencies)")


def normalize(text):
    text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
    text = text.replace("\r", "\n")
    lines = [l.rstrip() for l in text.split("\n") if l.strip() and not NOISE.search(l)]
    return "\n".join(lines)


def check(job):
    proj, files, args, tmproot = job
    name = os.path.basename(os.path.dirname(proj)) + "/" + os.path.basename(proj) if os.path.basename(os.path.dirname(proj)) not in ("pkgs", "pkgs-sample", "apps") else os.path.basename(proj)
    work = tempfile.mkdtemp(dir=tmproot)
    dst = os.path.join(work, "p")
    shutil.copytree(proj, dst, ignore=shutil.ignore_patterns("elm-stuff", ".git", "node_modules"))
    env = dict(os.environ, ELM_HOME=args.elm_home)
    ra, ta = run(args.safe, args.elm, ["make"] + files + ["--output=/dev/null"], dst, env, args.timeout)
    rb, tb = run(args.safe, args.elm, ["make"] + files + ["--output=x.types"], dst, env, args.timeout)
    res = {"name": name, "exit_a": ra, "exit_b": rb}
    if ra == 124 or rb == 124:
        res["status"] = "TIMEOUT"
    elif (ra == 0) != (rb == 0):
        res["status"] = "VERDICT_DIFF"
        res["detail"] = (ta if ra else tb)[-400:]
    elif ra != 0:
        same = normalize(ta) == normalize(tb)
        res["status"] = "BOTH_REJECT_SAME" if same else "BOTH_REJECT_TEXT_DIFF"
        if not same:
            res["detail"] = normalize(ta)[:300] + "\n--- types mode ---\n" + normalize(tb)[:300]
    else:
        path = os.path.join(dst, "x.types")
        text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        sums = re.findall(r"^-- module (\S+): problems=(\d+) instances=(\d+) instance-failures=(\d+) defaulted=(\d+)", text, re.M)
        bad = [s for s in sums if int(s[1]) or int(s[3])]
        res["modules"] = len(sums)
        res["instances"] = sum(int(s[2]) for s in sums)
        if not sums:
            res["status"] = "NO_DUMP"
        elif bad:
            res["status"] = "TYPES_PROBLEM"
            res["detail"] = "; ".join("%s problems=%s failures=%s" % (s[0], s[1], s[3]) for s in bad[:5])
            res["lines"] = [l for l in text.split("\n") if l.lstrip().startswith("!!")][:5]
        else:
            res["status"] = "SAME"
    shutil.rmtree(work, ignore_errors=True)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True)
    ap.add_argument("--safe", required=True)
    ap.add_argument("--elm-home", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--app", action="append", default=[], help="DIR:entry.elm (an application)")
    ap.add_argument("paths", nargs="*")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    tmproot = tempfile.mkdtemp(prefix="typed_check_", dir=args.out)

    jobs = []
    for proj in find_projects(args.paths):
        files = exposed_files(proj)
        if files:
            jobs.append((proj, files, args, tmproot))
    for a in args.app:
        d, entry = a.split(":", 1)
        jobs.append((d, [entry], args, tmproot))
    if args.limit:
        jobs = jobs[: args.limit]

    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for i, r in enumerate(ex.map(check, jobs), 1):
            results.append(r)
            if r["status"] not in ("SAME", "BOTH_REJECT_SAME"):
                print("%4d/%d %-22s %s %s" % (i, len(jobs), r["status"], r["name"], r.get("detail", "")[:160].replace("\n", " | ")), flush=True)
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    with open(os.path.join(args.out, "typed_check.json"), "w") as f:
        json.dump({"counts": counts, "results": results}, f, indent=1)
    print("projects:", len(results), counts)
    print("modules dumped:", sum(r.get("modules", 0) for r in results), "use instances matched:", sum(r.get("instances", 0) for r in results))
    shutil.rmtree(tmproot, ignore_errors=True)
    return 0 if all(r["status"] in ("SAME", "BOTH_REJECT_SAME") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
