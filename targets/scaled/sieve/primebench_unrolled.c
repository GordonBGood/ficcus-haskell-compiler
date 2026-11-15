#include <stdio.h>
#include <time.h>

/* Modern C99 build of PRMBENCH.C. Changes from the original: the assembler routines DoIt0..DoIt3
   are replaced by the supercull() calls that were left in the comments, the buffer size and
   the loop count can be set with -DBUFBYTES=... and -DNUMLOOPS=..., CLOCKS_PER_SEC became
   CLOCKS_PER_SEC, the final getchar() was removed, and the offsets r1..r7 are computed as
   integers (the original formed pointers past the end of cmpsts, which is undefined in C).
     gcc -std=c99 -pedantic -Wall -Wextra -O2 -DBUFBYTES=262144L -DNUMLOOPS=1000 primebench.c -o primebench */
#ifndef BUFBYTES
#define BUFBYTES 1048576L
#endif
#ifndef NUMLOOPS
#define NUMLOOPS 1
#endif
#define BUFBITS (BUFBYTES * 8L)

#define supercull(OFST, BP) { \
    for (; cp < plmt; cp += bp) { \
      *cp |= 1 << OFST; \
      cp[r1] |= 1 << ((OFST + BP) & 7); \
      cp[r2] |= 1 << ((OFST + 2 * BP) & 7); \
      cp[r3] |= 1 << ((OFST + 3 * BP) & 7); \
      cp[r4] |= 1 << ((OFST + 4 * BP) & 7); \
      cp[r5] |= 1 << ((OFST + 5 * BP) & 7); \
      cp[r6] |= 1 << ((OFST + 6 * BP) & 7); \
      cp[r7] |= 1 << ((OFST + 7 * BP) & 7); \
    } \
    j = (((long)cp - (long)&cmpsts[0]) << 3) + OFST; \
  }

char masks[8] = { 1, 2, 4, 8, 16, 32, 64, (char)128 };

int main(void) {
  static char cmpsts[BUFBYTES]; char *cmpstsp, *plmt, msk, *cp;
  int n;
  long int i, j, bp, cnt, lmt, r1, r2, r3, r4, r5, r6, r7;
  clock_t strt, stop;
  printf("Running...");
  cmpstsp = &cmpsts[0];
  plmt = cmpstsp + BUFBYTES;
  for (i = 0; i < BUFBYTES; ++i) cmpstsp[i] = 0;
  strt = clock();
  for (n = 0; n < NUMLOOPS; ++n) {
    for (i = 0; ; ++i) {
      j = (i + i) * (i + 3) + 3;
      if (j >= BUFBITS) break;
      if (cmpstsp[i >> 3] & masks[i & 7]) continue;
      bp = i + i + 3;
      cp = &cmpsts[j >> 3];
      r1 = ((j + bp) >> 3) - (j >> 3);
      r2 = ((j + 2 * bp) >> 3) - (j >> 3);
      r3 = ((j + 3 * bp) >> 3) - (j >> 3);
      r4 = ((j + 4 * bp) >> 3) - (j >> 3);
      r5 = ((j + 5 * bp) >> 3) - (j >> 3);
      r6 = ((j + 6 * bp) >> 3) - (j >> 3);
      r7 = ((j + 7 * bp) >> 3) - (j >> 3);
      plmt = &cmpsts[0] + BUFBYTES - r7;
      switch ((char)((j & 7) << 2) | ((char)(bp & 7) >> 1)) {
        case 0x0: supercull(0, 1); break;
        case 0x1: supercull(0, 3); break;
        case 0x2: supercull(0, 5); break;
        case 0x3: supercull(0, 7); break;
        case 0x4: supercull(1, 1); break;
        case 0x5: supercull(1, 3); break;
        case 0x6: supercull(1, 5); break;
        case 0x7: supercull(1, 7); break;
        case 0x8: supercull(2, 1); break;
        case 0x9: supercull(2, 3); break;
        case 0xA: supercull(2, 5); break;
        case 0xB: supercull(2, 7); break;
        case 0xC: supercull(3, 1); break;
        case 0xD: supercull(3, 3); break;
        case 0xE: supercull(3, 5); break;
        case 0xF: supercull(3, 7); break;
        case 0x10: supercull(4, 1); break;
        case 0x11: supercull(4, 3); break;
        case 0x12: supercull(4, 5); break;
        case 0x13: supercull(4, 7); break;
        case 0x14: supercull(5, 1); break;
        case 0x15: supercull(5, 3); break;
        case 0x16: supercull(5, 5); break;
        case 0x17: supercull(5, 7); break;
        case 0x18: supercull(6, 1); break;
        case 0x19: supercull(6, 3); break;
        case 0x1A: supercull(6, 5); break;
        case 0x1B: supercull(6, 7); break;
        case 0x1C: supercull(7, 1); break;
        case 0x1D: supercull(7, 3); break;
        case 0x1E: supercull(7, 5); break;
        case 0x1F: supercull(7, 7); 
      }
      for (; j < BUFBITS; j += bp) cmpsts[j >> 3] |= masks[j & 7];
      lmt = j; /* + (bp << 3); */
      for (; j < lmt; j += bp) {
        msk = masks[j & 7];
        /* following seems to produce same assembler pointer code */
        /* cp = &cmpsts[j >> 3];
        do { *cp |= msk; cp += bp; } while (cp < lmtp); */
        for (cp = &cmpsts[j >> 3]; cp < plmt; cp += bp) *cp |= msk;
        /* assembler code uses read/modify/write for extra 25% */
        /* DoIt(&cmpsts[j >> 3], lmtp, bp, msk); */
        /* pointers are a about 30% faster */
        /* for (c = j >> 3; c < BUFBYTES; c += bp) cmpstsp[c] |= msk; */
      }
    }
  }
  stop = clock();
  cnt = BUFBITS + 1;
  for (i = 0; i < BUFBITS; ++i)
    cnt -= (cmpstsp[i >> 3] >> (i & 7)) & 1;
  printf("\r\nFound %ld primes up to %ld", cnt, 2 * BUFBITS + 2);
  printf(" for %d loops", NUMLOOPS);
  printf(" in %ld milliseconds.", (stop - strt) * 1000L / CLOCKS_PER_SEC);
  return 0;
}
