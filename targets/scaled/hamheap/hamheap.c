/* hamheap.c -- what the Ficcus compiler should emit for HammingHeap.elm (C99).
 *
 *   gcc -std=c99 -pedantic -Wall -Wextra -O2 hamheap.c -o hamheap
 *
 * The min heap is the pure functional Priority Queue from the Rosetta Code Elm entry:
 *     type PriorityQ comparable v = Mt | Br comparable v (PriorityQ ..) (PriorityQ ..)
 * so this is the test of the custom type case (heap nodes with child references), of
 * closures (the lazy stream) and of Perceus drop/reuse. Assumed compiler passes:
 *   1. monomorphization: comparable = Float, v = Trival (three Ints), so a node is
 *      { header, pl, pr, key, v } with the two references first (nptr = 2);
 *   2. `Mt` is the tagged scalar FIC_SCALAR(0): no allocation, nothing to count;
 *   3. a `case` that takes a node apart (br_open) moves the children out when the node is
 *      unique, and then the node's memory is a REUSE TOKEN for the next `Br` built on that
 *      path (br_make): pushPQ and replaceMinPQ rebuild the path in place; when the node is
 *      shared the children are dup'ed, the count is lowered and a fresh node is allocated
 *      (copy on write, which is what persistence means);
 *   4. peekMinPQ is inlined and its Maybe removed (NULL = Nothing, else a borrowed node);
 *   5. records and tuples (LogRep, Trival) are C structs passed by value;
 *   6. the stream: a closure is an object { header, captured references first, code pointer,
 *      captured values }. Calling it consumes it; when it is unique its captures are moved
 *      out and its memory (and the old stream cell's) is the reuse token for the next
 *      closure (cell), so a steady state element allocates nothing but heap nodes it must.
 *      The three lambdas of hammingsLog have the same body (call next with the new state),
 *      so they are one lifted function.
 */
#include <stdio.h>
#include <time.h>
#include "ficrt.h"

#define NUMLOOPS 1000

typedef struct Trival { int64_t x2, x3, x5; } Trival;
typedef struct LogRep { double lr; Trival trv; } LogRep;

static const double lg2_2 = 1.0, lg2_3 = 1.584962500721156, lg2_5 = 2.321928094887362;
static const LogRep oneLogRep = { 0.0, { 0, 0, 0 } };

static LogRep multLR2(LogRep l) { l.lr += lg2_2; l.trv.x2 += 1; return l; }
static LogRep multLR3(LogRep l) { l.lr += lg2_3; l.trv.x3 += 1; return l; }
static LogRep multLR5(LogRep l) { l.lr += lg2_5; l.trv.x5 += 1; return l; }
static int ltLogRep(const LogRep *a, const LogRep *b) { return a->lr < b->lr; }

static int64_t xpnd(int64_t x, int64_t m, int64_t r) {
  while (x > 0) {
    if ((x & 1) != 0) r = FIC_MUL64(m, r);
    m = FIC_MUL64(m, m);
    x >>= 1;
  }
  return r;
}
static int64_t tvToNum(const Trival *t) { return xpnd(t->x5, 5, xpnd(t->x3, 3, xpnd(t->x2, 2, 1))); }

/* ---- PriorityQ Float Trival ------------------------------------------------------- */
typedef struct Br { fic_hdr h; fic_ref pl, pr; double key; Trival v; } Br;
#define TAG_BR 3
#define Mt FIC_SCALAR(0)

/* take a node apart: results are owned; returns the node's memory as a reuse token when
   it was unique (the children were moved), else NULL (children dup'ed, count lowered). */
static Br *br_open(fic_ref pq, fic_ref *pl, fic_ref *pr, double *k, Trival *v) {
  Br *b = (Br *)pq;
  *k = b->key; *v = b->v; *pl = b->pl; *pr = b->pr;
  if (b->h.rc == 1) return b;
  fic_dup(*pl); fic_dup(*pr); b->h.rc--;
  return NULL;
}
static Br *br_make(Br *tok, double k, Trival v, fic_ref pl, fic_ref pr) {
  Br *b = tok != NULL ? tok : (Br *)fic_alloc(sizeof(Br), TAG_BR, 2);
  b->pl = pl; b->pr = pr; b->key = k; b->v = v;
  return b;
}

static const Br *peekMinPQ(fic_ref pq) { return FIC_IS_SCALAR(pq) ? NULL : (const Br *)pq; }

static fic_ref pushPQ(double wk, Trival wv, fic_ref pq) {          /* pq owned */
  fic_ref pl, pr; double vk; Trival vv; Br *tok;
  if (FIC_IS_SCALAR(pq)) return (fic_ref)br_make(NULL, wk, wv, Mt, Mt);
  tok = br_open(pq, &pl, &pr, &vk, &vv);
  if (wk <= vk) return (fic_ref)br_make(tok, wk, wv, pushPQ(vk, vv, pr), pl);
  return (fic_ref)br_make(tok, vk, vv, pushPQ(wk, wv, pr), pl);
}

/* tok: the memory of the node being replaced; it is consumed exactly once, by the Br
   built at the bottom of the sift. */
static fic_ref siftdown(double wk, Trival wv, fic_ref pql, fic_ref pqr, Br *tok) {
  const Br *l, *r;
  fic_ref pll, prl, plr, prr; double vkl, vkr; Trival vvl, vvr; Br *t;
  if (FIC_IS_SCALAR(pql)) { fic_drop(pqr); return (fic_ref)br_make(tok, wk, wv, Mt, Mt); }
  l = (const Br *)pql;
  if (FIC_IS_SCALAR(pqr)) {
    if (wk <= l->key) return (fic_ref)br_make(tok, wk, wv, pql, Mt);
    t = br_open(pql, &pll, &prl, &vkl, &vvl);
    fic_drop(pll); fic_drop(prl);                                 /* both Mt in a valid heap */
    return (fic_ref)br_make(t, vkl, vvl, (fic_ref)br_make(tok, wk, wv, Mt, Mt), Mt);
  }
  r = (const Br *)pqr;
  if (wk <= l->key && wk <= r->key) return (fic_ref)br_make(tok, wk, wv, pql, pqr);
  if (l->key <= r->key) {
    t = br_open(pql, &pll, &prl, &vkl, &vvl);
    return (fic_ref)br_make(t, vkl, vvl, siftdown(wk, wv, pll, prl, tok), pqr);
  }
  t = br_open(pqr, &plr, &prr, &vkr, &vvr);
  return (fic_ref)br_make(t, vkr, vvr, pql, siftdown(wk, wv, plr, prr, tok));
}

static fic_ref replaceMinPQ(double wk, Trival wv, fic_ref pq) {    /* pq owned */
  fic_ref pl, pr; double k; Trival v; Br *tok;
  if (FIC_IS_SCALAR(pq)) return pq;                               /* Mt -> Mt */
  tok = br_open(pq, &pl, &pr, &k, &v);
  return siftdown(wk, wv, pl, pr, tok);
}

/* ---- version 1: the state carried in a loop (worker), no stream ---------------------- */
static int64_t countHamsTo(int64_t n) {
  fic_ref bpq = Mt, mpq = Mt;
  LogRep im35 = multLR3(oneLogRep);
  LogRep m235 = multLR2(oneLogRep), mrg = im35, m35 = im35, m5 = multLR5(oneLogRep);
  int64_t cnt = 1;                                  /* the first element, 1, is counted */
  for (;;) {
    if (ltLogRep(&m235, &mrg)) {
      LogRep omin = m235; const Br *p;
      if (tvToNum(&m235.trv) > n) break;
      if ((p = peekMinPQ(bpq)) != NULL) { omin.lr = p->key; omin.trv = p->v; }
      bpq = replaceMinPQ(m235.lr, m235.trv, bpq);
      m235 = multLR2(omin);
    } else if (ltLogRep(&mrg, &m5)) {
      LogRep omin = mrg, nm35; const Br *p;
      if (tvToNum(&mrg.trv) > n) break;
      if ((p = peekMinPQ(mpq)) != NULL) { omin.lr = p->key; omin.trv = p->v; }
      nm35 = multLR3(omin);
      mpq = replaceMinPQ(mrg.lr, mrg.trv, mpq);
      bpq = pushPQ(mrg.lr, mrg.trv, bpq);
      mrg = ltLogRep(&nm35, &m5) ? nm35 : m5;
      m35 = nm35;
    } else {
      LogRep nm5;
      if (tvToNum(&m5.trv) > n) break;
      nm5 = multLR5(m5);
      mpq = pushPQ(m5.lr, m5.trv, mpq);
      bpq = pushPQ(m5.lr, m5.trv, bpq);
      mrg = ltLogRep(&m35, &nm5) ? m35 : nm5;
      m5 = nm5;
    }
    cnt++;
  }
  fic_drop(bpq); fic_drop(mpq);
  return cnt;
}

/* ---- version 2: the lazy stream (CIS) ------------------------------------------------ */
typedef struct Cis Cis;                     /* CIS Trival = CIS hd (() -> CIS Trival) */
typedef struct Clo Clo;                     /* the closure () -> CIS Trival */
struct Cis { fic_hdr h; fic_ref tl; Trival hd; };
struct Clo { fic_hdr h; fic_ref bpq, mpq; Cis *(*fn)(Clo *self, Cis *tok);
             LogRep m235, mrg, m35, m5; };
#define TAG_CIS 4
#define TAG_CLO 5

/* build `CIS hd (\() -> next ...)`; ctok/ktok are reuse tokens for the cell and closure */
static Cis *cis_make(Cis *ctok, Clo *ktok, Trival hd, Cis *(*fn)(Clo *, Cis *), fic_ref bpq,
                     fic_ref mpq, LogRep m235, LogRep mrg, LogRep m35, LogRep m5) {
  Clo *k = ktok != NULL ? ktok : (Clo *)fic_alloc(sizeof(Clo), TAG_CLO, 2);
  Cis *c = ctok != NULL ? ctok : (Cis *)fic_alloc(sizeof(Cis), TAG_CIS, 1);
  k->bpq = bpq; k->mpq = mpq; k->fn = fn;
  k->m235 = m235; k->mrg = mrg; k->m35 = m35; k->m5 = m5;
  c->tl = (fic_ref)k; c->hd = hd;
  return c;
}

static Cis *thunk(Clo *self, Cis *ctok);

static Cis *next(fic_ref bpq, fic_ref mpq, LogRep m235, LogRep mrg, LogRep m35, LogRep m5,
                 Cis *ctok, Clo *ktok) {
  if (ltLogRep(&m235, &mrg)) {
    LogRep omin = m235; const Br *p;
    if ((p = peekMinPQ(bpq)) != NULL) { omin.lr = p->key; omin.trv = p->v; }
    {
      LogRep nm235 = multLR2(omin);
      fic_ref nbpq = replaceMinPQ(m235.lr, m235.trv, bpq);
      return cis_make(ctok, ktok, m235.trv, thunk, nbpq, mpq, nm235, mrg, m35, m5);
    }
  } else if (ltLogRep(&mrg, &m5)) {
    LogRep omin = mrg; const Br *p;
    if ((p = peekMinPQ(mpq)) != NULL) { omin.lr = p->key; omin.trv = p->v; }
    {
      LogRep nm35 = multLR3(omin);
      LogRep nmrg = ltLogRep(&nm35, &m5) ? nm35 : m5;
      fic_ref nmpq = replaceMinPQ(mrg.lr, mrg.trv, mpq);
      fic_ref nbpq = pushPQ(mrg.lr, mrg.trv, bpq);
      return cis_make(ctok, ktok, mrg.trv, thunk, nbpq, nmpq, m235, nmrg, nm35, m5);
    }
  } else {
    LogRep nm5 = multLR5(m5);
    LogRep nmrg = ltLogRep(&m35, &nm5) ? m35 : nm5;
    fic_ref nmpq = pushPQ(m5.lr, m5.trv, mpq);
    fic_ref nbpq = pushPQ(m5.lr, m5.trv, bpq);
    return cis_make(ctok, ktok, m5.trv, thunk, nbpq, nmpq, m235, nmrg, m35, nm5);
  }
}

/* the lifted lambda: \() -> next nbpq nmpq ...; self is owned, so it is consumed */
static Cis *thunk(Clo *self, Cis *ctok) {
  fic_ref bpq = self->bpq, mpq = self->mpq;
  LogRep m235 = self->m235, mrg = self->mrg, m35 = self->m35, m5 = self->m5;
  Clo *ktok = NULL;
  if (self->h.rc == 1) ktok = self;                       /* unique: moved out, memory reused */
  else { fic_dup(bpq); fic_dup(mpq); self->h.rc--; }
  return next(bpq, mpq, m235, mrg, m35, m5, ctok, ktok);
}

static Cis *hammingsLog(void) {
  LogRep im235 = multLR2(oneLogRep), im35 = multLR3(oneLogRep), imrg = im35, im5 = multLR5(oneLogRep);
  Trival zero = { 0, 0, 0 };
  return cis_make(NULL, NULL, zero, thunk, Mt, Mt, im235, imrg, im35, im5);
}

static int64_t countHamsToCIS(int64_t n) {
  Cis *cis = hammingsLog();
  int64_t cnt = 0;
  for (;;) {
    Clo *tl; Cis *tok = NULL;
    if (tvToNum(&cis->hd) > n) { fic_drop((fic_ref)cis); return cnt; }
    tl = (Clo *)cis->tl;
    if (cis->h.rc == 1) tok = cis;                         /* cell reused for the next one */
    else { fic_dup((fic_ref)tl); cis->h.rc--; }
    cnt = cnt + 1;
    cis = tl->fn(tl, tok);
  }
}

#define REPS 300
/* SCALED: the loop variant counted to (limit - k), k = 1 .. REPS, summed; one timed pass; the stream variant is not run. */
int main(void) {
  volatile int64_t limit = 9007199254740991LL;     /* 2 ^ 53 - 1 */
  int64_t answer = 0, sink; size_t allocs; int i; clock_t strt, stop;
  fic_total_allocs = 0;
  strt = clock();
  for (i = 1; i <= REPS; ++i) answer += countHamsTo(limit - i);
  allocs = fic_total_allocs / REPS;
  sink = answer;
  stop = clock();
  printf("Found %lld Hamming numbers to %lld inclusive.\r\n", (long long)answer, (long long)limit);
  printf("(1 loops in %ld milliseconds, check %lld; %zu allocations per run, %zu objects still live)\r\n",
         (long)((stop - strt) * 1000L / CLOCKS_PER_SEC), (long long)sink, allocs, fic_live_objects);
  return fic_live_objects == 0 ? 0 : 1;
}
