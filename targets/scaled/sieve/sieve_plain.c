/* sieve_plain.c -- what the Ficcus compiler should emit for Sieve.elm (C99).
 *
 *   gcc -std=c99 -pedantic -Wall -Wextra -O2 -DBUFBYTES=262144L -DNUMLOOPS=1000 sieve_plain.c -o sieve_plain
 *   (add -DHOIST for the variant with the uniqueness test moved out of the inner loop)
 *
 * Array Int holding bytes is a Vector Word8: a RAW vector with one byte per element.
 * The loops are self tail calls turned into loops. Without HOIST every update goes
 * through fic_vec_set (bounds test, uniqueness test, store), as straightforward
 * emission would; with HOIST the compiler has noticed that the vector stays unique
 * through the whole loop and tests once.
 */
#include <stdio.h>
#include <time.h>
#include "ficrt.h"

#ifndef BUFBYTES
#define BUFBYTES 1048576L
#endif
#ifndef NUMLOOPS
#define NUMLOOPS 1
#endif
#define BUFBITS (BUFBYTES * 8L)

static int testBit(int64_t k, fic_ref cmpsts) {            /* cmpsts borrowed */
  const uint8_t *b = (const uint8_t *)fic_vec_get(cmpsts, k >> 3);
  return b == NULL ? 1 : ((*b & (1u << (k & 7))) != 0);
}

static fic_ref cullPrime(int64_t bp, int64_t j, fic_ref cmpsts) {   /* consumes cmpsts */
#ifdef HOIST
  cmpsts = fic_vec_unique(cmpsts);
  { uint8_t *d = FIC_VEC(cmpsts)->data;
    for (; j < BUFBITS; j += bp) d[j >> 3] |= (uint8_t)(1u << (j & 7)); }
#else
  while (j < BUFBITS) {
    const uint8_t *p = (const uint8_t *)fic_vec_get(cmpsts, j >> 3);
    uint8_t b;
    if (p == NULL) break;
    b = (uint8_t)(*p | (1u << (j & 7)));
    cmpsts = fic_vec_set(cmpsts, j >> 3, &b);
    j += bp;
  }
#endif
  return cmpsts;
}

static fic_ref sieve(void) {
  uint8_t zero = 0;
  fic_ref cmpsts = fic_vec_repeat(BUFBYTES, &zero, 1, FIC_TAG_VEC_RAW);
  int64_t i;
  for (i = 0;; i++) {
    int64_t j = (i + i) * (i + 3) + 3;                     /* bit index of the square of 2 * i + 3 */
    if (j >= BUFBITS) break;
    if (!testBit(i, cmpsts)) cmpsts = cullPrime(i + i + 3, j, cmpsts);
  }
  return cmpsts;
}

static int64_t countPrimes(fic_ref cmpsts) {
  int64_t i, cnt = 1;
  for (i = 0; i < BUFBITS; i++) if (!testBit(i, cmpsts)) cnt++;
  return cnt;
}

int main(void) {
  int64_t answer, sink = 0;
  int i;
  clock_t strt, stop;
  fic_ref v;
  printf("Running...");
  v = sieve(); answer = countPrimes(v); fic_drop(v);
  strt = clock();
  for (i = 0; i < NUMLOOPS; ++i) { v = sieve(); sink += countPrimes(v); fic_drop(v); }
  stop = clock();
  printf("\r\nFound %lld primes up to %lld", (long long)answer, (long long)(2 * BUFBITS + 2));
  printf(" for %d loops in %ld milliseconds (check %lld, %zu objects live).", NUMLOOPS,
         (long)((stop - strt) * 1000L / CLOCKS_PER_SEC), (long long)sink, fic_live_objects);
  printf("\r\n");
  return fic_live_objects == 0 ? 0 : 1;
}
