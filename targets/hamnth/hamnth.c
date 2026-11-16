/* hamnth.c -- hand written C for HamNth.fic: the nth Hamming number by the linear three pointer merge over exponent triples,
 * ordered by i ln2 + j ln3 + k ln5 in double. The queue is one malloc'd array (doubling), cut off in front by memmove when the
 * dead part is >= 65536 and as long as the live part, as in the Ficcus program. The number is printed by a base 1e9 digit multiply.
 *   gcc -std=c99 -O2 -ffp-contract=off -DTARGET=1000000 hamnth.c -o hamnth
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifndef TARGET
#define TARGET 1000000
#endif

typedef struct { int64_t i, j, k; } trip;

static const double LN2 = 0.6931471805599453, LN3 = 1.0986122886681098, LN5 = 1.6094379124341003;

static inline double key(trip t) { return (double)t.i * LN2 + (double)t.j * LN3 + (double)t.k * LN5; }
static inline int same(trip a, trip b) { return a.i == b.i && a.j == b.j && a.k == b.k; }

static trip nth(int64_t target) {
  int64_t cap = 1024, len = 1, base = 0, p2 = 0, p3 = 0, p5 = 0;
  trip *q = (trip *)malloc((size_t)cap * sizeof(trip));
  trip res;
  if (q == NULL) abort();
  q[0].i = q[0].j = q[0].k = 0;
  while (base + len < target) {
    trip a = q[p2 - base], b = q[p3 - base], c = q[p5 - base], next;
    trip ca = { a.i + 1, a.j, a.k }, cb = { b.i, b.j + 1, b.k }, cc = { c.i, c.j, c.k + 1 };
    double ka = key(ca), kb = key(cb), kc = key(cc);
    if (ka <= kb && ka <= kc) next = ca; else if (kb <= kc) next = cb; else next = cc;
    if (same(ca, next)) p2++;
    if (same(cb, next)) p3++;
    if (same(cc, next)) p5++;
    if (len == cap) { cap *= 2; q = (trip *)realloc(q, (size_t)cap * sizeof(trip)); if (q == NULL) abort(); }
    q[len++] = next;
    { int64_t dead = p5 - base;
      if (dead >= 65536 && dead * 2 >= len) { memmove(q, q + dead, (size_t)(len - dead) * sizeof(trip)); len -= dead; base = p5; } }
  }
  res = q[target - 1 - base];
  free(q);
  return res;
}

#define LIMB 1000000000LL

static int64_t mul(int64_t *d, int64_t n, int64_t m) {          /* d *= m, returns the new length */
  int64_t carry = 0, ix;
  for (ix = 0; ix < n; ix++) { int64_t t = d[ix] * m + carry; d[ix] = t % LIMB; carry = t / LIMB; }
  while (carry != 0) { d[n++] = carry % LIMB; carry /= LIMB; }
  return n;
}

static int64_t mulpow(int64_t *d, int64_t n, int64_t p, int64_t chunkE, int64_t e) {
  int64_t v;
  for (; e > chunkE; e -= chunkE) { v = 1; for (int64_t x = 0; x < chunkE; x++) v *= p; n = mul(d, n, v); }
  v = 1; for (int64_t x = 0; x < e; x++) v *= p;
  return mul(d, n, v);
}

int main(void) {
  trip t = nth(TARGET);
  int64_t *d = (int64_t *)calloc(4096, sizeof(int64_t));
  int64_t n = 1, ix;
  char *s = (char *)malloc(40000);
  size_t len;
  d[0] = 1;
  n = mulpow(d, n, 2, 22, t.i); n = mulpow(d, n, 3, 13, t.j); n = mulpow(d, n, 5, 9, t.k);
  len = (size_t)sprintf(s, "%lld", (long long)d[n - 1]);
  for (ix = n - 2; ix >= 0; ix--) len += (size_t)sprintf(s + len, "%09lld", (long long)d[ix]);
  printf("Hamming number %lld = 2^%lld * 3^%lld * 5^%lld\r\n", (long long)TARGET, (long long)t.i, (long long)t.j, (long long)t.k);
  printf("%s (%zu digits)\r\n", s, len);
  return 0;
}
