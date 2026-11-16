#!/usr/bin/env python3
"""mkhome.py DEST -- an ELM_HOME for the attach tests: elm/core and elm/json copied from elm-home-difftest (so nothing is
downloaded and the user's real ELM_HOME is never touched), plus the local packages of tests/attach/packages/<author>/<name>/<version>/
entered in registry.dat (without a registry entry the builder rejects a package it does not know).

registry.dat (builder/src/Deps/Registry.hs): i64 count (LE), u32 number of packages, then per package, in ascending name order:
string8 author, string8 project, version of the newest (u8 major, u8 minor, u8 patch), u32 number of older versions, their versions."""
import os, shutil, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
def _find_root():
    # workspace root = the directory with targets/c and bin; works through the tests/attach symlink and from the repo
    for base in (HERE, os.path.dirname(os.path.realpath(__file__))):
        d = base
        while d != os.path.dirname(d):
            if os.path.isdir(os.path.join(d, "targets", "c")) and os.path.isdir(os.path.join(d, "bin")): return d
            d = os.path.dirname(d)
    return os.path.abspath(os.path.join(HERE, "..", ".."))
ROOT = _find_root()
SRC = os.path.join(ROOT, "elm-home-difftest", "0.19.3", "0.19.3", "packages")


def read_registry(path):
    d = open(path, "rb").read()
    count, = struct.unpack_from("<q", d, 0); n, = struct.unpack_from("<I", d, 8); pos = 12
    out = []
    for _ in range(n):
        a = d[pos + 1: pos + 1 + d[pos]]; pos += 1 + d[pos]
        p = d[pos + 1: pos + 1 + d[pos]]; pos += 1 + d[pos]
        newest = d[pos: pos + 3]; pos += 3
        m, = struct.unpack_from("<I", d, pos); pos += 4
        older = [d[pos + 3 * i: pos + 3 * i + 3] for i in range(m)]; pos += 3 * m
        out.append((a, p, newest, older))
    assert pos == len(d), "registry.dat not fully parsed"
    return count, out


def write_registry(path, count, entries):
    entries = sorted(entries, key=lambda e: (e[0], e[1]))
    b = bytearray(struct.pack("<qI", count, len(entries)))
    for a, p, newest, older in entries:
        b += bytes([len(a)]) + a + bytes([len(p)]) + p + newest + struct.pack("<I", len(older)) + b"".join(older)
    open(path, "wb").write(bytes(b))


def make(dest):
    pk = os.path.join(dest, "0.19.3", "packages")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.join(pk, "elm"))
    for name in ("core", "json"):
        shutil.copytree(os.path.join(SRC, "elm", name), os.path.join(pk, "elm", name), ignore=shutil.ignore_patterns("artifacts.dat"))
    count, entries = read_registry(os.path.join(SRC, "registry.dat"))
    entries = [e for e in entries if (e[0], e[1]) in {(b"elm", b"core"), (b"elm", b"json")}]
    count = len(entries)
    local = os.path.join(HERE, "packages")
    for author in sorted(os.listdir(local)) if os.path.isdir(local) else []:
        for name in sorted(os.listdir(os.path.join(local, author))):
            for ver in sorted(os.listdir(os.path.join(local, author, name))):
                shutil.copytree(os.path.join(local, author, name, ver), os.path.join(pk, author, name, ver))
                v = bytes(int(x) for x in ver.split("."))
                entries.append((author.encode(), name.encode(), v, [])); count += 1
    write_registry(os.path.join(pk, "registry.dat"), count, entries)


if __name__ == "__main__":
    make(os.path.abspath(sys.argv[1]))
