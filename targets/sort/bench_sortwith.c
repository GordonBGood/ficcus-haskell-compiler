/* H21d: separates the cost of the closure call from the cost of the index indirection. 1e6 random Int, a compare closure (a plain
   C function through fic_ap2). (1) direct: elements sorted in place, comparator = fic_ap2 on the two values; (2) index: what List.sortWith
   does now, indices sorted with an outer closure that reads the two elements and calls the inner compare closure through fic_ap2 again;
   (3) the same index sort with the comparison done inline (no closure at all); (4) the same direct sort with the comparison inline.
   gcc -std=gnu99 -O2 -I runtime -I targets/c targets/sort/bench_sortwith.c -o bsw -lm */
#include <stdio.h>
#include <time.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_vector.h"
#include "fic_closure.h"
#include "fic_sort.h"
#define N 1000000
static int64_t data[N], work[N], idx[N];
static uint64_t st = 12345;
static int64_t lcg(void) { st = st * 6364136223846793005ull + 1442695040888963407ull; return (int64_t)(st >> 33); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static fic_word cmpf(fic_ref self, fic_word a, fic_word b) { (void)self; return fic_w_b(a.i < b.i ? 0 : a.i == b.i ? 1 : 2); }
static const fic_code cmpcode = { (void (*)(void))cmpf, 2u FIC_CODE_OWN0 };
static fic_clo cmpclo;
static fic_word outerf(fic_ref self, fic_word i, fic_word j) { (void)self; return fic_ap2((fic_ref)&cmpclo, 0u, fic_w_i(data[i.i]), fic_w_i(data[j.i])); }
static const fic_code outcode = { (void (*)(void))outerf, 2u FIC_CODE_OWN0 };
static fic_clo outclo;
static int gt_direct(void *c, const void *a, const void *b) { return fic_ap2((fic_ref)c, 0u, fic_w_i(*(const int64_t *)a), fic_w_i(*(const int64_t *)b)).b == 2u; }
static int gt_idx_inline(void *c, const void *a, const void *b) { (void)c; return data[*(const int64_t *)a] > data[*(const int64_t *)b]; }
int main(void) {
  int r, k; double t, best[4] = { 1e9, 1e9, 1e9, 1e9 };
  cmpclo.h.rc = FIC_IMMORTAL; cmpclo.code = &cmpcode; outclo.h.rc = FIC_IMMORTAL; outclo.code = &outcode;
  for (k = 0; k < N; k++) data[k] = lcg();
  for (r = 0; r < 12; r++) {
    memcpy(work, data, sizeof data); t = now(); fic_ps_sort_inl(work, N, 8, gt_direct, &cmpclo); t = now() - t; if (t < best[0]) best[0] = t;
    for (k = 0; k < N; k++) idx[k] = k; t = now(); fic_ps_sort_inl(idx, N, 8, fic_psg_clo, &outclo); t = now() - t; if (t < best[1]) best[1] = t;
    for (k = 0; k < N; k++) idx[k] = k; t = now(); fic_ps_sort_inl(idx, N, 8, gt_idx_inline, NULL); t = now() - t; if (t < best[2]) best[2] = t;
    memcpy(work, data, sizeof data); t = now(); fic_ps_sort_inl(work, N, 8, fic_psg_i64, NULL); t = now() - t; if (t < best[3]) best[3] = t;
  }
  printf("direct elements + closure %.1f ms | index + 2 closures (as List.sortWith) %.1f ms | index, inline compare %.1f ms | direct, inline compare %.1f ms\n", best[0], best[1], best[2], best[3]);
  return 0;
}
