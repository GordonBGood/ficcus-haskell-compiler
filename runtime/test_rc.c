/* Standalone tests of the reference counts and the generic drop of fic_rt.h (STAGE4-PLAN S1): dup/drop, immortal
   objects, uniqueness, the explicit stack (no C recursion: test.sh runs this under `ulimit -s 256`), long lists of Ints,
   strings and lists, degenerate trees to the left and to the right, a PAP chain, closures, vectors, wide objects.
   Every test checks fic_live_objects against the value before it. Build and run: runtime/test.sh
   Variants (test.sh): -DFIC_DROP_ALL (smaller sizes, the layout check of fic_shutdown), -DFIC_STATS -DFIC_CHECK. */
#include "fic_rt.h"

static int failures = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)

#if defined(FIC_DROP_ALL) || defined(SMALL)
#  define BIG 100000
#else
#  define BIG 10000000
#endif

/* ---- the shapes of generated objects: references first, then scalars ---- */
typedef struct { fic_hdr h; fic_ref tail; int64_t head; } icell;               /* List Int: nptr 1 */
typedef struct { fic_hdr h; fic_ref head; fic_ref tail; } pcell;               /* List of references: nptr 2 */
typedef struct { fic_hdr h; fic_ref left; fic_ref right; int64_t v; } tnode;    /* a tree: nptr 2 */
typedef struct { fic_hdr h; int64_t len; int64_t cps; char data[8]; } fstr;     /* a string (FIC_TAG_STRING) */
typedef struct { fic_hdr h; const fic_code *code; fic_ref r0; int64_t s0; } kclo; /* a closure with one reference, one scalar */
typedef struct { fic_hdr h; fic_ref r[255]; } wide;

static fic_ref mk_icell(int64_t head, fic_ref tail) {
  icell *c = (icell *)fic_alloc(sizeof(icell), 1u, 1);
  c->tail = tail; c->head = head;
  return &c->h;
}
static fic_ref mk_pcell(fic_ref head, fic_ref tail) {
  pcell *c = (pcell *)fic_alloc(sizeof(pcell), 1u, 2);
  c->head = head; c->tail = tail;
  return &c->h;
}
static fic_ref mk_str(const char *s) {
  size_t n = strlen(s);
  fstr *r = (fstr *)fic_alloc(sizeof(fic_hdr) + 16 + n + 1, FIC_TAG_STRING, 0);
  r->len = (int64_t)n; r->cps = (int64_t)n;
  memcpy(r->data, s, n + 1);
  return &r->h;
}
static fic_ref mk_tnode(fic_ref l, fic_ref r, int64_t v) {
  tnode *t = (tnode *)fic_alloc(sizeof(tnode), 0u, 2);
  t->left = l; t->right = r; t->v = v;
  return &t->h;
}

int main(void) {
  size_t base = fic_live_objects;
  int64_t i;

  /* counts: dup, drop, uniqueness, sharing */
  { fic_ref a = mk_str("a"), b = mk_icell(1, NULL);
    b->nptr = 0;                                                       /* no reference to release */
    CHECK(fic_live_objects == base + 2 && a->rc == 1 && fic_is_unique(a));
    CHECK(fic_dup(a) == a && a->rc == 2 && !fic_is_unique(a));
    CHECK(FIC_DUP(a) == a && a->rc == 3);
    fic_drop(a); fic_drop(a);
    CHECK(fic_is_unique(a) && FIC_CHECK_UNIQUE(a) == a && fic_live_objects == base + 2);
    fic_drop(a); fic_drop(b);
    CHECK(fic_live_objects == base); }

  /* a shared child stays alive until its last owner is gone */
  { fic_ref s = mk_str("shared"), x = mk_pcell(FIC_DUP(s), &fic_nul0), y = mk_pcell(s, &fic_nul0);
    CHECK(s->rc == 2 && fic_live_objects == base + 3);
    fic_drop(x); CHECK(s->rc == 1 && fic_live_objects == base + 2);
    fic_drop(y); CHECK(fic_live_objects == base); }

  /* immortal (static) objects are counted like any other and never freed; they are never unique */
  { static fic_hdr st = { FIC_IMMORTAL, 5u, 0, 0 };
    fic_ref l;
    fic_dup(&st); fic_dup(&st);
    l = mk_pcell(&st, &st);                                            /* a heap cell that owns two counts of a static child */
    CHECK(st.rc == FIC_IMMORTAL + 2 && !fic_is_unique(&st));
    fic_dup(&st); fic_dup(&st); fic_drop(&st); fic_drop(&st);
    fic_drop(l);                                                       /* releases both counts */
    CHECK(st.rc == FIC_IMMORTAL && fic_live_objects == base); }

  /* nullary singletons as the end of a list */
  { fic_ref l = mk_pcell(mk_str("x"), mk_pcell(mk_str("y"), &fic_nul0));
    CHECK(fic_live_objects == base + 4);
    fic_drop(l);
    CHECK(fic_live_objects == base); }

  /* a list of BIG Ints: nptr 1, a leaf head */
  { fic_ref l = &fic_nul0;
    for (i = 0; i < BIG; i++) l = mk_icell(i, l);
    CHECK(fic_live_objects == base + (size_t)BIG);
    fic_drop(l);
    CHECK(fic_live_objects == base); printf("ok list of Ints\n"); }

  /* a list of BIG strings: each head dies as the cell dies (a leaf: freed at once, no stack) */
  { fic_ref l = &fic_nul0;
    for (i = 0; i < BIG; i++) l = mk_pcell(mk_str(i % 2 ? "odd" : "even"), l);
    CHECK(fic_live_objects == base + 2 * (size_t)BIG);
    fic_drop(l);
    CHECK(fic_live_objects == base); printf("ok list of strings\n"); }

  /* a list of BIG lists of two Ints: the head list dies, then the tail (the case that overflows a recursive drop) */
  { fic_ref l = &fic_nul0;
    for (i = 0; i < BIG; i++) l = mk_pcell(mk_icell(i, mk_icell(-i, &fic_nul0)), l);
    CHECK(fic_live_objects == base + 3 * (size_t)BIG);
    fic_drop(l);
    CHECK(fic_live_objects == base && fic_dtop == 0); printf("ok list of lists\n"); }

  /* a list that holds BIG/10 lists that are each 10 deep and then a few shared cells: shared tails survive */
  { fic_ref tailshared = mk_icell(7, mk_icell(8, &fic_nul0)), l = &fic_nul0, keep;
    for (i = 0; i < BIG / 10; i++) l = mk_pcell(mk_icell(i, FIC_DUP(tailshared)), l);
    keep = FIC_DUP(tailshared);
    fic_drop(tailshared);
    fic_drop(l);
    CHECK(fic_live_objects == base + 2 && keep->rc == 1);
    fic_drop(keep);
    CHECK(fic_live_objects == base); printf("ok shared tails\n"); }

  /* degenerate trees: a spine to the left, to the right */
  { fic_ref t = &fic_nul1;
    for (i = 0; i < BIG; i++) t = mk_tnode(t, &fic_nul1, i);
    CHECK(fic_live_objects == base + (size_t)BIG);
    fic_drop(t);
    CHECK(fic_live_objects == base);
    t = &fic_nul1;
    for (i = 0; i < BIG; i++) t = mk_tnode(&fic_nul1, t, i);
    fic_drop(t);
    CHECK(fic_live_objects == base && fic_dtop == 0); printf("ok degenerate trees\n"); }

  /* a zigzag tree (alternating left and right) and a complete tree of strings: both children die */
  { fic_ref t = &fic_nul1;
    for (i = 0; i < BIG; i++) t = (i & 1) ? mk_tnode(t, mk_tnode(&fic_nul1, &fic_nul1, 0), i) : mk_tnode(mk_tnode(&fic_nul1, &fic_nul1, 0), t, i);
    fic_drop(t);
    CHECK(fic_live_objects == base);
    { fic_ref d = mk_str("leaf"); int k;
      for (k = 0; k < 16; k++) d = mk_pcell(d, FIC_DUP(d));            /* a DAG: depth 16, 2^16 paths, 17 objects */
      CHECK(fic_live_objects == base + 17);
      fic_drop(d);
      CHECK(fic_live_objects == base && fic_dtop == 0); }
    printf("ok zigzag tree, shared DAG\n"); }

  /* a chain of partial applications: each holds the next one and a string argument (mask bit 0 only, one scalar) */
  { fic_ref p = mk_str("base");
    for (i = 0; i < BIG; i++) {
      fic_pap *q = (fic_pap *)fic_alloc(sizeof(fic_pap) + 2 * sizeof(fic_word), FIC_TAG_PAP, 1);
      q->code = NULL; q->fun = p; q->mask = 1u; q->nargs = 2;
      q->args[0].p = mk_str("arg"); q->args[1].i = i;                  /* a reference and a scalar that must not be released */
      p = &q->h;
    }
    CHECK(fic_live_objects == base + 1 + 2 * (size_t)BIG);
    fic_drop(p);
    CHECK(fic_live_objects == base); printf("ok PAP chain\n"); }

  /* a closure: references first (after the code pointer), then scalars; a closure without references is a leaf */
  { kclo *k = (kclo *)fic_alloc(sizeof(kclo), FIC_TAG_CLOSURE, 1);
    k->code = NULL; k->r0 = mk_str("captured"); k->s0 = 12345;
    CHECK(fic_live_objects == base + 2);
    fic_drop(&k->h);
    CHECK(fic_live_objects == base);
    k = (kclo *)fic_alloc(sizeof(kclo), FIC_TAG_CLOSURE, 0);
    k->code = NULL; k->r0 = NULL; k->s0 = 1;
    fic_drop(&k->h);
    CHECK(fic_live_objects == base); }

  /* vectors: references are released, raw elements are not looked at; a vector in a vector */
  { fic_ref v = fic_vec_new(1000, sizeof(fic_ref), FIC_TAG_VEC_REF), w = fic_vec_new(10, sizeof(int64_t), FIC_TAG_VEC_RAW);
    for (i = 0; i < 1000; i++) { fic_ref s = mk_str("e"); v = fic_vec_push(v, &s); }
    for (i = 0; i < 10; i++) { int64_t x = i * 1000003; w = fic_vec_push(w, &x); }
    { fic_ref outer = fic_vec_new(2, sizeof(fic_ref), FIC_TAG_VEC_REF), c = fic_vec_copy(v);   /* the copy shares the strings */
      CHECK(FIC_VEC(v)->len == 1000 && c != v);
      outer = fic_vec_push(outer, &v); outer = fic_vec_push(outer, &c);
      CHECK(fic_live_objects == base + 1000 + 3 + 1);
      fic_drop(outer);
      CHECK(fic_live_objects == base + 1); }                           /* only w is left */
    fic_drop(w);
    CHECK(fic_live_objects == base); printf("ok vectors\n"); }

  /* a vector of BIG/10 lists: the children die one after the other, each with its own chain */
  { fic_ref v = fic_vec_new(100, sizeof(fic_ref), FIC_TAG_VEC_REF);
    for (i = 0; i < 100; i++) {
      fic_ref l = &fic_nul0; int64_t j;
      for (j = 0; j < BIG / 100; j++) l = mk_icell(j, l);
      v = fic_vec_push(v, &l);
    }
    fic_drop(v);
    CHECK(fic_live_objects == base); printf("ok vector of lists\n"); }

  /* a wide object: 255 reference words, half of them the same child */
  { wide *w = (wide *)fic_alloc(sizeof(wide), 2u, 255);
    fic_ref shared = mk_str("w");
    for (i = 0; i < 255; i++) w->r[i] = (i % 2) ? FIC_DUP(shared) : mk_str("u");
    fic_drop(shared);
    CHECK(fic_live_objects == base + 1 + 1 + 128);
    fic_drop(&w->h);
    CHECK(fic_live_objects == base); printf("ok wide object\n"); }

  /* a drop started while another drop runs (a kernel dropping from a callback) leaves the stack as it was: simulated by
     dropping inside a loop that builds structure between drops, with the stack holding pending siblings */
  { fic_ref t = &fic_nul1;
    for (i = 0; i < 1000; i++) t = mk_tnode(mk_tnode(&fic_nul1, &fic_nul1, 0), t, i);
    { size_t top = fic_dtop;
      fic_drop(t);
      CHECK(fic_dtop == top); }
    CHECK(fic_live_objects == base); printf("ok stack mark\n"); }

#ifdef FIC_DROP_ALL
  /* leave three objects (a cell, its string, a closure) alive: the layout check of fic_shutdown accepts them and frees them */
  { fic_ref s = mk_str("left over"), c = mk_pcell(s, &fic_nul0);
    kclo *k = (kclo *)fic_alloc(sizeof(kclo), FIC_TAG_CLOSURE, 1);
    k->code = NULL; k->r0 = FIC_DUP(c); k->s0 = 3;
    CHECK(fic_live_objects == base + 3);
    CHECK(fic_shutdown() == 0);
    CHECK(fic_live_objects == 0); }
#else
  CHECK(fic_shutdown() == 0);
#endif

  if (failures) { printf("%d failure(s)\n", failures); return 1; }
  printf("rc tests ok\n");
  return 0;
}
