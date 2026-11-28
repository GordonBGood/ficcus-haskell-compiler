def lcg(x): return (x * 48271) % 2147483647
out = []
def log(k, v): out.append('%s: "%s"' % (k, v.replace('"', '\\"')))
n = 5000
isp = [i >= 2 for i in range(n + 1)]
i = 2
while i * i <= n:
    if isp[i]:
        for j in range(i * i, n + 1, i): isp[j] = False
    i += 1
log("primes below 5000", str(sum(isp)))
log("primes list", ",".join(str(i) for i, p in enumerate(isp) if p)[: 0] or ",".join(str(i) for i in [i for i, p in enumerate(isp) if p][:10]))
log("prefix", ",".join(str(sum(k * k for k in range(m + 1))) for m in range(10)))
x = 7; acc = []
for _ in range(40):
    acc.append(x % 100); x = lcg(x)
acc = list(reversed(acc))   # the Elm fold conses, so the list is reversed
data = acc
log("sorted", ",".join(str(v) for v in sorted(data)))
log("unsorted untouched", ",".join(str(v) for v in data[:8]))
a = [i + 1 for i in range(9)]; b = [1 if i % 4 == 0 else 0 for i in range(9)]
m = [sum(a[(i3 := idx // 3) * 3 + k] * b[k * 3 + idx % 3] for k in range(3)) for idx in range(9)]
log("matmul", ",".join(str(v) for v in m))
ps = [[0, 3, "a"], [10, -4, "b"], [-15, 7, "c"]]
for _ in range(8):
    for p in ps:
        nx = p[0] + p[1]
        p[1] = -p[1] if abs(nx) > 20 else p[1]
        p[0] = nx
log("particles", " ".join("%s:%d/%d" % (p[2], p[0], p[1]) for p in ps))
log("strings", "-".join(["AB", "CD", "EF"]))
g = [[r * 10 + c for c in range(3)] for r in range(3)]
t = [[g[r][c] for r in range(3)] for c in range(3)]
log("grid transpose", ",".join(str(v) for row in t for v in row))
def sl(v, s, e):
    n = len(v)
    s = s + n if s < 0 else s; e = e + n if e < 0 else e
    s = max(0, s); e = min(n, e)
    return v[s:e] if s < e else []
log("slice/append", ",".join(str(v) for v in sl(a, 1, 3) + sl(a, -2, 9)))
log("filter", ",".join(str(v) for v in range(20) if v % 3 == 0))
log("persistence", "1,2,3|99,2,3,4")
log("push 3000", "3000")
log("out of range", "Nothing,Nothing,3")
print("\n".join(out))
