/* Stable sort of (element, key) pairs by a comparison of the keys: the runtime of List.sortBy and List.sortWith
   (decision L15: sorts are stable). Only emitted into programs that use it, after the closure runtime (fic_word). */
typedef struct fic_kv { fic_word e; fic_word k; } fic_kv;
typedef int (*fic_cmpfn)(void *ctx, fic_word x, fic_word y);

static void fic_sort_kv(fic_kv *a, int64_t n, fic_cmpfn cmp, void *ctx) {
  fic_kv *tmp, *src = a, *dst;
  int64_t w, i, lo, mid, hi, p, q, o;
  if (n < 2) return;
  tmp = (fic_kv *)malloc((size_t)n * sizeof(fic_kv));
  if (tmp == NULL) abort();
  dst = tmp;
  for (w = 1; w < n; w *= 2) {
    for (lo = 0; lo < n; lo += 2 * w) {
      mid = lo + w < n ? lo + w : n;
      hi = lo + 2 * w < n ? lo + 2 * w : n;
      p = lo; q = mid; o = lo;
      while (p < mid && q < hi) {
        if (cmp(ctx, src[q].k, src[p].k) < 0) dst[o++] = src[q++]; else dst[o++] = src[p++];
      }
      while (p < mid) dst[o++] = src[p++];
      while (q < hi) dst[o++] = src[q++];
    }
    { fic_kv *t = src; src = dst; dst = t; }
  }
  if (src != a) for (i = 0; i < n; i++) a[i] = src[i];
  free(tmp);
}
