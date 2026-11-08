/* Standalone tests of the closure runtime: calls with the right, a smaller and a larger number of arguments,
   partial applications of partial applications, every mix of scalars and references in the words.
   Build and run: runtime/test.sh */
#include "fic_base.h"
#include "fic_closure.h"

static int failures = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)

/* arity 1, 2, 3 and 4 functions over Int; a function of arity 1 that returns a function of arity 2 */
static fic_word inc(fic_ref self, fic_word a) { (void)self; return fic_w_i(a.i + 1); }
static fic_word add(fic_ref self, fic_word a, fic_word b) { (void)self; return fic_w_i(a.i + b.i); }
static fic_word sub3(fic_ref self, fic_word a, fic_word b, fic_word c) { (void)self; return fic_w_i(a.i - b.i - c.i); }
static fic_word mix4(fic_ref self, fic_word a, fic_word b, fic_word c, fic_word d) { (void)self; return fic_w_d(a.i + b.d + c.c + d.b); }
static const fic_code inc_code = { (void (*)(void))inc, 1u };
static const fic_code add_code = { (void (*)(void))add, 2u };
static const fic_code sub3_code = { (void (*)(void))sub3, 3u };
static const fic_code mix4_code = { (void (*)(void))mix4, 4u };
static fic_clo inc_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &inc_code };
static fic_clo add_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &add_code };
static fic_clo sub3_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &sub3_code };
static fic_clo mix4_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &mix4_code };

/* a closure with a captured scalar: \x -> x + k */
typedef struct { fic_hdr h; const fic_code *code; int64_t k; } adder;
static fic_word adder_entry(fic_ref self, fic_word a) { return fic_w_i(a.i + ((adder *)self)->k); }
static const fic_code adder_code = { (void (*)(void))adder_entry, 1u };
static fic_ref make_adder(int64_t k) {
  adder *o = (adder *)fic_alloc(sizeof(adder), FIC_TAG_CLOSURE, 0);
  o->code = &adder_code; o->k = k;
  return &o->h;
}
/* arity 1 returning a closure of arity 1: \k -> (\x -> x + k) */
static fic_word curry_entry(fic_ref self, fic_word k) { (void)self; return fic_w_p(make_adder(k.i)); }
static const fic_code curry_code = { (void (*)(void))curry_entry, 1u };
static fic_clo curry_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &curry_code };

/* arity 2 returning a closure of arity 1: \a b -> sub3 a b */
static fic_word pair_entry(fic_ref self, fic_word a, fic_word b) { (void)self; return fic_w_p(fic_ap2(&sub3_clo.h, 0, a, b).p); }
static const fic_code pair_code = { (void (*)(void))pair_entry, 2u };
static fic_clo pair_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &pair_code };

int main(void) {
  fic_ref f1 = &inc_clo.h, f2 = &add_clo.h, f3 = &sub3_clo.h, f4 = &mix4_clo.h, cu = &curry_clo.h;
  /* arity equals the number of arguments */
  CHECK(fic_ap1(f1, 0, fic_w_i(41)).i == 42);
  CHECK(fic_ap2(f2, 0, fic_w_i(40), fic_w_i(2)).i == 42);
  CHECK(fic_ap3(f3, 0, fic_w_i(50), fic_w_i(5), fic_w_i(3)).i == 42);
  CHECK(fic_ap4(f4, 0, fic_w_i(1), fic_w_d(0.5), fic_w_c(3), fic_w_b(1)).d == 5.5);
  /* fewer arguments than the arity: a partial application, then the rest */
  { fic_ref p = fic_ap1(f2, 0, fic_w_i(40)).p;                       /* add 40 */
    CHECK(FIC_CLO(p)->code->arity == 1u);
    CHECK(fic_ap1(p, 0, fic_w_i(2)).i == 42);
    CHECK(fic_ap1(p, 0, fic_w_i(5)).i == 45); }                      /* a partial application is reusable */
  { fic_ref p = fic_ap1(f3, 0, fic_w_i(50)).p;                       /* sub3 50 : arity 2 */
    fic_ref q = fic_ap1(p, 0, fic_w_i(5)).p;                         /* then sub3 50 5 : arity 1 */
    CHECK(FIC_CLO(p)->code->arity == 2u && FIC_CLO(q)->code->arity == 1u);
    CHECK(fic_ap1(q, 0, fic_w_i(3)).i == 42);
    CHECK(fic_ap2(p, 0, fic_w_i(5), fic_w_i(3)).i == 42); }
  { fic_ref p = fic_ap2(f3, 0, fic_w_i(50), fic_w_i(5)).p;           /* two of three at once */
    CHECK(FIC_CLO(p)->code->arity == 1u && fic_ap1(p, 0, fic_w_i(3)).i == 42); }
  { fic_ref p = fic_ap3(f4, 0, fic_w_i(1), fic_w_d(0.5), fic_w_c(3)).p;   /* mixed classes in a partial application */
    CHECK(fic_ap1(p, 0, fic_w_b(1)).d == 5.5); }
  /* more arguments than the arity: call with the first ones, apply the result to the rest */
  CHECK(fic_ap2(cu, 0, fic_w_i(40), fic_w_i(2)).i == 42);            /* curry 40 2 */
  CHECK(fic_ap3(&pair_clo.h, 0, fic_w_i(50), fic_w_i(5), fic_w_i(3)).i == 42);   /* arity 2 returning arity 1, 3 arguments */
  /* a partial application of a closure with a captured value, applied through a different number of arguments */
  { fic_ref a = make_adder(40);
    CHECK(fic_ap1(a, 0, fic_w_i(2)).i == 42); }
  if (failures) { printf("%d failure(s)\n", failures); return 1; }
  printf("closure tests ok\n");
  return 0;
}
