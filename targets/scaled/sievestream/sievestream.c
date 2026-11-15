/* sievestream.c -- what the Ficcus compiler should emit for SieveStream.elm (C99).
 *
 *   gcc -std=c99 -pedantic -Wall -Wextra -O2 sievestream.c -o sievestream
 *
 * The incremental odds-only Sieve of Eratosthenes with a tree merge of the streams of
 * composites, all of it closure streams (no memoization, every stream is consumed once).
 * What it tests:
 *   - CIS monomorphized twice: `CIS Int` (hd is a scalar, 1 reference) and
 *     `CIS (CIS Int)` (hd is a reference, 2 references); same size, so a dead cell of one
 *     can be the reuse token for the other;
 *   - closures with different captures behind one type `() -> CIS a`, called through the
 *     code pointer at a fixed offset: layout { header, code, captured references,
 *     captured scalars } (tag FIC_TAG_CLOSURE; the generic drop skips the code pointer);
 *   - a closure that captures nothing is a static immortal object (oddprms, primes);
 *   - calling a closure consumes it: when unique its captures are moved out and its
 *     memory is the reuse token for the next closure of the same size built by the
 *     function it calls (passed as `ktok`); cells are reused the same way (`ctok`);
 *   - the as-patterns (xs, ys, cs) in the Elm source: a whole cell captured by a closure
 *     instead of being taken apart (merge GT branch, testprm), so no dup is needed;
 *   - nested generator instances: oddprms() builds the base primes with another oddprms();
 *   - self tail call of testprm as a loop.
 * Sizes (bytes): cell 24 (Cis and CisS), closures 16 (none), 24 (one reference),
 * 32 (two references, reference + scalar, or two scalars).
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "ficrt.h"

typedef struct Clo { fic_hdr h; fic_ref (*fn)(struct Clo *); } Clo;
typedef struct Cis { fic_hdr h; fic_ref tl; int64_t hd; } Cis;     /* CIS Int */
typedef struct CisS { fic_hdr h; fic_ref tl; fic_ref hd; } CisS;   /* CIS (CIS Int) */
typedef struct Clo1 { Clo c; fic_ref a; } Clo1;                    /* one reference */
typedef struct Clo2 { Clo c; fic_ref a, b; } Clo2;                 /* two references */
typedef struct CloRN { Clo c; fic_ref a; int64_t n; } CloRN;       /* reference, scalar */
typedef struct CloNN { Clo c; int64_t p, adv; } CloNN;             /* two scalars */
#define TAG_CIS 4
#define TAG_CISS 5

static fic_ref call0(fic_ref c) { return ((Clo *)c)->fn((Clo *)c); }   /* consumes c */
static void tok_free(void *t) { if (t != NULL) fic_free_obj(t); }

static void *clo_alloc(void *tok, size_t bytes, uint16_t nptr, fic_ref (*fn)(Clo *)) {
  Clo *k = tok != NULL ? (Clo *)tok : (Clo *)fic_alloc(bytes, FIC_TAG_CLOSURE, nptr);
  k->h.tag = FIC_TAG_CLOSURE; k->h.nptr = nptr; k->fn = fn;
  return k;
}
static fic_ref cis_alloc(void *tok, fic_ref tl, int64_t hd) {
  Cis *c = tok != NULL ? (Cis *)tok : (Cis *)fic_alloc(sizeof(Cis), TAG_CIS, 1);
  c->h.tag = TAG_CIS; c->h.nptr = 1; c->tl = tl; c->hd = hd;
  return (fic_ref)c;
}
static fic_ref cisS_alloc(void *tok, fic_ref hd, fic_ref tl) {
  CisS *c = tok != NULL ? (CisS *)tok : (CisS *)fic_alloc(sizeof(CisS), TAG_CISS, 2);
  c->h.tag = TAG_CISS; c->h.nptr = 2; c->tl = tl; c->hd = hd;
  return (fic_ref)c;
}

/* Taking things apart: results are owned; the result is the memory as a reuse token if
   the object was unique (its references were moved), else NULL (dup'ed, count lowered). */
static void *cis_take(Cis *c, fic_ref *tl) {
  *tl = c->tl;
  if (c->h.rc == 1) return c;
  fic_dup(*tl); c->h.rc--; return NULL;
}
static void *cisS_take(CisS *c, fic_ref *hd, fic_ref *tl) {
  *hd = c->hd; *tl = c->tl;
  if (c->h.rc == 1) return c;
  fic_dup(*hd); fic_dup(*tl); c->h.rc--; return NULL;
}
static void *clo1_open(Clo *k, fic_ref *a) {
  *a = ((Clo1 *)k)->a;
  if (k->h.rc == 1) return k;
  fic_dup(*a); k->h.rc--; return NULL;
}
static void *clo2_open(Clo *k, fic_ref *a, fic_ref *b) {
  *a = ((Clo2 *)k)->a; *b = ((Clo2 *)k)->b;
  if (k->h.rc == 1) return k;
  fic_dup(*a); fic_dup(*b); k->h.rc--; return NULL;
}
static void *cloRN_open(Clo *k, fic_ref *a, int64_t *n) {
  *a = ((CloRN *)k)->a; *n = ((CloRN *)k)->n;
  if (k->h.rc == 1) return k;
  fic_dup(*a); k->h.rc--; return NULL;
}
static void *cloNN_open(Clo *k) {                         /* scalars only: nothing to move */
  if (k->h.rc == 1) return k;
  k->h.rc--; return NULL;
}

/* ---- merge (CIS x xtl as xs) (CIS y ytl as ys) ---------------------------------------- */
static fic_ref mergeLT(Clo *self);
static fic_ref mergeEQ(Clo *self);
static fic_ref mergeGT(Clo *self);

static fic_ref mergeW(fic_ref xsr, fic_ref ysr, void *ktok) {      /* xs, ys owned */
  Cis *xs = (Cis *)xsr, *ys = (Cis *)ysr;
  int64_t x = xs->hd, y = ys->hd;
  fic_ref xtl, ytl; void *ctok; Clo2 *k;
  if (x < y) {                                      /* CIS x (\() -> merge (xtl()) ys) */
    ctok = cis_take(xs, &xtl);
    k = (Clo2 *)clo_alloc(ktok, sizeof(Clo2), 2, mergeLT); k->a = xtl; k->b = ysr;
    return cis_alloc(ctok, (fic_ref)k, x);
  } else if (x == y) {                              /* CIS x (\() -> merge (xtl()) (ytl())) */
    ctok = cis_take(xs, &xtl);
    tok_free(cis_take(ys, &ytl));
    k = (Clo2 *)clo_alloc(ktok, sizeof(Clo2), 2, mergeEQ); k->a = xtl; k->b = ytl;
    return cis_alloc(ctok, (fic_ref)k, x);
  }
  ctok = cis_take(ys, &ytl);                        /* CIS y (\() -> merge xs (ytl())): xs whole */
  k = (Clo2 *)clo_alloc(ktok, sizeof(Clo2), 2, mergeGT); k->a = xsr; k->b = ytl;
  return cis_alloc(ctok, (fic_ref)k, y);
}
static fic_ref mergeLT(Clo *self) { fic_ref a, b; void *t = clo2_open(self, &a, &b); return mergeW(call0(a), b, t); }
static fic_ref mergeEQ(Clo *self) { fic_ref a, b; void *t = clo2_open(self, &a, &b); return mergeW(call0(a), call0(b), t); }
static fic_ref mergeGT(Clo *self) { fic_ref a, b; void *t = clo2_open(self, &a, &b); return mergeW(a, call0(b), t); }

/* ---- pmult bp: the odd multiples of bp from bp*bp, step 2*bp -------------------------- */
static fic_ref pmltThunk(Clo *self);
static fic_ref pmltW(int64_t p, int64_t adv, void *ktok) {
  CloNN *k = (CloNN *)clo_alloc(ktok, sizeof(CloNN), 0, pmltThunk); k->p = p; k->adv = adv;
  return cis_alloc(NULL, (fic_ref)k, p);
}
static fic_ref pmltThunk(Clo *self) {
  int64_t p = ((CloNN *)self)->p, adv = ((CloNN *)self)->adv;
  void *t = cloNN_open(self);
  return pmltW(FIC_ADD64(p, adv), adv, t);
}
static fic_ref pmult(int64_t bp) { return pmltW(FIC_MUL64(bp, bp), FIC_ADD64(bp, bp), NULL); }

/* ---- allmlts (CIS bp bptl): CIS Int -> CIS (CIS Int) ---------------------------------- */
static fic_ref allmltsThunk(Clo *self);
static fic_ref allmltsW(fic_ref in, void *ktok) {                  /* in owned */
  Cis *c = (Cis *)in; int64_t bp = c->hd; fic_ref tl;
  void *ctok = cis_take(c, &tl);                    /* the Cis cell becomes the CisS cell */
  Clo1 *k = (Clo1 *)clo_alloc(ktok, sizeof(Clo1), 1, allmltsThunk); k->a = tl;
  return cisS_alloc(ctok, pmult(bp), (fic_ref)k);
}
static fic_ref allmltsThunk(Clo *self) { fic_ref a; void *t = clo1_open(self, &a); return allmltsW(call0(a), t); }

/* ---- pairs (CIS frst tls): merges the first two streams of a stream of streams -------- */
static fic_ref pairsThunk(Clo *self);
static fic_ref pairsW(fic_ref in, void *ktok) {                    /* in owned */
  fic_ref frst, tls, scnd, tlss;
  void *ctok = cisS_take((CisS *)in, &frst, &tls);
  fic_ref second = call0(tls);                      /* let (CIS scnd tlss) = tls() */
  void *t2 = cisS_take((CisS *)second, &scnd, &tlss);
  Clo1 *k = (Clo1 *)clo_alloc(ktok, sizeof(Clo1), 1, pairsThunk); k->a = tlss;
  tok_free(t2);
  return cisS_alloc(ctok, mergeW(frst, scnd, NULL), (fic_ref)k);
}
static fic_ref pairsThunk(Clo *self) { fic_ref a; void *t = clo1_open(self, &a); return pairsW(call0(a), t); }

/* ---- cmpsts (CIS (CIS hd tl) tls): the tree merge of all the composites --------------- */
static fic_ref cmpThunk(Clo *self);
static fic_ref cmpstsW(fic_ref in) {                               /* in owned */
  fic_ref h, tls, tl; int64_t hd;
  void *ctok = cisS_take((CisS *)in, &h, &tls);
  hd = ((Cis *)h)->hd;
  tok_free(cis_take((Cis *)h, &tl));
  {
    Clo2 *k = (Clo2 *)clo_alloc(NULL, sizeof(Clo2), 2, cmpThunk); k->a = tl; k->b = tls;
    return cis_alloc(ctok, (fic_ref)k, hd);          /* the CisS cell becomes the Cis cell */
  }
}
static fic_ref cmpThunk(Clo *self) {                  /* \() -> merge (tl()) (cmpsts (pairs (tls()))) */
  fic_ref a, b; void *t = clo2_open(self, &a, &b);
  fic_ref left = call0(a);
  return mergeW(left, cmpstsW(pairsW(call0(b), NULL)), t);
}

/* ---- testprm n (CIS hd tl as cs): the odd numbers that are not composite --------------- */
static fic_ref testThunk(Clo *self);
static fic_ref testprmW(int64_t n, fic_ref csr, void *ktok) {      /* cs owned; self tail call = loop */
  for (;;) {
    Cis *cs = (Cis *)csr;
    if (n < cs->hd) {                                /* CIS n (\() -> testprm (n + 2) cs) */
      CloRN *k = (CloRN *)clo_alloc(ktok, sizeof(CloRN), 1, testThunk); k->a = csr; k->n = n + 2;
      return cis_alloc(NULL, (fic_ref)k, n);
    } else {
      fic_ref tl; tok_free(cis_take(cs, &tl));
      csr = call0(tl); n += 2;
    }
  }
}
static fic_ref testThunk(Clo *self) {
  fic_ref a; int64_t n; void *t = cloRN_open(self, &a, &n);
  return testprmW(n, a, t);
}

/* ---- oddprms () and primesStream (): closures that capture nothing are static --------- */
static fic_ref oddThunk(Clo *self);
static fic_ref primesThunk(Clo *self);
static Clo static_odd = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, oddThunk };
static Clo static_primes = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, primesThunk };

static fic_ref oddprms(void) { return cis_alloc(NULL, fic_dup((fic_ref)&static_odd), 3); }
static fic_ref oddThunk(Clo *self) {                  /* \() -> testprm 5 (cmpsts (allmlts (oddprms ()))) */
  fic_drop((fic_ref)self);
  return testprmW(5, cmpstsW(allmltsW(oddprms(), NULL)), NULL);
}
static fic_ref primesThunk(Clo *self) { fic_drop((fic_ref)self); return oddprms(); }
static fic_ref primesStream(void) { return cis_alloc(NULL, fic_dup((fic_ref)&static_primes), 2); }

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
static int64_t countPrimesTo(int64_t n) { return countCISTo(n, primesStream()); }

int main(int argc, char **argv) {
  volatile int64_t limit = argc > 1 ? atoll(argv[1]) : 5000000;     /* optional limit, e.g. 100000000 */
  const int NUMLOOPS = 1;
  int64_t answer, sink = 0; size_t allocs; int i; clock_t strt, stop;
  fic_total_allocs = 0;
  strt = clock();
  answer = countPrimesTo(limit);
  allocs = fic_total_allocs;
  sink = answer; (void)i;
  stop = clock();
  printf("Found %lld Hamming numbers to %lld inclusive.\r\n", (long long)answer, (long long)limit);
  printf("(%d loops in %ld milliseconds, check %lld; %zu allocations per run, %zu objects still live)\r\n",
         NUMLOOPS, (long)((stop - strt) * 1000L / CLOCKS_PER_SEC), (long long)sink, allocs, fic_live_objects);
  return fic_live_objects == 0 ? 0 : 1;
}
