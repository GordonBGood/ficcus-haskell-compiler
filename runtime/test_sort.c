/* Standalone test of runtime/fic_sort.h (H21, Powersort): every pattern and size against a reference (qsort with the position as the tie
   break, so the reference is the stable order), stability with equal keys (elements of 16 bytes sorted by the first word), the three scalar
   modes, Vector sort of a unique and of a shared vector (counted: the shared one is unchanged), sortPerm, sortIdx with a closure, and a fuzz
   with inconsistent comparators (never out of bounds: canaries around the array are intact, the result is a permutation of the input). */
#include <stdio.h>
#include <stddef.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_vector.h"
#include "fic_closure.h"
#include "fic_sort.h"

static int failures;
#define CHECK(what, cond) do { if (!(cond)) { printf("FAIL %s\n", what); failures++; } else printf("ok   %s\n", what); } while (0)

static uint64_t rs = 88172645463325252ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }

typedef struct { int64_t k; int64_t i; } kp;
static int cmp_kp(const void *a, const void *b) { const kp *x = (const kp *)a, *y = (const kp *)b; return x->k < y->k ? -1 : x->k > y->k ? 1 : 0; }
static int ref_kp(const void *a, const void *b) { const kp *x = (const kp *)a, *y = (const kp *)b; return x->k < y->k ? -1 : x->k > y->k ? 1 : x->i < y->i ? -1 : x->i > y->i; }

static int64_t gen(int p, int64_t i, int64_t n) {
  switch (p) {
  case 0: return (int64_t)(rnd() % 1000003) - 500000;
  case 1: return i;
  case 2: return n - i;
  case 3: return 5;
  case 4: return i < n / 2 ? i : n - i;
  case 5: return i % 50;
  case 6: return (i / 37) % 2 ? (i % 37) : 1000 - (i % 37);
  case 7: return rnd() % 10 == 0 ? (int64_t)(rnd() % 1000) : i;
  default: return (int64_t)(rnd() % 9);
  }
}

static void sort_cases(void) {
  static const int64_t sizes[] = { 0, 1, 2, 3, 31, 32, 33, 63, 64, 65, 100, 255, 256, 257, 300, 1000, 4097, 100000 };
  int p, bad = 0, badk = 0, bads = 0, badr = 0;
  size_t s;
  for (p = 0; p < 9; p++)
    for (s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
      int64_t n = sizes[s], i;
      fic_vcmp_fn cmpf = cmp_kp;
      kp *a = (kp *)malloc((size_t)(n + 1) * sizeof(kp)), *b = (kp *)malloc((size_t)(n + 1) * sizeof(kp));
      int64_t *v = (int64_t *)malloc((size_t)(n + 1) * 8);
      double *d = (double *)malloc((size_t)(n + 1) * 8);
      uint32_t *u = (uint32_t *)malloc((size_t)(n + 1) * 4);
      int64_t *v2 = (int64_t *)malloc((size_t)(n + 1) * 8), *v3 = (int64_t *)malloc((size_t)(n + 1) * 8);
      uint32_t *u2 = (uint32_t *)malloc((size_t)(n + 1) * 4), *u3 = (uint32_t *)malloc((size_t)(n + 1) * 4);
      for (i = 0; i < n; i++) { a[i].k = gen(p, i, n); a[i].i = i; b[i] = a[i]; v[i] = a[i].k; d[i] = (double)a[i].k; u[i] = (uint32_t)(a[i].k + 500000); v2[i] = v3[i] = (i % 97 == 5) ? (a[i].k % 2 ? INT64_MIN : INT64_MAX) : a[i].k; u2[i] = u3[i] = (uint32_t)(a[i].k + 500000) ^ ((i % 89 == 3) ? 0xFF000000u : 0u); }
      qsort(a, (size_t)n, sizeof(kp), ref_kp);
      fic_ps_sort_inl(b, n, sizeof(kp), fic_psg_cmp, (void *)&cmpf);     /* stable: must equal the reference, indices included */
      for (i = 0; i < n; i++) if (a[i].k != b[i].k || a[i].i != b[i].i) { bads++; break; }
      fic_ps_sort_i64(v, n); fic_ps_sort_f64(d, n); fic_ps_sort_u32(u, n);
      fic_ps_sort_i64(v2, n); fic_radix_i64(v3, n); fic_ps_sort_u32(u2, n); fic_radix_u32(u3, n);        /* radix with the extremes and the top byte */
      for (i = 0; i < n; i++) if (v2[i] != v3[i] || u2[i] != u3[i]) { badr++; break; }
      { int64_t *v4 = (int64_t *)malloc((size_t)(n + 1) * 8); for (i = 0; i < n; i++) v4[i] = a[(i * 7919) % (n ? n : 1)].k; fic_sort_i64_auto(v4, n); for (i = 1; i < n; i++) if (v4[i - 1] > v4[i]) { badr++; break; } free(v4); }
      for (i = 0; i < n; i++) if (v[i] != a[i].k || d[i] != (double)a[i].k || u[i] != (uint32_t)(a[i].k + 500000)) { bad++; break; }
      { fic_ps_pi *q = (fic_ps_pi *)malloc((size_t)(n + 1) * sizeof(fic_ps_pi));
        for (i = 0; i < n; i++) { q[i].k = b[i].k; q[i].i = b[i].i; }
        fic_ps_sort_pi(q, n);
        { fic_ps_pi *r1 = (fic_ps_pi *)malloc((size_t)(n + 1) * sizeof(fic_ps_pi)), *r2 = (fic_ps_pi *)malloc((size_t)(n + 1) * sizeof(fic_ps_pi));
          for (i = 0; i < n; i++) { r1[i].k = r2[i].k = (i % 53 == 7) ? INT64_MIN : (i % 59 == 9) ? INT64_MAX : (a[(i * 7919) % n].k % 7) - 3; r1[i].i = r2[i].i = i; }
          qsort(r1, (size_t)n, sizeof(fic_ps_pi), ref_kp); fic_radix_pi(r2, n);                      /* many equal keys, negative, extremes: stable */
          for (i = 0; i < n; i++) if (r1[i].k != r2[i].k || r1[i].i != r2[i].i) { badr++; break; }
          for (i = 0; i < n; i++) r2[i] = r1[i];
          fic_sort_pi_auto(r2, n);                                                                      /* sorted input (few runs): Powersort, same order */
          for (i = 0; i < n; i++) if (r1[i].k != r2[i].k || r1[i].i != r2[i].i) { badr++; break; }
          free(r1); free(r2); }
        for (i = 1; i < n; i++) if (q[i - 1].k > q[i].k) { badk++; break; }
        free(q); }
      free(a); free(b); free(v); free(d); free(u); free(v2); free(v3); free(u2); free(u3);
    }
  CHECK("scalar modes equal the reference on 9 patterns x 18 sizes", bad == 0);
  CHECK("stable: pairs equal the reference with indices", bads == 0);
  CHECK("pair sort is ordered", badk == 0);
  CHECK("radix (Int with INT64_MIN/MAX, Char with a high byte; stable pairs with equal keys) equals Powersort or the stable reference; the automatic choice sorts", badr == 0);
}

static fic_word gtclo(fic_ref self, fic_word a, fic_word b) { (void)self; return fic_w_b(a.i < b.i ? 0 : a.i == b.i ? 1 : 2); }
static const fic_code gtcode = { (void (*)(void))gtclo, 2u FIC_CODE_OWN0 };
static fic_word key2(fic_ref self, fic_word a, fic_word b) { (void)self; return fic_w_b((a.i % 5) < (b.i % 5) ? 0 : (a.i % 5) == (b.i % 5) ? 1 : 2); }
static const fic_code keycode = { (void (*)(void))key2, 2u FIC_CODE_OWN0 };

static fic_ref ivec(int64_t n, int p) {
  fic_ref v = fic_vector_new(n, 8, NULL);
  int64_t i;
  for (i = 0; i < n; i++) ((int64_t *)(void *)FIC_VECTOR(v)->data)[i] = gen(p, i, n);
  FIC_VECTOR(v)->len = n;
  return v;
}
static fic_word wildf(fic_ref self, fic_word a, fic_word b) { (void)self; (void)a; (void)b; return fic_w_b((uint8_t)(rnd() % 3)); }
static const fic_code wildcode = { (void (*)(void))wildf, 2u FIC_CODE_OWN0 };
static int gtw(void *f, const void *a, const void *b) { return fic_ap2((fic_ref)f, 0u, fic_w_i(*(const int64_t *)a), fic_w_i(*(const int64_t *)b)).b == 2u; }
static int is_sorted(fic_ref v) {
  int64_t i, *d = (int64_t *)(void *)FIC_VECTOR(v)->data;
  for (i = 1; i < FIC_VECTOR(v)->len; i++) if (d[i - 1] > d[i]) return 0;
  return 1;
}

static void vector_cases(void) {
  fic_ref v = ivec(1000, 0), w, perm, idx;
  fic_clo clo;
  int64_t i, *pd, before;
  int ok = 1;
  w = v; fic_dup(w);                                   /* shared: two owners */
  v = fic_vsort(v, FIC_SORT_I64, NULL, "test");
  CHECK("sort of a shared vector gives a sorted copy", is_sorted(v) && v != w);
  CHECK("the other owner still sees the original order", !is_sorted(w));
  fic_drop(w);
  w = v;
  v = fic_vsort(v, FIC_SORT_I64, NULL, "test");
#ifdef FIC_RC
  CHECK("sort of a unique vector is in place", v == w);
#else
  CHECK("without counts every sort copies", v != w);
#endif
  fic_drop(v);
  v = ivec(5000, 8);
  perm = fic_vsort_perm(v, FIC_SORT_I64, NULL);
  pd = (int64_t *)(void *)FIC_VECTOR(perm)->data; before = 0;
  for (i = 1; i < 5000; i++) {
    int64_t a = ((int64_t *)(void *)FIC_VECTOR(v)->data)[pd[i - 1]], b = ((int64_t *)(void *)FIC_VECTOR(v)->data)[pd[i]];
    if (a > b || (a == b && pd[i - 1] > pd[i])) ok = 0;
    before += pd[i];
  }
  CHECK("sortPerm is the stable permutation of the keys", ok && before + pd[0] == 5000 * 4999 / 2);
  fic_drop(perm); fic_drop(v);
  memset(&clo, 0, sizeof clo); clo.h.rc = FIC_IMMORTAL; clo.code = &gtcode;
  idx = ivec(100, 1);                                  /* 0..99 */
  idx = fic_vsort_idx((fic_ref)&clo, idx, "test");
  CHECK("sortIdx with a closure keeps the order of an ordered vector", is_sorted(idx));
  fic_drop(idx);
  clo.code = &keycode;
  idx = ivec(100, 1);
  idx = fic_vsort_idx((fic_ref)&clo, idx, "test");
  pd = (int64_t *)(void *)FIC_VECTOR(idx)->data; ok = 1;
  for (i = 1; i < 100; i++) if ((pd[i - 1] % 5) > (pd[i] % 5) || ((pd[i - 1] % 5) == (pd[i] % 5) && pd[i - 1] > pd[i])) ok = 0;
  CHECK("sortIdx with a closure comparator is stable", ok);
  fic_drop(idx);
  /* sortWith on the elements themselves (H21d): stable by key mod 5 (elements 0..4999 tagged by their value), unique vector in place */
  { fic_ref e = ivec(5000, 1), e2; int64_t *ed; clo.code = &keycode;
    e2 = e; e = fic_vsort_gt(e, gtw, (fic_ref)&clo, "test");
    ed = (int64_t *)(void *)FIC_VECTOR(e)->data; ok = 1;
    for (i = 1; i < 5000; i++) if ((ed[i - 1] % 5) > (ed[i] % 5) || ((ed[i - 1] % 5) == (ed[i] % 5) && ed[i - 1] > ed[i])) ok = 0;
    CHECK("sortWith on the elements is stable", ok);
#ifdef FIC_RC
    CHECK("sortWith on a unique vector is in place", e == e2);
#endif
    fic_drop(e);
    e = ivec(3000, 0); { int64_t sum = 0, sum2 = 0; for (i = 0; i < 3000; i++) sum += ((int64_t *)(void *)FIC_VECTOR(e)->data)[i];
      clo.code = &wildcode; e = fic_vsort_gt(e, gtw, (fic_ref)&clo, "test");
      for (i = 0; i < 3000; i++) sum2 += ((int64_t *)(void *)FIC_VECTOR(e)->data)[i];
      CHECK("sortWith with an inconsistent comparison function keeps a permutation", sum == sum2 && FIC_VECTOR(e)->len == 3000); }
    fic_drop(e); }
}

static int wild(const void *a, const void *b) { (void)a; (void)b; return (int)(rnd() % 3) - 1; }

static void fuzz_cases(void) {
  int t, bad = 0;
  fic_vcmp_fn wildf = wild;
  for (t = 0; t < 400; t++) {
    int64_t n = (int64_t)(rnd() % 3000), i, sum = 0, sum2 = 0;
    kp *a = (kp *)malloc((size_t)(n + 2) * sizeof(kp));
    a[0].k = -1; a[0].i = -7;                                      /* canaries before and after */
    a[n + 1].k = -2; a[n + 1].i = -9;
    for (i = 1; i <= n; i++) { a[i].k = (int64_t)(rnd() % 100); a[i].i = i; sum += a[i].i * 31 + a[i].k; }
    fic_ps_sort_inl(a + 1, n, sizeof(kp), fic_psg_cmp, (void *)&wildf);
    for (i = 1; i <= n; i++) sum2 += a[i].i * 31 + a[i].k;
    if (a[0].k != -1 || a[0].i != -7 || a[n + 1].k != -2 || a[n + 1].i != -9 || sum != sum2) bad++;
    free(a);
  }
  CHECK("inconsistent comparator: canaries intact and the result is a permutation (400 runs)", bad == 0);
}

int main(void) {
  sort_cases();
  vector_cases();
  fuzz_cases();
#ifdef FIC_STATS
  CHECK("no live object", fic_live_objects == 0);
#endif
  return failures != 0;
}
