#!/usr/bin/env python3
"""Corpus scan for the name `Vector` (decisions D5, rev 129/130).

Usage: vscan2.py [CORPUS_DIR ...]   (default: <workspace>/corpus/pkgs and corpus/apps;
       corpus/pkgs-sample is a subset of pkgs)

Counts, over every elm.json below the given folders:
  (a) packages that expose a module named exactly `Vector`
  (b) applications with a module `Vector` in a source directory
  (c) .elm files that define `type Vector` or `type alias Vector`
  (d) projects that depend on one of the packages of (a) (default:
      jonathanfishbein1/linear-algebra, nphollon/geo3d) AND have a source
      file with `import Vector` (the module rule of 13 Nov: a core module
      added by Ficcus yields to a package module of the same name)
Read only. Prints the counts and the hits.
`--names Int8,Word8,...` (SIZED): the counts of (a) (b) (c) and the imports for those module names instead of `Vector`.
"""
import json, os, re, sys

VEC_PKGS = ("jonathanfishbein1/linear-algebra", "nphollon/geo3d")
SKIP = {"elm-stuff", "node_modules", ".git"}
RE_TYPE = re.compile(r"^type\s+(alias\s+)?Vector\b", re.M)
RE_IMPORT = re.compile(r"^import\s+Vector(\s|$)", re.M)
RE_MODULE = re.compile(r"^(?:port\s+|effect\s+)?module\s+([A-Z][A-Za-z0-9_.]*)", re.M)


def read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def exposed(j):
    e = j.get("exposed-modules", [])
    if isinstance(e, dict):
        return [m for ms in e.values() for m in ms]
    return list(e)


def deps(j):
    out = set()
    for k in ("dependencies", "test-dependencies"):
        d = j.get(k, {})
        if not isinstance(d, dict):
            continue
        if "direct" in d or "indirect" in d:
            for kk in ("direct", "indirect"):
                out.update(d.get(kk, {}) or {})
        else:
            out.update(d)
    return out


def elm_files(root):
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP]
        for fn in fns:
            if fn.endswith(".elm"):
                yield os.path.join(dp, fn)


def scan_names(names, roots):
    """SIZED: the same three counts for several module names (--names Int8,Word8,...): packages exposing the module, application modules of
    that name, files defining `type Name`, and the projects with `import Name`"""
    projects = []
    for r in roots:
        for dp, dns, fns in os.walk(r):
            dns[:] = [d for d in dns if d not in SKIP]
            if "elm.json" in fns:
                projects.append(dp)
    projects.sort()
    exposing = {n: [] for n in names}; modules = {n: [] for n in names}; types = {n: [] for n in names}; imports = {n: [] for n in names}
    npk = nap = 0
    for p in projects:
        try:
            j = json.loads(read(os.path.join(p, "elm.json")))
        except ValueError:
            continue
        if not isinstance(j, dict):
            continue
        kind = j.get("type")
        if kind == "package":
            npk += 1
            srcs = ["src"]
            for n in names:
                if n in exposed(j):
                    exposing[n].append(p)
        elif kind == "application":
            nap += 1
            srcs = j.get("source-directories", ["src"])
        else:
            continue
        files = []
        for sdir in srcs + ["tests"]:
            sd = os.path.normpath(os.path.join(p, sdir))
            if os.path.isdir(sd):
                files.extend(elm_files(sd))
        for f in sorted(set(files)):
            text = read(f)
            m = RE_MODULE.search(text)
            inside = os.path.realpath(f).startswith(os.path.realpath(p) + os.sep)
            for n in names:
                if inside and m and m.group(1) == n:
                    modules[n].append(f)
                if re.search(r"^type\s+(alias\s+)?%s\b" % n, text, re.M):
                    types[n].append(f)
                if re.search(r"^import\s+%s(\s|$)" % n, text, re.M):
                    imports[n].append(f)
    print("elm.json files: %d packages, %d applications" % (npk, nap))
    for n in names:
        print("%s: packages exposing it: %d; modules named so: %d; files defining a type or alias so named: %d; files importing it: %d" % (
            n, len(exposing[n]), len(modules[n]), len(types[n]), len(imports[n])))
        for label, lst in (("exposes", exposing[n]), ("module", modules[n]), ("defines", types[n]), ("imports", imports[n])):
            for x in lst:
                print("    %s  %s" % (label, x))


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    if "--names" in sys.argv:
        i = sys.argv.index("--names")
        names = sys.argv[i + 1].split(",")
        rest = sys.argv[1:i] + sys.argv[i + 2:]
        corpus = os.path.join(here, "..", "..", "corpus")
        return scan_names(names, rest or [os.path.join(corpus, "pkgs"), os.path.join(corpus, "apps")])
    corpus = os.path.join(here, "..", "..", "corpus")
    roots = sys.argv[1:] or [os.path.join(corpus, "pkgs"), os.path.join(corpus, "apps")]
    projects = []
    for r in roots:
        for dp, dns, fns in os.walk(r):
            dns[:] = [d for d in dns if d not in SKIP]
            if "elm.json" in fns:
                projects.append(dp)
    projects.sort()
    npk = nap = 0
    a, b, d_dep, d_hit = [], [], [], []
    for p in projects:
        try:
            j = json.loads(read(os.path.join(p, "elm.json")))
        except ValueError:
            continue
        if not isinstance(j, dict):
            continue
        kind = j.get("type")
        if kind == "package":
            npk += 1
            srcs = ["src"]
            if "Vector" in exposed(j):
                a.append(p)
        elif kind == "application":
            nap += 1
            srcs = j.get("source-directories", ["src"])
        else:
            continue
        files = []
        for s in srcs + ["tests"]:
            sd = os.path.normpath(os.path.join(p, s))
            if os.path.isdir(sd):
                files.extend(elm_files(sd))
        files = sorted(set(files))
        if kind == "application":
            for f in files:
                m = RE_MODULE.search(read(f))
                inside = os.path.realpath(f).startswith(os.path.realpath(p) + os.sep)
                if inside and m and m.group(1) == "Vector":
                    b.append(f)  # a module of the application itself, not of a package it reads by path
        dep = sorted(deps(j) & set(VEC_PKGS))
        own = j.get("name") in VEC_PKGS
        if dep and not own:
            imp = [f for f in files if RE_IMPORT.search(read(f))]
            d_dep.append((p, dep))
            if imp:
                d_hit.append((p, dep, imp))
    c = []
    seen = set()
    for r in roots:
        for f in elm_files(r):
            rf = os.path.realpath(f)
            if rf in seen:
                continue
            seen.add(rf)
            if RE_TYPE.search(read(f)):
                c.append(f)
    print("elm.json files: %d packages, %d applications; .elm files: %d" % (npk, nap, len(seen)))
    print("(a) packages exposing module Vector: %d" % len(a))
    for p in a:
        print("    " + p)
    print("(b) application modules named Vector: %d" % len(b))
    for f in b:
        print("    " + f)
    print("(c) files defining type or alias Vector: %d" % len(c))
    for f in c:
        print("    " + f)
    print("(d) projects depending on %s: %d; of those importing Vector: %d" % (
        " or ".join(VEC_PKGS), len(d_dep), len(d_hit)))
    for p, dep in d_dep:
        print("    dep  %s  (%s)" % (p, ", ".join(dep)))
    for p, dep, imp in d_hit:
        print("    HIT  %s  (%s): %s" % (p, ", ".join(dep), ", ".join(os.path.relpath(f, p) for f in imp)))


if __name__ == "__main__":
    main()
