#!/usr/bin/env python3
"""P1 JSON benchmark: the deterministic document generator and the reference checksum.

  python3 ficcus-tools/gen_json.py N OUT.json     write the document of N records and print the checksum line
  python3 ficcus-tools/gen_json.py N              only print the checksum line (and the size)

The same generator is written in every benchmark program (the C path cannot read a file, so each program builds the text itself,
as targets/elm/wordfreq does); this script is its specification and the oracle: the checksum comes from Python's json module,
independent of every parser under test. Sizes used: N = 7500 (about 1 MB), N = 375000 (about 50 MB), see docs/P1-JSON.md.

Generator (all integer arithmetic): seed s = 12345; draw(): s = s * 48271 mod 2147483647, the result is s.
  document  = "[\n" record (",\n" record)* "\n]\n"   (N records; the whole document is one array)
  value(d)  : r = draw(); k = r mod 20; if d >= 12 and k < 10 then k = k + 10;
     k 0..4   array   n = draw() mod 5 values (depth d+1) joined by ", " in [ ]
     k 5..9   object  n = draw() mod 5 members  key ": " value  (depth d+1) joined by ", " in { }, key = string(1, 8)
     k 10 null, 11 true, 12 false
     k 13..15 integer: "-" if draw() mod 4 == 0; draw() mod 1000000 in decimal
     k 16..17 float:   "-" if draw() mod 4 == 0; draw() mod 10000, ".", (draw() mod 64) * 15625 as 6 digits; e = draw() mod 8;
                       if e == 0: suffix "e1", "E+2" or "e0" by draw() mod 3     (every value is a multiple of 1/64: sums are exact)
     k 18..19 string(0, 12)
  string(lo, span): quote, n = lo + draw() mod span characters, quote; a character: r = draw(); k = r mod 20; p = (r div 20) mod 38;
     k < 14: ALPHA[p] ("abcdefghijklmnopqrstuvwxyz0123456789 _"), else ESC[p mod 8] (\\" \\\\ \\/ \\n \\t \\b \\u00e9 \\u0041)
  a record is value(2) (the document array is depth 1).
Checksum: nodes (every value), sum of the numbers times 64 (truncated, exact), total string length (code points of the decoded
strings, keys included), maximum depth (the document array is 1)."""
import json, sys

M = 2147483647
ALPHA = "abcdefghijklmnopqrstuvwxyz0123456789 _"
ESC = ['\\"', '\\\\', '\\/', '\\n', '\\t', '\\b', '\\u00e9', '\\u0041']


class Gen:
    def __init__(self):
        self.s = 12345
        self.out = []

    def draw(self):
        self.s = self.s * 48271 % M
        return self.s

    def string(self, lo, span):
        n = lo + self.draw() % span
        self.out.append('"')
        for _ in range(n):
            r = self.draw()
            k = r % 20
            p = (r // 20) % 38
            self.out.append(ALPHA[p] if k < 14 else ESC[p % 8])
        self.out.append('"')

    def value(self, d):
        r = self.draw()
        k = r % 20
        if d >= 12 and k < 10:
            k += 10
        o = self.out
        if k < 5:
            n = self.draw() % 5
            o.append("[")
            for i in range(n):
                if i: o.append(", ")
                self.value(d + 1)
            o.append("]")
        elif k < 10:
            n = self.draw() % 5
            o.append("{")
            for i in range(n):
                if i: o.append(", ")
                self.string(1, 8)
                o.append(": ")
                self.value(d + 1)
            o.append("}")
        elif k == 10: o.append("null")
        elif k == 11: o.append("true")
        elif k == 12: o.append("false")
        elif k < 16:
            if self.draw() % 4 == 0: o.append("-")
            o.append(str(self.draw() % 1000000))
        elif k < 18:
            if self.draw() % 4 == 0: o.append("-")
            ip = self.draw() % 10000
            fr = (self.draw() % 64) * 15625
            o.append("%d.%06d" % (ip, fr))
            if self.draw() % 8 == 0:
                o.append(["e1", "E+2", "e0"][self.draw() % 3])
        else:
            self.string(0, 12)

    def document(self, n):
        self.out.append("[\n")
        for i in range(n):
            if i: self.out.append(",\n")
            self.value(2)
        self.out.append("\n]\n")
        return "".join(self.out)


def checksum(doc):
    st = {"nodes": 0, "sum": 0.0, "str": 0, "depth": 0}

    def fold(v, d):
        st["nodes"] += 1
        st["depth"] = max(st["depth"], d)
        if isinstance(v, bool) or v is None: pass
        elif isinstance(v, (int, float)): st["sum"] += float(v)
        elif isinstance(v, str): st["str"] += len(v)
        elif isinstance(v, list):
            for x in v: fold(x, d + 1)
        else:
            for k, x in v.ps:
                st["str"] += len(k)
                fold(x, d + 1)
    sys.setrecursionlimit(10000)
    # object_pairs_hook keeps duplicate keys (random keys collide), as the parsers under test do
    class Obj:
        def __init__(self, ps): self.ps = ps
    def pairs(ps):
        return Obj(ps)
    v = json.loads(doc, object_pairs_hook=pairs)
    fold(v, 1)
    return "nodes=%d sum64=%d strlen=%d depth=%d" % (st["nodes"], int(st["sum"] * 64), st["str"], st["depth"])


if __name__ == "__main__":
    n = int(sys.argv[1])
    doc = Gen().document(n)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w", newline="\n") as f:
            f.write(doc)
    print("N=%d bytes=%d %s" % (n, len(doc), checksum(doc)))
