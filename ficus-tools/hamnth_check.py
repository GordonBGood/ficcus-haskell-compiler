#!/usr/bin/env python3
"""hamnth_check.py N I J K : is 2^I 3^J 5^K the Nth Hamming number?  Independent exact method (Python integers, no floating point):
the number of triples (a, b, c) with 2^a 3^b 5^c <= x is counted (for each (b, c) the largest a is the bit length of x // (3^b 5^c) minus 1);
x is the Nth Hamming number exactly when that count is N and x itself is a Hamming number (it is: it has the exponents I J K).
With --merge it also runs the exact linear merge with big integers (slow, up to about 2 million) and compares.
Prints the number of decimal digits and the first and last 12 digits, and exits 1 on a mismatch."""
import sys

def count_le(x):
    cnt = 0
    p3 = 1
    while p3 <= x:
        m = p3
        while m <= x:
            cnt += (x // m).bit_length()      # a = 0 .. bit_length - 1
            m *= 5
        p3 *= 3
    return cnt

def merge(n):
    q = [1]; i2 = i3 = i5 = 0
    while len(q) < n:
        a, b, c = q[i2] * 2, q[i3] * 3, q[i5] * 5
        m = min(a, b, c)
        q.append(m)
        if a == m: i2 += 1
        if b == m: i3 += 1
        if c == m: i5 += 1
    return q[n - 1]

n, i, j, k = map(int, sys.argv[1:5])
x = 2 ** i * 3 ** j * 5 ** k
c = count_le(x)
ok = c == n
s = str(x)
print("n=%d  2^%d 3^%d 5^%d  digits=%d  %s...%s  count(<= x)=%d  %s" % (n, i, j, k, len(s), s[:12], s[-12:], c, "EXACT OK" if ok else "MISMATCH"))
if "--merge" in sys.argv:
    y = merge(n)
    print("exact merge: %s" % ("same" if y == x else "DIFFERENT: %d digits" % len(str(y))))
    ok = ok and y == x
sys.exit(0 if ok else 1)
