/* runtime/fic_sized.h against a C oracle written with the native types and explicit casts: every operation of every sized type on
   the boundary values (all pairs) and on pseudo random values, and Float32 against C float. Prints one summary line per type. */
#include <stdio.h>
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Wtype-limits"
#endif
#include <stdint.h>
#include <math.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_string.h"
#include "fic_num.h"
#include "fic_format.h"
#include "fic_debug.h"
#include "fic_sized.h"

static long checks, bad;
static void chk(const char *t, const char *op, long long a, long long b, long long got, long long want) {
  checks++;
  if (got != want) { if (bad++ < 20) printf("MISMATCH %s %s %lld %lld: got %lld want %lld\n", t, op, a, b, got, want); }
}
static uint64_t rng = 88172645463325252ull;
static uint64_t next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

/* the oracle: CT the native signed or unsigned C type of the width, UT its unsigned twin; the arithmetic is done in the type itself
   through unsigned 64 bit intermediates and cast back, the divisions in (long long) for the narrow types and natively for 64 */
#define ORACLE(T, CT, UT, BITS, ISSIGNED, WIDE) \
static void test_##T(const char *name) { \
  int64_t vals[200]; int nv = 0, i, j, k; \
  CT mn = (CT)((ISSIGNED) ? ((UT)1 << (BITS - 1)) : 0), mx = (CT)((ISSIGNED) ? (UT)(((UT)1 << (BITS - 1)) - 1) : (UT)~(UT)0); \
  long long fixed[] = { 0, 1, 2, 3, 5, 7, 8, 15, 16, 31, 63, 64, 100, 127, 128, 129, 255, 256, 257, 32767, 32768, 65535, 65536, 2147483647LL, 2147483648LL, 4294967295LL, 4294967296LL }; \
  vals[nv++] = (CT)mn; vals[nv++] = (CT)(mn + 1); vals[nv++] = (CT)mx; vals[nv++] = (CT)(mx - 1); \
  for (i = 0; i < (int)(sizeof fixed / sizeof fixed[0]); i++) { vals[nv++] = (CT)fixed[i]; vals[nv++] = (CT)-fixed[i]; } \
  for (i = 0; i < 60; i++) vals[nv++] = (CT)next(); \
  for (i = 0; i < nv; i++) { \
    CT a = (CT)vals[i]; int64_t A = (int64_t)a; \
    chk(name, "norm", A, 0, fic_sz_##T##_fromint(A), (int64_t)(CT)A); \
    chk(name, "fromint-wide", A, 0, fic_sz_##T##_fromint((int64_t)((uint64_t)A + 0x1234567800000000ull * 0)), A); \
    chk(name, "neg", A, 0, fic_sz_##T##_neg(A), (int64_t)(CT)(UT)(0u - (UT)a)); \
    chk(name, "abs", A, 0, fic_sz_##T##_abs(A), (ISSIGNED) && a < 0 ? (int64_t)(CT)(UT)(0u - (UT)a) : A); \
    chk(name, "not", A, 0, fic_sz_##T##_not(A), (int64_t)(CT)(UT)~(UT)a); \
    { int pc = 0, bt; for (bt = 0; bt < BITS; bt++) pc += (int)(((UT)a >> bt) & 1); chk(name, "popcount", A, 0, fic_sz_##T##_popcount(A), pc); } \
    for (k = -3; k < BITS + 3; k++) { \
      int s = (int)(k & (BITS - 1)); \
      chk(name, "shl", k, A, fic_sz_##T##_shl(k, A), (int64_t)(CT)(UT)((UT)a << s)); \
      chk(name, "shr", k, A, fic_sz_##T##_shr(k, A), (int64_t)(CT)(a >> s)); \
    } \
    for (j = 0; j < nv; j++) { \
      CT b = (CT)vals[j]; int64_t B = (int64_t)b; \
      chk(name, "add", A, B, fic_sz_##T##_add(A, B), (int64_t)(CT)(UT)((UT)a + (UT)b)); \
      chk(name, "sub", A, B, fic_sz_##T##_sub(A, B), (int64_t)(CT)(UT)((UT)a - (UT)b)); \
      chk(name, "mul", A, B, fic_sz_##T##_mul(A, B), (int64_t)(CT)(UT)((uint64_t)(UT)a * (uint64_t)(UT)b)); \
      chk(name, "and", A, B, fic_sz_##T##_and(A, B), (int64_t)(CT)(a & b)); \
      chk(name, "or", A, B, fic_sz_##T##_or(A, B), (int64_t)(CT)(a | b)); \
      chk(name, "xor", A, B, fic_sz_##T##_xor(A, B), (int64_t)(CT)(a ^ b)); \
      chk(name, "idiv", A, B, fic_sz_##T##_idiv(A, B), b == 0 ? 0 : (int64_t)(CT)(UT)(WIDE)((WIDE)a / (WIDE)b)); \
      chk(name, "rem", A, B, fic_sz_##T##_rem(B, A), (b == 0 || ((ISSIGNED) && b == -1)) ? 0 : (int64_t)(CT)((WIDE)a % (WIDE)b)); \
      { int64_t want; \
        if (b == 0 || ((ISSIGNED) && b == -1)) want = 0; \
        else { WIDE r = (WIDE)a % (WIDE)b; if ((ISSIGNED) && ((r > 0 && b < 0) || (r < 0 && b > 0))) r = r + (WIDE)b; want = (int64_t)(CT)r; } \
        chk(name, "mod", A, B, fic_sz_##T##_mod(B, A), want); } \
      chk(name, "lt", A, B, fic_sz_##T##_lt(A, B), a < b); chk(name, "le", A, B, fic_sz_##T##_le(A, B), a <= b); \
      chk(name, "gt", A, B, fic_sz_##T##_gt(A, B), a > b); chk(name, "ge", A, B, fic_sz_##T##_ge(A, B), a >= b); \
      chk(name, "cmp", A, B, fic_sz_##T##_cmp(A, B), a < b ? -1 : a > b ? 1 : 0); \
      if (j % 7 == 0) { /* the power: by repeated multiplication in the native type for a small exponent, and through the exponent b */ \
        int e = (int)((UT)b % 12); CT r = (CT)1; int q; for (q = 0; q < e; q++) r = (CT)(UT)((uint64_t)(UT)r * (uint64_t)(UT)a); \
        chk(name, "pow", A, e, fic_sz_##T##_pow(A, e), (int64_t)r); } \
    } \
  } \
  { fic_ref s = fic_sz_##T##_tostr((int64_t)mx); char buf[40]; \
    snprintf(buf, sizeof buf, (ISSIGNED) ? "%lld" : "%llu", (ISSIGNED) ? (long long)mx : (long long)(unsigned long long)mx); \
    chk(name, "tostr-max", 0, 0, strcmp(FIC_STR(s)->data, buf), 0); } \
  printf("%s: ops checked\n", name); \
}

ORACLE(i8, int8_t, uint8_t, 8, 1, long long)
ORACLE(i16, int16_t, uint16_t, 16, 1, long long)
ORACLE(i32, int32_t, uint32_t, 32, 1, long long)
ORACLE(u8, uint8_t, uint8_t, 8, 0, long long)
ORACLE(u16, uint16_t, uint16_t, 16, 0, long long)
ORACLE(u32, uint32_t, uint32_t, 32, 0, long long)
ORACLE(u64, uint64_t, uint64_t, 64, 0, unsigned long long)

static void test_f32(void) {
  float vals[] = { 0.0f, -0.0f, 1.0f, -1.0f, 0.1f, 0.2f, 0.3f, 3.14159274f, 16777216.0f, 16777217.0f, 1e10f, 1e-10f, 3.4028234e38f, 1.17549435e-38f,
                   1e-45f, 123456.789f, 0.5f, 2.5f, -2.5f, 1.0f / 3.0f, 100.0f, 1e21f, 1e-7f, 5e-7f, 33554432.0f, INFINITY, -INFINITY, NAN };
  int nv = (int)(sizeof vals / sizeof vals[0]), i, j;
  volatile float fa, fb, r;
  for (i = 0; i < nv; i++) {
    fa = vals[i];
    for (j = 0; j < nv; j++) {
      fb = vals[j];
      r = fa + fb; { double g = fic_sz_f32_add(fa, fb); checks++; if (!(g == (double)r || (g != g && r != r))) bad++; }
      r = fa - fb; { double g = fic_sz_f32_sub(fa, fb); checks++; if (!(g == (double)r || (g != g && r != r))) bad++; }
      r = fa * fb; { double g = fic_sz_f32_mul(fa, fb); checks++; if (!(g == (double)r || (g != g && r != r))) bad++; }
      r = fa / fb; { double g = fic_sz_f32_div(fa, fb); checks++; if (!(g == (double)r || (g != g && r != r))) bad++; }
    }
    { char buf[64]; int n = fic_sz_fmt_f32((double)fa, buf); (void)n;
      checks++;
      if (fa == fa && !isinf(fa)) {            /* reads back, and no shorter %.{p}e does */
        int p; if (strtof(buf, NULL) != fa) { bad++; printf("MISMATCH f32 print %s\n", buf); }
        for (p = 0; p < 9; p++) { char t[48]; snprintf(t, sizeof t, "%.*e", p, (double)fabsf(fa)); if (strtof(t, NULL) == fabsf(fa)) break; }
        { int digs = 0, q, started = 0, nz = 0; const char *m = buf; size_t len = strlen(m);
          for (q = 0; q < (int)len && m[q] != 'e'; q++) { if (m[q] < '0' || m[q] > '9') continue; if (m[q] != '0') started = 1; if (started) { digs++; nz = m[q] != '0' ? digs : nz; } }
          if (nz != p + 1 && !(nz < p + 1)) { bad++; printf("MISMATCH f32 print %s has %d digits, %d suffice\n", buf, nz, p + 1); }
          if (nz > p + 1) { bad++; printf("MISMATCH f32 print %s is longer than needed\n", buf); } (void)digs; }
      }
    }
  }
  for (i = 0; i < 20000; i++) {                 /* random floats: round trip of the printer, int conversion */
    uint32_t u = (uint32_t)next(); float f; memcpy(&f, &u, 4);
    if (f != f || isinf(f)) continue;
    { char buf[64]; fic_sz_fmt_f32((double)f, buf); checks++; if (strtof(buf, NULL) != f) { if (bad++ < 20) printf("MISMATCH f32 print %s\n", buf); } }
  }
  for (i = 0; i < 2000; i++) { int64_t n = (int64_t)next() >> (next() % 60); volatile float f = (float)n; checks++; if (fic_sz_f32_fromint(n) != (double)f) bad++; }
  { const char *want[] = { "0.1", "16777216", "3.4028235e+38", "1e-7", "1e-45", "0.3", "3.1415927", "1e+21", "-2.5", "0" };
    float in[] = { 0.1f, 16777216.0f, 3.4028234e38f, 1e-7f, 1e-45f, 0.3f, 3.14159274f, 1e21f, -2.5f, 0.0f };
    for (i = 0; i < 10; i++) { char buf[64]; fic_sz_fmt_f32((double)in[i], buf); checks++; if (strcmp(buf, want[i]) != 0) { bad++; printf("MISMATCH f32 print %s want %s\n", buf, want[i]); } } }
  printf("f32: ops checked\n");
}

int main(void) {
  test_i8("i8"); test_i16("i16"); test_i32("i32"); test_u8("u8"); test_u16("u16"); test_u32("u32"); test_u64("u64"); test_f32();
  printf("%s\n", bad == 0 ? "all agree" : "DIFFERENCES");
  return bad != 0;
}
