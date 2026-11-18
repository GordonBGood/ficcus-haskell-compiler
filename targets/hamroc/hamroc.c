/* hamroc.c -- hand C for the algorithm of targets/roc/NthHamming.roc, the direct loop of nthHamming: two growable circular buffer queues
 * (front, back, size, array; initial size 16, doubled by appending a copy of the first `size` elements) and the running value fvs.
 * LogRep = { double log2; uint16_t twos, threes, fives } (16 bytes, as in Roc), or int64 counts (32 bytes) with -DWIDE.
 *   gcc -std=c99 -O2 -ffp-contract=off -DTARGET=1000000 [-DWIDE] hamroc.c -o hamroc */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifndef TARGET
#define TARGET 1000000
#endif
#ifdef WIDE
typedef int64_t cnt_t;
#else
typedef uint16_t cnt_t;
#endif

typedef struct { double log2; cnt_t twos, threes, fives; } logrep;
typedef struct { uint64_t front, back, size; logrep *list; } queue;

static const double LG2 = 1.0, LG3 = 1.584962500721156, LG5 = 2.321928094887362;
static const logrep ONE = { 0.0, 0, 0, 0 };

static inline logrep mult2(logrep l) { l.log2 += LG2; l.twos++; return l; }
static inline logrep mult3(logrep l) { l.log2 += LG3; l.threes++; return l; }
static inline logrep mult5(logrep l) { l.log2 += LG5; l.fives++; return l; }

static queue init_queue(logrep x) {
  queue q; uint64_t i;
  q.front = 0; q.back = 1; q.size = 16; q.list = (logrep *)malloc(16 * sizeof(logrep));
  if (q.list == NULL) abort();
  for (i = 0; i < 16; i++) q.list[i] = x;
  return q;
}

static inline void push_queue(queue *q, logrep x) {
  uint64_t nb;
  if (q->back == q->front) {
    q->list = (logrep *)realloc(q->list, (size_t)(q->size * 2) * sizeof(logrep));
    if (q->list == NULL) abort();
    memcpy(q->list + q->size, q->list, (size_t)q->size * sizeof(logrep));
    q->front += q->size; q->size *= 2;
  }
  nb = (q->back >= q->size - 1) ? 0 : q->back + 1;
  q->list[q->back] = x;
  q->back = nb;
}

#define REPLACE(q, MULT) do { \
    uint64_t nf = ((q)->front >= (q)->size - 1) ? 0 : (q)->front + 1; \
    uint64_t nb = ((q)->back >= (q)->size - 1) ? 0 : (q)->back + 1; \
    (q)->list[(q)->back] = MULT((q)->list[(q)->front]); (q)->front = nf; (q)->back = nb; } while (0)

int main(void) {
  queue bigq = init_queue(mult2(ONE)), smlq = init_queue(mult3(ONE));
  logrep fvs = mult5(ONE), hd = ONE;
  uint64_t cnt = 1;
  while (cnt < TARGET) {
    logrep b = bigq.list[bigq.front], s = smlq.list[smlq.front];
    double min23 = b.log2 < s.log2 ? b.log2 : s.log2;
    if (min23 > fvs.log2) {
      hd = fvs; push_queue(&bigq, mult2(fvs)); push_queue(&smlq, mult3(fvs)); fvs = mult5(fvs);
    } else if (b.log2 < s.log2) {
      hd = b; REPLACE(&bigq, mult2);
    } else {
      hd = s; push_queue(&bigq, mult2(s)); REPLACE(&smlq, mult3);
    }
    cnt++;
  }
  printf("Hamming number %llu = 2^%lld * 3^%lld * 5^%lld\r\n", (unsigned long long)TARGET, (long long)hd.twos, (long long)hd.threes, (long long)hd.fives);
  return 0;
}
