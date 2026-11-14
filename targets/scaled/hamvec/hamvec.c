/* hamvec.c -- what the Ficcus compiler should emit for HammingVec.elm (C99).
 *
 *   gcc -std=c99 -pedantic -Wall -Wextra -O2 hamvec.c -o hamvec
 *
 * The memo is a growable RAW vector of Int (Vector Int64) with three read cursors;
 * Array.push is an in place append when the vector is unique. The self tail call
 * is a loop and the three cursor tests are plain integer compares.
 */
#include <stdio.h>
#include <time.h>
#include "ficrt.h"

const int NUMLOOPS = 1;  /* one pass of REPS repetitions, see HammingVec.elm */
#define REPS 1000

static int64_t countHamsTo(int64_t n) {
  int64_t one = 1, i2 = 0, i3 = 0, i5 = 0, len;
  fic_ref arr = fic_vec_repeat(1, &one, sizeof one, FIC_TAG_VEC_RAW);   /* Array.fromList [1] */
  for (;;) {
    const int64_t *a2 = (const int64_t *)fic_vec_get(arr, i2);          /* Nothing -> 0, as in the Elm */
    const int64_t *a3 = (const int64_t *)fic_vec_get(arr, i3);
    const int64_t *a5 = (const int64_t *)fic_vec_get(arr, i5);
    int64_t x2 = FIC_MUL64(2, a2 ? *a2 : 0), x3 = FIC_MUL64(3, a3 ? *a3 : 0), x5 = FIC_MUL64(5, a5 ? *a5 : 0);
    int64_t m = x2 < x3 ? x2 : x3;
    if (x5 < m) m = x5;
    if (m > n) break;
    arr = fic_vec_push(arr, &m);
    if (x2 == m) i2++;
    if (x3 == m) i3++;
    if (x5 == m) i5++;
  }
  len = FIC_VEC(arr)->len;
  fic_drop(arr);
  return len;
}

int main(void) {
  volatile int64_t limit = 9007199254740991LL;     /* 2 ^ 53 - 1 */
  int64_t n = limit, answer, sink = 0;
  size_t allocs;
  int i;
  clock_t strt, stop;
  printf("Running...");
  strt = clock();
  answer = 0;
  for (i = 1; i <= REPS; ++i) answer += countHamsTo(limit - i);
  allocs = fic_total_allocs / REPS;
  sink = answer;
  stop = clock();
  printf("\r\nFound %lld Hamming numbers to %lld inclusive.\r\n", (long long)answer, (long long)n);
  printf("(%d loops in %ld milliseconds, check %lld; %zu allocations per run, %zu objects still live)\r\n",
         NUMLOOPS, (long)((stop - strt) * 1000L / CLOCKS_PER_SEC), (long long)sink, allocs,
         fic_live_objects);
  return fic_live_objects == 0 ? 0 : 1;
}
