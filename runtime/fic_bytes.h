/* The kernel of elm/bytes (Bytes, Bytes.Encode, Bytes.Decode), decisions L23 and L29; STAGE4-PLAN section 8. Emitted only into
   programs that use a fic_bytes_ function (after fic_ustring.h).

   A `Bytes` value is an immutable raw vector (fic_vec, FIC_TAG_VEC_RAW, element size 1). `Bytes.Encode.encode` walks the `Encoder`
   value (an ordinary Elm custom type, the layouts are below) and writes a new vector. The readers of `Bytes.Decode` take the bytes
   and an offset and give the new offset and the value; a read that fails (not enough bytes, text that is not UTF-8: L23) gives the
   offset -1: the combinators of overlay/FicOverlayBytes.elm test it, so a failed decode needs no exception and frees everything.

   Ownership: every Bytes, Encoder and String argument is BORROWED; results are owned (new objects). */

static fic_ref fic_bytes_new(int64_t n) {
  fic_ref v = fic_vec_new(n < 1 ? 1 : n, 1, FIC_TAG_VEC_RAW);
  FIC_VEC(v)->len = n;
  return v;
}

static int64_t fic_bytes_width(fic_ref b) { return FIC_VEC(b)->len; }

static uint8_t fic_bytes_eq(fic_ref a, fic_ref b) {
  return FIC_VEC(a)->len == FIC_VEC(b)->len && memcmp(FIC_VEC(a)->data, FIC_VEC(b)->data, (size_t)FIC_VEC(a)->len) == 0;
}

/* Bytes.Encode.getStringWidth: the number of bytes of the UTF-8 text */
static int64_t fic_bytes_string_width(fic_ref s) { return FIC_STR(s)->len; }

/* ---- Bytes.Encode.encode ----
   type Encoder = I8 Int | I16 Endianness Int | I32 Endianness Int | U8 Int | U16 Endianness Int | U32 Endianness Int
                | F32 Endianness Float | F64 Endianness Float | Seq Int (List Encoder) | Utf8 Int String | Bytes Bytes
   (tags 0 to 10; Endianness is the enumeration LE = 0, BE = 1; the reference words of an object come first) */
typedef struct fic_bytes_en { fic_hdr h; int64_t s0; } fic_bytes_en;                 /* I8, U8 */
typedef struct fic_bytes_een { fic_hdr h; uint8_t s0; int64_t s1; } fic_bytes_een;   /* I16, I32, U16, U32 */
typedef struct fic_bytes_eef { fic_hdr h; uint8_t s0; double s1; } fic_bytes_eef;    /* F32, F64 */
typedef struct fic_bytes_ewr { fic_hdr h; fic_ref r0; int64_t s0; } fic_bytes_ewr;   /* Seq, Utf8 */
typedef struct fic_bytes_er { fic_hdr h; fic_ref r0; } fic_bytes_er;                 /* Bytes */
typedef struct fic_bytes_cell { fic_hdr h; fic_ref f0; fic_ref f1; } fic_bytes_cell; /* a cell of a List Encoder */

static int64_t fic_bytes_enc_width(fic_ref e) {
  switch (e->tag) {
  case 0u: case 3u: return 1;
  case 1u: case 4u: return 2;
  case 2u: case 5u: case 6u: return 4;
  case 7u: return 8;
  case 8u: {
    int64_t w = 0;
    fic_ref p;
    for (p = ((fic_bytes_ewr *)e)->r0; p->tag != 0u; p = ((fic_bytes_cell *)p)->f1) w += fic_bytes_enc_width(((fic_bytes_cell *)p)->f0);
    return w; }
  case 9u: return FIC_STR(((fic_bytes_ewr *)e)->r0)->len;
  default: return FIC_VEC(((fic_bytes_er *)e)->r0)->len;
  }
}

static unsigned char *fic_bytes_put(unsigned char *p, uint64_t v, int n, int le) {
  int i;
  for (i = 0; i < n; i++) p[le ? i : n - 1 - i] = (unsigned char)(v >> (8 * i));
  return p + n;
}

/* a double as the nearest single (round to nearest even; beyond the range: an infinity) */
static float fic_bytes_to_f32(double x) {
  if (x != x) return (float)x;
  if (x >= 3.4028235677973366e38) return (float)HUGE_VAL;             /* FLT_MAX plus half a step and above */
  if (x <= -3.4028235677973366e38) return (float)-HUGE_VAL;
  if (x > 3.4028234663852886e38) return 3.4028234663852886e38f;
  if (x < -3.4028234663852886e38) return -3.4028234663852886e38f;
  return (float)x;
}

static unsigned char *fic_bytes_enc_write(fic_ref e, unsigned char *p) {
  switch (e->tag) {
  case 0u: case 3u: return fic_bytes_put(p, (uint64_t)((fic_bytes_en *)e)->s0, 1, 1);
  case 1u: case 4u: return fic_bytes_put(p, (uint64_t)((fic_bytes_een *)e)->s1, 2, ((fic_bytes_een *)e)->s0 == 0);
  case 2u: case 5u: return fic_bytes_put(p, (uint64_t)((fic_bytes_een *)e)->s1, 4, ((fic_bytes_een *)e)->s0 == 0);
  case 6u: {
    float f = fic_bytes_to_f32(((fic_bytes_eef *)e)->s1);
    uint32_t u;
    memcpy(&u, &f, 4);
    return fic_bytes_put(p, u, 4, ((fic_bytes_eef *)e)->s0 == 0); }
  case 7u: {
    uint64_t u;
    memcpy(&u, &((fic_bytes_eef *)e)->s1, 8);
    return fic_bytes_put(p, u, 8, ((fic_bytes_eef *)e)->s0 == 0); }
  case 8u: {
    fic_ref q;
    for (q = ((fic_bytes_ewr *)e)->r0; q->tag != 0u; q = ((fic_bytes_cell *)q)->f1) p = fic_bytes_enc_write(((fic_bytes_cell *)q)->f0, p);
    return p; }
  case 9u: {
    fic_ref s = ((fic_bytes_ewr *)e)->r0;
    if (FIC_STR(s)->len > 0) memcpy(p, FIC_STR(s)->data, (size_t)FIC_STR(s)->len);
    return p + FIC_STR(s)->len; }
  default: {
    fic_ref b = ((fic_bytes_er *)e)->r0;
    if (FIC_VEC(b)->len > 0) memcpy(p, FIC_VEC(b)->data, (size_t)FIC_VEC(b)->len);
    return p + FIC_VEC(b)->len; }
  }
}

static fic_ref fic_bytes_encode(fic_ref e) {
  fic_ref r = fic_bytes_new(fic_bytes_enc_width(e));
  fic_bytes_enc_write(e, FIC_VEC(r)->data);
  return r;
}

/* ---- Bytes.Decode: the readers. Each returns the offset after the value, or -1 when the read fails ---- */

/* an integer of n bytes (1, 2 or 4) */
static int64_t fic_bytes_read_int(int n, int is_signed, uint8_t le, fic_ref bs, int64_t off, int64_t *out) {
  const unsigned char *d = FIC_VEC(bs)->data;
  uint64_t v = 0;
  int i;
  *out = 0;
  if (off < 0 || off > FIC_VEC(bs)->len - n) return -1;
  for (i = 0; i < n; i++) v |= (uint64_t)d[off + (le ? i : n - 1 - i)] << (8 * i);
  if (is_signed && ((v >> (8 * n - 1)) & 1u)) *out = (int64_t)v - ((int64_t)1 << (8 * n));
  else *out = (int64_t)v;
  return off + n;
}

static int64_t fic_bytes_read_f32(uint8_t le, fic_ref bs, int64_t off, double *out) {
  int64_t v;
  uint32_t u;
  float f;
  *out = 0;
  if (fic_bytes_read_int(4, 0, le, bs, off, &v) < 0) return -1;
  u = (uint32_t)v;
  memcpy(&f, &u, 4);
  *out = (double)f;
  return off + 4;
}

static int64_t fic_bytes_read_f64(uint8_t le, fic_ref bs, int64_t off, double *out) {
  const unsigned char *d = FIC_VEC(bs)->data;
  uint64_t v = 0;
  int i;
  *out = 0;
  if (off < 0 || off > FIC_VEC(bs)->len - 8) return -1;
  for (i = 0; i < 8; i++) v |= (uint64_t)d[off + (le ? i : 7 - i)] << (8 * i);
  memcpy(out, &v, 8);
  return off + 8;
}

/* a copy of n bytes; *out is always a Bytes value (empty when the read fails) */
static int64_t fic_bytes_read_bytes(int64_t n, fic_ref bs, int64_t off, fic_ref *out) {
  if (n < 0 || off < 0 || off > FIC_VEC(bs)->len - n) { *out = fic_bytes_new(0); return -1; }
  *out = fic_bytes_new(n);
  if (n > 0) memcpy(FIC_VEC(*out)->data, FIC_VEC(bs)->data + off, (size_t)n);
  return off + n;
}

/* well formed UTF-8 (Unicode table 3-7): no overlong forms, no surrogates, nothing above U+10FFFF, nothing truncated */
static int fic_bytes_utf8_ok(const unsigned char *s, int64_t n) {
  int64_t i = 0;
  while (i < n) {
    unsigned char c = s[i];
    int k, j;
    unsigned char lo = 0x80u, hi = 0xBFu;
    if (c < 0x80u) { i++; continue; }
    if (c >= 0xC2u && c <= 0xDFu) k = 1;
    else if (c >= 0xE0u && c <= 0xEFu) { k = 2; if (c == 0xE0u) lo = 0xA0u; if (c == 0xEDu) hi = 0x9Fu; }
    else if (c >= 0xF0u && c <= 0xF4u) { k = 3; if (c == 0xF0u) lo = 0x90u; if (c == 0xF4u) hi = 0x8Fu; }
    else return 0;
    if (i + k >= n) return 0;
    if (s[i + 1] < lo || s[i + 1] > hi) return 0;
    for (j = 2; j <= k; j++) if (s[i + j] < 0x80u || s[i + j] > 0xBFu) return 0;
    i += k + 1;
  }
  return 1;
}

/* a string of n bytes of UTF-8; *out is always a string (empty when the read fails); L23: bytes that are not UTF-8 fail */
static int64_t fic_bytes_read_string(int64_t n, fic_ref bs, int64_t off, fic_ref *out) {
  if (n < 0 || off < 0 || off > FIC_VEC(bs)->len - n || !fic_bytes_utf8_ok(FIC_VEC(bs)->data + off, n)) { *out = fic_str_new("", 0); return -1; }
  *out = fic_str_new((const char *)FIC_VEC(bs)->data + off, n);
  return off + n;
}
