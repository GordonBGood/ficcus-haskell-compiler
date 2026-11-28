#!/usr/bin/env python3
"""E3c review, item 2: the range checks of every sized type and Float32 at their edges, through JSON text (fic_port_send_json is
what host3's `send` uses) into E3cSized, built --rc with ASan + UBSan (build.sh).  The expected result of every send is computed
independently in node from JavaScript's semantics (JSON.parse, then elm/json's int rule and the type's range; Float32 is
Math.fround; Word64 of a plain digit literal is exact, as the design's JUINT, else the double).  Successes and refusals are compared
as two ordered lists (the refusals print at once, the successes when the program's commands run).

  python3 edges.py EXE            EXE: build.sh E3cSized ../effects3/host/host3.c OUT  -> OUT/E3cSized-host3"""
import json, math, os, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
INTS = {"i8": (-128, 127), "i16": (-32768, 32767), "i32": (-2**31, 2**31 - 1), "w8": (0, 255), "w16": (0, 65535),
        "w32": (0, 2**32 - 1), "w64": (0, 2**64 - 1)}
COMMON = ["0", "-0", "-0.0", "0.0", "0e0", "1E0", "1e-0", "1e+0", "0.5e1", "1.5", "-1", "1e400", "-1e400", "4.9e-324", "1e-400",
          "null", "\"1\"", "true", "[]", "1" + "0" * 400, "-1" + "0" * 400, "0." + "0" * 400 + "1", "1." + "0" * 400,
          "1" + "0" * 400 + "e-400", "18446744073709551615", "18446744073709551616", "18446744073709551615.0",
          "18446744073709551615e0", "1.8446744073709551615e19", "1e19", "9223372036854775807", "9223372036854775808",
          "-9223372036854775808", "-9223372036854775809", "9007199254740993", "00", "01", "-", "1e", ".5", "+1", "0x10", "1.", "Infinity",
          "NaN"]


def edge_ints(lo, hi):
    out = []
    for e in (lo, hi):
        for d in (-1, 0, 1):
            x = e + d
            out += [str(x), "%d.0" % x, "%de0" % x]
    out += ["%d.5" % hi, "%d.5" % lo, "%d.00000000000001" % hi, "%d.0000000000000000000001" % hi,
            "%s%de-1" % ("-" if lo < 0 else "", abs(lo) * 10), "%de-1" % (hi * 10), "%d0e-1" % (hi + 1)]
    return out


F32 = ["3.4028234663852886e38", "3.4028235e38", "3.4028235677973362e38", "3.4028235677973366e38", "3.4028235677973370e38",
       "-3.4028235677973366e38", "1e39", "1.401298464324817e-45", "7.006492321624085e-46", "7.006492321624087e-46", "1e-46",
       "1.1754942106924411e-38", "1.1754943508222875e-38", "-1.4e-45", "16777217", "16777219", "0.1", "1.000000059604644775390625",
       "1.00000005960464477550", "2.5e-324", "-0.0", "1e400", "-1e400", "18446744073709551615", "123456789012345678901234567890"]


def plan():
    sends = []
    for t, (lo, hi) in INTS.items():
        for v in edge_ints(lo, hi) + COMMON:
            sends.append((t, v))
    for v in F32 + COMMON:
        sends.append(("f32", v))
    return sends


MODEL = r"""
const sends = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const R = {i8:[-128n,127n],i16:[-32768n,32767n],i32:[-2147483648n,2147483647n],w8:[0n,255n],w16:[0n,65535n],w32:[0n,4294967295n],
           w64:[0n,18446744073709551615n]};
const out = [];
for (const [t, s] of sends) {
  let x;
  try { x = JSON.parse(s); } catch (e) { out.push(['syntax']); continue; }
  if (t === 'f32') {
    if (typeof x !== 'number') { out.push(['refuse']); continue; }
    const f = Math.fround(x);
    out.push(['ok', String(f)]); continue;
  }
  if (typeof x !== 'number') { out.push(['refuse']); continue; }
  let b;
  if (t === 'w64' && /^[0-9]+$/.test(s) && BigInt(s) <= R.w64[1]) b = BigInt(s);           // D5: a plain literal is exact
  else if (!isFinite(x) || Math.floor(x) !== x) { out.push(['refuse']); continue; }        // elm/json's int rule
  else if (t !== 'w64' && (x >= 9223372036854775808 || x < -9223372036854775808)) { out.push(['refuse']); continue; }  // L21
  else b = BigInt(x);
  out.push(b >= R[t][0] && b <= R[t][1] ? ['ok', b.toString()] : ['refuse']);
}
process.stdout.write(JSON.stringify(out));
"""


def main():
    exe = sys.argv[1]
    sends = plan()
    model = json.loads(subprocess.run(["node", "-e", MODEL], input=json.dumps(sends).encode(), capture_output=True, check=True).stdout)
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    script = os.path.join(tmp, "edges.script")
    with open(script, "w") as f:
        f.write("sub output\n")
        for t, v in sends:
            f.write("send %sIn %s\n" % (t, v))
    r = subprocess.run([exe], env=dict(os.environ, FIC_HOST_SCRIPT=script), capture_output=True)
    lines = r.stdout.decode().split("\n")
    fails, oks, i = [], [], 0
    while i < len(lines):
        l = lines[i]
        if l.startswith("send ") and l.endswith(" failed:"):
            j = i + 1
            while j < len(lines) and not (lines[j].startswith("send ") or lines[j].split(" ")[0] in INTS or lines[j].startswith("f32 ")):
                j += 1
            fails.append("\n".join(lines[i + 1:j]).strip()); i = j; continue
        w = l.split(" ")
        if len(w) == 2 and (w[0] in INTS or w[0] == "f32"): oks.append((w[0], w[1]))
        i += 1
    want_ok = [(t, m[1]) for (t, v), m in zip(sends, model) if m[0] == "ok"]
    want_fail = [(t, v, m[0]) for (t, v), m in zip(sends, model) if m[0] != "ok"]
    bad = 0
    print("sends %d: model ok %d, refused %d (of which JSON syntax %d); got ok %d, refused %d; exit %d"
          % (len(sends), len(want_ok), len(want_fail), sum(1 for x in want_fail if x[2] == "syntax"), len(oks), len(fails), r.returncode))
    if len(oks) != len(want_ok) or len(fails) != len(want_fail):
        bad += 1
        print("COUNT MISMATCH")
    f32 = lambda x: struct.unpack("f", struct.pack("f", float(x)))[0] if math.isfinite(float(x)) else float(x)
    same = lambda g, w: g == w or (g[0] == w[0] == "f32" and f32(g[1]) == float(w[1]) and math.copysign(1, float(g[1])) == math.copysign(1, float(w[1])))
    for k, (g, w) in enumerate(zip(oks, want_ok)):          # Float32.toString prints the shortest float32 text: compare the values
        if not same(g, w): bad += 1; print("DIFF ok #%d: got %s want %s" % (k, g, w))
    # the refusal texts: the type's text for a number out of range, Elm's for the rest (printed for reading)
    for (t, v, why), text in zip(want_fail, fails):
        last = [x for x in text.split("\n") if x.strip()][-1] if text.strip() else ""
        print("refused %-4s %-40s %-7s | %s" % (t, (v[:37] + "...") if len(v) > 40 else v, why, last[:110]))
    if "ERROR: AddressSanitizer" in r.stderr.decode() or "runtime error" in r.stderr.decode():
        bad += 1; print("SANITIZER:\n" + r.stderr.decode()[-3000:])
    print("edges: %s" % ("%d problems" % bad if bad else "all equal to the model"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
