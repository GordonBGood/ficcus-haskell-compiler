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

