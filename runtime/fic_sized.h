/* Sized integers and Float32 (G24, G41; docs/SIZED-PLAN.md). Emitted only by programs that use them (CGen: the text `fic_sz_`).
   Needs the prelude (fic_rt.h, fic_num.h, fic_format.h, fic_debug.h).

   An IntN or WordN value is an int64_t that holds the sign or zero extended value, so `toInt` is free and a value fits the 8 byte slot
   of Int. Every operation computes in uint64_t (no signed overflow anywhere) and normalizes the result with explicit casts, so the
   arithmetic wraps in two's complement. Word64 holds its bits in the int64_t and orders, divides and prints as unsigned.
   Float32 is a double that always holds exactly a float: a result is rounded with (double)(float)(...), which is correctly rounded
   for + - * / (a double has more than twice the precision of a float). Needs -ffp-contract=off as the rest of the output. */

static int fic_sz_popcount(uint64_t x) {
  x = x - ((x >> 1) & 0x5555555555555555ull);
  x = (x & 0x3333333333333333ull) + ((x >> 2) & 0x3333333333333333ull);
  x = (x + (x >> 4)) & 0x0f0f0f0f0f0f0f0full;
  return (int)((x * 0x0101010101010101ull) >> 56);
}

/* b ^ e with wrapping; `sgn` says that the exponent is signed: a negative one gives the truncated integer result (decision L4) */
static uint64_t fic_sz_pow(int64_t b, int64_t e, int sgn) {
  uint64_t r = 1, bb = (uint64_t)b, ue = (uint64_t)e;
  if (sgn && e < 0) return b == 1 ? 1u : (b == -1 ? ((e & 1) ? (uint64_t)-1 : 1u) : 0u);
  while (ue > 0) { if (ue & 1) r = r * bb; bb = bb * bb; ue >>= 1; }
  return r;
}

static fic_ref fic_sz_u64_str(int64_t v) {
  char buf[32];
  int n = snprintf(buf, sizeof buf, "%llu", (unsigned long long)(uint64_t)v);
  return fic_str_new(buf, n);
}

/* T: tag; WRAP: normalization of a uint64_t; BITS; SGN: signed; DT: type of the division and the order; MASK: bits of the width */
#define FIC_SZ_DEFINE(T, WRAP, BITS, SGN, DT, MASK, TOSTR) \
static int64_t fic_sz_##T##_fromint(int64_t n) { return WRAP((uint64_t)n); } \
static int64_t fic_sz_##T##_toint(int64_t a) { return a; } \
static int64_t fic_sz_##T##_add(int64_t a, int64_t b) { return WRAP((uint64_t)a + (uint64_t)b); } \
static int64_t fic_sz_##T##_sub(int64_t a, int64_t b) { return WRAP((uint64_t)a - (uint64_t)b); } \
static int64_t fic_sz_##T##_mul(int64_t a, int64_t b) { return WRAP((uint64_t)a * (uint64_t)b); } \
static int64_t fic_sz_##T##_pow(int64_t a, int64_t b) { return WRAP(fic_sz_pow(a, b, SGN)); } \
static int64_t fic_sz_##T##_neg(int64_t a) { return WRAP(0u - (uint64_t)a); } \
static int64_t fic_sz_##T##_abs(int64_t a) { return (SGN && a < 0) ? WRAP(0u - (uint64_t)a) : a; } \
static int64_t fic_sz_##T##_idiv(int64_t a, int64_t b) { return b == 0 ? 0 : WRAP((uint64_t)(DT)((DT)a / (DT)b)); } \
static int64_t fic_sz_##T##_mod(int64_t m, int64_t x) { \
  if (m == 0 || (SGN && m == -1)) return 0; \
  if (!SGN) return WRAP((uint64_t)((DT)x % (DT)m)); \
  { int64_t r = x % m; return ((r > 0 && m < 0) || (r < 0 && m > 0)) ? WRAP((uint64_t)r + (uint64_t)m) : r; } } \
static int64_t fic_sz_##T##_rem(int64_t m, int64_t x) { \
  if (m == 0 || (SGN && m == -1)) return 0; \
  return WRAP((uint64_t)((DT)x % (DT)m)); } \
static int64_t fic_sz_##T##_and(int64_t a, int64_t b) { return WRAP((uint64_t)a & (uint64_t)b); } \
static int64_t fic_sz_##T##_or(int64_t a, int64_t b) { return WRAP((uint64_t)a | (uint64_t)b); } \
static int64_t fic_sz_##T##_xor(int64_t a, int64_t b) { return WRAP((uint64_t)a ^ (uint64_t)b); } \
static int64_t fic_sz_##T##_not(int64_t a) { return WRAP(~(uint64_t)a); } \
static int64_t fic_sz_##T##_shl(int64_t n, int64_t a) { return WRAP((uint64_t)a << (n & (BITS - 1))); } \
static int64_t fic_sz_##T##_shr(int64_t n, int64_t a) { \
  int s = (int)(n & (BITS - 1)); \
  if (SGN && a < 0) return (int64_t)~(~(uint64_t)a >> s); \
  return (int64_t)((uint64_t)a >> s); } \
static int64_t fic_sz_##T##_popcount(int64_t a) { return fic_sz_popcount((uint64_t)a & MASK); } \
static uint8_t fic_sz_##T##_lt(int64_t a, int64_t b) { return (DT)a < (DT)b; } \
static uint8_t fic_sz_##T##_le(int64_t a, int64_t b) { return (DT)a <= (DT)b; } \
static uint8_t fic_sz_##T##_gt(int64_t a, int64_t b) { return (DT)a > (DT)b; } \
static uint8_t fic_sz_##T##_ge(int64_t a, int64_t b) { return (DT)a >= (DT)b; } \
static int fic_sz_##T##_cmp(int64_t a, int64_t b) { return (DT)a < (DT)b ? -1 : (DT)a > (DT)b ? 1 : 0; } \
static fic_ref fic_sz_##T##_tostr(int64_t a) { return TOSTR(a); } \
static void fic_sz_##T##_show(fic_sb *b, int64_t a) { fic_ref s = TOSTR(a); fic_sb_putn(b, FIC_STR(s)->data, FIC_STR(s)->len); FIC_RC_DROP(s); }

#define FIC_SZ_W_I8(x) ((int64_t)(int8_t)(uint8_t)(x))
#define FIC_SZ_W_I16(x) ((int64_t)(int16_t)(uint16_t)(x))
#define FIC_SZ_W_I32(x) ((int64_t)(int32_t)(uint32_t)(x))
#define FIC_SZ_W_U8(x) ((int64_t)(uint8_t)(x))
#define FIC_SZ_W_U16(x) ((int64_t)(uint16_t)(x))
#define FIC_SZ_W_U32(x) ((int64_t)(uint32_t)(x))
#define FIC_SZ_W_U64(x) ((int64_t)(uint64_t)(x))

FIC_SZ_DEFINE(i8, FIC_SZ_W_I8, 8, 1, int64_t, 0xffull, fic_str_from_int)
FIC_SZ_DEFINE(i16, FIC_SZ_W_I16, 16, 1, int64_t, 0xffffull, fic_str_from_int)
FIC_SZ_DEFINE(i32, FIC_SZ_W_I32, 32, 1, int64_t, 0xffffffffull, fic_str_from_int)
FIC_SZ_DEFINE(u8, FIC_SZ_W_U8, 8, 0, int64_t, 0xffull, fic_str_from_int)
FIC_SZ_DEFINE(u16, FIC_SZ_W_U16, 16, 0, int64_t, 0xffffull, fic_str_from_int)
FIC_SZ_DEFINE(u32, FIC_SZ_W_U32, 32, 0, int64_t, 0xffffffffull, fic_str_from_int)
FIC_SZ_DEFINE(u64, FIC_SZ_W_U64, 64, 0, uint64_t, 0xffffffffffffffffull, fic_sz_u64_str)

/* Float32: the value is a double that is exactly a float */
#define FIC_SZ_F32(x) ((double)(float)(x))
static double fic_sz_f32_fromint(int64_t n) { return (double)(float)n; }
static double fic_sz_f32_fromfloat(double d) { return (double)(float)d; }
static double fic_sz_f32_tofloat(double a) { return a; }
static double fic_sz_f32_add(double a, double b) { return FIC_SZ_F32(a + b); }
static double fic_sz_f32_sub(double a, double b) { return FIC_SZ_F32(a - b); }
static double fic_sz_f32_mul(double a, double b) { return FIC_SZ_F32(a * b); }
static double fic_sz_f32_div(double a, double b) { return FIC_SZ_F32(a / b); }
static double fic_sz_f32_neg(double a) { return -a; }
static double fic_sz_f32_abs(double a) { return a < 0 ? -a : (a == 0 ? 0.0 : a); }
static int fic_sz_f32_cmp(double a, double b) { return a == b ? 0 : a < b ? -1 : 1; }      /* as Float: a NaN gives GT */

/* a Float32 as JavaScript prints a Number, with the shortest digits that read back as the same float */
static int fic_sz_fmt_f32(double xd, char *out) {
  char e[40], t[48], digits[32];
  int p, k = 0, n, exp10 = 0, o = 0, i;
  float x = (float)xd;
  if (x != x) return sprintf(out, "NaN");
  if (x == 0) return sprintf(out, "0");
  if (x > 3.4028234663852886e38f) return sprintf(out, "Infinity");
  if (x < -3.4028234663852886e38f) return sprintf(out, "-Infinity");
  if (x < 0) { out[o++] = '-'; x = -x; }
  for (p = 0; p < 9; p++) {
    unsigned long long d; int ex, dl, delta, found = 0;
    snprintf(e, sizeof e, "%.*e", p, (double)x);
    for (i = 0, d = 0; e[i] != 'e'; i++) if (e[i] != '.') d = d * 10 + (unsigned long long)(e[i] - '0');
    ex = atoi(e + i + 1);
    for (delta = 0; delta != 2 && !found; delta = (delta == 0 ? -1 : delta == -1 ? 1 : 2)) {
      unsigned long long d2 = d + (unsigned long long)(long long)delta;
      if (d2 == 0) continue;
      snprintf(t, sizeof t, "%llue%d", d2, ex - p);
      if (strtof(t, NULL) == x) {
        dl = snprintf(digits, sizeof digits, "%llu", d2);
        k = dl; exp10 = ex + (dl - (p + 1)); found = 1;
      }
    }
    if (found) break;
  }
  while (k > 1 && digits[k - 1] == '0') k--;
  n = exp10 + 1;
  if (k <= n && n <= 21) {
    memcpy(out + o, digits, (size_t)k); o += k;
    for (i = 0; i < n - k; i++) out[o++] = '0';
  } else if (0 < n && n <= 21) {
    memcpy(out + o, digits, (size_t)n); o += n; out[o++] = '.';
    memcpy(out + o, digits + n, (size_t)(k - n)); o += k - n;
  } else if (-6 < n && n <= 0) {
    out[o++] = '0'; out[o++] = '.';
    for (i = 0; i < -n; i++) out[o++] = '0';
    memcpy(out + o, digits, (size_t)k); o += k;
  } else {
    out[o++] = digits[0];
    if (k > 1) { out[o++] = '.'; memcpy(out + o, digits + 1, (size_t)(k - 1)); o += k - 1; }
    o += sprintf(out + o, "e%c%d", n - 1 < 0 ? '-' : '+', n - 1 < 0 ? 1 - n : n - 1);
  }
  out[o] = 0;
  return o;
}
static fic_ref fic_sz_f32_tostr(double x) { char buf[64]; int n = fic_sz_fmt_f32(x, buf); return fic_str_new(buf, n); }
static void fic_sz_f32_show(fic_sb *b, double x) { fic_ref s = fic_sz_f32_tostr(x); fic_sb_putn(b, FIC_STR(s)->data, FIC_STR(s)->len); FIC_RC_DROP(s); }
