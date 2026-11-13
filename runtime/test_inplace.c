/* Standalone test of the S6 runtime (docs/STAGE4-S6.md), compiled with -DFIC_RC -DFIC_STATS: fic_ja_set, fic_ja_push and fic_ja_take
   on unique and on shared arrays (raw and reference elements), and fic_ap<n>_own on a unique and on a shared partial application.
   The counts are checked after every step and the program must end with no live object. */
#include <stdio.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_closure.h"
#include "fic_jsarray.h"

static int failures;
#define CHECK(what, cond) do { if (!(cond)) { printf("FAIL %s\n", what); failures++; } else printf("ok   %s\n", what); } while (0)

static fic_ref box(int64_t v) {                   /* a counted object with one scalar */
  fic_ref o = (fic_ref)fic_alloc(sizeof(fic_hdr) + 8, 7, 0);
  *(int64_t *)(o + 1) = v;
  return o;
}
static int64_t unbox(fic_ref o) { return *(int64_t *)(o + 1); }

/* add3 a b c = a + b + c, with boxed a; consumes a */
static fic_word add3(fic_ref self, fic_word a, fic_word b, fic_word c) {
  int64_t r = unbox(a.p) + b.i + c.i;
  (void)self;
  printf("     add3: the count of the boxed argument is %u\n", (unsigned)a.p->rc);
  fic_drop(a.p);
  return fic_w_i(r);
}
static const fic_code add3_code = { (void (*)(void))add3, 3u FIC_CODE_OWN0 };
static fic_clo add3_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &add3_code };

/* S7 part 3: a closure object { header, code, one captured box } with a second entry. `held x b = x + b`: the ordinary entry reads the
   captured box (the object keeps its count), the own entry takes it out of the object, frees the object and consumes the box */
typedef struct { fic_hdr h; const fic_code *code; fic_ref r0; } held;
static fic_word held_entry(fic_ref self, fic_word b) {
  printf("     held: the ordinary entry, the count of the captured box is %u\n", (unsigned)((held *)self)->r0->rc);
  return fic_w_i(unbox(((held *)self)->r0) + b.i);
}
static fic_word held_own(fic_ref self, fic_word b) {
  fic_ref x = ((held *)self)->r0;
  int64_t r;
  FIC_STAT(fic_n_clo_steal++);
  fic_free_obj(self);
  printf("     held: the own entry, the count of the captured box is %u\n", (unsigned)x->rc);
  r = unbox(x) + b.i;
  fic_drop(x);
  return fic_w_i(r);
}
static const fic_code held_code = { (void (*)(void))held_entry, 1u, (void (*)(void))held_own };
static fic_ref mkheld(fic_ref x) {
  held *k = (held *)fic_alloc(sizeof(held), FIC_TAG_CLOSURE, 1);
  k->code = &held_code; k->r0 = x;
  return &k->h;
}

int main(void) {
  fic_ref a, b, c, x, y, pap;
  fic_word w;
  size_t live0 = fic_live_objects;
  int64_t i;

  /* raw elements */
  a = fic_ja_empty(FIC_TAG_VEC_RAW);
  for (i = 0; i < 6; i++) a = fic_ja_push(fic_w_i(i * 10), a);
  CHECK("push on a unique array: 6 elements, capacity 8", fic_ja_length(a) == 6 && FIC_VEC(a)->cap == 8 && fic_n_inplace == 4 && fic_n_copied == 2);
  b = fic_ja_set(2, fic_w_i(99), a);
  CHECK("set on a unique array is in place", b == a && fic_ja_data(a)[2].i == 99);
  fic_dup(a);
  b = fic_ja_set(3, fic_w_i(77), a);
  CHECK("set on a shared array copies", b != a && fic_ja_data(a)[3].i == 30 && fic_ja_data(b)[3].i == 77 && a->rc == 1 && b->rc == 1);
  fic_dup(a);
  c = fic_ja_push(fic_w_i(5), a);
  CHECK("push on a shared array copies", c != a && fic_ja_length(a) == 6 && fic_ja_length(c) == 7 && a->rc == 1);
  b = fic_ja_set(9, fic_w_i(1), b);
  CHECK("set out of range changes nothing", fic_ja_length(b) == 6 && fic_ja_data(b)[5].i == 50);
  fic_drop(a); fic_drop(b); fic_drop(c);
  CHECK("raw arrays: nothing is live", fic_live_objects == live0);

  /* reference elements */
  a = fic_ja_empty(FIC_TAG_VEC_REF);
  for (i = 0; i < 5; i++) a = fic_ja_push(fic_w_p(box(i)), a);
  x = box(100);
  y = fic_ja_data(a)[1].p;
  fic_dup(y);                                      /* keep the old element to see its count */
  a = fic_ja_set(1, fic_w_p(x), a);
  CHECK("set in place drops the old element", fic_ja_data(a)[1].p == x && y->rc == 1 && x->rc == 1);
  fic_drop(y);
  fic_dup(a);
  b = fic_ja_set(0, fic_w_p(box(200)), a);
  CHECK("the copy of a shared array counts the elements it shares", b != a && fic_ja_data(a)[2].p->rc == 2 && fic_ja_data(a)[0].p->rc == 1 && unbox(fic_ja_data(b)[0].p) == 200);
  fic_drop(b);
  CHECK("after the copy is dropped the elements are unique again", fic_ja_data(a)[2].p->rc == 1);

  /* take: unique array */
  w = fic_ja_take(3, a);
  CHECK("take from a unique array moves the element out", w.p->rc == 1 && unbox(w.p) == 3 && fic_ja_data(a)[3].p == (fic_ref)&fic_nul0);
  a = fic_ja_set(3, w, a);
  CHECK("the set after the take puts it back in place", unbox(fic_ja_data(a)[3].p) == 3 && fic_ja_data(a)[3].p->rc == 1);
  w = fic_ja_take(4, a);
  fic_drop(a);                                     /* a path without the set: the array with the placeholder is dropped */
  CHECK("an array with a placeholder can be dropped", unbox(w.p) == 4 && w.p->rc == 1);
  fic_drop(w.p);
  CHECK("reference arrays: nothing is live", fic_live_objects == live0);

  /* take: shared array */
  a = fic_ja_empty(FIC_TAG_VEC_REF);
  for (i = 0; i < 3; i++) a = fic_ja_push(fic_w_p(box(i)), a);
  fic_dup(a);
  w = fic_ja_take(1, a);
  CHECK("take from a shared array gives a counted copy", w.p->rc == 2 && fic_ja_data(a)[1].p == w.p);
  b = fic_ja_set(1, w, a);
  CHECK("the set after it copies the array", b != a && fic_ja_data(b)[1].p == fic_ja_data(a)[1].p && fic_ja_data(a)[1].p->rc == 2);
  fic_drop(a); fic_drop(b);
  CHECK("shared take: nothing is live", fic_live_objects == live0);

  /* fic_ap<n>_own: a unique partial application gives its argument up */
  x = box(1000);
  pap = fic_ap1(&add3_clo.h, 1u, fic_w_p(x)).p;
  CHECK("a partial application holds the argument", pap->tag == FIC_TAG_PAP && x->rc == 1);
  w = fic_ap2_own(pap, 0u, fic_w_i(20), fic_w_i(3));
  CHECK("unique: the result, one steal (the count printed above is 1)", w.i == 1023 && fic_n_pap_steal == 1);
  CHECK("unique: nothing is live", fic_live_objects == live0);
  /* a shared partial application: the argument is shared with it during the call, the partial application survives */
  x = box(2000);
  pap = fic_ap1(&add3_clo.h, 1u, fic_w_p(x)).p;
  fic_dup(pap);
  w = fic_ap2_own(pap, 0u, fic_w_i(20), fic_w_i(3));
  CHECK("shared: the result, no steal (the count printed above is 2)", w.i == 2023 && fic_n_pap_steal == 1 && pap->rc == 1 && x->rc == 1);
  w = fic_ap2_own(pap, 0u, fic_w_i(1), fic_w_i(1));
  CHECK("then unique: stolen", w.i == 2002 && fic_n_pap_steal == 2);
  /* not a partial application, and a partial application that is still partial */
  w = fic_ap3_own(&add3_clo.h, 1u, fic_w_p(box(1)), fic_w_i(2), fic_w_i(3));
  CHECK("a static closure is called and stays", w.i == 6 && add3_clo.h.rc == FIC_IMMORTAL - 1u);
  add3_clo.h.rc = FIC_IMMORTAL;                    /* (the test did not own a count on it) */
  x = box(5);
  pap = fic_ap1(&add3_clo.h, 1u, fic_w_p(x)).p;
  y = fic_ap1_own(pap, 0u, fic_w_i(6)).p;
  CHECK("one more argument: a partial application of the partial application", y->tag == FIC_TAG_PAP && x->rc == 1);
  w = fic_ap1_own(y, 0u, fic_w_i(7));
  CHECK("completed through both, both stolen (the count printed above is 1)", w.i == 18 && fic_n_pap_steal == 4);
  CHECK("closures: nothing is live", fic_live_objects == live0);

  /* fic_ap<n>_own on a closure object with a second entry (S7 part 3) */
  y = mkheld(box(100));
  w = fic_ap1_own(y, 0u, fic_w_i(5));
  CHECK("unique closure: the own entry ran, the object and the box are gone", w.i == 105 && fic_n_clo_steal == 1 && fic_live_objects == live0);
  x = box(200);
  y = mkheld(x);
  fic_dup(y);
  w = fic_ap1_own(y, 0u, fic_w_i(5));
  CHECK("shared closure: the ordinary entry ran, the object lost one count and keeps the box", w.i == 205 && fic_n_clo_steal == 1 && y->rc == 1 && x->rc == 1);
  w = fic_ap1(y, 0u, fic_w_i(6));
  CHECK("a borrowing call never takes the box", w.i == 206 && fic_n_clo_steal == 1 && y->rc == 1 && x->rc == 1);
  pap = fic_ap1(&add3_clo.h, 1u, fic_w_p(box(1))).p;       /* an under-applied call of a unique closure is not its own entry */
  fic_drop(pap);
  w = fic_ap1_own(y, 0u, fic_w_i(7));
  CHECK("then unique: taken", w.i == 207 && fic_n_clo_steal == 2 && fic_live_objects == live0);

  printf("%d failure(s)\n", failures);
  return failures != 0 || fic_shutdown() != 0;
}
