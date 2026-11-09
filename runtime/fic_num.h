static int64_t fic_idiv(int64_t a, int64_t b) {         /* Elm: x // 0 is 0; wraps like every Int operation */
  if (b == 0) return 0;
  if (b == -1) return FIC_NEG64(a);
  return a / b;
}

static int64_t fic_ipow(int64_t b, int64_t e) {         /* Int ^ Int by repeated squaring, wrapping */
  int64_t r = 1;
  if (e < 0) return 0;
  while (e > 0) { if (e & 1) r = FIC_MUL64(r, b); b = FIC_MUL64(b, b); e >>= 1; }
  return r;
}

/* Float comparison as Elm's kernel does it: cmp(x, y) = x === y ? 0 : x < y ? -1 : 1, so NaN compares as GT */
static uint8_t fic_f_lt(double a, double b) { return a < b; }
static uint8_t fic_f_le(double a, double b) { return a < b || a == b; }
static uint8_t fic_f_gt(double a, double b) { return !(a < b || a == b); }
static uint8_t fic_f_ge(double a, double b) { return !(a < b); }


/* Bitwise exactly as Elm (JavaScript): operands truncated to signed 32 bit, result signed 32 bit, shift count & 31;
   shiftRightZfBy gives the unsigned 32 bit result (0 .. 4294967295) */
static int32_t fic_i32(int64_t a) { return (int32_t)(uint32_t)(uint64_t)a; }
static int64_t fic_bw_and(int64_t a, int64_t b) { return (int64_t)(int32_t)((uint32_t)fic_i32(a) & (uint32_t)fic_i32(b)); }
static int64_t fic_bw_or(int64_t a, int64_t b) { return (int64_t)(int32_t)((uint32_t)fic_i32(a) | (uint32_t)fic_i32(b)); }
static int64_t fic_bw_xor(int64_t a, int64_t b) { return (int64_t)(int32_t)((uint32_t)fic_i32(a) ^ (uint32_t)fic_i32(b)); }
static int64_t fic_bw_not(int64_t a) { return (int64_t)(int32_t)(~(uint32_t)fic_i32(a)); }
static int64_t fic_bw_shl(int64_t n, int64_t a) { return (int64_t)(int32_t)((uint32_t)fic_i32(a) << (n & 31)); }
static int64_t fic_bw_shr(int64_t n, int64_t a) { int32_t x = fic_i32(a); int s = (int)(n & 31); return (int64_t)(x < 0 ? ~(~x >> s) : x >> s); }
static int64_t fic_bw_shrz(int64_t n, int64_t a) { return (int64_t)((uint32_t)fic_i32(a) >> (n & 31)); }

/* Bitwise64 (name provisional): the same on the full 64 bit Int, shift count & 63; shiftRightZfBy is a logical shift
   whose result wraps to the signed 64 bit Int */
static int64_t fic_bw64_and(int64_t a, int64_t b) { return (int64_t)((uint64_t)a & (uint64_t)b); }
static int64_t fic_bw64_or(int64_t a, int64_t b) { return (int64_t)((uint64_t)a | (uint64_t)b); }
static int64_t fic_bw64_xor(int64_t a, int64_t b) { return (int64_t)((uint64_t)a ^ (uint64_t)b); }
static int64_t fic_bw64_not(int64_t a) { return (int64_t)(~(uint64_t)a); }
static int64_t fic_bw64_shl(int64_t n, int64_t a) { return (int64_t)((uint64_t)a << (n & 63)); }
static int64_t fic_bw64_shr(int64_t n, int64_t a) { int s = (int)(n & 63); return a < 0 ? (int64_t)~(~(uint64_t)a >> s) : (int64_t)((uint64_t)a >> s); }
static int64_t fic_bw64_shrz(int64_t n, int64_t a) { return (int64_t)((uint64_t)a >> (n & 63)); }

/* compare as Elm's kernel: cmp(x, y) = x === y ? 0 : x < y ? -1 : 1 (a NaN gives 1); Int and Char never need the NaN case */
static int fic_f_cmp(double a, double b) { return a == b ? 0 : a < b ? -1 : 1; }
static int fic_i_cmp(int64_t a, int64_t b) { return a < b ? -1 : a > b ? 1 : 0; }

/* `==` on two different functions: Elm's runtime error (`_Debug_crash(5)`, the text of a development build) */
static void fic_panic_eq_fun(void) {
  fputs("Trying to use `(==)` on functions.\nThere is no way to know if functions are \"the same\" in the Elm sense.\nRead more about this at https://package.elm-lang.org/packages/elm/core/latest/Basics#== which describes why it is this way and what the better version will look like.\n", stderr);
  exit(1);
}

/* modBy and remainderBy: floored and truncated remainders; a zero divisor gives 0 (decision L1, Elm crashes or gives NaN) */
static int64_t fic_modby(int64_t m, int64_t x) {
  int64_t r;
  if (m == 0 || m == -1) return 0;
  r = x % m;
  return ((r > 0 && m < 0) || (r < 0 && m > 0)) ? r + m : r;
}
static int64_t fic_remby(int64_t m, int64_t x) {
  if (m == 0 || m == -1) return 0;
  return x % m;
}
