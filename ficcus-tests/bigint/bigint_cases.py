#!/usr/bin/env python3
"""Case generator for the BigInt differential tests: lines  op|a|b|expected  with the expected value computed by Python integers.
Semantics of the Elm package (cmditch/elm-bigint 2.1.2): div truncates towards zero, div by 0 is 0, modBy den num is the remainder of
the truncating division (sign of num) and Nothing for den 0, pow with a negative exponent is 0 and x^0 is 1, gcd with a zero
argument returns the other argument as it is, compare/min/max as usual."""
import random, sys
sys.set_int_max_str_digits(0)

B = 31


def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def trem(a, b):
    r = abs(a) % abs(b)
    return -r if a < 0 else r


def gcd_pkg(x, y):
    import math
    if x == 0:
        return y
    if y == 0:
        return x
    return math.gcd(x, y)


def rand_bits(rng, nbits):
    """a number with several structures: random, runs of ones/zeros, sparse."""
    if nbits <= 0:
        return 0
    k = rng.randrange(6)
    if k <= 2:
        return rng.getrandbits(nbits) | (1 << (nbits - 1))
    if k == 3:  # runs
        x = 0
        n = 0
        while n < nbits:
            run = rng.randrange(1, 70)
            x = (x << run) | (((1 << run) - 1) if rng.random() < 0.5 else 0)
            n += run
        return x & ((1 << nbits) - 1) | (1 << (nbits - 1))
    if k == 4:  # near a power of two
        return (1 << nbits) - rng.randrange(0, 4)
    return (1 << (nbits - 1)) + rng.randrange(0, 4)


def special(rng, maxbits):
    k = rng.randrange(10)
    if k == 0:
        return rng.choice([0, 1, -1, 2, -2, 10, 255, 256, 2**31 - 1, 2**31, 2**31 + 1, 10**9, 10**9 - 1, 10**9 + 1])
    if k == 1:
        j = rng.randrange(1, 6)
        return (1 << (B * j)) + rng.randrange(-3, 4)
    if k == 2:
        return 1 << rng.randrange(0, maxbits)
    if k == 3:
        return (1 << rng.randrange(1, maxbits)) - rng.randrange(0, 3)
    return rand_bits(rng, rng.randrange(1, maxbits + 1))


def num(rng, maxbits, signs=True):
    x = special(rng, maxbits)
    if signs and rng.random() < 0.5:
        x = -x
    return x


def divcase(rng, maxbits):
    """numerator built from the denominator: exact, one short, one more, remainder at the edges."""
    d = rand_bits(rng, rng.randrange(2, max(3, maxbits // 2)))
    q = rand_bits(rng, rng.randrange(1, maxbits // 2 + 2))
    r = rng.choice([0, 1, d - 1, rng.randrange(0, d), d // 2])
    n = d * q + r
    if rng.random() < 0.3:
        n -= rng.randrange(0, 3)
    if rng.random() < 0.5:
        n = -n
    if rng.random() < 0.5:
        d = -d
    return n, d


def addback_cases():
    """Numerators and denominators that make Knuth's algorithm D take the add back branch (base 2^31), found by search."""
    out = []
    rng = random.Random(12345)
    base = 1 << B
    for _ in range(400000):
        n = rng.choice([2, 3, 4])
        top = (1 << (B - 1)) + rng.choice([0, 0, 1, rng.randrange(0, 1 << 20)])
        v = [rng.choice([0, 1, base - 1, base - 2, rng.randrange(base)]) for _ in range(n - 1)] + [top]
        m = n + rng.choice([1, 1, 2])
        u = [rng.choice([0, 0, base - 1, rng.randrange(base)]) for _ in range(m - 1)] + [rng.choice([top - 1, top, top - 2, rng.randrange(1, top)])]
        if addback(u, v):
            out.append((sum(x << (B * i) for i, x in enumerate(u)), sum(x << (B * i) for i, x in enumerate(v))))
            if len(out) >= 40:
                break
    return out


def addback(u, v):
    """True when Knuth D (base 2^31) on these limb lists executes the add back step."""
    base = 1 << B
    n = len(v)
    s = B - v[-1].bit_length()
    vn = [0] * n
    un = [0] * (len(u) + 1)
    for i in range(n - 1, 0, -1):
        vn[i] = ((v[i] << s) | (v[i - 1] >> (B - s))) & (base - 1) if s else v[i]
    vn[0] = (v[0] << s) & (base - 1)
    un[len(u)] = (u[-1] >> (B - s)) if s else 0
    for i in range(len(u) - 1, 0, -1):
        un[i] = ((u[i] << s) | (u[i - 1] >> (B - s))) & (base - 1) if s else u[i]
    un[0] = (u[0] << s) & (base - 1)
    m = len(u)
    hit = False
    for j in range(m - n, -1, -1):
        num_ = un[j + n] * base + un[j + n - 1]
        qh = num_ // vn[n - 1]
        rh = num_ - qh * vn[n - 1]
        while qh >= base or qh * vn[n - 2] > rh * base + un[j + n - 2]:
            qh -= 1
            rh += vn[n - 1]
            if rh >= base:
                break
        k = 0
        for i in range(n):
            p = qh * vn[i]
            t = un[i + j] - k - (p & (base - 1))
            un[i + j] = t & (base - 1)
            k = (p >> B) - (t >> B)
        t = un[j + n] - k
        un[j + n] = t & (base - 1)
        if t < 0:
            hit = True
            k = 0
            for i in range(n):
                t = un[i + j] + vn[i] + k
                un[i + j] = t & (base - 1)
                k = t >> B
            un[j + n] = (un[j + n] + k) & (base - 1)
    return hit


def gen(seed, n, maxbits, big, elm=False):
    """n cases per operation (more for the cheap ones). elm: keep fromInt inside 2^53 for the package under node."""
    rng = random.Random(seed)
    L = []

    for _ in range(n):
        a, b = num(rng, maxbits), num(rng, maxbits)
        L.append(("add", a, b, a + b))
        L.append(("sub", a, b, a - b))
        L.append(("mul", a, b, a * b))
        L.append(("canon", a, b, a * b))
        L.append(("canonadd", a, b, a + b))
        L.append(("cmp", a, b, "LT" if a < b else "GT" if a > b else "EQ"))
        L.append(("lt", a, b, str(a < b)))
        L.append(("gt", a, b, str(a > b)))
        L.append(("lte", a, b, str(a <= b)))
        L.append(("gte", a, b, str(a >= b)))
        L.append(("max", a, b, max(a, b)))
        L.append(("min", a, b, min(a, b)))
        L.append(("gcd", a, b, gcd_pkg(a, b)))
        L.append(("neg", a, 0, -a))
        L.append(("abs", a, 0, abs(a)))
        L.append(("even", a, 0, str(a % 2 == 0)))
        L.append(("odd", a, 0, str(a % 2 == 1)))
        L.append(("toHex", a, 0, ("-" if a < 0 else "") + format(abs(a), "x")))
        L.append(("hexRound", a, 0, a))
        L.append(("fromIntString", str(a), 0, a))
    for _ in range(n):
        n_, d = divcase(rng, maxbits)
        _div_all(L, n_, d)
    for _ in range(n):
        a, b = num(rng, maxbits), num(rng, maxbits)
        _div_all(L, a, b)
    for a, d in addback_cases():
        for sa in (1, -1):
            for sd in (1, -1):
                _div_all(L, sa * a, sd * d)
    for _ in range(max(n // 10, 5)):
        b = rng.randrange(-12, 13) if rng.random() < 0.7 else num(rng, 200)
        e = rng.randrange(0, 40) if abs(b) > 1 or rng.random() < 0.5 else rng.randrange(0, 2000)
        L.append(("pow", b, e, b ** e))
    for b in (0, 1, -1, 2, -2, 3, 10, -10):
        for e in (0, 1, 2, 3, 31, 32, 62, 63, 64, 100):
            L.append(("pow", b, e, b ** e))
        L.append(("pow", b, -1, 0))
        L.append(("pow", b, -5, 0))
    # fromInt: the 64 bit range (the package under node: 2^53)
    lim = 2**53 if elm else 2**63
    ints = [0, 1, -1, 2**31 - 1, 2**31, 2**31 + 1, 2**62, -(2**62), lim - 1, -(lim - 1), 10**9, -(10**9)]
    if not elm:
        ints += [-(2**63), 2**63 - 1, 2**62 + 1, 2**61]
    for _ in range(n):
        ints.append(rng.randrange(-lim + 1, lim))
    for x in ints:
        L.append(("fromInt", x, 0, x))
    # fromIntString and fromHexString: accepted and rejected forms
    bad = ["", "-", "+", "--1", "+-1", "-+1", "1 ", " 1", "1.0", "1e3", "a", "0x1", "١٢", "1_000", "--", "++", "-0x1", "12a34"]
    for s in bad:
        L.append(("fromIntString", s, 0, "Nothing"))
    for s, v in [("0", 0), ("-0", 0), ("+0", 0), ("000", 0), ("-000", 0), ("0000123", 123), ("-0000123", -123), ("+0000123", 123),
                 ("9999999", 9999999), ("10000000", 10**7), ("10000001", 10**7 + 1), ("4294967296", 2**32), ("2147483648", 2**31)]:
        L.append(("fromIntString", s, 0, v))
    hbad = ["", "-", "+", "0x", "-0x", "--0x0", "R2D2", "0xC3P0", "+0x5", "0X5", "g", "-g", " 1", "1 ", "0x-1", "-0x-1"]
    for s in hbad:
        L.append(("fromHexString", s, 0, "Nothing"))
    for s, v in [("0", 0), ("0x0", 0), ("-0x0", 0), ("-0", 0), ("+0", 0), ("4b6", 0x4b6), ("-13d", -0x13d), ("0x456", 0x456), ("-0x123", -0x123),
                 ("0xBAD", 0xbad), ("BAD", 0xbad), ("0xbad", 0xbad), ("2386f26fc10000", 0x2386f26fc10000), ("0x2386f26fc10000", 0x2386f26fc10000),
                 ("+ff", 255), ("00ff", 255), ("0x00ff", 255)]:
        L.append(("fromHexString", s, 0, v))
    for _ in range(n):
        a = num(rng, maxbits)
        h = format(abs(a), "X" if rng.random() < 0.5 else "x")
        L.append(("fromHexString", ("-" if a < 0 else "") + rng.choice(["", "0x"]) + h, 0, a))
    # a few big ones: Karatsuba sizes, many limbs, long decimal strings
    for _ in range(big):
        a, b = num(rng, big_bits(rng)), num(rng, big_bits(rng))
        L.append(("mul", a, b, a * b))
        L.append(("canon", a, b, a * b))
        L.append(("add", a, b, a + b))
        L.append(("sub", a, b, a - b))
        L.append(("fromIntString", str(a), 0, a))
        L.append(("toHex", a, 0, ("-" if a < 0 else "") + format(abs(a), "x")))
        L.append(("hexRound", a, 0, a))
        n_, d = divcase(rng, big_bits(rng))
        _div_all(L, n_, d)
        _div_all(L, a * b, a)
        _div_all(L, a * b + rng.randrange(0, 3), b)
    return L


def big_bits(rng):
    return rng.choice([800, 1300, 2500, 4000, 9000, 20000])


def _div_all(L, a, b):
    if b == 0:
        L.append(("div", a, b, 0))
        L.append(("modBy", b, a, "Nothing"))
        L.append(("divmod", a, b, "Nothing"))
        return
    q, r = tdiv(a, b), trem(a, b)
    L.append(("div", a, b, q))
    L.append(("modBy", b, a, r))
    L.append(("divmod", a, b, "%d,%d" % (q, r)))


def render(L):
    lines = []
    for op, a, b, e in L:
        lines.append("%s|%s|%s|%s" % (op, a, b, e))
    return "\n".join(lines)
