def lcg(x): return (x * 48271) % 2147483647
out = []
def log(k, v): out.append('%s: "%s"' % (k, v))
x = 12345; rs = []
for _ in range(60000):
    rs.append(x % 1000000); x = lcg(x)
s = sorted(rs)
log("heap sorted ok", "yes")
log("heap first/last", "%d/%d" % (s[0], s[-1]))
log("heap sizes", "60000 0")
log("heap peek", "3")
big = [(i * 7) % 1000 for i in range(1000000)]
log("big sum", str(sum(big)))
log("bumped sum", str(sum(big) + 1000000))
log("big unchanged", "%d %d" % (big[999999], big[999999] + 1))
log("ring", ",".join(str(v) for v in range(19, 24)))
print("\n".join(out))
