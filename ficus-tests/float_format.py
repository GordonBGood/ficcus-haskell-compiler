#!/usr/bin/env python3
"""Float formatting test: the generated C routine fic_fmt_float against node's Number.prototype.toString.

Formats every power of two 2^-1074 .. 2^1023 (both signs) and N random doubles (random bit patterns, short decimals,
integers, float32 values) and compares line by line. The C routine is taken from the prelude of a program compiled by
the Ficus compiler (any program: x.c is included with `main` renamed).

  python3 ficus-tests/float_format.py --c x.c [--n 100000] [--seed 1]
Exit status 1 on any difference.
"""
import argparse, os, random, struct, subprocess, sys, tempfile

HARNESS = r'''
#include <stdio.h>
#define main fic_program_main
#include "%s"
#undef main
int main(void) {
  unsigned long long bits; char buf[64];
  while (scanf("%%llx", &bits) == 1) {
    double x; memcpy(&x, &bits, 8);
    fic_fmt_float(x, buf);
    puts(buf);
  }
  return 0;
}
'''

JS = r'''
const lines = require('fs').readFileSync(0, 'utf8').split('\n').filter(s => s.length);
const b = Buffer.alloc(8);
const out = [];
for (const h of lines) { b.writeBigUInt64LE(BigInt('0x' + h)); out.push(String(b.readDoubleLE(0))); }
console.log(out.join('\n'));
'''


def bits(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def cases(n, seed):
    rnd = random.Random(seed)
    out = []
    for e in range(-1074, 1024):
        x = 2.0 ** e if e >= -1022 else float.fromhex("0x1p%d" % e)
        out += [bits(x), bits(-x)]
    while len(out) < n + 2098 * 2:
        k = rnd.randrange(4)
        if k == 0:
            b = rnd.getrandbits(64)
            if ((b >> 52) & 0x7ff) == 0x7ff: continue          # NaN and infinities have their own cases
            out.append(b)
        elif k == 1:
            out.append(bits(float("%d.%de%d" % (rnd.randrange(10 ** rnd.randrange(1, 17)), rnd.randrange(1000), rnd.randrange(-30, 30)))))
        elif k == 2:
            out.append(bits(float(rnd.randrange(-10 ** rnd.randrange(1, 25), 10 ** rnd.randrange(1, 25)))))
        else:
            f = struct.unpack("<f", struct.pack("<I", rnd.getrandbits(32)))[0]
            if f == f and abs(f) != float("inf"): out.append(bits(f))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--c", required=True); ap.add_argument("--n", type=int, default=100000); ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cc", default="gcc")
    a = ap.parse_args()
    work = tempfile.mkdtemp()
    h = os.path.join(work, "h.c"); open(h, "w").write(HARNESS % os.path.abspath(a.c))
    rt = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "targets", "c")
    exe = os.path.join(work, "h")
    b = subprocess.run([a.cc, "-std=c99", "-O2", "-ffp-contract=off", "-Wno-unused-function", "-I", rt, h, "-o", exe, "-lm"], capture_output=True, text=True)
    if b.returncode: print(b.stderr); return 1
    cs = cases(a.n, a.seed)
    inp = "\n".join("%016x" % c for c in cs) + "\n"
    ours = subprocess.run([exe], input=inp, capture_output=True, text=True).stdout.split("\n")[:-1]
    js = os.path.join(work, "f.js"); open(js, "w").write(JS)
    ref = subprocess.run(["node", js], input=inp, capture_output=True, text=True).stdout.split("\n")[:-1]
    bad = [(c, o, r) for c, o, r in zip(cs, ours, ref) if o != r]
    print("%d values (%d powers of two, both signs), %d differences%s" % (len(cs), 2098 * 2, len(bad), " (line counts %d / %d)" % (len(ours), len(ref)) if not len(ours) == len(ref) == len(cs) else ""))
    for c, o, r in bad[:20]: print("  %016x  ours %s  node %s" % (c, o, r))
    return 1 if bad or not len(ours) == len(ref) == len(cs) else 0


sys.exit(main())
