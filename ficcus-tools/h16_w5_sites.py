#!/usr/bin/env python3
"""H16 stage 2, E2: allocation sites of P1 A2 by function, stage 2 minus stage 1 (= parse).
Input: two FIC_SITE reports (stage 1 and stage 2 builds, FICCUS_ALLOC_SITES=1 at compile time, -DFIC_SITES -DFIC_NO_POOL -Wl,--wrap=free).
Sites are matched on (kind, definition name, source position); the `fNN_` clone number is dropped.
  python3 ficcus-tools/h16_s2_sites.py stage1.txt stage2.txt [--top 40]
Columns: parse allocations (stage 2 - stage 1), share of parse, freed in the activation that allocated, stage 1 count."""
import re, sys, collections

def load(p):
    d = collections.Counter(); same = collections.Counter(); other = collections.Counter(); tot = {}
    for l in open(p):
        if l.startswith("FIC_SITE_TOTAL"): tot["line"] = l.strip()
        m = re.match(r"FIC_SITE (\d+)\t(\d+)\t(\d+)\t(\d+)\t(\d+)\t([^\t]*)\t([^\t]*)\t(.*)", l.rstrip("\n"))
        if not m: continue
        _, n, ex, fs, fo, kind, fn, site = m.groups()
        k = (kind, re.sub(r"^f\d+_", "", fn), site)
        d[k] += int(n); same[k] += int(fs); other[k] += int(fo)
    return d, same, other, tot

a, as_, ao, ta = load(sys.argv[1]); b, bs, bo, tb = load(sys.argv[2])
top = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 40
print("stage 1", ta.get("line")); print("stage 2", tb.get("line"))
parse = {k: b[k] - a.get(k, 0) for k in set(b) | set(a)}
total = sum(parse.values()); print("attributed parse allocations:", total, " stage 1 attributed:", sum(a.values()), " stage 2 attributed:", sum(b.values()))
rows = sorted(parse.items(), key=lambda kv: -kv[1])
cum = 0
print("%-6s %-6s %-5s %-8s %-8s  %s" % ("parse", "share", "cum", "same-act", "stage1", "kind / function / source position"))
for k, v in rows[:top]:
    cum += v
    print("%-6d %5.1f%% %4.0f%% %-8d %-8d  %s | %s | %s" % (v, 100.0 * v / total, 100.0 * cum / total, bs[k] - as_.get(k, 0), a.get(k, 0), *k))
print("\nby function (parse):")
byf = collections.Counter()
for k, v in parse.items(): byf[k[1] + " @" + k[2]] += v
byfn = collections.Counter()
for k, v in parse.items(): byfn[k[1]] += v
for k, v in byfn.most_common(25): print("  %-6d %5.1f%%  %s" % (v, 100.0 * v / total, k))
print("\nby kind (parse):")
byk = collections.Counter()
for k, v in parse.items(): byk[k[0]] += v
for k, v in byk.most_common(): print("  %-6d %5.1f%%  %s" % (v, 100.0 * v / total, k))
print("\nstage 1 only, sites with count > 0 and no stage 2 growth are generation/conversion; list cells at List.lambda@261:")
for k in a:
    if "List.lambda@261" in k[2]: print("  stage1", a[k], "stage2", b.get(k, 0), k)
