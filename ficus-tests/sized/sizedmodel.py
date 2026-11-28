"""Reference model of the sized integers and Float32 (docs/SIZED-PLAN.md section 3), in Python integers and numpy float32.
Written independently of runtime/fic_sized.h: arbitrary precision arithmetic with explicit masks (integers) and numpy float32
arithmetic (Float32). Used by gen_cases.py (the attach cases) and fuzz.py."""
import math
import numpy as np

class Int:
    def __init__(self, name, bits, signed):
        self.name, self.bits, self.signed = name, bits, signed
        self.mask = (1 << bits) - 1
        self.lo = -(1 << (bits - 1)) if signed else 0
        self.hi = (1 << (bits - 1)) - 1 if signed else self.mask
    isfloat = False
    def wrap(self, x):
        x &= self.mask
        return x - (1 << self.bits) if self.signed and x >= (1 << (self.bits - 1)) else x
    def add(self, a, b): return self.wrap(a + b)
    def sub(self, a, b): return self.wrap(a - b)
    def mul(self, a, b): return self.wrap(a * b)
    def pow(self, a, e):
        if e < 0:                                     # only IntN has negative exponents: the truncated integer result (decision L4)
            return 1 if a == 1 else (self.wrap(-1 if e % 2 else 1) if a == -1 else 0)
        return self.wrap(pow(a, e, 1 << self.bits)) if self.bits < 64 or True else None
    def neg(self, a): return self.wrap(-a)
    def abs(self, a): return self.wrap(-a) if (self.signed and a < 0) else a
    def idiv(self, a, b):
        if b == 0: return 0
        q = abs(a) // abs(b)
        return self.wrap(-q if (a < 0) != (b < 0) else q)
    def mod(self, m, x):                              # modBy m x
        if m == 0 or (self.signed and m == -1): return 0
        return self.wrap(x % m)
    def rem(self, m, x):                              # remainderBy m x
        if m == 0 or (self.signed and m == -1): return 0
        r = abs(x) % abs(m)
        return self.wrap(-r if x < 0 else r)
    def and_(self, a, b): return self.wrap(a & b)
    def or_(self, a, b): return self.wrap(a | b)
    def xor(self, a, b): return self.wrap(a ^ b)
    def complement(self, a): return self.wrap(~a)
    def shl(self, n, a): return self.wrap(a << (n & (self.bits - 1)))
    def shr(self, n, a): return self.wrap(a >> (n & (self.bits - 1)))
    def popcount(self, a): return bin(a & self.mask).count("1")
    def tostr(self, a): return str(a)
    def toint(self, a): return a - (1 << 64) if (self.bits == 64 and not self.signed and a >= (1 << 63)) else a
    def fromint(self, n): return self.wrap(n)
    def cmp(self, a, b): return "LT" if a < b else ("EQ" if a == b else "GT")
    def fromstr(self, s):
        import re
        if not re.fullmatch(r"[+-]?[0-9]+", s) or (not self.signed and s[0] in "+-" and False): return None
        if not self.signed and s[0] in "-+": return None if s[0] == "-" else None
        n = int(s)
        return n if self.lo <= n <= self.hi else None

def f32(x):
    with np.errstate(all="ignore"):
        return np.float32(x)

class F32:
    name, bits, signed, isfloat = "Float32", 32, True, True
    def add(self, a, b):
        with np.errstate(all="ignore"): return np.float32(a + b)
    def sub(self, a, b):
        with np.errstate(all="ignore"): return np.float32(a - b)
    def mul(self, a, b):
        with np.errstate(all="ignore"): return np.float32(a * b)
    def div(self, a, b):
        with np.errstate(all="ignore"): return np.float32(a / b)
    def neg(self, a): return np.float32(-a)
    def abs(self, a): return np.float32(abs(a))
    def pow(self, a, b):
        try: return np.float32(math.pow(float(a), float(b)))
        except OverflowError: return np.float32(math.inf)
        except ValueError: return np.float32(math.nan)
    def fromint(self, n): return np.float32(n)          # numpy rounds an int64 to float directly (one rounding)
    def cmp(self, a, b): return "EQ" if a == b else ("LT" if a < b else "GT")      # a NaN gives GT, as Float
    def lt(self, a, b): return bool(a < b)
    def le(self, a, b): return bool(a <= b)
    def gt(self, a, b): return bool(not (a < b or a == b))     # as the Elm kernel: NaN compares as GT, so `>` is true
    def ge(self, a, b): return bool(not (a < b))
    def tostr(self, a):
        a = np.float32(a)
        if a != a: return "NaN"
        if a == 0: return "0"
        if np.isinf(a): return "Infinity" if a > 0 else "-Infinity"
        neg = a < 0
        s = np.format_float_scientific(np.float32(abs(a)), unique=True, trim="-")       # d.ddde+XX
        mant, ex = s.split("e")
        digits = mant.replace(".", "").rstrip("0") or "0"
        e10 = int(ex)
        k, n = len(digits), e10 + 1
        if k <= n <= 21: out = digits + "0" * (n - k)
        elif 0 < n <= 21: out = digits[:n] + "." + digits[n:]
        elif -6 < n <= 0: out = "0." + "0" * (-n) + digits
        else:
            out = digits[0] + ("." + digits[1:] if k > 1 else "") + "e" + ("-" if n - 1 < 0 else "+") + str(abs(n - 1))
        return ("-" if neg else "") + out

INTS = [Int("Int8", 8, True), Int("Int16", 16, True), Int("Int32", 32, True),
        Int("Word8", 8, False), Int("Word16", 16, False), Int("Word32", 32, False), Int("Word64", 64, False)]
BY_NAME = {t.name: t for t in INTS}
BY_NAME["Float32"] = F32()

def lt(t, a, b): return t.lt(a, b) if t.isfloat else a < b
def le(t, a, b): return t.le(a, b) if t.isfloat else a <= b
def gt(t, a, b): return t.gt(a, b) if t.isfloat else a > b
def ge(t, a, b): return t.ge(a, b) if t.isfloat else a >= b

def boundary(t):
    """boundary values of an integer type (canonical)"""
    vals = {t.lo, t.lo + 1, t.hi, t.hi - 1, 0, 1, 2, 3, 7, 8, 15, 16}
    for x in (-1, -2, 100, 127, 128, 255, 256, 32767, 32768, 65535, 65536):
        vals.add(t.wrap(x))
    return sorted(vals)

def fvals():
    return [np.float32(x) for x in (0.0, 1.0, -1.0, 0.1, 0.2, 0.3, 3.14159274, 16777216.0, 16777217.0, 1e10, 1e-10, 3.4028234e38, 1.17549435e-38, 1e-45,
                                     0.5, 2.5, -2.5, 100.0, 1e21, 1e-7, 123456.789)] + [np.float32(math.inf), np.float32(-math.inf), np.float32(math.nan)]
