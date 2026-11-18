/* H21 benchmark of the sort kernel alone (no List conversion): fic_ps_sort_i64 vs a plain top down merge sort vs qsort, 1e6 int64.
   gcc -std=gnu99 -O2 -I runtime -I targets/c targets/sort/bench_kernel.c -o bk -lm */
#include <stdio.h>
#include <time.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_vector.h"
#include "fic_closure.h"
#include "fic_sort.h"
#define N 1000000
static uint64_t st = 12345;
static int64_t lcg(void) { st = st * 6364136223846793005ull + 1442695040888963407ull; return (int64_t)(st >> 33); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static int cmpi(const void *a, const void *b) { int64_t x = *(const int64_t *)a, y = *(const int64_t *)b; return x < y ? -1 : x > y; }
static void msort(int64_t *a, int64_t *t, int n) {
  int h = n / 2, i = 0, j = h, k = 0;
  if (n < 2) return;
  msort(a, t, h); msort(a + h, t, n - h);
  while (i < h && j < n) t[k++] = a[j] < a[i] ? a[j++] : a[i++];
  while (i < h) t[k++] = a[i++];
  while (j < n) t[k++] = a[j++];
  memcpy(a, t, (size_t)n * 8);
}
static int cmpd(const void *a, const void *b) { return cmpi(a, b); }
int main(void) {
  static int64_t src[N], w[N], t[N];
  const char *names[] = { "random", "sorted", "reversed", "swap10", "dups" };
  int p, r, k;
  for (p = 0; p < 5; p++) {
    double best[3] = { 1e9, 1e9, 1e9 };
    for (k = 0; k < N; k++) src[k] = p == 0 ? lcg() : p == 1 ? k : p == 2 ? N - k : p == 3 ? (lcg() % 10 == 0 ? lcg() : k) : lcg() % 100;
    for (r = 0; r < 5; r++) {
      double a;
      memcpy(w, src, sizeof src); a = now(); fic_ps_sort_i64(w, N); a = now() - a; if (a < best[0]) best[0] = a;
      memcpy(w, src, sizeof src); a = now(); msort(w, t, N); a = now() - a; if (a < best[1]) best[1] = a;
      memcpy(w, src, sizeof src); a = now(); qsort(w, N, 8, cmpd); a = now() - a; if (a < best[2]) best[2] = a;
    }
    printf("%-9s powersort %7.2f ms   merge %7.2f ms   qsort %7.2f ms\n", names[p], best[0], best[1], best[2]);
  }
  return 0;
}
