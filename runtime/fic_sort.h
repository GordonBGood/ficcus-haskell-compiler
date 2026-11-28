/* fic_sort.h -- Powersort for the flat Vector (H21). Needs fic_vector.h (and fic_closure.h for the closure comparator).

   Algorithm: Powersort (Munro and Wild 2018, "Nearly-Optimal Mergesorts"), written from the paper.
     1. NATURAL RUNS. A run is a maximal ascending (not strictly: equal elements stay in order) or strictly descending stretch; a strictly
        descending run is reversed in place. Equal elements are never reversed, so the sort is STABLE.
     2. A run shorter than the minimum run length (32..64, as in Timsort: n for n < 64) is extended to it by binary insertion (upper
        bound: an element goes behind the equal ones).
     3. MERGE ORDER. The boundary between two adjacent runs gets a "power": with the midpoints of the two runs as fractions of n, the
        index of the first binary digit in which they differ. It is computed with integer arithmetic (no division, no floating point).
        A stack holds the runs that wait; before a run is pushed, every stack run whose boundary power is larger than the new one is
        merged into it. This is a merge tree that is within a constant of the optimum for the run lengths.
     4. MERGE with a scratch buffer of at most n/2 elements: the smaller half is copied out, the merge goes forward (left half copied)
        or backward (right half copied), ties take the left element (stability). No galloping (not measured to be needed).
   The only test the algorithm makes is GT(x, y), "x is strictly greater than y"; it never reads outside [0, n) and never calls GT with
   the scratch buffer as anything but a value, so a comparator that is inconsistent (not a total order) gives a wrong order, never a crash.
   Elements are moved with memcpy (their reference counts do not change: a sort only permutes), the comparator gets BORROWED element
   addresses. The core is `always_inline` with the element size and the comparator as arguments, so each wrapper below (Int, Float,
   Char, pairs) is a specialisation with a constant size and a direct, inlined comparison; the others call through a function pointer.

   Comparison modes of the kernels (the generator picks one from the exact element type, Ficus.Mono.CGen `vectorCall`):
     FIC_SORT_I64  Int, direct int64 compare          FIC_SORT_F64  Float, `!(a <= b)` (Elm's compare: a NaN is GT)
     FIC_SORT_U32  Char (code point)                  FIC_SORT_CMP  a generated comparator on element addresses (String: fic_str_cmp;
     and structural compare for tuples and lists: the same `fic_cmp_N` that `compare` uses)
   and the closure comparator (List.sortWith, Vector.sortWith: `fic_vsort_idx`, a user function that returns an Order).

   sortBy and sortWith are done by a PERMUTATION: `fic_vsort_perm` sorts (key, index) pairs by key (Int, Float, Char keys) or the indices
   with an indirect compare (other keys) and returns the index vector; the Elm side (overlay/Vector.elm) builds the result from it.
   KNOWN DIFFERENCE from Elm's JS kernel: sortBy computes the key of EVERY element once (n key calls); elm/core calls it at each comparison,
   so a key function with an effect (Debug.log) shows a different log, and a key of an element that is never compared is computed here. */
#ifndef FIC_SORT_H
#define FIC_SORT_H

#include <stdlib.h>
#include <string.h>

#define FIC_SORT_I64 1
#define FIC_SORT_F64 2
#define FIC_SORT_U32 3
#define FIC_SORT_CMP 4

typedef int (*fic_ps_gt_fn)(void *ctx, const void *a, const void *b);     /* nonzero when *a > *b strictly */
typedef int (*fic_vcmp_fn)(const void *a, const void *b);                  /* the sign of the comparison of two elements */

#if defined(__GNUC__)
#  define FIC_PS_INLINE static inline __attribute__((always_inline))
#else
#  define FIC_PS_INLINE static inline
#endif

#define FIC_PS_MAXSTACK 96

/* the minimum run length: n itself below 64, else 32..64 such that n / minrun is (almost) a power of two */
static inline int64_t fic_ps_minrun(int64_t n) {
  int64_t r = 0;
  while (n >= 64) { r |= n & 1; n >>= 1; }
  return n + r;
}

/* the power of the boundary between the runs [s1,e1) and [s2,e2) (e1 == s2) of an array of n elements, n >= 2: the first binary digit
   at which the midpoints (s1+e1)/2n and (s2+e2)/2n differ. a and b are twice the midpoints, below 2n, and a < b, so this stops. */
static inline int fic_ps_power(int64_t n, int64_t s1, int64_t e1, int64_t s2, int64_t e2) {
  uint64_t nn = 2u * (uint64_t)n, a = (uint64_t)(s1 + e1), b = (uint64_t)(s2 + e2);
  int k = 0;
  for (;;) {
    int da, db;
    k++; a <<= 1; b <<= 1;
    da = a >= nn; db = b >= nn;
    if (da != db) return k;
    if (da) { a -= nn; b -= nn; }
  }
}

#define FIC_PS_AT(i) (base + (size_t)(i) * es)

/* binary insertion of the elements start..hi-1 into the sorted [lo, start); tmp holds one element */
FIC_PS_INLINE void fic_ps_insertion(unsigned char *base, size_t es, int64_t lo, int64_t start, int64_t hi, fic_ps_gt_fn gt, void *ctx, unsigned char *tmp) {
  int64_t i;
  for (i = start; i < hi; i++) {
    int64_t l = lo, r = i;
    if (i > lo && !gt(ctx, FIC_PS_AT(i - 1), FIC_PS_AT(i))) continue;       /* already in place */
    memcpy(tmp, FIC_PS_AT(i), es);
    while (l < r) { int64_t m = l + (r - l) / 2; if (gt(ctx, FIC_PS_AT(m), tmp)) r = m; else l = m + 1; }
    memmove(FIC_PS_AT(l + 1), FIC_PS_AT(l), (size_t)(i - l) * es);
    memcpy(FIC_PS_AT(l), tmp, es);
  }
}

/* the end of the run that starts at s (reversed if strictly descending, extended to minrun by insertion) */
FIC_PS_INLINE int64_t fic_ps_extend(unsigned char *base, size_t es, int64_t n, int64_t s, int64_t minrun, fic_ps_gt_fn gt, void *ctx, unsigned char *tmp) {
  int64_t e = s + 1;
  if (e < n) {
    if (gt(ctx, FIC_PS_AT(s), FIC_PS_AT(e))) {
      int64_t lo = s, hi;
      e++;
      while (e < n && gt(ctx, FIC_PS_AT(e - 1), FIC_PS_AT(e))) e++;
      hi = e - 1;
      while (lo < hi) { memcpy(tmp, FIC_PS_AT(lo), es); memcpy(FIC_PS_AT(lo), FIC_PS_AT(hi), es); memcpy(FIC_PS_AT(hi), tmp, es); lo++; hi--; }
    } else {
      e++;
      while (e < n && !gt(ctx, FIC_PS_AT(e - 1), FIC_PS_AT(e))) e++;
    }
  }
  if (e - s < minrun) {
    int64_t end = s + minrun;
    if (end > n) end = n;
    fic_ps_insertion(base, es, s, e, end, gt, ctx, tmp);
    e = end;
  }
  return e;
}

/* merge the sorted [lo,mid) and [mid,hi) (both not empty); scr has room for min(mid-lo, hi-mid) elements */
FIC_PS_INLINE void fic_ps_merge(unsigned char *base, size_t es, int64_t lo, int64_t mid, int64_t hi, fic_ps_gt_fn gt, void *ctx, unsigned char *scr) {
  int64_t a = mid - lo, b = hi - mid;
  if (!gt(ctx, FIC_PS_AT(mid - 1), FIC_PS_AT(mid))) return;                  /* already in order */
  if (a <= b) {
    int64_t i = 0, j = mid, k = lo;
    memcpy(scr, FIC_PS_AT(lo), (size_t)a * es);
    while (i < a && j < hi) {
      if (gt(ctx, scr + (size_t)i * es, FIC_PS_AT(j))) { memcpy(FIC_PS_AT(k), FIC_PS_AT(j), es); j++; }
      else { memcpy(FIC_PS_AT(k), scr + (size_t)i * es, es); i++; }
      k++;
    }
    if (i < a) memcpy(FIC_PS_AT(k), scr + (size_t)i * es, (size_t)(a - i) * es);
  } else {
    int64_t i = mid - 1, t = b - 1, k = hi - 1;
    memcpy(scr, FIC_PS_AT(mid), (size_t)b * es);
    while (i >= lo && t >= 0) {
      if (gt(ctx, FIC_PS_AT(i), scr + (size_t)t * es)) { memcpy(FIC_PS_AT(k), FIC_PS_AT(i), es); i--; }
      else { memcpy(FIC_PS_AT(k), scr + (size_t)t * es, es); t--; }
      k--;
    }
    if (t >= 0) memcpy(FIC_PS_AT(lo), scr, (size_t)(t + 1) * es);
  }
}

FIC_PS_INLINE void fic_ps_sort_inl(void *basev, int64_t n, size_t es, fic_ps_gt_fn gt, void *ctx) {
  unsigned char *base = (unsigned char *)basev, *scr;
  int64_t sb[FIC_PS_MAXSTACK], b1, e1, minrun;
  int sp[FIC_PS_MAXSTACK], top = 0;
  if (n < 2) return;
  minrun = fic_ps_minrun(n);
  scr = (unsigned char *)malloc((size_t)(n / 2 + 1) * es);
  if (scr == NULL) abort();
  b1 = 0;
  e1 = fic_ps_extend(base, es, n, 0, minrun, gt, ctx, scr);
  while (e1 < n) {
    int64_t b2 = e1, e2 = fic_ps_extend(base, es, n, b2, minrun, gt, ctx, scr);
    int p = fic_ps_power(n, b1, e1, b2, e2);
    while (top > 0 && sp[top - 1] > p) { top--; fic_ps_merge(base, es, sb[top], b1, e1, gt, ctx, scr); b1 = sb[top]; }
    sb[top] = b1; sp[top] = p; top++;
    b1 = b2; e1 = e2;
  }
  while (top > 0) { top--; fic_ps_merge(base, es, sb[top], b1, e1, gt, ctx, scr); b1 = sb[top]; }
  free(scr);
}

/* the specialisations */
static int fic_psg_i64(void *c, const void *a, const void *b) { (void)c; return *(const int64_t *)a > *(const int64_t *)b; }
static int fic_psg_f64(void *c, const void *a, const void *b) { (void)c; return !(*(const double *)a <= *(const double *)b); }
static int fic_psg_u32(void *c, const void *a, const void *b) { (void)c; return *(const uint32_t *)a > *(const uint32_t *)b; }
typedef struct { int64_t k; int64_t i; } fic_ps_pi;
typedef struct { double k; int64_t i; } fic_ps_pd;
static int fic_psg_pi(void *c, const void *a, const void *b) { (void)c; return ((const fic_ps_pi *)a)->k > ((const fic_ps_pi *)b)->k; }
static int fic_psg_pd(void *c, const void *a, const void *b) { (void)c; return !(((const fic_ps_pd *)a)->k <= ((const fic_ps_pd *)b)->k); }
static void fic_ps_sort_i64(int64_t *p, int64_t n) { fic_ps_sort_inl(p, n, sizeof(int64_t), fic_psg_i64, NULL); }
static void fic_ps_sort_f64(double *p, int64_t n) { fic_ps_sort_inl(p, n, sizeof(double), fic_psg_f64, NULL); }
static void fic_ps_sort_u32(uint32_t *p, int64_t n) { fic_ps_sort_inl(p, n, sizeof(uint32_t), fic_psg_u32, NULL); }
static void fic_ps_sort_pi(fic_ps_pi *p, int64_t n) { fic_ps_sort_inl(p, n, sizeof(fic_ps_pi), fic_psg_pi, NULL); }
static void fic_ps_sort_pd(fic_ps_pd *p, int64_t n) { fic_ps_sort_inl(p, n, sizeof(fic_ps_pd), fic_psg_pd, NULL); }

/* H21b: LSD radix sort for the INT and CHAR modes (not Float: NaN and -0.0; not String; not closures). 8 bit digits; ALL digit histograms
   are computed in one pass; a digit that is the same in every key is skipped (the values of a typical Int vector use few of the 8 bytes);
   the sign of an Int is flipped in place so that the unsigned order is the signed one. Two buffers (the vector and a scratch of n) are
   used alternately; when the last pass lands in the scratch it is copied back, so the result is always in the vector. Equal keys are equal
   elements, so stability does not matter for these types. */
#define FIC_RADIX_DEF(NAME, T, U, NB, FLIP) \
static void NAME(T *a, int64_t n) { \
  size_t h[NB][256]; \
  U *src = (U *)(void *)a, *dst, *t; \
  int64_t i; int b; \
  if (n < 2) return; \
  dst = (U *)malloc((size_t)n * sizeof(U)); \
  if (dst == NULL) abort(); \
  t = dst; \
  memset(h, 0, sizeof h); \
  for (i = 0; i < n; i++) { U k = src[i] ^ (U)(FLIP); src[i] = k; for (b = 0; b < NB; b++) h[b][(k >> (8 * b)) & 255]++; } \
  for (b = 0; b < NB; b++) { \
    size_t sum = 0; int d; \
    if (h[b][(src[0] >> (8 * b)) & 255] == (size_t)n) continue; \
    for (d = 0; d < 256; d++) { size_t c = h[b][d]; h[b][d] = sum; sum += c; } \
    for (i = 0; i < n; i++) { U k = src[i]; dst[h[b][(k >> (8 * b)) & 255]++] = k; } \
    { U *x = src; src = dst; dst = x; } \
  } \
  if (src == t) { for (i = 0; i < n; i++) ((U *)(void *)a)[i] = src[i] ^ (U)(FLIP); } \
  else { for (i = 0; i < n; i++) src[i] ^= (U)(FLIP); } \
  free(t); \
}
FIC_RADIX_DEF(fic_radix_i64, int64_t, uint64_t, 8, 0x8000000000000000ull)
FIC_RADIX_DEF(fic_radix_u32, uint32_t, uint32_t, 4, 0u)

/* the choice: n below FIC_RADIX_MIN is Powersort; otherwise one pass counts the natural runs (an ascending run, or a strictly descending
   one that Powersort reverses) and stops as soon as there are more than n / 32: then the average run is shorter than 32 and the radix sort
   is used; fewer runs (sorted, reversed, a few swaps, concatenated runs) go to Powersort, which is linear for them */
#ifndef FIC_RADIX_MIN
#define FIC_RADIX_MIN 256
#endif
#define FIC_RUNS_DEF(NAME, T) \
static int NAME(const T *a, int64_t n) { \
  int64_t i = 0, runs = 0, limit = n / 32; \
  while (i < n) { \
    int64_t j = i + 1; \
    if (++runs > limit) return 0; \
    if (j < n) { if (a[i] > a[j]) { j++; while (j < n && a[j - 1] > a[j]) j++; } else { j++; while (j < n && a[j - 1] <= a[j]) j++; } } \
    i = j; \
  } \
  return 1; \
}
FIC_RUNS_DEF(fic_fewruns_i64, int64_t)
FIC_RUNS_DEF(fic_fewruns_u32, uint32_t)
static void fic_sort_i64_auto(int64_t *p, int64_t n) {
  if (n >= FIC_RADIX_MIN && !fic_fewruns_i64(p, n)) fic_radix_i64(p, n); else fic_ps_sort_i64(p, n);
}
static void fic_sort_u32_auto(uint32_t *p, int64_t n) {
  if (n >= FIC_RADIX_MIN && !fic_fewruns_u32(p, n)) fic_radix_u32(p, n); else fic_ps_sort_u32(p, n);
}

/* H21c: the same radix sort on (key, index) pairs, for sortBy with an Int or Char key: LSD passes are stable, so equal keys keep their order of
   indices; the key is flipped like the Int radix above. The run test looks at the keys. */
static void fic_radix_pi(fic_ps_pi *a, int64_t n) {
  size_t h[8][256];
  fic_ps_pi *src = a, *dst, *t;
  int64_t i;
  int b;
  if (n < 2) return;
  dst = (fic_ps_pi *)malloc((size_t)n * sizeof(fic_ps_pi));
  if (dst == NULL) abort();
  t = dst;
  memset(h, 0, sizeof h);
  for (i = 0; i < n; i++) { uint64_t k = (uint64_t)src[i].k ^ 0x8000000000000000ull; src[i].k = (int64_t)k; for (b = 0; b < 8; b++) h[b][(k >> (8 * b)) & 255]++; }
  for (b = 0; b < 8; b++) {
    size_t sum = 0;
    int d;
    if (h[b][((uint64_t)src[0].k >> (8 * b)) & 255] == (size_t)n) continue;
    for (d = 0; d < 256; d++) { size_t c = h[b][d]; h[b][d] = sum; sum += c; }
    for (i = 0; i < n; i++) dst[h[b][((uint64_t)src[i].k >> (8 * b)) & 255]++] = src[i];
    { fic_ps_pi *x = src; src = dst; dst = x; }
  }
  if (src == t) memcpy(a, src, (size_t)n * sizeof(fic_ps_pi));
  for (i = 0; i < n; i++) a[i].k = (int64_t)((uint64_t)a[i].k ^ 0x8000000000000000ull);
  free(t);
}
static int fic_fewruns_pi(const fic_ps_pi *a, int64_t n) {
  int64_t i = 0, runs = 0, limit = n / 32;
  while (i < n) {
    int64_t j = i + 1;
    if (++runs > limit) return 0;
    if (j < n) { if (a[i].k > a[j].k) { j++; while (j < n && a[j - 1].k > a[j].k) j++; } else { j++; while (j < n && a[j - 1].k <= a[j].k) j++; } }
    i = j;
  }
  return 1;
}
static void fic_sort_pi_auto(fic_ps_pi *p, int64_t n) {
  if (n >= FIC_RADIX_MIN && !fic_fewruns_pi(p, n)) fic_radix_pi(p, n); else fic_ps_sort_pi(p, n);
}

/* a comparator on element addresses (FIC_SORT_CMP) and the closure comparator on indices, as a GT test */
typedef struct { fic_vcmp_fn cmp; const unsigned char *keys; size_t es; } fic_ps_keyctx;
/* ctx is the ADDRESS of a fic_vcmp_fn (a function pointer is not converted to void *) */
static int fic_psg_cmp(void *c, const void *a, const void *b) { return (*(const fic_vcmp_fn *)c)(a, b) > 0; }
static int fic_psg_key(void *c, const void *a, const void *b) {
  const fic_ps_keyctx *k = (const fic_ps_keyctx *)c;
  return k->cmp(k->keys + (size_t)*(const int64_t *)a * k->es, k->keys + (size_t)*(const int64_t *)b * k->es) > 0;
}
/* Order: LT 0, EQ 1, GT 2 (a result word of the closure ABI: the byte) */
static int fic_psg_clo(void *c, const void *a, const void *b) {
  fic_word r = fic_ap2((fic_ref)c, 0u, fic_w_i(*(const int64_t *)a), fic_w_i(*(const int64_t *)b));
  return r.b == 2u;
}

/* the elements of the vector (not shared, at least 2) in order */
static void fic_vsort_data(fic_ref v, int mode, fic_vcmp_fn cmp) {
  int64_t n = FIC_VECTOR(v)->len;
  void *d = FIC_VECTOR(v)->data;
  fic_vcmp_fn cf = cmp;
  switch (mode) {
  case FIC_SORT_I64: fic_sort_i64_auto((int64_t *)d, n); break;
  case FIC_SORT_F64: fic_ps_sort_f64((double *)d, n); break;
  case FIC_SORT_U32: fic_sort_u32_auto((uint32_t *)d, n); break;
  default: fic_ps_sort_inl(d, n, FIC_VECTOR(v)->esize, fic_psg_cmp, (void *)&cf); break;
  }
}

/* a vector that this call may write: v itself when it has one owner, else a copy (v is consumed) */
static fic_ref fic_vsort_own(fic_ref v, const char *where) {
  (void)where;
#ifdef FIC_RC
  if (v->rc == 1) { FIC_STAT(fic_n_inplace++); return v; }
  fic_vector_shared("sort", v, where);
  { fic_ref r = fic_vector_copy(v, 0); fic_drop(v); return r; }
#else
  return fic_vector_copy(v, 0);
#endif
}

/* Vector.sort: consumes v, sorts in place when it is unique and copies first when it is shared */
static fic_ref fic_vsort(fic_ref v, int mode, fic_vcmp_fn cmp, const char *where) {
  if (FIC_VECTOR(v)->len < 2) return v;
  v = fic_vsort_own(v, where);
  fic_vsort_data(v, mode, cmp);
  return v;
}

/* the sorting permutation of the BORROWED keys: a vector of Int, the indices in the order of a stable sort of the keys */
static fic_ref fic_vsort_perm(fic_ref keys, int mode, fic_vcmp_fn cmp) {
  int64_t n = FIC_VECTOR(keys)->len, i;
  fic_ref r = fic_vector_new(n, (uint32_t)sizeof(int64_t), NULL);
  int64_t *out = (int64_t *)(void *)FIC_VECTOR(r)->data;
  const void *kd = FIC_VECTOR(keys)->data;
  FIC_VECTOR(r)->len = n;
  if (n < 2) { if (n == 1) out[0] = 0; return r; }
  if (mode == FIC_SORT_I64 || mode == FIC_SORT_U32) {
    fic_ps_pi *p = (fic_ps_pi *)malloc((size_t)n * sizeof(fic_ps_pi));
    if (p == NULL) abort();
    for (i = 0; i < n; i++) { p[i].k = mode == FIC_SORT_I64 ? ((const int64_t *)kd)[i] : (int64_t)((const uint32_t *)kd)[i]; p[i].i = i; }
    fic_sort_pi_auto(p, n);
    for (i = 0; i < n; i++) out[i] = p[i].i;
    free(p);
  } else if (mode == FIC_SORT_F64) {
    fic_ps_pd *p = (fic_ps_pd *)malloc((size_t)n * sizeof(fic_ps_pd));
    if (p == NULL) abort();
    for (i = 0; i < n; i++) { p[i].k = ((const double *)kd)[i]; p[i].i = i; }
    fic_ps_sort_pd(p, n);
    for (i = 0; i < n; i++) out[i] = p[i].i;
    free(p);
  } else {
    fic_ps_keyctx k;
    k.cmp = cmp; k.keys = (const unsigned char *)kd; k.es = FIC_VECTOR(keys)->esize;
    for (i = 0; i < n; i++) out[i] = i;
    fic_ps_sort_inl(out, n, sizeof(int64_t), fic_psg_key, &k);
  }
  return r;
}

/* Vector.sortIdx f idx: the vector of Int idx (consumed; in place when unique) sorted with the closure f : Int -> Int -> Order (borrowed) */
static fic_ref fic_vsort_idx(fic_ref f, fic_ref idx, const char *where) {
  if (FIC_VECTOR(idx)->len < 2) return idx;
  idx = fic_vsort_own(idx, where);
  fic_ps_sort_inl(FIC_VECTOR(idx)->data, FIC_VECTOR(idx)->len, sizeof(int64_t), fic_psg_clo, (void *)f);
  return idx;
}

/* Vector.sortWith f v (H21d): the elements themselves are sorted (v consumed, in place when unique) with the comparison function f (a closure,
   borrowed) through `gt`, the generated test for the element class (CGen `vecSortCmpBody`): no index vector, no gather. */
static fic_ref fic_vsort_gt(fic_ref v, fic_ps_gt_fn gt, fic_ref f, const char *where) {
  if (FIC_VECTOR(v)->len < 2) return v;
  v = fic_vsort_own(v, where);
  /* the element size as a constant for the usual sizes (a scalar, a reference or a pair of words): the moves become plain loads and stores */
  switch (FIC_VECTOR(v)->esize) {
  case 8: fic_ps_sort_inl(FIC_VECTOR(v)->data, FIC_VECTOR(v)->len, 8, gt, (void *)f); break;
  case 16: fic_ps_sort_inl(FIC_VECTOR(v)->data, FIC_VECTOR(v)->len, 16, gt, (void *)f); break;
  default: fic_ps_sort_inl(FIC_VECTOR(v)->data, FIC_VECTOR(v)->len, FIC_VECTOR(v)->esize, gt, (void *)f); break;
  }
  return v;
}

#endif
