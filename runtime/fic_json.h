/* The kernel of elm/json (Json.Encode, Json.Decode), decisions L20, L21, L27, L28, L35, L36; STAGE4-PLAN section 8. Needs the closure runtime
   (fic_word, fic_apN), fic_jsarray.h and fic_ustring.h; emitted only into programs that use a fic_json_ or fic_jd_ function.

   A Json value (`Json.Encode.Value`) is an ordinary counted tree:
     null          the static object fic_json_null_obj
     true, false   two static objects (tag FIC_TAG_JBOOL)
     a number      FIC_TAG_JINT {int64} (Encode.int, an integer literal that fits 64 bits) or FIC_TAG_JFLOAT {double} (L21)
     a string      the string object itself (FIC_TAG_STRING)
     an array      a JsArray of references (FIC_TAG_VEC_REF, fic_jsarray.h)
     an object     FIC_TAG_JOBJ with two references: the keys (a JsArray of strings) and the values (a JsArray), in the order of a
                   JavaScript object (L35): first the keys that are canonical array indices ("0" to "4294967294") in numeric
                   order, then the others in insertion order; no duplicate keys (the last value wins, at the place of the first)
   A decoder (`Json.Decode.Decoder a`) is a tree of fic_jdec nodes that fic_jd_run interprets. Values of the type `a` are words
   (fic_word, a struct boxed, as in a closure); a class code says what a word holds: 'p' a reference, 'i' Int, 'd' Float, 'c' Char,
   'e' an enumeration, Bool or unit. The primitive decoders are static objects.

   Ownership (the signatures are in Ficcus.Mono.Kernel): the functions that build a decoder CONSUME the decoders, closures and
   values they store; fic_jd_run BORROWS the decoder and the value and gives an owned result or an owned `Error`; Json.Encode
   functions give owned values. Without -DFIC_RC nothing is counted or freed (FIC_RC_DUP, FIC_RC_DROP). */

#define FIC_TAG_JNULL  0xFFE0u
#define FIC_TAG_JBOOL  0xFFE1u
#define FIC_TAG_JINT   0xFFE2u
#define FIC_TAG_JFLOAT 0xFFE3u
#define FIC_TAG_JOBJ   0xFFE4u
#define FIC_TAG_JDEC   0xFFE5u

typedef struct fic_jint { fic_hdr h; int64_t i; } fic_jint;
typedef struct fic_jfloat { fic_hdr h; double d; } fic_jfloat;
typedef struct fic_jbool { fic_hdr h; uint8_t b; } fic_jbool;
typedef struct fic_jobj { fic_hdr h; fic_ref keys; fic_ref vals; } fic_jobj;

static fic_hdr fic_json_null_obj = { FIC_IMMORTAL, FIC_TAG_JNULL, 0, 0 };
static fic_jbool fic_json_false_obj = { { FIC_IMMORTAL, FIC_TAG_JBOOL, 0, 0 }, 0 };
static fic_jbool fic_json_true_obj = { { FIC_IMMORTAL, FIC_TAG_JBOOL, 0, 0 }, 1 };

static int64_t fic_json_len(fic_ref arr) { return FIC_VEC(arr)->len; }
static fic_ref fic_json_at(fic_ref arr, int64_t i) { return fic_ja_data(arr)[i].p; }

/* ---- Json.Encode ---- */

static fic_ref fic_json_null(void) { FIC_RC_DUP(&fic_json_null_obj); return &fic_json_null_obj; }
static fic_ref fic_json_bool(uint8_t b) { fic_ref r = b ? &fic_json_true_obj.h : &fic_json_false_obj.h; FIC_RC_DUP(r); return r; }
static fic_ref fic_json_int(int64_t i) { fic_jint *o = (fic_jint *)fic_alloc(sizeof(fic_jint), FIC_TAG_JINT, 0); o->i = i; return &o->h; }
static fic_ref fic_json_float(double d) { fic_jfloat *o = (fic_jfloat *)fic_alloc(sizeof(fic_jfloat), FIC_TAG_JFLOAT, 0); o->d = d; return &o->h; }

/* an array from a List Value (the list is borrowed) */
static fic_ref fic_json_array_from(fic_ref list) {
  int64_t n = 0, i = 0;
  fic_ref p, r;
  for (p = list; p->tag != 0u; p = ((fic_us_cell *)p)->f1) n++;
  r = fic_ja_new(n, FIC_TAG_VEC_REF);
  for (p = list; p->tag != 0u; p = ((fic_us_cell *)p)->f1) { fic_ref x = ((fic_us_cell *)p)->f0; FIC_RC_DUP(x); fic_ja_data(r)[i++].p = x; }
  return r;
}

static fic_ref fic_json_obj_new(fic_ref keys, fic_ref vals) {      /* consumes both arrays */
  fic_jobj *o = (fic_jobj *)fic_alloc(sizeof(fic_jobj), FIC_TAG_JOBJ, 2);
  o->keys = keys; o->vals = vals;
  return &o->h;
}

typedef struct fic_json_kv { fic_ref key; int64_t ix; int64_t num; } fic_json_kv;

/* L35, L36: the number of a key that is a canonical array index of JavaScript ("0", or digits without a leading zero, at most
   4294967294), -1 for every other key */
static int64_t fic_json_index_key(fic_ref key) {
  const char *s = FIC_STR(key)->data;
  int64_t n = FIC_STR(key)->len, i, v = 0;
  if (n < 1 || n > 10 || (s[0] == '0' && n > 1)) return -1;
  for (i = 0; i < n; i++) { if (s[i] < '0' || s[i] > '9') return -1; v = v * 10 + (s[i] - '0'); }
  return v <= 4294967294LL ? v : -1;
}

static int fic_json_kv_numcmp(const void *a, const void *b) {
  const fic_json_kv *x = (const fic_json_kv *)a, *y = (const fic_json_kv *)b;
  return x->num < y->num ? -1 : x->num > y->num ? 1 : 0;
}
static int fic_json_kv_cmp(const void *a, const void *b) {
  const fic_json_kv *x = (const fic_json_kv *)a, *y = (const fic_json_kv *)b;
  int c = fic_str_cmp(x->key, y->key);
  return c != 0 ? c : (x->ix < y->ix ? -1 : x->ix > y->ix ? 1 : 0);
}

/* an object from n keys and n values (the references in ks and vs are owned by the caller and are moved into the object or dropped):
   a key that occurs again replaces the value and keeps the place of its first occurrence */
static fic_ref fic_json_obj_build(fic_ref *ks, fic_ref *vs, int64_t n) {
  fic_ref keys, vals;
  int64_t i, m = 0, nix = 0;
  if (n > 1) {
    fic_json_kv *t = (fic_json_kv *)malloc((size_t)n * sizeof(fic_json_kv));
    if (t == NULL) abort();
    for (i = 0; i < n; i++) { t[i].key = ks[i]; t[i].ix = i; }
    qsort(t, (size_t)n, sizeof(fic_json_kv), fic_json_kv_cmp);
    for (i = 0; i < n; ) {
      int64_t j = i + 1;
      while (j < n && fic_str_eq(t[i].key, t[j].key)) j++;
      if (j > i + 1) {                        /* t[i] is the first occurrence, t[j - 1] the last */
        int64_t first = t[i].ix, last = t[j - 1].ix, k;
        fic_ref v = vs[last];
        for (k = i; k < j; k++) {
          int64_t x = t[k].ix;
          if (x != last) FIC_RC_DROP(vs[x]);
          if (x != first) { FIC_RC_DROP(ks[x]); ks[x] = NULL; }
          vs[x] = NULL;
        }
        vs[first] = v;
      }
      i = j;
    }
    free(t);
  }
  for (i = 0; i < n; i++) if (ks[i] != NULL) m++;
  keys = fic_ja_new(m, FIC_TAG_VEC_REF);
  vals = fic_ja_new(m, FIC_TAG_VEC_REF);
  m = 0;
  /* L35, the order of JavaScript objects: first the keys that are array indices, in ascending numeric order ... */
  for (i = 0; i < n; i++) if (ks[i] != NULL && fic_json_index_key(ks[i]) >= 0) nix++;
  if (nix > 0) {
    fic_json_kv *t = (fic_json_kv *)malloc((size_t)nix * sizeof(fic_json_kv));
    if (t == NULL) abort();
    for (i = 0; i < n; i++) if (ks[i] != NULL) { int64_t x = fic_json_index_key(ks[i]); if (x >= 0) { t[m].key = ks[i]; t[m].ix = i; t[m].num = x; m++; } }
    qsort(t, (size_t)nix, sizeof(fic_json_kv), fic_json_kv_numcmp);
    for (m = 0; m < nix; m++) { fic_ja_data(keys)[m].p = ks[t[m].ix]; fic_ja_data(vals)[m].p = vs[t[m].ix]; ks[t[m].ix] = NULL; }
    free(t);
  }
  /* ... then the other keys in the order of their first occurrence */
  for (i = 0; i < n; i++) if (ks[i] != NULL) { fic_ja_data(keys)[m].p = ks[i]; fic_ja_data(vals)[m].p = vs[i]; m++; }
  return fic_json_obj_new(keys, vals);
}

/* an object from a List String and a List Value of the same length (both borrowed) */
static fic_ref fic_json_object_from(fic_ref klist, fic_ref vlist) {
  int64_t n = 0, i = 0;
  fic_ref p, q, r, *ks, *vs;
  for (p = klist; p->tag != 0u; p = ((fic_us_cell *)p)->f1) n++;
  ks = (fic_ref *)malloc((size_t)(n + 1) * sizeof(fic_ref));
  vs = (fic_ref *)malloc((size_t)(n + 1) * sizeof(fic_ref));
  if (ks == NULL || vs == NULL) abort();
  for (p = klist, q = vlist; p->tag != 0u && q->tag != 0u; p = ((fic_us_cell *)p)->f1, q = ((fic_us_cell *)q)->f1) {
    ks[i] = ((fic_us_cell *)p)->f0; vs[i] = ((fic_us_cell *)q)->f0;
    FIC_RC_DUP(ks[i]); FIC_RC_DUP(vs[i]);
    i++;
  }
  r = fic_json_obj_build(ks, vs, i);
  free(ks); free(vs);
  return r;
}

/* JSON.stringify's string: the two character escapes, \u00XX for the other control characters */
static void fic_json_put_string(fic_sb *b, fic_ref s) {
  const char *d = FIC_STR(s)->data;
  int64_t n = FIC_STR(s)->len, i, from = 0;
  fic_sb_putn(b, "\"", 1);
  for (i = 0; i < n; i++) {
    unsigned char c = (unsigned char)d[i];
    const char *esc = NULL;
    char u[8];
    switch (c) {
    case '"': esc = "\\\""; break;
    case '\\': esc = "\\\\"; break;
    case '\b': esc = "\\b"; break;
    case '\f': esc = "\\f"; break;
    case '\n': esc = "\\n"; break;
    case '\r': esc = "\\r"; break;
    case '\t': esc = "\\t"; break;
    default: if (c < 0x20u) { snprintf(u, sizeof u, "\\u%04x", (unsigned)c); esc = u; } break;
    }
    if (esc != NULL) { fic_sb_putn(b, d + from, i - from); fic_sb_puts(b, esc); from = i + 1; }
  }
  fic_sb_putn(b, d + from, n - from);
  fic_sb_putn(b, "\"", 1);
}

/* L41: nesting limit of the parser, printer and equality (each recurses once per level): 1,000,000 levels when `main` runs on the big
   stack (fic_rt.h), the old 2000 where it does not; beyond it the parser fails (not valid JSON) and the printer and equality stop
   the program with a message */
#ifndef FIC_JSON_MAX_DEPTH
#  if !defined(FIC_NO_BIG_STACK) && (defined(__unix__) || defined(__APPLE__))
#    define FIC_JSON_MAX_DEPTH 1000000
#  else
#    define FIC_JSON_MAX_DEPTH 2000
#  endif
#endif

static void fic_json_too_deep(const char *what) {
  fprintf(stderr, "%s: the Json value is nested more than %d levels.\n", what, (int)FIC_JSON_MAX_DEPTH);
  exit(1);
}

static void fic_json_put_indent(fic_sb *b, int64_t indent, int64_t depth) {
  int64_t i;
  fic_sb_putn(b, "\n", 1);
  for (i = 0; i < indent * depth; i++) fic_sb_putn(b, " ", 1);
}

static void fic_json_put(fic_sb *b, fic_ref v, int64_t indent, int64_t depth) {
  int64_t i, n;
  if (depth > FIC_JSON_MAX_DEPTH) fic_json_too_deep("Json.Encode.encode");
  switch (v->tag) {
  case FIC_TAG_JNULL: fic_sb_puts(b, "null"); break;
  case FIC_TAG_JBOOL: fic_sb_puts(b, ((fic_jbool *)v)->b ? "true" : "false"); break;
  case FIC_TAG_JINT: fic_sb_int(b, ((fic_jint *)v)->i); break;
  case FIC_TAG_JFLOAT: {
    double d = ((fic_jfloat *)v)->d;
    if (d != d || d > 1.7976931348623157e308 || d < -1.7976931348623157e308) fic_sb_puts(b, "null");   /* L20 */
    else fic_sb_float(b, d);
    break; }
  case FIC_TAG_STRING: fic_json_put_string(b, v); break;
  case FIC_TAG_VEC_REF:
    n = fic_json_len(v);
    if (n == 0) { fic_sb_puts(b, "[]"); break; }
    fic_sb_putn(b, "[", 1);
    for (i = 0; i < n; i++) {
      if (i > 0) fic_sb_putn(b, ",", 1);
      if (indent > 0) fic_json_put_indent(b, indent, depth + 1);
      fic_json_put(b, fic_json_at(v, i), indent, depth + 1);
    }
    if (indent > 0) fic_json_put_indent(b, indent, depth);
    fic_sb_putn(b, "]", 1);
    break;
  case FIC_TAG_JOBJ: {
    fic_jobj *o = (fic_jobj *)v;
    n = fic_json_len(o->keys);
    if (n == 0) { fic_sb_puts(b, "{}"); break; }
    fic_sb_putn(b, "{", 1);
    for (i = 0; i < n; i++) {
      if (i > 0) fic_sb_putn(b, ",", 1);
      if (indent > 0) fic_json_put_indent(b, indent, depth + 1);
      fic_json_put_string(b, fic_json_at(o->keys, i));
      fic_sb_puts(b, indent > 0 ? ": " : ":");
      fic_json_put(b, fic_json_at(o->vals, i), indent, depth + 1);
    }
    if (indent > 0) fic_json_put_indent(b, indent, depth);
    fic_sb_putn(b, "}", 1);
    break; }
  default: fic_sb_puts(b, "null"); break;
  }
}

/* Json.Encode.encode: JSON.stringify(value, null, indent); the indentation is at most 10 spaces, as in JavaScript */
static fic_ref fic_json_encode(int64_t indent, fic_ref v) {
  fic_sb b;
  fic_sb_init(&b);
  fic_json_put(&b, v, indent < 0 ? 0 : indent > 10 ? 10 : indent, 0);
  return fic_sb_str(&b);
}

/* ---- equality of values: structural; a number equals a number of the same value; objects whatever the order of their keys ---- */

static int64_t fic_json_find_key(fic_ref keys, fic_ref name) {
  int64_t i, n = fic_json_len(keys);
  for (i = 0; i < n; i++) if (fic_str_eq(fic_json_at(keys, i), name)) return i;
  return -1;
}

static uint8_t fic_json_eq_d(fic_ref a, fic_ref b, int64_t depth) {
  int64_t i, n;
  if (a == b) return 1;
  if (depth > FIC_JSON_MAX_DEPTH) fic_json_too_deep("Json equality");
  if ((a->tag == FIC_TAG_JINT || a->tag == FIC_TAG_JFLOAT) && (b->tag == FIC_TAG_JINT || b->tag == FIC_TAG_JFLOAT)) {
    if (a->tag == FIC_TAG_JINT && b->tag == FIC_TAG_JINT) return ((fic_jint *)a)->i == ((fic_jint *)b)->i;
    return (a->tag == FIC_TAG_JINT ? (double)((fic_jint *)a)->i : ((fic_jfloat *)a)->d)
        == (b->tag == FIC_TAG_JINT ? (double)((fic_jint *)b)->i : ((fic_jfloat *)b)->d);
  }
  if (a->tag != b->tag) return 0;
  switch (a->tag) {
  case FIC_TAG_JNULL: return 1;
  case FIC_TAG_JBOOL: return ((fic_jbool *)a)->b == ((fic_jbool *)b)->b;
  case FIC_TAG_STRING: return fic_str_eq(a, b);
  case FIC_TAG_VEC_REF:
    n = fic_json_len(a);
    if (n != fic_json_len(b)) return 0;
    for (i = 0; i < n; i++) if (!fic_json_eq_d(fic_json_at(a, i), fic_json_at(b, i), depth + 1)) return 0;
    return 1;
  case FIC_TAG_JOBJ: {
    fic_jobj *x = (fic_jobj *)a, *y = (fic_jobj *)b;
    n = fic_json_len(x->keys);
    if (n != fic_json_len(y->keys)) return 0;
    for (i = 0; i < n; i++) {
      int64_t j = fic_str_eq(fic_json_at(x->keys, i), fic_json_at(y->keys, i)) ? i : fic_json_find_key(y->keys, fic_json_at(x->keys, i));
      if (j < 0 || !fic_json_eq_d(fic_json_at(x->vals, i), fic_json_at(y->vals, j), depth + 1)) return 0;
    }
    return 1; }
  default: return 0;
  }
}
static uint8_t fic_json_eq(fic_ref a, fic_ref b) { return fic_json_eq_d(a, b, 0); }

/* ---- the parser of JSON text (JSON.parse): NULL when the text is not valid JSON ---- */

typedef struct fic_json_in { const unsigned char *p, *end; int depth; } fic_json_in;

static void fic_json_ws(fic_json_in *in) {
  while (in->p < in->end && (*in->p == ' ' || *in->p == '\t' || *in->p == '\n' || *in->p == '\r')) in->p++;
}

static int fic_json_hex4(fic_json_in *in, uint32_t *out) {
  uint32_t v = 0;
  int i;
  if (in->end - in->p < 4) return 0;
  for (i = 0; i < 4; i++) {
    unsigned char c = in->p[i];
    if (c >= '0' && c <= '9') v = v * 16u + (uint32_t)(c - '0');
    else if (c >= 'a' && c <= 'f') v = v * 16u + (uint32_t)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F') v = v * 16u + (uint32_t)(c - 'A' + 10);
    else return 0;
  }
  in->p += 4;
  *out = v;
  return 1;
}

/* a string literal (in->p is after the opening quote); a lone surrogate escape becomes U+FFFD (strings are valid UTF-8) */
static fic_ref fic_json_parse_string(fic_json_in *in) {
  fic_sb b;
  fic_sb_init(&b);
  for (;;) {
    const unsigned char *s = in->p;
    while (in->p < in->end && *in->p != '"' && *in->p != '\\' && *in->p >= 0x20u) in->p++;
    fic_sb_putn(&b, (const char *)s, (int64_t)(in->p - s));
    if (in->p >= in->end || *in->p < 0x20u) { free(b.p); return NULL; }
    if (*in->p == '"') { in->p++; return fic_sb_str(&b); }
    in->p++;                                          /* the backslash */
    if (in->p >= in->end) { free(b.p); return NULL; }
    switch (*in->p++) {
    case '"': fic_sb_putn(&b, "\"", 1); break;
    case '\\': fic_sb_putn(&b, "\\", 1); break;
    case '/': fic_sb_putn(&b, "/", 1); break;
    case 'b': fic_sb_putn(&b, "\b", 1); break;
    case 'f': fic_sb_putn(&b, "\f", 1); break;
    case 'n': fic_sb_putn(&b, "\n", 1); break;
    case 'r': fic_sb_putn(&b, "\r", 1); break;
    case 't': fic_sb_putn(&b, "\t", 1); break;
    case 'u': {
      uint32_t c, lo;
      char u[4];
      if (!fic_json_hex4(in, &c)) { free(b.p); return NULL; }
      if (c >= 0xD800u && c < 0xDC00u) {
        const unsigned char *save = in->p;
        if (in->end - in->p >= 6 && in->p[0] == '\\' && in->p[1] == 'u' && (in->p += 2, fic_json_hex4(in, &lo)) && lo >= 0xDC00u && lo < 0xE000u)
          c = 0x10000u + ((c - 0xD800u) << 10) + (lo - 0xDC00u);
        else { in->p = save; c = 0xFFFDu; }
      } else if (c >= 0xDC00u && c < 0xE000u) c = 0xFFFDu;
      fic_sb_putn(&b, u, fic_us_put(u, c));
      break; }
    default: free(b.p); return NULL;
    }
  }
}

/* a number: an integer literal that fits 64 bits is an Int value, everything else the nearest double (L21); "-0" is the double */
static fic_ref fic_json_parse_number(fic_json_in *in) {
  const unsigned char *s = in->p;
  int integral = 1, neg = 0;
  char small[64], *buf = small, *stop;
  size_t n;
  fic_ref r;
  if (in->p < in->end && *in->p == '-') { in->p++; neg = 1; }
  if (in->p >= in->end) return NULL;
  if (*in->p == '0') in->p++;
  else if (*in->p >= '1' && *in->p <= '9') { while (in->p < in->end && *in->p >= '0' && *in->p <= '9') in->p++; }
  else return NULL;
  if (in->p < in->end && *in->p == '.') {
    integral = 0; in->p++;
    if (in->p >= in->end || *in->p < '0' || *in->p > '9') return NULL;
    while (in->p < in->end && *in->p >= '0' && *in->p <= '9') in->p++;
  }
  if (in->p < in->end && (*in->p == 'e' || *in->p == 'E')) {
    integral = 0; in->p++;
    if (in->p < in->end && (*in->p == '+' || *in->p == '-')) in->p++;
    if (in->p >= in->end || *in->p < '0' || *in->p > '9') return NULL;
    while (in->p < in->end && *in->p >= '0' && *in->p <= '9') in->p++;
  }
  n = (size_t)(in->p - s);
  if (integral && n <= 20) {                           /* at most 19 digits and a sign can fit */
    uint64_t v = 0, limit = neg ? (uint64_t)1 << 63 : ((uint64_t)1 << 63) - 1u;
    const unsigned char *q = s + neg;
    int fits = 1;
    for (; q < in->p; q++) {
      uint64_t dgt = (uint64_t)(*q - '0');
      if (v > (limit - dgt) / 10u) { fits = 0; break; }
      v = v * 10u + dgt;
    }
    if (fits && !(neg && v == 0)) return fic_json_int(neg ? (int64_t)(0u - v) : (int64_t)v);
  }
  if (n + 1 > sizeof small) { buf = (char *)malloc(n + 1); if (buf == NULL) abort(); }
  memcpy(buf, s, n); buf[n] = 0;
  r = fic_json_float(strtod(buf, &stop));
  if (buf != small) free(buf);
  return r;
}

static fic_ref fic_json_parse_value(fic_json_in *in);

static void fic_json_drop_all(fic_ref *xs, int64_t n) {
  int64_t i;
  for (i = 0; i < n; i++) FIC_RC_DROP(xs[i]);
  (void)xs; (void)i;
}

static fic_ref fic_json_parse_compound(fic_json_in *in, int object) {
  fic_ref *ks = NULL, *vs = NULL, r = NULL;
  int64_t n = 0, cap = 0, i;
  unsigned char close = object ? '}' : ']';
  int ok = 0;
  if (++in->depth > FIC_JSON_MAX_DEPTH) { in->depth--; return NULL; }
  fic_json_ws(in);
  if (in->p < in->end && *in->p == close) { in->p++; ok = 1; }
  else for (;;) {
    fic_ref k = NULL, v;
    if (object) {
      fic_json_ws(in);
      if (in->p >= in->end || *in->p != '"') break;
      in->p++;
      k = fic_json_parse_string(in);
      if (k == NULL) break;
      fic_json_ws(in);
      if (in->p >= in->end || *in->p != ':') { FIC_RC_DROP(k); break; }
      in->p++;
    }
    v = fic_json_parse_value(in);
    if (v == NULL) { if (k != NULL) FIC_RC_DROP(k); break; }
    if (n == cap) {
      cap = cap == 0 ? 8 : cap * 2;
      vs = (fic_ref *)realloc(vs, (size_t)cap * sizeof(fic_ref));
      if (vs == NULL) abort();
      if (object) { ks = (fic_ref *)realloc(ks, (size_t)cap * sizeof(fic_ref)); if (ks == NULL) abort(); }
    }
    if (object) ks[n] = k;
    vs[n++] = v;
    fic_json_ws(in);
    if (in->p < in->end && *in->p == ',') { in->p++; continue; }
    if (in->p < in->end && *in->p == close) { in->p++; ok = 1; }
    break;
  }
  in->depth--;
  if (!ok) {
    if (object) fic_json_drop_all(ks, n);
    fic_json_drop_all(vs, n);
  } else if (object) {
    r = fic_json_obj_build(ks, vs, n);
  } else {
    r = fic_ja_new(n, FIC_TAG_VEC_REF);
    for (i = 0; i < n; i++) fic_ja_data(r)[i].p = vs[i];
  }
  free(ks); free(vs);
  return r;
}

static fic_ref fic_json_parse_value(fic_json_in *in) {
  fic_json_ws(in);
  if (in->p >= in->end) return NULL;
  switch (*in->p) {
  case '{': in->p++; return fic_json_parse_compound(in, 1);
  case '[': in->p++; return fic_json_parse_compound(in, 0);
  case '"': in->p++; return fic_json_parse_string(in);
  case 't': if (in->end - in->p >= 4 && memcmp(in->p, "true", 4) == 0) { in->p += 4; return fic_json_bool(1); } return NULL;
  case 'f': if (in->end - in->p >= 5 && memcmp(in->p, "false", 5) == 0) { in->p += 5; return fic_json_bool(0); } return NULL;
  case 'n': if (in->end - in->p >= 4 && memcmp(in->p, "null", 4) == 0) { in->p += 4; return fic_json_null(); } return NULL;
  default: return fic_json_parse_number(in);
  }
}

static fic_ref fic_json_parse(fic_ref text) {          /* text borrowed; an owned value or NULL */
  fic_json_in in;
  fic_ref v;
  in.p = (const unsigned char *)FIC_STR(text)->data;
  in.end = in.p + FIC_STR(text)->len;
  in.depth = 0;
  v = fic_json_parse_value(&in);
  if (v == NULL) return NULL;
  fic_json_ws(&in);
  if (in.p != in.end) { FIC_RC_DROP(v); return NULL; }
  return v;
}

/* ---- Json.Decode: the decoders ---- */

enum { FIC_JD_STRING, FIC_JD_BOOL, FIC_JD_INT, FIC_JD_FLOAT, FIC_JD_VALUE, FIC_JD_KEYS,       /* the static ones */
       FIC_JD_NULL, FIC_JD_SUCCEED, FIC_JD_FAIL, FIC_JD_LIST, FIC_JD_ARRAY, FIC_JD_VALUES, FIC_JD_FIELD, FIC_JD_INDEX, FIC_JD_ONEOF,
       FIC_JD_MAP1, FIC_JD_MAP2, FIC_JD_ANDTHEN };

/* a, b, c: the first h.nptr of them are references (sub-decoders, a closure, a name, a list of decoders, a constant that is a
   reference); w: a constant that is not a reference; n: the index; code: the class code of the constant or of the result of f */
typedef struct fic_jdec { fic_hdr h; fic_ref a; fic_ref b; fic_ref c; fic_word w; int64_t n; uint8_t kind; char code; } fic_jdec;
#define FIC_JDEC(r) ((fic_jdec *)(r))

static fic_jdec fic_jd_statics[6] = {
  { { FIC_IMMORTAL, FIC_TAG_JDEC, 0, 0 }, NULL, NULL, NULL, { 0 }, 0, FIC_JD_STRING, 'p' },
  { { FIC_IMMORTAL, FIC_TAG_JDEC, 0, 0 }, NULL, NULL, NULL, { 0 }, 0, FIC_JD_BOOL, 'e' },
  { { FIC_IMMORTAL, FIC_TAG_JDEC, 0, 0 }, NULL, NULL, NULL, { 0 }, 0, FIC_JD_INT, 'i' },
  { { FIC_IMMORTAL, FIC_TAG_JDEC, 0, 0 }, NULL, NULL, NULL, { 0 }, 0, FIC_JD_FLOAT, 'd' },
  { { FIC_IMMORTAL, FIC_TAG_JDEC, 0, 0 }, NULL, NULL, NULL, { 0 }, 0, FIC_JD_VALUE, 'p' },
  { { FIC_IMMORTAL, FIC_TAG_JDEC, 0, 0 }, NULL, NULL, NULL, { 0 }, 0, FIC_JD_KEYS, 'p' }
};

static fic_ref fic_jd_prim(int kind) { fic_ref r = &fic_jd_statics[kind].h; FIC_RC_DUP(r); return r; }

static fic_jdec *fic_jd_new(int kind, unsigned nptr, char code) {
  fic_jdec *d = (fic_jdec *)fic_alloc(sizeof(fic_jdec), FIC_TAG_JDEC, (uint16_t)nptr);
  d->a = d->b = d->c = NULL; d->w.i = 0; d->n = 0; d->kind = (uint8_t)kind; d->code = code;
  return d;
}

/* Decode.null x and Decode.succeed x: the constant is consumed */
static fic_ref fic_jd_const(int kind, char code, fic_word x) {
  fic_jdec *d = fic_jd_new(kind, code == 'p' ? 1u : 0u, code);
  if (code == 'p') d->a = x.p; else d->w = x;
  return &d->h;
}
static fic_ref fic_jd_fail(fic_ref msg) { fic_jdec *d = fic_jd_new(FIC_JD_FAIL, 1u, 'p'); d->a = msg; return &d->h; }
static fic_ref fic_jd_list(int kind, fic_ref sub) { fic_jdec *d = fic_jd_new(kind, 1u, 'p'); d->a = sub; return &d->h; }   /* LIST, ARRAY, VALUES */
static fic_ref fic_jd_field(fic_ref name, fic_ref sub) { fic_jdec *d = fic_jd_new(FIC_JD_FIELD, 2u, 'p'); d->a = name; d->b = sub; return &d->h; }
static fic_ref fic_jd_index(int64_t i, fic_ref sub) { fic_jdec *d = fic_jd_new(FIC_JD_INDEX, 1u, 'p'); d->a = sub; d->n = i; return &d->h; }
static fic_ref fic_jd_oneof(fic_ref list) { fic_jdec *d = fic_jd_new(FIC_JD_ONEOF, 1u, 'p'); d->a = list; return &d->h; }
static fic_ref fic_jd_map1(char code, fic_ref f, fic_ref d1) { fic_jdec *d = fic_jd_new(FIC_JD_MAP1, 2u, code); d->a = f; d->b = d1; return &d->h; }
static fic_ref fic_jd_map2(char code, fic_ref f, fic_ref d1, fic_ref d2) {
  fic_jdec *d = fic_jd_new(FIC_JD_MAP2, 3u, code); d->a = f; d->b = d1; d->c = d2; return &d->h;
}
static fic_ref fic_jd_andthen(fic_ref f, fic_ref d1) { fic_jdec *d = fic_jd_new(FIC_JD_ANDTHEN, 2u, 'p'); d->a = f; d->b = d1; return &d->h; }

/* ---- the Error values of Json.Decode: Field String Error | Index Int Error | OneOf (List Error) | Failure String Value ---- */

typedef struct fic_jd_e2 { fic_hdr h; fic_ref r0; fic_ref r1; } fic_jd_e2;
typedef struct fic_jd_ei { fic_hdr h; fic_ref r0; int64_t s0; } fic_jd_ei;
typedef struct fic_jd_e1 { fic_hdr h; fic_ref r0; } fic_jd_e1;

static fic_ref fic_jd_err_field(fic_ref name, fic_ref err) {       /* name borrowed, err consumed */
  fic_jd_e2 *e = (fic_jd_e2 *)fic_alloc(sizeof(fic_jd_e2), 0u, 2);
  FIC_RC_DUP(name);
  e->r0 = name; e->r1 = err;
  return &e->h;
}
static fic_ref fic_jd_err_index(int64_t i, fic_ref err) {
  fic_jd_ei *e = (fic_jd_ei *)fic_alloc(sizeof(fic_jd_ei), 1u, 1);
  e->r0 = err; e->s0 = i;
  return &e->h;
}
static fic_ref fic_jd_err_oneof(fic_ref list) {
  fic_jd_e1 *e = (fic_jd_e1 *)fic_alloc(sizeof(fic_jd_e1), 2u, 1);
  e->r0 = list;
  return &e->h;
}
static fic_ref fic_jd_failure(fic_ref msg, fic_ref val) {          /* msg consumed, val borrowed */
  fic_jd_e2 *e = (fic_jd_e2 *)fic_alloc(sizeof(fic_jd_e2), 3u, 2);
  FIC_RC_DUP(val);
  e->r0 = msg; e->r1 = val;
  return &e->h;
}
static fic_ref fic_jd_expecting(const char *what, fic_ref val) {
  fic_sb b;
  fic_sb_init(&b);
  fic_sb_puts(&b, "Expecting ");
  fic_sb_puts(&b, what);
  return fic_jd_failure(fic_sb_str(&b), val);
}

/* a list cell of the element class `code` (the layouts of the generated code: the reference words first) */
typedef struct fic_jd_ci { fic_hdr h; fic_ref r0; int64_t s0; } fic_jd_ci;
typedef struct fic_jd_cd { fic_hdr h; fic_ref r0; double s0; } fic_jd_cd;
typedef struct fic_jd_cc { fic_hdr h; fic_ref r0; uint32_t s0; } fic_jd_cc;
typedef struct fic_jd_ce { fic_hdr h; fic_ref r0; uint8_t s0; } fic_jd_ce;

static fic_ref fic_jd_cons(char code, fic_word x, fic_ref tail) {
  switch (code) {
  case 'p': return fic_us_cons_cell(x.p, tail);
  case 'i': { fic_jd_ci *c = (fic_jd_ci *)fic_alloc(sizeof(fic_jd_ci), 1u, 1); c->r0 = tail; c->s0 = x.i; return &c->h; }
  case 'd': { fic_jd_cd *c = (fic_jd_cd *)fic_alloc(sizeof(fic_jd_cd), 1u, 1); c->r0 = tail; c->s0 = x.d; return &c->h; }
  case 'c': { fic_jd_cc *c = (fic_jd_cc *)fic_alloc(sizeof(fic_jd_cc), 1u, 1); c->r0 = tail; c->s0 = x.c; return &c->h; }
  default: { fic_jd_ce *c = (fic_jd_ce *)fic_alloc(sizeof(fic_jd_ce), 1u, 1); c->r0 = tail; c->s0 = x.b; return &c->h; }
  }
}

/* ---- the interpreter. dec and val are borrowed. On success: NULL, *out the result (owned) and *code its class code.
        On failure: an owned Error. ---- */

static fic_ref fic_jd_run(fic_ref dec, fic_ref val, fic_word *out, char *code);

/* the elements of an array (or the values of an object: keys != NULL) with one decoder, as a list */
static fic_ref fic_jd_run_seq(fic_ref sub, fic_ref arr, fic_ref keys, fic_word *out) {
  int64_t n = fic_json_len(arr), i;
  fic_word *xs = (fic_word *)malloc((size_t)(n + 1) * sizeof(fic_word));
  char ec = 'p';
  fic_ref list;
  if (xs == NULL) abort();
  for (i = 0; i < n; i++) {
    fic_ref err = fic_jd_run(sub, fic_json_at(arr, i), &xs[i], &ec);
    if (err != NULL) {
      int64_t k;
      if (ec == 'p') for (k = 0; k < i; k++) FIC_RC_DROP(xs[k].p);
      free(xs);
      return keys != NULL ? fic_jd_err_field(fic_json_at(keys, i), err) : fic_jd_err_index(i, err);
    }
  }
  list = fic_nil();
  for (i = n - 1; i >= 0; i--) list = fic_jd_cons(ec, xs[i], list);
  free(xs);
  out->p = list;
  return NULL;
}

static fic_ref fic_jd_run(fic_ref dec, fic_ref val, fic_word *out, char *code) {
  fic_jdec *d = FIC_JDEC(dec);
  out->i = 0;
  *code = d->code;
  switch (d->kind) {
  case FIC_JD_STRING:
    if (val->tag != FIC_TAG_STRING) return fic_jd_expecting("a STRING", val);
    FIC_RC_DUP(val); out->p = val;
    return NULL;
  case FIC_JD_BOOL:
    if (val->tag != FIC_TAG_JBOOL) return fic_jd_expecting("a BOOL", val);
    out->b = ((fic_jbool *)val)->b;
    return NULL;
  case FIC_JD_INT:
    if (val->tag == FIC_TAG_JINT) { out->i = ((fic_jint *)val)->i; return NULL; }
    if (val->tag == FIC_TAG_JFLOAT) {                 /* L21: an integral number below 2^63 in size (1e3, 1.0, -0) */
      double x = ((fic_jfloat *)val)->d;
      if (x >= -9223372036854775808.0 && x < 9223372036854775808.0 && x == (double)(int64_t)x) { out->i = (int64_t)x; return NULL; }
    }
    return fic_jd_expecting("an INT", val);
  case FIC_JD_FLOAT:
    if (val->tag == FIC_TAG_JFLOAT) { out->d = ((fic_jfloat *)val)->d; return NULL; }
    if (val->tag == FIC_TAG_JINT) { out->d = (double)((fic_jint *)val)->i; return NULL; }
    return fic_jd_expecting("a FLOAT", val);
  case FIC_JD_VALUE:
    FIC_RC_DUP(val); out->p = val;
    return NULL;
  case FIC_JD_KEYS: {
    fic_ref keys, list;
    int64_t i;
    if (val->tag != FIC_TAG_JOBJ) return fic_jd_expecting("an OBJECT", val);
    keys = ((fic_jobj *)val)->keys;
    list = fic_nil();
    for (i = fic_json_len(keys) - 1; i >= 0; i--) { fic_ref k = fic_json_at(keys, i); FIC_RC_DUP(k); list = fic_us_cons_cell(k, list); }
    out->p = list;
    return NULL; }
  case FIC_JD_NULL:
    if (val->tag != FIC_TAG_JNULL) return fic_jd_expecting("null", val);
    if (d->code == 'p') { FIC_RC_DUP(d->a); out->p = d->a; } else *out = d->w;
    return NULL;
  case FIC_JD_SUCCEED:
    if (d->code == 'p') { FIC_RC_DUP(d->a); out->p = d->a; } else *out = d->w;
    return NULL;
  case FIC_JD_FAIL:
    FIC_RC_DUP(d->a);
    return fic_jd_failure(d->a, val);
  case FIC_JD_LIST: case FIC_JD_ARRAY:            /* ARRAY: Decode.array (a list that the overlay turns into an Array) */
    if (val->tag != FIC_TAG_VEC_REF) return fic_jd_expecting(d->kind == FIC_JD_LIST ? "a LIST" : "an ARRAY", val);
    return fic_jd_run_seq(d->a, val, NULL, out);
  case FIC_JD_VALUES:
    if (val->tag != FIC_TAG_JOBJ) return fic_jd_expecting("an OBJECT", val);
    return fic_jd_run_seq(d->a, ((fic_jobj *)val)->vals, ((fic_jobj *)val)->keys, out);
  case FIC_JD_FIELD: {
    int64_t i = val->tag == FIC_TAG_JOBJ ? fic_json_find_key(((fic_jobj *)val)->keys, d->a) : -1;
    fic_ref err;
    if (val->tag == FIC_TAG_VEC_REF) {                /* L36, as JavaScript: an array has the fields "length" and its indices */
      int64_t ix = fic_json_index_key(d->a);
      if (ix >= 0 && ix < fic_json_len(val)) {
        err = fic_jd_run(d->b, fic_json_at(val, ix), out, code);
        return err == NULL ? NULL : fic_jd_err_field(d->a, err);
      }
      if (FIC_STR(d->a)->len == 6 && memcmp(FIC_STR(d->a)->data, "length", 6) == 0) {
        fic_ref len = fic_json_int(fic_json_len(val));
        err = fic_jd_run(d->b, len, out, code);
        FIC_RC_DROP(len);
        return err == NULL ? NULL : fic_jd_err_field(d->a, err);
      }
    }
    if (i < 0) {
      fic_sb b;
      fic_sb_init(&b);
      fic_sb_puts(&b, "Expecting an OBJECT with a field named `");
      fic_sb_putn(&b, FIC_STR(d->a)->data, FIC_STR(d->a)->len);
      fic_sb_puts(&b, "`");
      return fic_jd_failure(fic_sb_str(&b), val);
    }
    err = fic_jd_run(d->b, fic_json_at(((fic_jobj *)val)->vals, i), out, code);
    return err == NULL ? NULL : fic_jd_err_field(d->a, err); }
  case FIC_JD_INDEX: {
    fic_ref err;
    if (val->tag != FIC_TAG_VEC_REF) return fic_jd_expecting("an ARRAY", val);
    if (d->n < 0 || d->n >= fic_json_len(val)) {      /* L28: a negative index fails like one that is too large */
      char what[120];
      snprintf(what, sizeof what, "a LONGER array. Need index %lld but only see %lld entries", (long long)d->n, (long long)fic_json_len(val));
      return fic_jd_expecting(what, val);
    }
    err = fic_jd_run(d->a, fic_json_at(val, d->n), out, code);
    return err == NULL ? NULL : fic_jd_err_index(d->n, err); }
  case FIC_JD_ONEOF: {
    fic_ref p, list, *errs = NULL;
    int64_t n = 0, cap = 0, i;
    for (p = d->a; p->tag != 0u; p = ((fic_us_cell *)p)->f1) {
      fic_ref err = fic_jd_run(((fic_us_cell *)p)->f0, val, out, code);
      if (err == NULL) { fic_json_drop_all(errs, n); free(errs); return NULL; }
      if (n == cap) { cap = cap == 0 ? 4 : cap * 2; errs = (fic_ref *)realloc(errs, (size_t)cap * sizeof(fic_ref)); if (errs == NULL) abort(); }
      errs[n++] = err;
    }
    list = fic_nil();
    for (i = n - 1; i >= 0; i--) list = fic_us_cons_cell(errs[i], list);
    free(errs);
    return fic_jd_err_oneof(list); }
  case FIC_JD_MAP1: {
    fic_word x;
    char cx;
    fic_ref err = fic_jd_run(d->b, val, &x, &cx);
    if (err != NULL) return err;
    *out = fic_ap1(d->a, cx == 'p' ? 1u : 0u, x);
    *code = d->code;
    return NULL; }
  case FIC_JD_MAP2: {
    fic_word x, y;
    char cx, cy;
    fic_ref err = fic_jd_run(d->b, val, &x, &cx);
    if (err != NULL) return err;
    err = fic_jd_run(d->c, val, &y, &cy);
    if (err != NULL) { if (cx == 'p') FIC_RC_DROP(x.p); return err; }
    *out = fic_ap2(d->a, (cx == 'p' ? 1u : 0u) | (cy == 'p' ? 2u : 0u), x, y);
    *code = d->code;
    return NULL; }
  case FIC_JD_ANDTHEN: {
    fic_word x;
    char cx;
    fic_ref next, err = fic_jd_run(d->b, val, &x, &cx);
    if (err != NULL) return err;
    next = fic_ap1(d->a, cx == 'p' ? 1u : 0u, x).p;
    err = fic_jd_run(next, val, out, code);
    FIC_RC_DROP(next);
    return err; }
  default:
    abort();
  }
}

/* Decode.decodeValue: NULL and *out on success, an owned Error otherwise */
static fic_ref fic_jd_decode_value(fic_ref dec, fic_ref val, fic_word *out) {
  char code;
  return fic_jd_run(dec, val, out, &code);
}

/* Decode.decodeString (L27: one fixed text for input that is not JSON; the value of the Failure is the input string) */
static fic_ref fic_jd_decode_string(fic_ref dec, fic_ref text, fic_word *out) {
  fic_ref v = fic_json_parse(text), err;
  char code;
  if (v == NULL) return fic_jd_failure(fic_str_new("This is not valid JSON! Syntax error", 36), text);
  err = fic_jd_run(dec, v, out, &code);
  FIC_RC_DROP(v);
  return err;
}

/* ---- equality of decoders: by structure, as Elm's `==` on the decoder objects. Functions are equal when they are the same closure
        and a runtime error otherwise (as Elm); a constant that is a reference is equal when it is the same object, the same string
        or the same Json value ---- */

static uint8_t fic_jd_eq(fic_ref x, fic_ref y);

static uint8_t fic_jd_eq_const(fic_jdec *a, fic_jdec *b) {
  if (a->code != b->code) return 0;
  switch (a->code) {
  case 'p':
    if (a->a == b->a) return 1;
    if (a->a->tag != b->a->tag) return 0;
    if (a->a->tag == FIC_TAG_JDEC) return fic_jd_eq(a->a, b->a);
    if (a->a->tag == FIC_TAG_STRING || (a->a->tag >= FIC_TAG_JNULL && a->a->tag <= FIC_TAG_JOBJ)) return fic_json_eq(a->a, b->a);
    return 0;
  case 'i': return a->w.i == b->w.i;
  case 'd': return a->w.d == b->w.d;
  case 'c': return a->w.c == b->w.c;
  default: return a->w.b == b->w.b;
  }
}

static uint8_t fic_jd_eq(fic_ref x, fic_ref y) {
  fic_jdec *a = FIC_JDEC(x), *b = FIC_JDEC(y);
  if (x == y) return 1;
  if (a->kind != b->kind) return 0;
  switch (a->kind) {
  case FIC_JD_NULL: case FIC_JD_SUCCEED: return fic_jd_eq_const(a, b);
  case FIC_JD_FAIL: return fic_str_eq(a->a, b->a);
  case FIC_JD_LIST: case FIC_JD_ARRAY: case FIC_JD_VALUES: return fic_jd_eq(a->a, b->a);
  case FIC_JD_FIELD: return fic_str_eq(a->a, b->a) && fic_jd_eq(a->b, b->b);
  case FIC_JD_INDEX: return a->n == b->n && fic_jd_eq(a->a, b->a);
  case FIC_JD_ONEOF: {
    fic_ref p = a->a, q = b->a;
    for (; p->tag != 0u && q->tag != 0u; p = ((fic_us_cell *)p)->f1, q = ((fic_us_cell *)q)->f1)
      if (!fic_jd_eq(((fic_us_cell *)p)->f0, ((fic_us_cell *)q)->f0)) return 0;
    return p->tag == 0u && q->tag == 0u; }
  case FIC_JD_MAP1: case FIC_JD_ANDTHEN:
    if (a->a != b->a) fic_panic_eq_fun();
    return fic_jd_eq(a->b, b->b);
  case FIC_JD_MAP2:
    if (a->a != b->a) fic_panic_eq_fun();
    return fic_jd_eq(a->b, b->b) && fic_jd_eq(a->c, b->c);
  default: return 1;
  }
}
