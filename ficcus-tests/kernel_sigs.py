#!/usr/bin/env python3
"""Checks that every kernel of Ficcus.Mono.Kernel (kernelArity) has an ownership signature (kernelSig, STAGE4-PLAN section 8) of the
right length, and prints the table with --markdown (the table of the plan). Exit status 1 on a missing or wrong entry."""
import os, re, sys

K = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "compiler", "src", "Ficcus", "Mono", "Kernel.hs")


def table():
    k = open(K, encoding="utf-8").read()
    ar = dict((m.group(1), int(m.group(2))) for m in re.finditer(r'\("([^"]+)", (\d+)\)', k[k.index("kernelArity ::"):k.index("forcedExact ::")]))
    sec = k[k.index("kernelSig ::"):k.index("-- the kernels whose arguments are never references")]
    sig = dict((m.group(1), m.group(2)) for m in re.finditer(r'\("([^"]+)", "([sbo]*)"\)', sec))
    sc = k[k.index("scalarKernels ::"):k.index("kernelResultBorrowed ::")]
    head = sc[:sc.index("++ [ (\"elm/core:Bitwise.\"")]
    for n, a in re.findall(r'\("(\w+)", (\d)\)', head): sig["elm/core:Basics." + n] = "s" * int(a)
    bw = [("and", 2), ("or", 2), ("xor", 2), ("complement", 1), ("shiftLeftBy", 2), ("shiftRightBy", 2), ("shiftRightZfBy", 2)]
    for pre in ("Bitwise", "Bitwise64"):
        for n, a in bw: sig["elm/core:%s.%s" % (pre, n)] = "s" * a
    return ar, sig


def main():
    ar, sig = table()
    bad = [c for c in ar if c != "elm/core:Basics.append" and c not in sig] + [c for c in ar if c in sig and len(sig[c]) != ar[c]]
    if "--markdown" in sys.argv:
        print("| kernel | arity | signature | note |\n|---|---|---|---|")
        for c in ar:
            s = "bb (string), bo (list)" if c == "elm/core:Basics.append" else sig.get(c, "?")
            note = "result is a borrowed element: the pass adds the count" if c == "elm/core:Elm.JsArray.unsafeGet" else ""
            print("| %s | %d | `%s` | %s |" % (c, ar[c], s, note))
    print(("FAIL kernel signatures: " + ", ".join(bad)) if bad else "ok   kernel signatures: %d kernels, all have a signature of the right length" % len(ar), file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
