/* Hand C reference for the BigInt benchmarks: the same algorithm on plain limb arrays (uint32_t limbs of 31 bits, uint64_t products),
   so that the Ficcus package can be compared with the same work done without a runtime: schoolbook and Karatsuba (from KARA limbs),
   Knuth D, one pass divisions by 10^9 for the decimal conversion.   ./ref fact|fib|pow3|build|tostr|fromstr|divmod  */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uint32_t limb;
typedef uint64_t u64;
typedef int64_t i64;
#define BITS 31
#define BASE ((u64)1 << BITS)
#define MASK (BASE - 1)
#define KARA 48
typedef struct { limb *d; int n, cap; } num;   /* trimmed: d[n-1] != 0, zero is n == 0 */

static num mk(int cap) { num r; r.cap = cap < 1 ? 1 : cap; r.d = calloc(r.cap, sizeof(limb)); r.n = 0; return r; }
static void trim(num *a) { while (a->n > 0 && a->d[a->n - 1] == 0) a->n--; }
static num copy(const limb *d, int n) { num r = mk(n); memcpy(r.d, d, n * sizeof(limb)); r.n = n; return r; }
static void fr(num *a) { free(a->d); a->d = NULL; a->n = 0; }

static num add(const num *a, const num *b) {
    if (a->n < b->n) { const num *t = a; a = b; b = t; }
    num r = mk(a->n + 1); u64 c = 0;
    for (int i = 0; i < a->n; i++) { u64 s = (u64)a->d[i] + (i < b->n ? b->d[i] : 0) + c; r.d[i] = s & MASK; c = s >> BITS; }
    r.d[a->n] = (limb)c; r.n = a->n + 1; trim(&r); return r;
}
/* a >= b */
static num sub(const num *a, const num *b) {
    num r = mk(a->n); i64 br = 0;
    for (int i = 0; i < a->n; i++) { i64 d = (i64)a->d[i] - (i < b->n ? b->d[i] : 0) - br; r.d[i] = d & MASK; br = d < 0; }
    r.n = a->n; trim(&r); return r;
}
static void addinto(limb *r, int off, const num *x) {
    u64 c = 0; int i;
    for (i = 0; i < x->n; i++) { u64 s = (u64)x->d[i] + r[off + i] + c; r[off + i] = s & MASK; c = s >> BITS; }
    for (int j = off + i; c; j++) { u64 s = r[j] + c; r[j] = s & MASK; c = s >> BITS; }
}
static int bitlen(limb x) { int n = 0; while (x) { n++; x >>= 1; } return n; }
static int pow2exp(const num *a) {
    if (a->n == 0) return -1;
    int i = 0; while (a->d[i] == 0) i++;
    if (i != a->n - 1 || (a->d[i] & (a->d[i] - 1))) return -1;
    return i * BITS + bitlen(a->d[i]) - 1;
}
static num shl(int k, const num *a) {
    if (a->n == 0) return mk(1);
    int q = k / BITS, s = k % BITS; num r = mk(a->n + q + 1); u64 c = 0;
    for (int i = 0; i < a->n; i++) { u64 t = ((u64)a->d[i] << s) | c; r.d[i + q] = t & MASK; c = t >> BITS; }
    r.d[a->n + q] = (limb)c; r.n = a->n + q + 1; trim(&r); return r;
}
static num mul(const num *a, const num *b);
static num school(const num *a, const num *b) {
    num r = mk(a->n + b->n);
    for (int i = 0; i < a->n; i++) {
        u64 ai = a->d[i], c = 0; if (!ai) continue;
        for (int j = 0; j < b->n; j++) { u64 t = ai * b->d[j] + r.d[i + j] + c; r.d[i + j] = t & MASK; c = t >> BITS; }
        r.d[i + b->n] = (limb)c;
    }
    r.n = a->n + b->n; trim(&r); return r;
}
static num slice(const num *a, int from, int to) { if (to > a->n) to = a->n; if (from >= to) return mk(1); num r = copy(a->d + from, to - from); trim(&r); return r; }
static num core(const num *a, const num *b) {
    if (a->n < b->n) { const num *t = a; a = b; b = t; }
    if (b->n < KARA) return school(a, b);
    if (a->n >= 2 * b->n) {
        num r = mk(a->n + b->n + 1);
        for (int off = 0; off < a->n; off += b->n) { num p = slice(a, off, off + b->n); num m = core(&p, b); addinto(r.d, off, &m); fr(&p); fr(&m); }
        r.n = a->n + b->n + 1; trim(&r); return r;
    }
    int m = (a->n + 1) / 2;
    num a0 = slice(a, 0, m), a1 = slice(a, m, a->n), b0 = slice(b, 0, m), b1 = slice(b, m, b->n);
    num z0 = mul(&a0, &b0), z2 = mul(&a1, &b1), sa = add(&a0, &a1), sb = add(&b0, &b1), z1 = mul(&sa, &sb);
    num t1 = sub(&z1, &z0), t2 = sub(&t1, &z2);
    num r = mk(a->n + b->n + 1);
    addinto(r.d, 0, &z0); addinto(r.d, m, &t2); addinto(r.d, 2 * m, &z2);
    r.n = a->n + b->n + 1; trim(&r);
    fr(&a0); fr(&a1); fr(&b0); fr(&b1); fr(&z0); fr(&z1); fr(&z2); fr(&sa); fr(&sb); fr(&t1); fr(&t2);
    return r;
}
static num mul(const num *a, const num *b) {
    int k = pow2exp(a); if (k >= 0) return shl(k, b);
    k = pow2exp(b); if (k >= 0) return shl(k, a);
    return core(a, b);
}
static int cmp(const num *a, const num *b) {
    if (a->n != b->n) return a->n < b->n ? -1 : 1;
    for (int i = a->n - 1; i >= 0; i--) if (a->d[i] != b->d[i]) return a->d[i] < b->d[i] ? -1 : 1;
    return 0;
}
/* in place a = a * m + c */
static void muladd(num *a, u64 m, u64 c) {
    for (int i = 0; i < a->n; i++) { u64 t = a->d[i] * m + c; a->d[i] = t & MASK; c = t >> BITS; }
    if (c) { if (a->n == a->cap) { a->cap *= 2; a->d = realloc(a->d, a->cap * sizeof(limb)); } a->d[a->n++] = (limb)c; }
}
/* in place a = a / d, returns the remainder */
static u64 divsmall(num *a, u64 d) {
    u64 r = 0;
    for (int i = a->n - 1; i >= 0; i--) { u64 cur = (r << BITS) | a->d[i]; u64 q = cur / d; r = cur - q * d; a->d[i] = (limb)q; }
    trim(a); return r;
}
static void divmod(const num *u0, const num *v0, num *q, num *rem) {
    if (cmp(u0, v0) < 0) { *q = mk(1); *rem = copy(u0->d, u0->n); return; }
    if (v0->n == 1) { *q = copy(u0->d, u0->n); u64 r = divsmall(q, v0->d[0]); *rem = mk(1); if (r) { rem->d[0] = (limb)r; rem->n = 1; } return; }
    int n = v0->n, m = u0->n, s = BITS - bitlen(v0->d[n - 1]);
    limb *vn = calloc(n, sizeof(limb)), *un = calloc(m + 1, sizeof(limb));
    for (int i = n - 1; i > 0; i--) vn[i] = ((v0->d[i] << s) | (u64)v0->d[i - 1] >> (BITS - s)) & MASK;
    vn[0] = (v0->d[0] << s) & MASK;
    un[m] = (u64)u0->d[m - 1] >> (BITS - s);
    for (int i = m - 1; i > 0; i--) un[i] = ((u0->d[i] << s) | (u64)u0->d[i - 1] >> (BITS - s)) & MASK;
    un[0] = (u0->d[0] << s) & MASK;
    *q = mk(m - n + 1);
    for (int j = m - n; j >= 0; j--) {
        u64 num_ = (u64)un[j + n] * BASE + un[j + n - 1], qh = num_ / vn[n - 1], rh = num_ - qh * vn[n - 1];
        while (qh >= BASE || qh * vn[n - 2] > rh * BASE + un[j + n - 2]) { qh--; rh += vn[n - 1]; if (rh >= BASE) break; }
        i64 k = 0;
        for (int i = 0; i < n; i++) { u64 p = qh * vn[i]; i64 t = (i64)un[i + j] - k - (i64)(p & MASK); un[i + j] = t & MASK; k = (i64)(p >> BITS) - (t >> BITS); }
        i64 t = (i64)un[j + n] - k; un[j + n] = t & MASK;
        if (t < 0) {
            qh--; u64 c = 0;
            for (int i = 0; i < n; i++) { u64 s2 = (u64)un[i + j] + vn[i] + c; un[i + j] = s2 & MASK; c = s2 >> BITS; }
            un[j + n] = (un[j + n] + c) & MASK;
        }
        q->d[j] = (limb)qh;
    }
    q->n = m - n + 1; trim(q);
    num t = copy(un, n); trim(&t);
    /* denormalise */
    for (int i = 0; i < t.n; i++) t.d[i] = ((t.d[i] >> s) | ((u64)(i + 1 < n ? t.d[i + 1] : 0) << (BITS - s))) & MASK;
    trim(&t); *rem = t;
    free(vn); free(un);
}
static char *tostr(const num *a0) {
    num a = copy(a0->d, a0->n); int cap = a.n * 10 + 10; unsigned *chunks = malloc(cap * sizeof(unsigned)); int nc = 0;
    while (a.n) chunks[nc++] = (unsigned)divsmall(&a, 1000000000);
    char *s = malloc(nc * 9 + 2), *p = s;
    if (nc == 0) { strcpy(s, "0"); free(chunks); fr(&a); return s; }
    p += sprintf(p, "%u", chunks[nc - 1]);
    for (int i = nc - 2; i >= 0; i--) p += sprintf(p, "%09u", chunks[i]);
    free(chunks); fr(&a); return s;
}
static num fromstr(const char *s) {
    int len = strlen(s); num r = mk(len / 9 + 2); int cnt = 0; u64 acc = 0;
    for (int i = 0; i < len; i++) {
        acc = acc * 10 + (s[i] - '0');
        if (++cnt == 9) { muladd(&r, 1000000000, acc); cnt = 0; acc = 0; }
    }
    if (cnt) { u64 p = 1; for (int i = 0; i < cnt; i++) p *= 10; muladd(&r, p, acc); }
    trim(&r); return r;
}
static num small(u64 x) { num r = mk(3); while (x) { r.d[r.n++] = x & MASK; x >>= BITS; } return r; }
static num powi(u64 b, int e) {  /* left to right square and multiply */
    num bb = small(b), acc = copy(bb.d, bb.n);
    int top = 31 - __builtin_clz(e);
    for (int p = top - 1; p >= 0; p--) {
        num sq = mul(&acc, &acc); fr(&acc);
        if ((e >> p) & 1) { acc = mul(&sq, &bb); fr(&sq); } else acc = sq;
    }
    fr(&bb); return acc;
}
static void summary(const char *what, const char *s) {
    int n = strlen(s);
    printf("%s: \"len=%d head=%.20s tail=%s\"\n", what, n, s, s + (n > 20 ? n - 20 : 0));
}
#ifndef NOMAIN
int main(int argc, char **argv) {
    const char *w = argc > 1 ? argv[1] : "fact";
    if (!strcmp(w, "fact")) {
        num f = small(1);
        for (int i = 2; i <= 10000; i++) muladd(&f, i, 0);
        char *s = tostr(&f); summary("fact10000", s);
    } else if (!strcmp(w, "fib")) {
        num a = small(0), b = small(1);
        for (int i = 0; i < 100000; i++) { num c = add(&a, &b); fr(&a); a = b; b = c; }
        char *s = tostr(&a); summary("fib100000", s);
    } else if (!strcmp(w, "pow3")) {
        num p = powi(3, 200000); char *s = tostr(&p); summary("pow3_200000", s);
    } else if (!strcmp(w, "build")) {
        num p = powi(3, 209589); printf("build: \"%s\"\n", p.n > 0 ? "positive" : "zero");
    } else if (!strcmp(w, "tostr")) {
        num p = powi(3, 209589); char *s = tostr(&p); summary("tostr", s);
    } else if (!strcmp(w, "fromstr")) {
        char *s = malloc(100001); for (int i = 0; i < 100000; i++) s[i] = "1234567890"[i % 10]; s[100000] = 0;
        num p = fromstr(s); printf("fromstr: \"odd %s\"\n", (p.d[0] & 1) ? "True" : "False");
    } else if (!strcmp(w, "mulbig")) {
        num x = powi(3, 150000), y = powi(7, 90000), acc = small(0);
        for (int i = 0; i < 5; i++) {
            num xi = small(i), x2 = add(&x, &xi), p = mul(&x2, &y); u64 m = divsmall(&p, 1000000007);
            num mm = small(m), a2 = add(&acc, &mm); fr(&acc); acc = a2; fr(&xi); fr(&x2); fr(&p); fr(&mm);
        }
        char *s = tostr(&acc); printf("mulbig: \"%s\"\n", s);
    } else if (!strcmp(w, "divmod")) {
        num n = powi(3, 209589), d = powi(7, 59200), sum = small(0);
        for (int i = 0; i < 10; i++) {
            num ni = small(i), n2 = add(&n, &ni), q, r; divmod(&n2, &d, &q, &r);
            num s1 = add(&sum, &q), s2 = add(&s1, &r); fr(&sum); fr(&s1); sum = s2; fr(&q); fr(&r); fr(&n2); fr(&ni);
        }
        char *s = tostr(&sum); summary("divmod", s);
    }
    return 0;
}
#endif
