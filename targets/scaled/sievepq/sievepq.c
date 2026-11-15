/* sievepq.c -- what the Ficcus compiler should emit for SievePQ.elm (C99).
 *
 *   gcc -std=c99 -pedantic -Wall -Wextra -O2 sievepq.c -o sievepq
 *
 * The incremental odds-only Sieve of Eratosthenes with a min heap (PriorityQ Int Int: the
 * key is the next composite, the value its step) and a lazy stream of primes (CIS Int).
 * Combines the two earlier tests: the heap code of hamheap.c with the key and value
 * monomorphized to Int (a node is { header, left, right, key, step }, 40 bytes, nptr 2) and
 * the closure conventions of sievestream.c (header, code pointer, references, scalars).
 *   - `sieve` is a self tail call: a loop. It returns only where it builds
 *     `CIS n (\() -> sieve (n + 2) pq q bps)`, a closure capturing two references (pq and
 *     the base primes cell, whole: an as-pattern) and two scalars (n + 2, q): 48 bytes;
 *   - when a base prime cell is used up (n >= q) its memory is kept as the reuse token for
 *     the stream cell returned later in the same call; the closure's own memory (unique when
 *     called) is the token for the next closure;
 *   - peekMinPQ with Maybe.withDefault is a null test on a borrowed node;
 *   - `adjust` (replace the minimum while it is <= n) is a loop of replaceMinPQ, which
 *     rebuilds the unique heap in place (drop-reuse token passed down siftdown);
 *   - oddprms() builds its own base primes with a nested oddprms(), as in the Elm source.
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "ficrt.h"

typedef struct Clo { fic_hdr h; fic_ref (*fn)(struct Clo *); } Clo;
typedef struct Cis { fic_hdr h; fic_ref tl; int64_t hd; } Cis;            /* CIS Int */
typedef struct CloSv { Clo c; fic_ref pq, bps; int64_t n, q; } CloSv;     /* 48 bytes */
typedef struct Br { fic_hdr h; fic_ref pl, pr; int64_t key, step; } Br;   /* PriorityQ Int Int node */
#define TAG_CIS 4
#define TAG_BR 3
#define Mt FIC_SCALAR(0)

static fic_ref call0(fic_ref c) { return ((Clo *)c)->fn((Clo *)c); }   /* consumes c */
static void tok_free(void *t) { if (t != NULL) fic_free_obj(t); }

static void *clo_alloc(void *tok, size_t bytes, uint16_t nptr, fic_ref (*fn)(Clo *)) {
  Clo *k = tok != NULL ? (Clo *)tok : (Clo *)fic_alloc(bytes, FIC_TAG_CLOSURE, nptr);
  k->h.tag = FIC_TAG_CLOSURE; k->h.nptr = (uint8_t)nptr; k->fn = fn;
  return k;
}
static fic_ref cis_alloc(void *tok, fic_ref tl, int64_t hd) {
  Cis *c = tok != NULL ? (Cis *)tok : (Cis *)fic_alloc(sizeof(Cis), TAG_CIS, 1);
  c->h.tag = TAG_CIS; c->h.nptr = 1; c->tl = tl; c->hd = hd;
  return (fic_ref)c;
}
static void *cis_take(Cis *c, fic_ref *tl) {              /* the memory as a token when unique */
  *tl = c->tl;
  if (c->h.rc == 1) return c;
  fic_dup(*tl); c->h.rc--; return NULL;
}

/* ---- PriorityQ Int Int (the user's min heap, monomorphized) ---------------------------- */
static Br *br_open(fic_ref pq, fic_ref *pl, fic_ref *pr, int64_t *k, int64_t *v) {
  Br *b = (Br *)pq;
  *k = b->key; *v = b->step; *pl = b->pl; *pr = b->pr;
  if (b->h.rc == 1) return b;
  fic_dup(*pl); fic_dup(*pr); b->h.rc--;
  return NULL;
}
static Br *br_make(Br *tok, int64_t k, int64_t v, fic_ref pl, fic_ref pr) {
  Br *b = tok != NULL ? tok : (Br *)fic_alloc(sizeof(Br), TAG_BR, 2);
  b->pl = pl; b->pr = pr; b->key = k; b->step = v;
  return b;
}
static const Br *peekMinPQ(fic_ref pq) { return FIC_IS_SCALAR(pq) ? NULL : (const Br *)pq; }

static fic_ref pushPQ(int64_t wk, int64_t wv, fic_ref pq) {
  fic_ref pl, pr; int64_t vk, vv; Br *tok;
  if (FIC_IS_SCALAR(pq)) return (fic_ref)br_make(NULL, wk, wv, Mt, Mt);
  tok = br_open(pq, &pl, &pr, &vk, &vv);
  if (wk <= vk) return (fic_ref)br_make(tok, wk, wv, pushPQ(vk, vv, pr), pl);
  return (fic_ref)br_make(tok, vk, vv, pushPQ(wk, wv, pr), pl);
}
static fic_ref siftdown(int64_t wk, int64_t wv, fic_ref pql, fic_ref pqr, Br *tok) {
  const Br *l, *r;
  fic_ref pll, prl, plr, prr; int64_t vkl, vkr, vvl, vvr; Br *t;
  if (FIC_IS_SCALAR(pql)) { fic_drop(pqr); return (fic_ref)br_make(tok, wk, wv, Mt, Mt); }
  l = (const Br *)pql;
  if (FIC_IS_SCALAR(pqr)) {
    if (wk <= l->key) return (fic_ref)br_make(tok, wk, wv, pql, Mt);
    t = br_open(pql, &pll, &prl, &vkl, &vvl);
    fic_drop(pll); fic_drop(prl);
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
static fic_ref replaceMinPQ(int64_t wk, int64_t wv, fic_ref pq) {
  fic_ref pl, pr; int64_t k, v; Br *tok;
  if (FIC_IS_SCALAR(pq)) return pq;
  tok = br_open(pq, &pl, &pr, &k, &v);
  return siftdown(wk, wv, pl, pr, tok);
}

/* adjust tpq: replace the minimum while its key is <= n */
static fic_ref adjust(fic_ref tpq, int64_t n) {
  for (;;) {
    const Br *m = peekMinPQ(tpq);
    int64_t c = m != NULL ? m->key : 0, adv = m != NULL ? m->step : 0;   /* withDefault (0, 0) */
    if (c > n) return tpq;
    tpq = replaceMinPQ(FIC_ADD64(c, adv), adv, tpq);
  }
}

/* ---- the sieve ---------------------------------------------------------------------------- */
static fic_ref sieveThunk(Clo *self);
static fic_ref oddThunk(Clo *self);
static fic_ref primesThunk(Clo *self);
static Clo static_odd = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, oddThunk };
static Clo static_primes = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, primesThunk };
static fic_ref oddprms(void) { return cis_alloc(NULL, fic_dup((fic_ref)&static_odd), 3); }

static fic_ref sieveW(int64_t n, fic_ref pq, int64_t q, fic_ref bpsr, void *ktok) {
  void *ctok = NULL;                                  /* a dead stream cell, kept for the one we return */
  for (;;) {
    Cis *bps = (Cis *)bpsr;
    int64_t bp = bps->hd;
    if (n >= q) {                                     /* the square of the next base prime is reached */
      int64_t adv = FIC_ADD64(bp, bp), nbp; fic_ref tl, nbpsr; void *t;
      t = cis_take(bps, &tl);
      tok_free(ctok); ctok = t;
      nbpsr = call0(tl);                              /* let (CIS nbp _ as nbps) = bptl () */
      nbp = ((Cis *)nbpsr)->hd;
      pq = pushPQ(FIC_ADD64(q, adv), adv, pq);
      q = FIC_MUL64(nbp, nbp); bpsr = nbpsr; n = FIC_ADD64(n, 2);
      continue;
    }
    {
      const Br *m = peekMinPQ(pq);
      int64_t nxtc = m != NULL ? m->key : q;          /* peekMinPQ pq |> withDefault (q, 0) */
      if (n >= nxtc) { pq = adjust(pq, n); n = FIC_ADD64(n, 2); continue; }
    }
    {                                                 /* CIS n (\() -> sieve (n + 2) pq q bps) */
      CloSv *k = (CloSv *)clo_alloc(ktok, sizeof(CloSv), 2, sieveThunk);
      k->pq = pq; k->bps = bpsr; k->n = FIC_ADD64(n, 2); k->q = q;
      return cis_alloc(ctok, (fic_ref)k, n);
    }
  }
}
static fic_ref sieveThunk(Clo *self) {
  CloSv *k = (CloSv *)self;
  fic_ref pq = k->pq, bps = k->bps; int64_t n = k->n, q = k->q; void *t = NULL;
  if (self->h.rc == 1) t = self;                      /* unique: captures moved out, memory reused */
  else { fic_dup(pq); fic_dup(bps); self->h.rc--; }
  return sieveW(n, pq, q, bps, t);
}
static fic_ref oddThunk(Clo *self) {                  /* \() -> sieve 5 emptyPQ 9 (oddprms ()) */
  fic_drop((fic_ref)self);
  return sieveW(5, Mt, 9, oddprms(), NULL);
}
static fic_ref primesThunk(Clo *self) { fic_drop((fic_ref)self); return oddprms(); }
static fic_ref primesPQ(void) { return cis_alloc(NULL, fic_dup((fic_ref)&static_primes), 2); }

static int64_t countCISTo(int64_t n, fic_ref cisr) {
  int64_t cnt = 0;
  for (;;) {
    Cis *c = (Cis *)cisr; fic_ref tl;
    if (c->hd > n) { fic_drop(cisr); return cnt; }
    tok_free(cis_take(c, &tl));
    cnt++;
    cisr = call0(tl);
  }
}
static int64_t countPrimesTo(int64_t n) { return countCISTo(n, primesPQ()); }

int main(int argc, char **argv) {
  volatile int64_t limit = argc > 1 ? atoll(argv[1]) : 6000000;     /* optional limit, e.g. 100000000 */
  const int NUMLOOPS = 1;
  int64_t answer, sink = 0; size_t allocs; int i; clock_t strt, stop;
  fic_total_allocs = 0;
  strt = clock();
  answer = countPrimesTo(limit);
  allocs = fic_total_allocs;
  sink = answer; (void)i;
  stop = clock();
  printf("Found %lld prime numbers to %lld inclusive.\r\n", (long long)answer, (long long)limit);
  printf("(%d loops in %ld milliseconds, check %lld; %zu allocations per run, %zu objects still live)\r\n",
         NUMLOOPS, (long)((stop - strt) * 1000L / CLOCKS_PER_SEC), (long long)sink, allocs, fic_live_objects);
  return fic_live_objects == 0 ? 0 : 1;
}
