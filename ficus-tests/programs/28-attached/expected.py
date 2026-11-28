# independent computation of expected.out for 28-attached (Debug.log of a String prints label: "text")
def money(a): return "$%d.%02d" % (a // 100, a % 100)
def v2(a, b): return "(%d,%d)" % (a, b)
def poly_add(a, b):
    n = max(len(a), len(b)); return [(a[i] if i < len(a) else 0) + (b[i] if i < len(b) else 0) for i in range(n)]
def poly(cs): return "0" if not cs else "+".join("%dx%d" % (c, i) for i, c in enumerate(cs))
def vsum(xs, add, zero):
    acc = zero
    for x in xs: acc = add(acc, x)
    return acc
out = []
def log(k, v): out.append('%s: "%s"' % (k, v))
log("money sum", money(sum([150, 275, 5])))
log("v2 sum", v2(1 + 3 - 10, 2 + 4 + 7))
ps = vsum([[1, 2], [0, 0, 3], [5]], poly_add, [])
log("poly sum", poly(ps))
log("bag sum", "{" + ",".join(sorted(["pear"] + ["apple", "fig"])) + "}")
log("empty sums", " ".join([money(0), v2(0, 0), "0", "{}"]))
log("render", "[" + " ".join([money(1), money(99999)]) + "]" + "[" + v2(0, 0) + "]")
d = lambda cs: poly_add(cs, cs)
log("sumShown", money(2 * 12) + " " + v2(2 * 3, 2 * 4) + " " + poly(d(poly_add([1], [1, 1]))))
log("weighted", money(2 * 100 + 3 * 5) + " " + v2(-4 + 10, -4))
log("partial", " ".join(money(3 * x) for x in [1, 20]))
log("pipeline", money((7 + 8) * 2))
log("sizes", ",".join(str(x) for x in [1, 0, 3]))
print("\n".join(out))
