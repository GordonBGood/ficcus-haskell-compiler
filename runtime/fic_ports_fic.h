/* fic_ports_fic.h -- the payloads of Ficcus at the host interface (effects slices E3c and E3d; docs/E3-PORTS-DESIGN.md D5, D6, D9,
 * D10) and the walks of a host value that do not recurse (E3A-REVIEW F2). Emitted between runtime/fic_ports_api.h and
 * runtime/fic_ports.h, only into programs that have ports or flags; runtime/fic_json.h is unchanged, so the C of every other program
 * is unchanged too.
 *
 * Two node kinds exist only on the host's side of the boundary; the program never sees them:
 *   JUINT   {u64}: an integer above 2^63 - 1 (D5). Made by fic_hv_uint, by the Word64 encoder and by the JSON text adapter for an
 *           integer literal in (2^63 - 1, 2^64 - 1]. A Word64 decoder takes it exactly, a Float decoder as the double it parses to,
 *           every other decoder refuses it as it refuses the double (an Int is below 2^63, L21); inside a Json.Value payload it becomes
 *           that double (fic_pv_plain), so Json.Decode results do not change.
 *   HV_VEC  {vec, n, elem, data[]}: a raw vector of n numbers of one element kind (D9). The 8 byte kinds (I64, U64, F64) hold the
 *           program's Vector itself (vec, counted): zero copy both ways. The narrow kinds hold their elements at natural width in
 *           data[] (D10, until G30 makes a Vector Word8 one byte per element): outgoing, the encoder narrows into it once; incoming,
 *           it is the staging buffer of fic_hv_vector_alloc, widened into a new Vector by the decoder in one pass. A uint8_t cannot be
 *           out of range, so the widening needs no check. A Vector port takes such a node only of its own element kind; inside a
 *           Json.Value payload it becomes an array of numbers.
 *
 * Depth (F2): the JSON text parser of the host, the JSON writer (fic_hv_to_json, the value in an error text) and the conversion of a
 * Json.Value payload keep their own stack of open containers, so no depth exits or overflows the C stack. An error text stops
 * printing the refused value after FIC_PORTS_ERR_BUDGET bytes and ends it with `...` (Elm's text is unchanged below that size).
 */

#define FIC_TAG_JUINT   0xFFEBu     /* an integer in (2^63 - 1, 2^64 - 1] (host side only) */
#define FIC_TAG_HV_VEC  0xFFECu     /* a raw vector of numbers (host side only) */

#ifndef FIC_PORTS_ERR_BUDGET
#define FIC_PORTS_ERR_BUDGET 1048576
#endif

typedef struct { fic_hdr h; uint64_t u; } fic_juint;
typedef struct { fic_hdr h; fic_ref vec; int64_t n; uint32_t elem; uint32_t spare; unsigned char data[]; } fic_hvvec;

/* the number of JUINT and HV_VEC nodes ever made: while it is 0 a Json.Value payload cannot hold one, and is not walked */
static uint64_t fic_hv_specials;

static const unsigned char fic_el_size[10] = { 1, 2, 4, 8, 1, 2, 4, 8, 4, 8 };
static const char *const fic_el_name[10] = { "INT8", "INT16", "INT32", "INT", "WORD8", "WORD16", "WORD32", "WORD64", "FLOAT32", "FLOAT" };
#define FIC_EL_WIDE(k) ((k) == FIC_EL_I64 || (k) == FIC_EL_U64 || (k) == FIC_EL_F64)

static int fic_hv_int_of(fic_ref v, int64_t *out);         /* runtime/fic_ports.h (Json.Decode.int's rule, L21) */

/* ---- JUINT and the sized numbers (D5) ---- */

static fic_ref fic_pv_juint(uint64_t u) {
  fic_juint *o = (fic_juint *)fic_alloc(sizeof(fic_juint), FIC_TAG_JUINT, 0);
  o->u = u;
  fic_hv_specials++;
  return &o->h;
}

fic_hv fic_hv_uint(uint64_t u) { return u <= (uint64_t)INT64_MAX ? fic_json_int((int64_t)u) : fic_pv_juint(u); }

/* a whole number in [0, 2^64): an Int node that is not negative, a JUINT, or a Float node that is a whole number in range */
static int fic_pv_uint_of(fic_ref v, uint64_t *out) {
  if (v->tag == FIC_TAG_JINT) { int64_t i = ((fic_jint *)v)->i; if (i < 0) return 0; *out = (uint64_t)i; return 1; }
  if (v->tag == FIC_TAG_JUINT) { *out = ((fic_juint *)v)->u; return 1; }
  if (v->tag == FIC_TAG_JFLOAT) {
    double x = ((fic_jfloat *)v)->d;
    if (x >= 0.0 && x < 18446744073709551616.0 && x == (double)(uint64_t)x) { *out = (uint64_t)x; return 1; }
  }
  return 0;
}

int fic_hv_get_uint(fic_hv v, uint64_t *out) {
  uint64_t u;
  if (v == NULL || out == NULL || !fic_pv_uint_of(v, &u)) return FIC_E_INVALID;
  *out = u;
  return FIC_OK;
}

/* the range of a narrow integer type by its description character (Ficcus.Mono.PortFic) */
static int fic_pv_range(char d, int64_t *lo, int64_t *hi, const char **what) {
  switch (d) {
  case 'c': *lo = -128; *hi = 127; *what = "an INT8 (a whole number from -128 to 127)"; return 1;
  case 'h': *lo = -32768; *hi = 32767; *what = "an INT16 (a whole number from -32768 to 32767)"; return 1;
  case 'n': *lo = -2147483647 - 1; *hi = 2147483647; *what = "an INT32 (a whole number from -2147483648 to 2147483647)"; return 1;
  case 'C': *lo = 0; *hi = 255; *what = "a WORD8 (a whole number from 0 to 255)"; return 1;
  case 'H': *lo = 0; *hi = 65535; *what = "a WORD16 (a whole number from 0 to 65535)"; return 1;
  case 'N': *lo = 0; *hi = 4294967295; *what = "a WORD32 (a whole number from 0 to 4294967295)"; return 1;
  default: return 0;
  }
}

/* the decoders of the generated code (out: the 8 byte slot of the type) */
static FIC_UNUSED int fic_pv_int_in(fic_ref j, char d, int64_t *out) {
  int64_t x, lo, hi;
  const char *what;
  if (!fic_pv_range(d, &lo, &hi, &what) || !fic_hv_int_of(j, &x) || x < lo || x > hi) return 0;
  *out = x;
  return 1;
}

static FIC_UNUSED int fic_pv_u64_in(fic_ref j, int64_t *out) {
  uint64_t u;
  if (!fic_pv_uint_of(j, &u)) return 0;
  *out = (int64_t)u;                                        /* the bits (runtime/fic_sized.h) */
  return 1;
}

/* Float32.fromFloat of the number's double (D5): out of range is an infinity, not a failure */
static FIC_UNUSED int fic_pv_f32_in(fic_ref j, double *out) {
  double d;
  if (j->tag == FIC_TAG_JINT) d = (double)((fic_jint *)j)->i;
  else if (j->tag == FIC_TAG_JFLOAT) d = ((fic_jfloat *)j)->d;
  else if (j->tag == FIC_TAG_JUINT) d = (double)((fic_juint *)j)->u;
  else return 0;
  *out = (double)(float)d;
  return 1;
}

static FIC_UNUSED fic_ref fic_pv_u64_out(int64_t bits) { return bits >= 0 ? fic_json_int(bits) : fic_pv_juint((uint64_t)bits); }

/* the slow path (fic_pd_explain): NULL when the fast decoder takes v, else Elm's style of Error; d one of c h n C H N W g */
static fic_ref fic_pv_explain_sized(char d, fic_ref v) {
  int64_t x, lo, hi;
  uint64_t u;
  const char *what;
  if (d == 'W') return fic_pv_uint_of(v, &u) ? NULL : fic_jd_expecting("a WORD64 (a whole number from 0 to 18446744073709551615)", v);
  if (d == 'g') return v->tag == FIC_TAG_JINT || v->tag == FIC_TAG_JFLOAT || v->tag == FIC_TAG_JUINT ? NULL : fic_jd_expecting("a FLOAT", v);
  if (!fic_pv_range(d, &lo, &hi, &what)) return NULL;
  return fic_hv_int_of(v, &x) && x >= lo && x <= hi ? NULL : fic_jd_expecting(what, v);
}

/* ---- raw vectors (D9, D10) ---- */

/* the element kind of a description character, or -1 when a Vector of that type does not cross raw */
static int fic_pv_desc_el(char d) {
  switch (d) {
  case 'i': return FIC_EL_I64;  case 'f': return FIC_EL_F64;
  case 'c': return FIC_EL_I8;   case 'h': return FIC_EL_I16;  case 'n': return FIC_EL_I32;
  case 'C': return FIC_EL_U8;   case 'H': return FIC_EL_U16;  case 'N': return FIC_EL_U32;  case 'W': return FIC_EL_U64;
  case 'g': return FIC_EL_F32;
  default: return -1;
  }
}

/* a Vector of n 8 byte elements without references (runtime/fic_vector.h fic_vector_new, which a program may not contain) */
static fic_ref fic_pv_vector_new(int64_t n) {
  fic_vector *v = (fic_vector *)fic_alloc(sizeof(fic_vector) + (size_t)n * 8u, FIC_TAG_VECTOR, 0);
  v->esize = 8; v->spare = 0; v->len = n; v->cap = n; v->desc = NULL;
  return &v->h;
}

static fic_hvvec *fic_pv_hvvec_new(int elem, int64_t n, fic_ref vec) {
  size_t extra = vec != NULL ? 0 : (size_t)n * fic_el_size[elem];
  fic_hvvec *h = (fic_hvvec *)fic_alloc(sizeof(fic_hvvec) + extra, FIC_TAG_HV_VEC, vec != NULL ? 1 : 0);
  h->vec = vec; h->n = n; h->elem = (uint32_t)elem; h->spare = 0;
  fic_hv_specials++;
  return h;
}

static int fic_pv_count_ok(int elem, size_t n) {
  return elem >= FIC_EL_I8 && elem <= FIC_EL_F64 && n <= (SIZE_MAX / 2 - sizeof(fic_vector) - sizeof(fic_hvvec)) / 8u;
}

fic_hv fic_hv_vector_alloc(enum fic_el elem, size_t n, void **data) {
  fic_hvvec *h;
  if (data == NULL || !fic_pv_count_ok((int)elem, n)) return NULL;
  if (FIC_EL_WIDE(elem)) {
    fic_ref vec = fic_pv_vector_new((int64_t)n);
    h = fic_pv_hvvec_new((int)elem, (int64_t)n, vec);
    *data = FIC_VECTOR(vec)->data;
  } else {
    h = fic_pv_hvvec_new((int)elem, (int64_t)n, NULL);
    *data = h->data;
  }
  return &h->h;
}

fic_hv fic_hv_vector_copy(enum fic_el elem, const void *data, size_t n) {
  void *p;
  fic_hv v;
  if (n > 0 && data == NULL) return NULL;
  v = fic_hv_vector_alloc(elem, n, &p);
  if (v != NULL && n > 0) memcpy(p, data, n * fic_el_size[elem]);
  return v;
}

const void *fic_hv_vector(fic_hv v, enum fic_el *elem, size_t *n) {
  fic_hvvec *h = (fic_hvvec *)v;
  if (v == NULL || v->tag != FIC_TAG_HV_VEC) return NULL;
  if (elem != NULL) *elem = (enum fic_el)h->elem;
  if (n != NULL) *n = (size_t)h->n;
  return h->vec != NULL ? (const void *)FIC_VECTOR(h->vec)->data : (const void *)h->data;
}

/* the encoder of a Vector of fixed width numbers (vec borrowed; 8 byte elements, as every such Vector is stored today) */
static FIC_UNUSED fic_ref fic_pv_vec_out(fic_ref vec, int elem) {
  int64_t i, n = FIC_VECTOR(vec)->len;
  const int64_t *xi = (const int64_t *)(const void *)FIC_VECTOR(vec)->data;
  const double *xd = (const double *)(const void *)FIC_VECTOR(vec)->data;
  fic_hvvec *h;
  if (FIC_EL_WIDE(elem)) { FIC_RC_DUP(vec); return &fic_pv_hvvec_new(elem, n, vec)->h; }
  h = fic_pv_hvvec_new(elem, n, NULL);
  switch (elem) {                                           /* the values are in range: the type's invariant */
  case FIC_EL_I8:  { int8_t *o = (int8_t *)(void *)h->data; for (i = 0; i < n; i++) o[i] = (int8_t)xi[i]; break; }
  case FIC_EL_I16: { int16_t *o = (int16_t *)(void *)h->data; for (i = 0; i < n; i++) o[i] = (int16_t)xi[i]; break; }
  case FIC_EL_I32: { int32_t *o = (int32_t *)(void *)h->data; for (i = 0; i < n; i++) o[i] = (int32_t)xi[i]; break; }
  case FIC_EL_U8:  { uint8_t *o = (uint8_t *)(void *)h->data; for (i = 0; i < n; i++) o[i] = (uint8_t)xi[i]; break; }
  case FIC_EL_U16: { uint16_t *o = (uint16_t *)(void *)h->data; for (i = 0; i < n; i++) o[i] = (uint16_t)xi[i]; break; }
  case FIC_EL_U32: { uint32_t *o = (uint32_t *)(void *)h->data; for (i = 0; i < n; i++) o[i] = (uint32_t)xi[i]; break; }
  default:         { float *o = (float *)(void *)h->data; for (i = 0; i < n; i++) o[i] = (float)xd[i]; break; }   /* F32: exact */
  }
  return &h->h;
}

/* the decoder of a Vector of fixed width numbers from a raw node j (borrowed): 0 when its element kind is another one */
static FIC_UNUSED int fic_pv_vec_in(fic_ref j, int elem, fic_ref *out) {
  fic_hvvec *h = (fic_hvvec *)j;
  fic_ref r;
  int64_t i, n = h->n;
  int64_t *wi;
  double *wd;
  if ((int)h->elem != elem) return 0;
  if (FIC_EL_WIDE(elem)) { FIC_RC_DUP(h->vec); *out = h->vec; return 1; }   /* moved: unique once send releases the node (D3) */
  r = fic_pv_vector_new(n);
  wi = (int64_t *)(void *)FIC_VECTOR(r)->data; wd = (double *)(void *)FIC_VECTOR(r)->data;
  switch (elem) {                                           /* D10: one widening pass; a natural width value is in range */
  case FIC_EL_I8:  { const int8_t *s = (const int8_t *)(const void *)h->data; for (i = 0; i < n; i++) wi[i] = s[i]; break; }
  case FIC_EL_I16: { const int16_t *s = (const int16_t *)(const void *)h->data; for (i = 0; i < n; i++) wi[i] = s[i]; break; }
  case FIC_EL_I32: { const int32_t *s = (const int32_t *)(const void *)h->data; for (i = 0; i < n; i++) wi[i] = s[i]; break; }
  case FIC_EL_U8:  { const uint8_t *s = (const uint8_t *)(const void *)h->data; for (i = 0; i < n; i++) wi[i] = s[i]; break; }
  case FIC_EL_U16: { const uint16_t *s = (const uint16_t *)(const void *)h->data; for (i = 0; i < n; i++) wi[i] = s[i]; break; }
  case FIC_EL_U32: { const uint32_t *s = (const uint32_t *)(const void *)h->data; for (i = 0; i < n; i++) wi[i] = s[i]; break; }
  default:         { const float *s = (const float *)(const void *)h->data; for (i = 0; i < n; i++) wd[i] = s[i]; break; }
  }
  *out = r;
  return 1;
}

/* element i of a raw node as a JSON number node (Json.Value's view) */
static fic_ref fic_pv_vec_node(fic_hvvec *h, int64_t i) {
  const void *p = h->vec != NULL ? (const void *)FIC_VECTOR(h->vec)->data : (const void *)h->data;
  switch (h->elem) {
  case FIC_EL_I8: return fic_json_int(((const int8_t *)p)[i]);
  case FIC_EL_I16: return fic_json_int(((const int16_t *)p)[i]);
  case FIC_EL_I32: return fic_json_int(((const int32_t *)p)[i]);
  case FIC_EL_I64: return fic_json_int(((const int64_t *)p)[i]);
  case FIC_EL_U8: return fic_json_int(((const uint8_t *)p)[i]);
  case FIC_EL_U16: return fic_json_int(((const uint16_t *)p)[i]);
  case FIC_EL_U32: return fic_json_int(((const uint32_t *)p)[i]);
  case FIC_EL_U64: { uint64_t u = ((const uint64_t *)p)[i]; return u <= (uint64_t)INT64_MAX ? fic_json_int((int64_t)u) : fic_json_float((double)u); }
  case FIC_EL_F32: return fic_json_float(((const float *)p)[i]);
  default: return fic_json_float(((const double *)p)[i]);
  }
}

/* ---- walks without recursion (F2) ---- */

typedef struct { fic_ref c; int64_t i, n; fic_ref out; } fic_pv_frame;
typedef struct { fic_pv_frame *f; size_t n, cap; } fic_pv_stack;

static fic_pv_frame *fic_pv_push(fic_pv_stack *s, fic_ref c, int64_t n) {
  if (s->n == s->cap) {
    s->cap = s->cap == 0 ? 64 : s->cap * 2;
    s->f = (fic_pv_frame *)realloc(s->f, s->cap * sizeof(fic_pv_frame));
    if (s->f == NULL) abort();
  }
  s->f[s->n].c = c; s->f[s->n].i = 0; s->f[s->n].n = n; s->f[s->n].out = NULL;
  return &s->f[s->n++];
}

static int fic_pv_is_container(fic_ref v) { return v->tag == FIC_TAG_VEC_REF || v->tag == FIC_TAG_JOBJ; }
static int64_t fic_pv_len(fic_ref c) { return c->tag == FIC_TAG_JOBJ ? fic_json_len(((fic_jobj *)c)->keys) : fic_json_len(c); }
static fic_ref fic_pv_item(fic_ref c, int64_t i) { return c->tag == FIC_TAG_JOBJ ? fic_json_at(((fic_jobj *)c)->vals, i) : fic_json_at(c, i); }

/* a host leaf as Json.Decode sees it (owned), or NULL when it is one already */
static fic_ref fic_pv_plain_leaf(fic_ref v) {
  if (v->tag == FIC_TAG_JUINT) return fic_json_float((double)((fic_juint *)v)->u);
  if (v->tag == FIC_TAG_HV_VEC) {
    fic_hvvec *h = (fic_hvvec *)v;
    fic_ref r = fic_ja_new(h->n, FIC_TAG_VEC_REF);
    int64_t i;
    for (i = 0; i < h->n; i++) fic_ja_data(r)[i].p = fic_pv_vec_node(h, i);
    return r;
  }
  return NULL;
}

/* a frame's child i is r (owned; NULL: the child unchanged): the frame's copy is made at the first change */
static void fic_pv_plain_put(fic_pv_frame *f, fic_ref r) {
  if (r == NULL && f->out == NULL) return;
  if (f->out == NULL) {
    int64_t k;
    f->out = fic_ja_new(f->n, FIC_TAG_VEC_REF);
    for (k = 0; k < f->i; k++) { fic_ref x = fic_pv_item(f->c, k); FIC_RC_DUP(x); fic_ja_data(f->out)[k].p = x; }
  }
  if (r == NULL) { r = fic_pv_item(f->c, f->i); FIC_RC_DUP(r); }
  fic_ja_data(f->out)[f->i].p = r;
}

/* the Json.Value of a payload (v borrowed; owned result): v itself unless it holds a JUINT or a raw vector node, else a copy of the
   containers on the way to them, with those nodes converted */
static FIC_UNUSED fic_ref fic_pv_plain(fic_ref v) {
  fic_pv_stack s = { NULL, 0, 0 };
  fic_ref r = NULL;
  if (fic_hv_specials == 0 || !fic_pv_is_container(v)) {
    r = fic_hv_specials == 0 ? NULL : fic_pv_plain_leaf(v);
    if (r == NULL) { FIC_RC_DUP(v); r = v; }
    return r;
  }
  fic_pv_push(&s, v, fic_pv_len(v));
  for (;;) {
    fic_pv_frame *f = &s.f[s.n - 1];
    if (f->i < f->n) {
      fic_ref c = fic_pv_item(f->c, f->i);
      if (fic_pv_is_container(c)) { fic_pv_push(&s, c, fic_pv_len(c)); continue; }
      fic_pv_plain_put(f, fic_pv_plain_leaf(c));
      f->i++;
      continue;
    }
    r = f->out;                                            /* this container done: its copy, or NULL when unchanged */
    if (r != NULL && f->c->tag == FIC_TAG_JOBJ) { fic_ref k = ((fic_jobj *)f->c)->keys; FIC_RC_DUP(k); r = fic_json_obj_new(k, r); }
    if (--s.n == 0) break;
    f = &s.f[s.n - 1];
    fic_pv_plain_put(f, r);
    f->i++;
  }
  free(s.f);
  if (r == NULL) { FIC_RC_DUP(v); r = v; }
  return r;
}

/* JSON.stringify(v, null, indent) of a host value; stops after `budget` bytes (the last item may pass it) with `...`: 0 then, else 1 */
static void fic_pv_put_leaf(fic_sb *b, fic_ref v) {
  if (v->tag == FIC_TAG_JUINT) { char buf[24]; snprintf(buf, sizeof buf, "%llu", (unsigned long long)((fic_juint *)v)->u); fic_sb_puts(b, buf); }
  else fic_json_put(b, v, 0, 0);                            /* a leaf: null, a Bool, a number, a string */
}

static void fic_pv_put_el(fic_sb *b, fic_hvvec *h, int64_t i) {
  const void *p = h->vec != NULL ? (const void *)FIC_VECTOR(h->vec)->data : (const void *)h->data;
  char buf[32];
  double d;
  switch (h->elem) {
  case FIC_EL_I8: fic_sb_int(b, ((const int8_t *)p)[i]); return;
  case FIC_EL_I16: fic_sb_int(b, ((const int16_t *)p)[i]); return;
  case FIC_EL_I32: fic_sb_int(b, ((const int32_t *)p)[i]); return;
  case FIC_EL_I64: fic_sb_int(b, ((const int64_t *)p)[i]); return;
  case FIC_EL_U8: fic_sb_int(b, ((const uint8_t *)p)[i]); return;
  case FIC_EL_U16: fic_sb_int(b, ((const uint16_t *)p)[i]); return;
  case FIC_EL_U32: fic_sb_int(b, ((const uint32_t *)p)[i]); return;
  case FIC_EL_U64: snprintf(buf, sizeof buf, "%llu", (unsigned long long)((const uint64_t *)p)[i]); fic_sb_puts(b, buf); return;
  case FIC_EL_F32: d = ((const float *)p)[i]; break;
  default: d = ((const double *)p)[i]; break;
  }
  if (d != d || d > 1.7976931348623157e308 || d < -1.7976931348623157e308) fic_sb_puts(b, "null");   /* L20 */
  else fic_sb_float(b, d);
}

static void fic_pv_newline(fic_sb *b, int64_t spaces) {
  fic_sb_putn(b, "\n", 1);
  while (spaces >= 16) { fic_sb_putn(b, "                ", 16); spaces -= 16; }
  if (spaces > 0) fic_sb_putn(b, "                ", spaces);
}

static int fic_pv_put(fic_sb *b, fic_ref v, int64_t indent, int64_t budget) {
  fic_pv_stack s = { NULL, 0, 0 };
  int ok = 1;
  if (!fic_pv_is_container(v) && v->tag != FIC_TAG_HV_VEC) { fic_pv_put_leaf(b, v); return 1; }
  for (;;) {
    fic_ref c;
    fic_pv_frame *f;
    if (v != NULL) {                                       /* open a container (or a raw vector) */
      int64_t n = v->tag == FIC_TAG_HV_VEC ? ((fic_hvvec *)v)->n : fic_pv_len(v);
      if (n == 0) fic_sb_puts(b, v->tag == FIC_TAG_JOBJ ? "{}" : "[]");
      else { fic_sb_putn(b, v->tag == FIC_TAG_JOBJ ? "{" : "[", 1); fic_pv_push(&s, v, n); }
      v = NULL;
      if (s.n == 0) break;
    }
    if (b->n > budget) { fic_sb_puts(b, "..."); ok = 0; break; }
    f = &s.f[s.n - 1];
    if (f->i >= f->n) {                                    /* close it */
      if (indent > 0) fic_pv_newline(b, indent * (int64_t)(s.n - 1));
      fic_sb_putn(b, f->c->tag == FIC_TAG_JOBJ ? "}" : "]", 1);
      if (--s.n == 0) break;
      continue;
    }
    if (f->i > 0) fic_sb_putn(b, ",", 1);
    if (indent > 0) fic_pv_newline(b, indent * (int64_t)s.n);
    if (f->c->tag == FIC_TAG_HV_VEC) { fic_pv_put_el(b, (fic_hvvec *)f->c, f->i++); continue; }
    if (f->c->tag == FIC_TAG_JOBJ) {
      fic_json_put_string(b, fic_json_at(((fic_jobj *)f->c)->keys, f->i));
      fic_sb_puts(b, indent > 0 ? ": " : ":");
    }
    c = fic_pv_item(f->c, f->i++);
    if (fic_pv_is_container(c) || c->tag == FIC_TAG_HV_VEC) v = c;
    else fic_pv_put_leaf(b, c);
  }
  free(s.f);
  return ok;
}

/* ---- JSON.parse for the host (D8): runtime/fic_json.h's leaves and rules, its own stack of open containers (no depth limit), and
        an integer literal in (2^63 - 1, 2^64 - 1] as a JUINT (D5) ---- */

static fic_ref fic_pv_parse_number(fic_json_in *in) {
  const unsigned char *s = in->p, *q;
  fic_ref r = fic_json_parse_number(in);
  uint64_t u = 0;
  if (r == NULL || r->tag != FIC_TAG_JFLOAT || in->p - s > 20) return r;
  for (q = s; q < in->p; q++) {                            /* only digits: a whole number without sign, fraction or exponent */
    uint64_t dgt;
    if (*q < '0' || *q > '9') return r;
    dgt = (uint64_t)(*q - '0');
    if (u > (UINT64_MAX - dgt) / 10u) return r;            /* 2^64 or more: the double */
    u = u * 10u + dgt;
  }
  FIC_RC_DROP(r);
  return fic_pv_juint(u);
}

typedef struct { int object; fic_ref *ks, *vs, key; int64_t n, cap; } fic_pv_open;

static void fic_pv_open_drop(fic_pv_open *o) {
  int64_t i;
  for (i = 0; i < o->n; i++) { if (o->object) FIC_RC_DROP(o->ks[i]); FIC_RC_DROP(o->vs[i]); }
  if (o->key != NULL) FIC_RC_DROP(o->key);
  free(o->ks); free(o->vs);
}

/* after `{` or `,` in an object: the key and the colon (0 when they are not there) */
static int fic_pv_parse_key(fic_json_in *in, fic_pv_open *o) {
  fic_json_ws(in);
  if (in->p >= in->end || *in->p != '"') return 0;
  in->p++;
  o->key = fic_json_parse_string(in);
  if (o->key == NULL) return 0;
  fic_json_ws(in);
  if (in->p >= in->end || *in->p != ':') return 0;
  in->p++;
  return 1;
}

static fic_ref fic_pv_parse_value(fic_json_in *in) {
  fic_pv_open *st = NULL;
  size_t n = 0, cap = 0;
  fic_ref v = NULL;
  for (;;) {
    /* a value: a leaf in v, or a container opened on the stack */
    fic_json_ws(in);
    if (in->p >= in->end) goto fail;
    switch (*in->p) {
    case '{': case '[': {
      int object = *in->p == '{';
      in->p++;
      if (n == cap) { cap = cap == 0 ? 16 : cap * 2; st = (fic_pv_open *)realloc(st, cap * sizeof(fic_pv_open)); if (st == NULL) abort(); }
      memset(&st[n], 0, sizeof(fic_pv_open));
      st[n++].object = object;
      fic_json_ws(in);
      if (in->p < in->end && *in->p == (object ? '}' : ']')) { in->p++; v = NULL; break; }   /* empty: closed below */
      if (object && !fic_pv_parse_key(in, &st[n - 1])) goto fail;
      continue; }
    case '"': in->p++; v = fic_json_parse_string(in); if (v == NULL) goto fail; break;
    case 't': if (in->end - in->p >= 4 && memcmp(in->p, "true", 4) == 0) { in->p += 4; v = fic_json_bool(1); break; } goto fail;
    case 'f': if (in->end - in->p >= 5 && memcmp(in->p, "false", 5) == 0) { in->p += 5; v = fic_json_bool(0); break; } goto fail;
    case 'n': if (in->end - in->p >= 4 && memcmp(in->p, "null", 4) == 0) { in->p += 4; v = fic_json_null(); break; } goto fail;
    default: v = fic_pv_parse_number(in); if (v == NULL) goto fail; break;
    }
    /* v done (NULL: the empty container on top of the stack); store it and close what ends here */
    for (;;) {
      fic_pv_open *o;
      if (v == NULL) {                                     /* the container on top is complete: build it */
        fic_pv_open *t = &st[--n];
        int64_t i;
        if (t->object) v = fic_json_obj_build(t->ks, t->vs, t->n);
        else { v = fic_ja_new(t->n, FIC_TAG_VEC_REF); for (i = 0; i < t->n; i++) fic_ja_data(v)[i].p = t->vs[i]; }
        free(t->ks); free(t->vs);
      }
      if (n == 0) { free(st); return v; }
      o = &st[n - 1];
      if (o->n == o->cap) {
        o->cap = o->cap == 0 ? 8 : o->cap * 2;
        o->vs = (fic_ref *)realloc(o->vs, (size_t)o->cap * sizeof(fic_ref));
        if (o->vs == NULL) abort();
        if (o->object) { o->ks = (fic_ref *)realloc(o->ks, (size_t)o->cap * sizeof(fic_ref)); if (o->ks == NULL) abort(); }
      }
      if (o->object) { o->ks[o->n] = o->key; o->key = NULL; }
      o->vs[o->n++] = v;
      v = NULL;
      fic_json_ws(in);
      if (in->p < in->end && *in->p == ',') {
        in->p++;
        if (o->object && !fic_pv_parse_key(in, o)) goto fail;
        break;                                             /* the next value */
      }
      if (in->p < in->end && *in->p == (o->object ? '}' : ']')) { in->p++; continue; }   /* v = NULL: close o */
      goto fail;
    }
  }
fail:
  if (v != NULL) FIC_RC_DROP(v);
  while (n > 0) fic_pv_open_drop(&st[--n]);
  free(st);
  return NULL;
}
