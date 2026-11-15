/* Standalone test of runtime/fic_vector.h (V1, docs/STAGE4-V1.md). As a counted program (-DFIC_RC -DFIC_STATS): every operation on a
   unique and on a shared vector, for the three element layouts (RAW scalars and structs of scalars, REF one reference, MAP a struct
   with a pointer map), growth, take, the counter of copies of shared vectors, the FIC_WARN_COPY line, and no live object at the end.
   Without -DFIC_RC (the oracle): every update copies and nothing is freed. */
#include <stdio.h>
#include <stddef.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_vector.h"

static int failures;
#define CHECK(what, cond) do { if (!(cond)) { printf("FAIL %s\n", what); failures++; } else printf("ok   %s\n", what); } while (0)

static fic_ref box(int64_t v) {                   /* a counted object with one scalar */
  fic_ref o = (fic_ref)fic_alloc(sizeof(fic_hdr) + 8, 7, 0);
  *(int64_t *)(o + 1) = v;
  return o;
}
static int64_t unbox(fic_ref o) { return *(int64_t *)(o + 1); }

typedef struct { double x; double y; uint8_t on; } pt;                 /* RAW struct */
typedef struct { int64_t id; fic_ref name; double w; fic_ref tag; } rec;   /* MAP struct: two references */
static const uint16_t rec_off[2] = { offsetof(rec, name), offsetof(rec, tag) };
static const fic_vdesc rec_desc = { 2u, rec_off };

#define I64(v, i) FIC_VECTOR_AT(v, int64_t, i)
#define REF(v, i) FIC_VECTOR_AT(v, fic_ref, i)
#define REC(v, i) FIC_VECTOR_AT(v, rec, i)

static fic_ref push_i(int64_t x, fic_ref v) { return fic_vector_push(&x, v, "test"); }
static fic_ref set_i(int64_t i, int64_t x, fic_ref v) { return fic_vector_set(i, &x, v, "test"); }
static fic_ref push_r(fic_ref x, fic_ref v) { return fic_vector_push(&x, v, "test"); }
static fic_ref set_r(int64_t i, fic_ref x, fic_ref v) { return fic_vector_set(i, &x, v, "test"); }
static rec mkrec(int64_t id) { rec r; r.id = id; r.name = box(id * 10); r.w = (double)id / 2; r.tag = box(id * 100); return r; }
static fic_ref push_rec(rec x, fic_ref v) { return fic_vector_push(&x, v, "test"); }

int main(void) {
  fic_ref a, b, c, x, y;
  size_t live0 = fic_live_objects;
  int64_t i, sum;
  rec r;
  pt p;
  (void)unbox; (void)y; (void)x; (void)c; (void)r;

  /* ---- RAW: Int ---- */
  a = fic_vector_new(0, sizeof(int64_t), NULL);
  CHECK("an empty vector: length 0, a leaf for the drop", FIC_VECTOR_LEN(a) == 0 && a->nptr == 0 && a->tag == FIC_TAG_VECTOR);
  for (i = 0; i < 100; i++) a = push_i(i * 3, a);
  sum = 0; for (i = 0; i < 100; i++) sum += I64(a, i);
#ifdef FIC_RC
  CHECK("100 pushes: length 100, capacity 128, the elements", FIC_VECTOR_LEN(a) == 100 && FIC_VECTOR(a)->cap == 128 && sum == 3 * 4950);
#else
  CHECK("100 pushes: length 100, the elements", FIC_VECTOR_LEN(a) == 100 && sum == 3 * 4950);
#endif
#ifdef FIC_RC
  CHECK("growth is amortized: 6 moves (4, 8, .. 128), 94 pushes in place, no copy of a shared vector",
        fic_n_copied == 6 && fic_n_inplace == 94 && fic_n_vcopy == 0);
  b = set_i(7, -1, a);
  CHECK("set on a unique vector is in place", b == a && I64(a, 7) == -1);
  fic_dup(a);
  b = set_i(8, -2, a);
  CHECK("set on a shared vector copies; the original is unchanged and unique again", b != a && I64(a, 8) == 24 && I64(b, 8) == -2 && I64(b, 7) == -1 && a->rc == 1 && b->rc == 1 && fic_n_vcopy == 1);
  CHECK("the copy has no spare capacity", FIC_VECTOR(b)->cap == 100);
  b = set_i(100, 5, b); b = set_i(-1, 5, b);
  CHECK("set out of range changes nothing", FIC_VECTOR_LEN(b) == 100 && I64(b, 99) == 297 && fic_n_vcopy == 1);
  b = fic_vector_swap(0, 99, b, "test");
  CHECK("swap on a unique vector is in place", I64(b, 0) == 297 && I64(b, 99) == 0);
  b = fic_vector_swap(0, 100, b, "test"); b = fic_vector_swap(-1, 3, b, "test"); b = fic_vector_swap(5, 5, b, "test");
  CHECK("swap out of range, or of an element with itself, changes nothing", I64(b, 0) == 297 && I64(b, 5) == 15);
  fic_dup(b);
  c = fic_vector_swap(1, 2, b, "test");
  CHECK("swap on a shared vector copies", c != b && I64(c, 1) == 6 && I64(c, 2) == 3 && I64(b, 1) == 3 && fic_n_vcopy == 2);
  fic_drop(c);
  fic_dup(a);
  c = push_i(1000, a);
  CHECK("push on a shared vector copies, with room to grow", c != a && FIC_VECTOR_LEN(c) == 101 && FIC_VECTOR_LEN(a) == 100 && FIC_VECTOR(c)->cap == 200 && fic_n_vcopy == 3);
  fic_drop(c);
  c = fic_vector_slice(10, 20, a);
  CHECK("slice 10 20: ten elements, a new vector", FIC_VECTOR_LEN(c) == 10 && I64(c, 0) == 30 && I64(c, 9) == 57 && c != a);
  fic_drop(c);
  c = fic_vector_slice(-3, 1000, a);
  CHECK("slice -3 1000: the last three", FIC_VECTOR_LEN(c) == 3 && I64(c, 0) == 291);
  fic_drop(c);
  c = fic_vector_slice(50, 40, a);
  CHECK("slice 50 40: empty", FIC_VECTOR_LEN(c) == 0);
  c = fic_vector_append(c, a, "test");
  CHECK("append to a unique empty vector moves into a larger one", FIC_VECTOR_LEN(c) == 100 && I64(c, 99) == 297 && fic_n_vcopy == 3);
  fic_dup(c);                                                /* the same vector twice: one count for the owner, one for the borrower */
  x = fic_vector_append(c, c, "test");
  CHECK("append v v: the vector is shared for the call, so it is copied; the elements are doubled", x != c && c->rc == 1 && FIC_VECTOR_LEN(x) == 200 && I64(x, 100) == 0 && I64(x, 199) == 297 && fic_n_vcopy == 4);
  fic_drop(c); c = x;
  fic_dup(a);
  x = fic_vector_append(a, b, "test");
  CHECK("append on a shared vector copies", x != a && FIC_VECTOR_LEN(x) == 200 && I64(x, 100) == 297 && a->rc == 1 && fic_n_vcopy == 5);
  fic_drop(x); fic_drop(a); fic_drop(b); fic_drop(c);
  CHECK("Int vectors: nothing is live", fic_live_objects == live0);

  /* ---- RAW: Bool (one byte) and a struct of scalars ---- */
  a = fic_vector_new(1000, 1, NULL);
  { uint8_t f = 0, t = 1; for (i = 0; i < 1000; i++) a = fic_vector_push(&f, a, "test"); for (i = 0; i < 1000; i += 7) a = fic_vector_set(i, &t, a, "test"); }
  sum = 0; for (i = 0; i < 1000; i++) sum += FIC_VECTOR_AT(a, uint8_t, i);
  CHECK("a vector of 1000 bytes with capacity given: no growth, 143 set", FIC_VECTOR(a)->cap == 1000 && sum == 143);
  fic_drop(a);
  a = fic_vector_new(0, sizeof(pt), NULL);
  for (i = 0; i < 10; i++) { p.x = (double)i; p.y = (double)i * 0.5; p.on = (uint8_t)(i & 1); a = fic_vector_push(&p, a, "test"); }
  a = fic_vector_swap(2, 9, a, "test");
  CHECK("a vector of structs of scalars: stored flat, swapped whole", FIC_VECTOR(a)->esize == sizeof(pt) && FIC_VECTOR_AT(a, pt, 2).y == 4.5 && FIC_VECTOR_AT(a, pt, 2).on == 1 && FIC_VECTOR_AT(a, pt, 9).x == 2.0);
  fic_drop(a);
  CHECK("raw vectors: nothing is live", fic_live_objects == live0);

  /* ---- REF: one reference per element ---- */
  a = fic_vector_new(0, sizeof(fic_ref), &fic_vd_ref);
  for (i = 0; i < 5; i++) a = push_r(box(i), a);
  CHECK("a vector of references is not a leaf", a->nptr == 1);
  x = box(100);
  y = REF(a, 1); fic_dup(y);
  a = set_r(1, x, a);
  CHECK("set in place drops the old element", REF(a, 1) == x && y->rc == 1 && x->rc == 1);
  fic_drop(y);
  fic_dup(a);
  b = set_r(0, box(200), a);
  CHECK("the copy of a shared vector counts the elements it shares", b != a && REF(a, 2)->rc == 2 && REF(a, 0)->rc == 1 && unbox(REF(b, 0)) == 200);
  x = box(7);
  b = set_r(77, x, b);
  CHECK("set out of range releases the element", fic_live_objects == live0 + 2 + 5 + 1);
  fic_drop(b);
  CHECK("after the copy is dropped the elements are unique again", REF(a, 2)->rc == 1);
  fic_vector_take(3, a, &x);
  CHECK("take from a unique vector moves the element out and leaves a placeholder", x->rc == 1 && unbox(x) == 3 && REF(a, 3) == (fic_ref)&fic_nul0);
  a = set_r(3, x, a);
  CHECK("the set after the take puts it back in place", unbox(REF(a, 3)) == 3 && REF(a, 3)->rc == 1);
  fic_vector_take(4, a, &x);
  fic_drop(a);
  CHECK("a vector with a placeholder can be dropped", unbox(x) == 4 && x->rc == 1);
  fic_drop(x);
  a = fic_vector_new(0, sizeof(fic_ref), &fic_vd_ref);
  for (i = 0; i < 3; i++) a = push_r(box(i), a);
  fic_dup(a);
  fic_vector_take(1, a, &x);
  CHECK("take from a shared vector gives a counted copy", x->rc == 2 && REF(a, 1) == x);
  b = set_r(1, x, a);
  CHECK("the set after it copies the vector", b != a && REF(b, 1) == REF(a, 1) && REF(a, 1)->rc == 2);
  c = fic_vector_slice(1, 3, a);
  CHECK("a slice counts its elements", REF(c, 0)->rc == 3 && REF(c, 1)->rc == 3);
  c = fic_vector_append(c, b, "test");
  CHECK("append counts the elements it takes from the borrowed vector", FIC_VECTOR_LEN(c) == 5 && REF(a, 0)->rc == 3 && REF(a, 1)->rc == 4);
  fic_drop(a); fic_drop(b); fic_drop(c);
  CHECK("reference vectors: nothing is live", fic_live_objects == live0);

  /* ---- MAP: a struct with two references ---- */
  a = fic_vector_new(0, sizeof(rec), &rec_desc);
  for (i = 0; i < 6; i++) a = push_rec(mkrec(i), a);
  CHECK("a vector of structs with references: 6 elements, 12 objects held", FIC_VECTOR_LEN(a) == 6 && fic_live_objects == live0 + 13 && REC(a, 5).w == 2.5);
  r = mkrec(50);
  a = fic_vector_set(2, &r, a, "test");
  CHECK("set in place drops both references of the old element", fic_live_objects == live0 + 13 && REC(a, 2).id == 50);
  fic_dup(a);
  b = fic_vector_swap(0, 5, a, "test");
  CHECK("a copy counts exactly the reference words", REC(a, 1).name->rc == 2 && REC(a, 1).tag->rc == 2 && REC(b, 0).id == 5 && REC(a, 0).id == 0);
  fic_vector_take(1, b, &r);
  CHECK("take from a unique vector of structs: both references moved, placeholders left", r.name->rc == 2 && REC(b, 1).name == (fic_ref)&fic_nul0 && REC(b, 1).tag == (fic_ref)&fic_nul0 && r.id == 1);
  r.id = 11;
  b = fic_vector_set(1, &r, b, "test");
  CHECK("and put back in place", REC(b, 1).id == 11 && REC(b, 1).name->rc == 2);
  fic_drop(a);
  CHECK("the elements of the copy are unique after the original is dropped", REC(b, 1).name->rc == 1 && REC(b, 3).tag->rc == 1);
  fic_drop(b);
  CHECK("struct vectors: nothing is live", fic_live_objects == live0);

  /* ---- a vector of vectors, and the drop without recursion ---- */
  a = fic_vector_new(0, sizeof(fic_ref), &fic_vd_ref);
  for (i = 0; i < 2000; i++) { b = fic_vector_new(0, sizeof(fic_ref), &fic_vd_ref); b = push_r(a, b); a = b; }   /* 2000 deep */
  fic_drop(a);
  CHECK("a chain of 2000 nested vectors is dropped", fic_live_objects == live0);

  /* ---- FIC_WARN_COPY ---- */
  CHECK("copies of shared vectors so far", fic_n_vcopy == 8);
#else
  /* the oracle: every update copies, nothing is freed */
  b = set_i(7, -1, a);
  CHECK("no counts: set copies", b != a && I64(a, 7) == 21 && I64(b, 7) == -1);
  c = push_i(5, b);
  CHECK("no counts: push copies", c != b && FIC_VECTOR_LEN(b) == 100 && FIC_VECTOR_LEN(c) == 101);
  c = fic_vector_swap(0, 1, c, "test");
  CHECK("no counts: swap copies", I64(c, 0) == 3 && I64(c, 1) == 0 && I64(b, 0) == 0);
  x = fic_vector_append(a, b, "test");
  CHECK("no counts: append copies", x != a && FIC_VECTOR_LEN(x) == 200 && FIC_VECTOR_LEN(a) == 100);
  x = fic_vector_slice(-2, 100, x);
  CHECK("slice", FIC_VECTOR_LEN(x) == 0);
  a = fic_vector_new(0, sizeof(rec), &rec_desc);
  for (i = 0; i < 3; i++) a = push_rec(mkrec(i), a);
  fic_vector_take(1, a, &r);
  CHECK("no counts: take is a read", r.id == 1 && REC(a, 1).name == r.name);
  (void)p; (void)live0; (void)push_r; (void)set_r;
#endif
  printf("%d failures\n", failures);
  return failures != 0 || (
#ifdef FIC_RC
    fic_shutdown()
#else
    0
#endif
  );
}
