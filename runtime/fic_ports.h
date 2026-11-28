/* fic_ports.h -- effects slices E3a and E3b: the host interface of ports and flags (docs/E3-PORTS-DESIGN.md D1 to D4, D6 (Array),
 * D7, D8, D11, D12; the declarations and the rules for hosts are in runtime/fic_ports_api.h, which comes just before this file).
 * Needs fic_json.h; the port part (the second half) also needs fic_sched.h. Emitted into programs that have ports or flags.
 *
 * Values. A host value is a node of a Json.Value (fic_json.h). Three more kinds of object exist only here: an array or an object
 * being built (FIC_TAG_HV_ARR, FIC_TAG_HV_OBJ: a slot not set yet holds the static `unset` object), and a string being filled
 * (FIC_TAG_HV_STRBUF: a string object whose bytes are not checked yet). None of them can enter the program: fic_port_send and the
 * setters take only sealed values. JUNDEF is JavaScript's undefined: the flags of a program started without flags (D11). Every
 * decoder refuses it, also Json.Value's (where Elm would let undefined into the program: a recorded deviation).
 *
 * Errors (D7). The generated decoders only say yes or no. On a no, and only then, fic_pd_explain walks the value along a static
 * description of the type and builds the Error that Elm's decoder (Optimize.Port.toDecoder) gives: the same decoders in the same order
 * (oneOf [null, map Just] for Maybe; index 0, 1, 2 for a tuple; the fields of a record in the reverse of Elm's (length, bytes) order,
 * the order of foldM over Map.toList); fic_jd_error_to_string is elm/json's errorToString. Success never pays for this. */

#define FIC_TAG_JUNDEF    0xFFE6u     /* JavaScript's undefined (absent flags; static) */
#define FIC_TAG_HV_ARR    0xFFE7u     /* an array being built: { items } (a JsArray of references) */
#define FIC_TAG_HV_OBJ    0xFFE8u     /* an object being built: { keys, vals } */
#define FIC_TAG_HV_UNSET  0xFFE9u     /* a slot of a builder that was not set (static) */
#define FIC_TAG_HV_STRBUF 0xFFEAu     /* a string being filled (fic_hv_string_alloc) */

static fic_hdr fic_json_undef_obj = { FIC_IMMORTAL, FIC_TAG_JUNDEF, 0, 0 };
static fic_hdr fic_hv_unset_obj = { FIC_IMMORTAL, FIC_TAG_HV_UNSET, 0, 0 };
typedef struct { fic_hdr h; fic_ref items; } fic_hv_arr_b;
typedef struct { fic_hdr h; fic_ref keys; fic_ref vals; } fic_hv_obj_b;

/* ---- the text of the last failure ---- */

static char *fic_port_err_text;
static int fic_app_started;                         /* fic_app_start has run (it runs once) */

static int fic_port_fail_n(int code, const char *s, size_t n) {
  char *t = (char *)malloc(n + 1);
  if (t == NULL) abort();
  if (n > 0) memcpy(t, s, n);
  t[n] = 0;
  free(fic_port_err_text);
  fic_port_err_text = t;
  return code;
}
static int fic_port_fail(int code, const char *what, const char *name) {
  char buf[512];
  snprintf(buf, sizeof buf, what, name != NULL ? name : "");
  return fic_port_fail_n(code, buf, strlen(buf));
}
const char *fic_port_error(void) { return fic_port_err_text != NULL ? fic_port_err_text : ""; }

/* ---- UTF-8 (D4): the rule of a Ficcus String: no overlong forms, no surrogates, at most U+10FFFF ---- */

static int fic_utf8_valid(const char *s, size_t n) {
  const unsigned char *p = (const unsigned char *)s, *e = p + n;
  while (p < e) {
    unsigned c = *p;
    if (c < 0x80u) { p++; continue; }
    if (c >= 0xC2u && c <= 0xDFu) {
      if (e - p < 2 || (p[1] & 0xC0u) != 0x80u) return 0;
      p += 2;
    } else if (c >= 0xE0u && c <= 0xEFu) {
      if (e - p < 3 || (p[1] & 0xC0u) != 0x80u || (p[2] & 0xC0u) != 0x80u) return 0;
      if (c == 0xE0u && p[1] < 0xA0u) return 0;                   /* overlong */
      if (c == 0xEDu && p[1] >= 0xA0u) return 0;                  /* a surrogate */
      p += 3;
    } else if (c >= 0xF0u && c <= 0xF4u) {
      if (e - p < 4 || (p[1] & 0xC0u) != 0x80u || (p[2] & 0xC0u) != 0x80u || (p[3] & 0xC0u) != 0x80u) return 0;
      if (c == 0xF0u && p[1] < 0x90u) return 0;                   /* overlong */
      if (c == 0xF4u && p[1] >= 0x90u) return 0;                  /* above U+10FFFF */
      p += 4;
    } else return 0;
  }
  return 1;
}

/* a node of a Json.Value (sealed): what a port, a setter and the readers accept */
static int fic_hv_sealed(fic_ref v) {
  if (v == NULL) return 0;
  switch (v->tag) {
  case FIC_TAG_JNULL: case FIC_TAG_JBOOL: case FIC_TAG_JINT: case FIC_TAG_JFLOAT: case FIC_TAG_STRING: case FIC_TAG_VEC_REF: case FIC_TAG_JOBJ:
  case FIC_TAG_JUINT: case FIC_TAG_HV_VEC:                 /* E3c, E3d (runtime/fic_ports_fic.h) */
    return 1;
  default:
    return 0;
  }
}

/* ---- build ---- */

fic_hv fic_hv_null(void) { return fic_json_null(); }
fic_hv fic_hv_bool(int b) { return fic_json_bool(b != 0 ? 1u : 0u); }
fic_hv fic_hv_int(int64_t i) { return fic_json_int(i); }
fic_hv fic_hv_float(double d) { return fic_json_float(d); }

fic_hv fic_hv_string(const char *utf8, size_t n) {
  if (utf8 == NULL && n > 0) return NULL;
  if (n > 0 && !fic_utf8_valid(utf8, n)) return NULL;
  return fic_str_new(n > 0 ? utf8 : "", (int64_t)n);
}

fic_hv fic_hv_string_alloc(size_t n, char **p) {
  fic_string *s;
  if (p == NULL || n > ((size_t)1 << 48)) return NULL;
  s = (fic_string *)fic_alloc(sizeof(fic_string) + n + 1, FIC_TAG_HV_STRBUF, 0);
  s->len = (int64_t)n; s->cps = 0; s->data[n] = 0;
  *p = s->data;
  return &s->h;
}

fic_hv fic_hv_string_seal(fic_hv v) {
  fic_string *s;
  if (v == NULL) return NULL;
  if (v->tag == FIC_TAG_STRING) return v;
  if (v->tag != FIC_TAG_HV_STRBUF) { FIC_RC_DROP(v); return NULL; }
  s = FIC_STR(v);
  s->data[s->len] = 0;
  if (!fic_utf8_valid(s->data, (size_t)s->len)) { FIC_RC_DROP(v); return NULL; }
  s->cps = fic_str_cps_of(s->data, s->len);
  v->tag = FIC_TAG_STRING;
  return v;
}

static fic_ref fic_hv_slots(size_t n) {                /* a JsArray of n unset slots */
  fic_ref a = fic_ja_new((int64_t)n, FIC_TAG_VEC_REF);
  size_t i;
  for (i = 0; i < n; i++) { FIC_RC_DUP(&fic_hv_unset_obj); fic_ja_data(a)[i].p = &fic_hv_unset_obj; }
  return a;
}

fic_hv fic_hv_array(size_t n) {
  fic_hv_arr_b *b;
  if (n > ((size_t)1 << 40)) return NULL;
  b = (fic_hv_arr_b *)fic_alloc(sizeof(fic_hv_arr_b), FIC_TAG_HV_ARR, 1);
  b->items = fic_hv_slots(n);
  return &b->h;
}

fic_hv fic_hv_object(size_t n) {
  fic_hv_obj_b *b;
  if (n > ((size_t)1 << 40)) return NULL;
  b = (fic_hv_obj_b *)fic_alloc(sizeof(fic_hv_obj_b), FIC_TAG_HV_OBJ, 2);
  b->keys = fic_hv_slots(n); b->vals = fic_hv_slots(n);
  return &b->h;
}

static void fic_hv_put(fic_ref arr, size_t i, fic_ref v) {       /* consumes v */
  fic_ref old = fic_ja_data(arr)[i].p;
  fic_ja_data(arr)[i].p = v;
  FIC_RC_DROP(old);
}

int fic_hv_array_set(fic_hv a, size_t i, fic_hv v) {
  fic_ref items;
  if (v == NULL) return fic_port_fail(FIC_E_INVALID, "fic_hv_array_set: no value%s", NULL);
  if (a == NULL || a->tag != FIC_TAG_HV_ARR) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_hv_array_set: not an array being built%s", NULL); }
  if (!fic_hv_sealed(v)) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_hv_array_set: the value is an unsealed array, object or string%s", NULL); }
  items = ((fic_hv_arr_b *)a)->items;
  if (i >= (size_t)fic_ja_length(items)) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_hv_array_set: index out of range%s", NULL); }
  fic_hv_put(items, i, v);
  return FIC_OK;
}

int fic_hv_object_set(fic_hv o, size_t i, const char *key, size_t kn, fic_hv v) {
  fic_hv_obj_b *b;
  if (v == NULL) return fic_port_fail(FIC_E_INVALID, "fic_hv_object_set: no value%s", NULL);
  if (o == NULL || o->tag != FIC_TAG_HV_OBJ) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_hv_object_set: not an object being built%s", NULL); }
  if (!fic_hv_sealed(v)) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_hv_object_set: the value is an unsealed array, object or string%s", NULL); }
  b = (fic_hv_obj_b *)o;
  if (i >= (size_t)fic_ja_length(b->keys)) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_hv_object_set: index out of range%s", NULL); }
  if ((key == NULL && kn > 0) || (kn > 0 && !fic_utf8_valid(key, kn))) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_hv_object_set: the key is not valid UTF-8%s", NULL); }
  fic_hv_put(b->keys, i, fic_str_new(kn > 0 ? key : "", (int64_t)kn));
  fic_hv_put(b->vals, i, v);
  return FIC_OK;
}

static int fic_hv_all_set(fic_ref arr) {
  int64_t i, n = fic_ja_length(arr);
  for (i = 0; i < n; i++) if (fic_ja_data(arr)[i].p == &fic_hv_unset_obj) return 0;
  return 1;
}

fic_hv fic_hv_finish(fic_hv v) {
  if (v == NULL) return NULL;
  if (v->tag != FIC_TAG_HV_ARR && v->tag != FIC_TAG_HV_OBJ) return v;
#ifdef FIC_RC
  if (v->rc != 1) { fic_port_fail(FIC_E_INVALID, "fic_hv_finish: the builder is shared (retained)%s", NULL); FIC_RC_DROP(v); return NULL; }
#endif
  if (v->tag == FIC_TAG_HV_ARR) {
    fic_ref items = ((fic_hv_arr_b *)v)->items;
    if (!fic_hv_all_set(items)) { fic_port_fail(FIC_E_INVALID, "fic_hv_finish: a slot of the array was not set%s", NULL); FIC_RC_DROP(v); return NULL; }
    FIC_RC_DUP(items);
    FIC_RC_DROP(v);
    return items;
  } else {
    fic_hv_obj_b *b = (fic_hv_obj_b *)v;
    int64_t i, n = fic_ja_length(b->keys);
    fic_ref *ks, *vs, r;
    if (!fic_hv_all_set(b->keys)) { fic_port_fail(FIC_E_INVALID, "fic_hv_finish: a slot of the object was not set%s", NULL); FIC_RC_DROP(v); return NULL; }
    ks = (fic_ref *)malloc((size_t)(n + 1) * sizeof(fic_ref));
    vs = (fic_ref *)malloc((size_t)(n + 1) * sizeof(fic_ref));
    if (ks == NULL || vs == NULL) abort();
    for (i = 0; i < n; i++) {
      ks[i] = fic_ja_data(b->keys)[i].p; vs[i] = fic_ja_data(b->vals)[i].p;
      FIC_RC_DUP(ks[i]); FIC_RC_DUP(vs[i]);
    }
    FIC_RC_DROP(v);
    r = fic_json_obj_build(ks, vs, n);                         /* L35 order; a later duplicate key wins */
    free(ks); free(vs);
    return r;
  }
}

/* ---- read ---- */

enum fic_hv_kind fic_hv_kind(fic_hv v) {
  if (v == NULL) return FIC_HV_INVALID;
  switch (v->tag) {
  case FIC_TAG_JNULL: return FIC_HV_NULL;
  case FIC_TAG_JBOOL: return FIC_HV_BOOL;
  case FIC_TAG_JINT: return FIC_HV_INT;
  case FIC_TAG_JFLOAT: return FIC_HV_FLOAT;
  case FIC_TAG_STRING: return FIC_HV_STRING;
  case FIC_TAG_VEC_REF: return FIC_HV_ARRAY;
  case FIC_TAG_JOBJ: return FIC_HV_OBJECT;
  case FIC_TAG_JUINT: return FIC_HV_INT;
  case FIC_TAG_HV_VEC: return FIC_HV_VECTOR;
  default: return FIC_HV_INVALID;
  }
}

int fic_hv_get_bool(fic_hv v, int *out) {
  if (v == NULL || out == NULL || v->tag != FIC_TAG_JBOOL) return FIC_E_INVALID;
  *out = ((fic_jbool *)v)->b;
  return FIC_OK;
}

/* an Int as Json.Decode.int takes it (L21): an Int node, or a Float node that is a whole number below 2^63 in size */
static int fic_hv_int_of(fic_ref v, int64_t *out) {
  if (v->tag == FIC_TAG_JINT) { *out = ((fic_jint *)v)->i; return 1; }
  if (v->tag == FIC_TAG_JFLOAT) {
    double x = ((fic_jfloat *)v)->d;
    if (x >= -9223372036854775808.0 && x < 9223372036854775808.0 && x == (double)(int64_t)x) { *out = (int64_t)x; return 1; }
  }
  return 0;
}

int fic_hv_get_int(fic_hv v, int64_t *out) {
  int64_t i;
  if (v == NULL || out == NULL || !fic_hv_int_of(v, &i)) return FIC_E_INVALID;
  *out = i;
  return FIC_OK;
}

int fic_hv_get_float(fic_hv v, double *out) {
  if (v == NULL || out == NULL) return FIC_E_INVALID;
  if (v->tag == FIC_TAG_JFLOAT) { *out = ((fic_jfloat *)v)->d; return FIC_OK; }
  if (v->tag == FIC_TAG_JINT) { *out = (double)((fic_jint *)v)->i; return FIC_OK; }
  if (v->tag == FIC_TAG_JUINT) { *out = (double)((fic_juint *)v)->u; return FIC_OK; }
  return FIC_E_INVALID;
}

const char *fic_hv_get_string(fic_hv v, size_t *n) {
  if (v == NULL || v->tag != FIC_TAG_STRING) return NULL;
  if (n != NULL) *n = (size_t)FIC_STR(v)->len;
  return FIC_STR(v)->data;
}

size_t fic_hv_len(fic_hv v) {
  if (v == NULL) return 0;
  if (v->tag == FIC_TAG_VEC_REF) return (size_t)fic_json_len(v);
  if (v->tag == FIC_TAG_JOBJ) return (size_t)fic_json_len(((fic_jobj *)v)->keys);
  if (v->tag == FIC_TAG_HV_VEC) return (size_t)((fic_hvvec *)v)->n;
  return 0;
}

fic_hv fic_hv_at(fic_hv v, size_t i) {
  if (v == NULL || i >= fic_hv_len(v)) return NULL;
  return v->tag == FIC_TAG_VEC_REF ? fic_json_at(v, (int64_t)i) : fic_json_at(((fic_jobj *)v)->vals, (int64_t)i);
}

const char *fic_hv_key(fic_hv o, size_t i, size_t *n) {
  fic_ref k;
  if (o == NULL || o->tag != FIC_TAG_JOBJ || i >= fic_hv_len(o)) return NULL;
  k = fic_json_at(((fic_jobj *)o)->keys, (int64_t)i);
  if (n != NULL) *n = (size_t)FIC_STR(k)->len;
  return FIC_STR(k)->data;
}

fic_hv fic_hv_field(fic_hv o, const char *key) {
  int64_t i, n;
  size_t kn;
  fic_ref keys;
  if (o == NULL || key == NULL || o->tag != FIC_TAG_JOBJ) return NULL;
  keys = ((fic_jobj *)o)->keys;
  n = fic_json_len(keys); kn = strlen(key);
  for (i = 0; i < n; i++) {
    fic_ref k = fic_json_at(keys, i);
    if ((size_t)FIC_STR(k)->len == kn && memcmp(FIC_STR(k)->data, key, kn) == 0) return fic_json_at(((fic_jobj *)o)->vals, i);
  }
  return NULL;
}

fic_hv fic_hv_retain(fic_hv v) { if (v != NULL) FIC_RC_DUP(v); return v; }
void fic_hv_release(fic_hv v) { if (v != NULL) FIC_RC_DROP(v); }

/* ---- JSON text (D8) ---- */

fic_hv fic_hv_from_json(const char *text, size_t n) {
  fic_json_in in;
  fic_ref v;
  if (text == NULL || !fic_utf8_valid(text, n)) return NULL;
  in.p = (const unsigned char *)text; in.end = in.p + n; in.depth = 0;
  v = fic_pv_parse_value(&in);                              /* E3c: JUINT, no depth limit (runtime/fic_ports_fic.h) */
  if (v == NULL) return NULL;
  fic_json_ws(&in);
  if (in.p != in.end) { FIC_RC_DROP(v); return NULL; }
  return v;
}

char *fic_hv_to_json(fic_hv v, size_t *n) {
  fic_sb b;
  if (!fic_hv_sealed(v)) return NULL;
  fic_sb_init(&b);
  fic_pv_put(&b, v, 0, INT64_MAX);                         /* JSON.stringify (L20: NaN and the infinities are null); any depth (F2) */
  if (n != NULL) *n = (size_t)b.n;
  fic_sb_putn(&b, "", 1);
  return b.p;
}

/* ---- elm/json's errorToString (Json.Decode 1.1.3), line for line ---- */

static void fic_ets_indent(fic_sb *out, const char *s, int64_t n) {       /* indent = String.join "\n    " (String.split "\n" str) */
  int64_t i, from = 0;
  for (i = 0; i < n; i++) if (s[i] == '\n') { fic_sb_putn(out, s + from, i + 1 - from); fic_sb_puts(out, "    "); from = i + 1; }
  fic_sb_putn(out, s + from, n - from);
}

static void fic_ets_encode4(fic_sb *out, fic_ref json) {                 /* indent (Json.Encode.encode 4 json) */
  if (json->tag == FIC_TAG_JUNDEF) fic_sb_puts(out, "undefined");          /* JSON.stringify(undefined) + '' */
  else {
    fic_sb b;
    fic_sb_init(&b);
    fic_pv_put(&b, json, 4, FIC_PORTS_ERR_BUDGET);         /* F2: any depth; a text past the budget ends with `...` */
    fic_ets_indent(out, b.p, b.n);
    free(b.p);
  }
}

static void fic_ets_help(fic_sb *out, fic_ref err, fic_sb *ctx);

static void fic_ets(fic_sb *out, fic_ref err) {                          /* errorToString error = errorToStringHelp error [] */
  fic_sb ctx;
  fic_sb_init(&ctx);
  fic_ets_help(out, err, &ctx);
  free(ctx.p);
}

/* Char.isAlpha and Char.isAlphaNum are ASCII only */
static int fic_ets_simple(fic_ref f) {
  const unsigned char *s = (const unsigned char *)FIC_STR(f)->data;
  int64_t i, n = FIC_STR(f)->len;
  if (n == 0) return 0;
  if (!((s[0] >= 'a' && s[0] <= 'z') || (s[0] >= 'A' && s[0] <= 'Z'))) return 0;
  for (i = 1; i < n; i++) if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= '0' && s[i] <= '9'))) return 0;
  return 1;
}

/* ctx: String.join "" (List.reverse context), the path so far (it is empty exactly when the context is) */
static void fic_ets_help(fic_sb *out, fic_ref err, fic_sb *ctx) {
  for (;;) {
    switch (err->tag) {
    case 0u: {                                                            /* Field f err */
      fic_ref f = ((fic_jd_e2 *)err)->r0;
      if (fic_ets_simple(f)) { fic_sb_puts(ctx, "."); fic_sb_putn(ctx, FIC_STR(f)->data, FIC_STR(f)->len); }
      else { fic_sb_puts(ctx, "['"); fic_sb_putn(ctx, FIC_STR(f)->data, FIC_STR(f)->len); fic_sb_puts(ctx, "']"); }
      err = ((fic_jd_e2 *)err)->r1;
      continue; }
    case 1u: {                                                            /* Index i err */
      char buf[32];
      snprintf(buf, sizeof buf, "[%lld]", (long long)((fic_jd_ei *)err)->s0);
      fic_sb_puts(ctx, buf);
      err = ((fic_jd_ei *)err)->r0;
      continue; }
    case 2u: {                                                            /* OneOf errors */
      fic_ref l = ((fic_jd_e1 *)err)->r0, p;
      int64_t n = 0, i = 0;
      char buf[80];
      for (p = l; p->tag != 0u; p = ((fic_us_cell *)p)->f1) n++;
      if (n == 0) {
        fic_sb_puts(out, "Ran into a Json.Decode.oneOf with no possibilities");
        if (ctx->n == 0) fic_sb_puts(out, "!"); else { fic_sb_puts(out, " at json"); fic_sb_putn(out, ctx->p, ctx->n); }
        return;
      }
      if (n == 1) { err = ((fic_us_cell *)l)->f0; continue; }
      if (ctx->n == 0) fic_sb_puts(out, "Json.Decode.oneOf");
      else { fic_sb_puts(out, "The Json.Decode.oneOf at json"); fic_sb_putn(out, ctx->p, ctx->n); }
      snprintf(buf, sizeof buf, " failed in the following %lld ways:", (long long)n);
      fic_sb_puts(out, buf);
      for (p = l; p->tag != 0u; p = ((fic_us_cell *)p)->f1) {           /* String.join "\n\n" (intro :: indexedMap errorOneOf errors) */
        fic_sb one;
        snprintf(buf, sizeof buf, "\n\n\n\n(%lld) ", (long long)++i);   /* the join's "\n\n", then errorOneOf's "\n\n(i) " */
        fic_sb_puts(out, buf);
        fic_sb_init(&one);
        fic_ets(&one, ((fic_us_cell *)p)->f0);
        fic_ets_indent(out, one.p, one.n);
        free(one.p);
      }
      return; }
    default: {                                                            /* Failure msg json */
      fic_ref msg = ((fic_jd_e2 *)err)->r0, json = ((fic_jd_e2 *)err)->r1;
      if (ctx->n == 0) fic_sb_puts(out, "Problem with the given value:\n\n");
      else { fic_sb_puts(out, "Problem with the value at json"); fic_sb_putn(out, ctx->p, ctx->n); fic_sb_puts(out, ":\n\n    "); }
      fic_ets_encode4(out, json);
      fic_sb_puts(out, "\n\n");
      fic_sb_putn(out, FIC_STR(msg)->data, FIC_STR(msg)->len);
      return; }
    }
  }
}

/* ---- the slow path of a decode failure: Elm's Error for a value that the type's decoder refuses (D7) ----
 *
 * A type is described by a string (generated by the compiler, Ficcus.Mono.CGen portDesc): i Int, f Float, b Bool, s String,
 * v Json.Value, u (), m<T> Maybe, l<T> List, a<T> Array, t<n><T1>..<Tn> a tuple, r<n>:<name>=<T>..<name>=<T> a record with its fields
 * in the order Elm's decoder tries them; E3c, E3d (Ficcus.Mono.PortFic): c h n C H N W the sized integers, g Float32, V<T> Vector. */

static const char *fic_pd_skip(const char *d) {
  switch (*d++) {
  case 'm': case 'l': case 'a': case 'V': return fic_pd_skip(d);
  case 't': { int n = *d++ - '0'; while (n-- > 0) d = fic_pd_skip(d); return d; }
  case 'r': {
    long n = strtol(d, (char **)&d, 10);
    d++;                                                       /* ':' */
    while (n-- > 0) { d = strchr(d, '=') + 1; d = fic_pd_skip(d); }
    return d; }
  default: return d;
  }
}

static fic_ref fic_pd_failure(const char *text, fic_ref v) { return fic_jd_failure(fic_str_new(text, (int64_t)strlen(text)), v); }

/* NULL when Elm's decoder (with the ranges of Ficcus's Int, L21) takes v; else that decoder's Error (owned). v borrowed. */
static fic_ref fic_pd_explain(const char *d, fic_ref v) {
  switch (*d) {
  case 'i': { int64_t x; return fic_hv_int_of(v, &x) ? NULL : fic_jd_expecting("an INT", v); }
  case 'f': return v->tag == FIC_TAG_JINT || v->tag == FIC_TAG_JFLOAT || v->tag == FIC_TAG_JUINT ? NULL : fic_jd_expecting("a FLOAT", v);
  case 'c': case 'h': case 'n': case 'C': case 'H': case 'N': case 'W': case 'g': return fic_pv_explain_sized(*d, v);
  case 'V': {                                     /* E3c, E3d: a JSON array of the elements, or a raw vector of the element kind */
    int64_t i, n;
    int k = fic_pv_desc_el(d[1]);
    char what[96];
    if (k >= 0) snprintf(what, sizeof what, "a raw vector of %s elements or an ARRAY", fic_el_name[k]);
    else snprintf(what, sizeof what, "an ARRAY");
    if (v->tag == FIC_TAG_HV_VEC && k >= 0 && (int)((fic_hvvec *)v)->elem == k) return NULL;
    if (v->tag != FIC_TAG_VEC_REF) return fic_jd_expecting(what, v);
    n = fic_json_len(v);
    for (i = 0; i < n; i++) { fic_ref e = fic_pd_explain(d + 1, fic_json_at(v, i)); if (e != NULL) return fic_jd_err_index(i, e); }
    return NULL; }
  case 'b': return v->tag == FIC_TAG_JBOOL ? NULL : fic_jd_expecting("a BOOL", v);
  case 's': return v->tag == FIC_TAG_STRING ? NULL : fic_jd_expecting("a STRING", v);
  case 'u': return v->tag == FIC_TAG_JNULL ? NULL : fic_jd_expecting("null", v);
  case 'v':                                       /* Ficcus: undefined never enters a Json.Value (D11, a recorded deviation) */
    return v->tag != FIC_TAG_JUNDEF ? NULL
         : fic_pd_failure("Expecting a value: no flags were given, and Ficcus does not pass JavaScript's undefined into a Json.Value", v);
  case 'm': {                                     /* oneOf [ null Nothing, map Just d ] */
    fic_ref e;
    if (v->tag == FIC_TAG_JNULL) return NULL;
    e = fic_pd_explain(d + 1, v);
    if (e == NULL) return NULL;
    return fic_jd_err_oneof(fic_us_cons_cell(fic_jd_expecting("null", v), fic_us_cons_cell(e, fic_nil())));
  }
  case 'l': case 'a': {
    int64_t i, n;
    if (v->tag != FIC_TAG_VEC_REF) return fic_jd_expecting(*d == 'l' ? "a LIST" : "an ARRAY", v);
    n = fic_json_len(v);
    for (i = 0; i < n; i++) { fic_ref e = fic_pd_explain(d + 1, fic_json_at(v, i)); if (e != NULL) return fic_jd_err_index(i, e); }
    return NULL; }
  case 't': {                                     /* index 0 andThen index 1 (andThen index 2) */
    int i, n = d[1] - '0';
    const char *s = d + 2;
    for (i = 0; i < n; i++) {
      fic_ref e;
      if (v->tag != FIC_TAG_VEC_REF) return fic_jd_expecting("an ARRAY", v);
      if (i >= fic_json_len(v)) {
        char what[120];
        snprintf(what, sizeof what, "a LONGER array. Need index %d but only see %lld entries", i, (long long)fic_json_len(v));
        return fic_jd_expecting(what, v);
      }
      e = fic_pd_explain(s, fic_json_at(v, i));
      if (e != NULL) return fic_jd_err_index(i, e);
      s = fic_pd_skip(s);
    }
    return NULL; }
  case 'r': {                                     /* field f1 d1 andThen field f2 d2 ...: the order of the description */
    const char *s;
    long k, n = strtol(d + 1, (char **)&s, 10);
    s++;                                          /* ':' */
    for (k = 0; k < n; k++) {
      const char *eq = strchr(s, '=');
      fic_ref name = fic_str_new(s, (int64_t)(eq - s)), e;
      int64_t at = v->tag == FIC_TAG_JOBJ ? fic_json_find_key(((fic_jobj *)v)->keys, name) : -1;
      if (at < 0) {
        fic_sb b;
        fic_sb_init(&b);
        fic_sb_puts(&b, "Expecting an OBJECT with a field named `");
        fic_sb_putn(&b, s, (int64_t)(eq - s));
        fic_sb_puts(&b, "`");
        FIC_RC_DROP(name);
        return fic_jd_failure(fic_sb_str(&b), v);
      }
      e = fic_pd_explain(eq + 1, fic_json_at(((fic_jobj *)v)->vals, at));
      if (e != NULL) { fic_ref r = fic_jd_err_field(name, e); FIC_RC_DROP(name); return r; }
      FIC_RC_DROP(name);
      s = fic_pd_skip(eq + 1);
    }
    return NULL; }
  default:
    return NULL;
  }
}

/* the text of a refused value: errorToString of Elm's Error (prefix: the crash 2 line for flags, or nothing) */
static int fic_pd_refuse(const char *prefix, const char *desc, fic_ref v) {
  fic_ref e = fic_pd_explain(desc, v);
  fic_sb b;
  fic_sb_init(&b);
  fic_sb_puts(&b, prefix);
  if (e != NULL) { fic_ets(&b, e); FIC_RC_DROP(e); }
  else fic_sb_puts(&b, "internal: the generated decoder refused a value that Elm's decoder takes");
  fic_port_fail_n(FIC_E_DECODE, b.p, (size_t)b.n);
  free(b.p);
  return FIC_E_DECODE;
}

/* ---- Array payloads (D6): Elm's Array.fromList and a walk of the tree (elm/core 1.0.5 Array.elm: branchFactor 32, shiftStep 5;
        Node = SubTree (tag 0) | Leaf (tag 1)) ---- */

typedef struct { fic_hdr h; fic_ref r0; } fic_port_node;

static fic_ref fic_port_node_new(uint16_t tag, fic_ref arr) {
  fic_port_node *n = (fic_port_node *)fic_alloc(sizeof(fic_port_node), tag, 1);
  n->r0 = arr;
  return &n->h;
}

/* Array.fromList of the n words xs (consumed: moved into the leaves); etag the tag of a leaf's JsArray */
static FIC_UNUSED void fic_port_array_build(fic_word *xs, int64_t n, uint16_t etag, int64_t *len, int64_t *shift, fic_ref *tree, fic_ref *tail) {
  int64_t leaves = n / 32, rest = n % 32, cnt, i, j;
  fic_ref *nodes;
  *tail = fic_ja_new(rest, etag);
  for (i = 0; i < rest; i++) fic_ja_data(*tail)[i] = xs[leaves * 32 + i];
  if (leaves == 0) { *len = rest; *shift = 5; *tree = fic_ja_new(0, FIC_TAG_VEC_REF); return; }
  nodes = (fic_ref *)malloc((size_t)leaves * sizeof(fic_ref));
  if (nodes == NULL) abort();
  for (i = 0; i < leaves; i++) {
    fic_ref a = fic_ja_new(32, etag);
    for (j = 0; j < 32; j++) fic_ja_data(a)[j] = xs[i * 32 + j];
    nodes[i] = fic_port_node_new(1u, a);
  }
  {                                                            /* builderToArray: depth = floor (logBase 32 (treeLen - 1)) */
    int64_t depth = (int64_t)floor(log((double)(leaves * 32 - 1)) / log(32.0));
    *len = rest + leaves * 32;
    *shift = depth * 5 > 5 ? depth * 5 : 5;
  }
  for (cnt = leaves;;) {                                       /* treeFromBuilder, compressNodes */
    int64_t groups = (cnt + 31) / 32;
    if (groups == 1) {
      *tree = fic_ja_new(cnt, FIC_TAG_VEC_REF);
      for (i = 0; i < cnt; i++) fic_ja_data(*tree)[i].p = nodes[i];
      break;
    }
    for (i = 0; i < groups; i++) {
      int64_t m = cnt - i * 32 < 32 ? cnt - i * 32 : 32;
      fic_ref a = fic_ja_new(m, FIC_TAG_VEC_REF);
      for (j = 0; j < m; j++) fic_ja_data(a)[j].p = nodes[i * 32 + j];
      nodes[i] = fic_port_node_new(0u, a);
    }
    cnt = groups;
  }
  free(nodes);
}

static void fic_port_array_walk(fic_ref tree, fic_word *out, int64_t *k) {
  int64_t i, n = fic_ja_length(tree);
  for (i = 0; i < n; i++) {
    fic_ref node = fic_ja_data(tree)[i].p, arr = ((fic_port_node *)node)->r0;
    if (node->tag == 1u) { int64_t j, m = fic_ja_length(arr); for (j = 0; j < m; j++) out[(*k)++] = fic_ja_data(arr)[j]; }
    else fic_port_array_walk(arr, out, k);
  }
}

/* the elements of an Array in order, borrowed (a malloc'd buffer of len words) */
static FIC_UNUSED fic_word *fic_port_array_words(fic_ref tree, fic_ref tail, int64_t len) {
  fic_word *out = (fic_word *)malloc((size_t)(len + 1) * sizeof(fic_word));
  int64_t k = 0, i, m = fic_ja_length(tail);
  if (out == NULL) abort();
  fic_port_array_walk(tree, out, &k);
  for (i = 0; i < m; i++) out[k++] = fic_ja_data(tail)[i];
  return out;
}

/* ---- flags (D11): the standalone program reads them from FIC_FLAGS (JSON text) or FIC_FLAGS_FILE (a file of JSON text); with
        neither the flags are absent (NULL: undefined). Both set, an unreadable file or text that is not JSON: a message, exit 1. ---- */

static FIC_UNUSED fic_hv fic_flags_env(void) {
  const char *t = getenv("FIC_FLAGS"), *f = getenv("FIC_FLAGS_FILE");
  int ht = t != NULL && *t != 0, hf = f != NULL && *f != 0;
  fic_hv v;
  if (ht && hf) {
    fflush(stdout);
    fprintf(stderr, "FIC_FLAGS and FIC_FLAGS_FILE are both set: give the flags in one of them\n");
    exit(1);
  }
  if (ht) {
    v = fic_hv_from_json(t, strlen(t));
    if (v == NULL) { fflush(stdout); fprintf(stderr, "FIC_FLAGS: not valid JSON: %s\n", t); exit(1); }
    return v;
  }
  if (hf) {
    FILE *fp = fopen(f, "rb");
    char *buf = NULL;
    size_t n = 0, cap = 0, k;
    if (fp == NULL) { fflush(stdout); fprintf(stderr, "FIC_FLAGS_FILE: cannot open %s\n", f); exit(1); }
    do {
      if (n == cap) { cap = cap == 0 ? 4096 : cap * 2; buf = (char *)realloc(buf, cap); if (buf == NULL) abort(); }
      k = fread(buf + n, 1, cap - n, fp);
      n += k;
    } while (k > 0);
    fclose(fp);
    v = fic_hv_from_json(buf, n);
    free(buf);
    if (v == NULL) { fflush(stdout); fprintf(stderr, "FIC_FLAGS_FILE: %s is not valid JSON\n", f); exit(1); }
    return v;
  }
  return NULL;
}

/* the flags given to fic_app_start (consumed; NULL is undefined): decoded by the generated decoder of the flags type, or Elm's crash 2
   text and FIC_E_DECODE */
typedef int (*fic_flags_decode)(fic_ref json, fic_word *out);
static FIC_UNUSED int fic_flags_take(fic_hv flags, fic_flags_decode dec, const char *desc, fic_word *out) {
  fic_ref v = flags != NULL ? flags : &fic_json_undef_obj;
  if (flags != NULL && !fic_hv_sealed(flags)) { FIC_RC_DROP(flags); return fic_port_fail(FIC_E_INVALID, "fic_app_start: the flags are an unsealed array, object or string%s", NULL); }
  if (!dec(v, out)) {
    int rc = fic_pd_refuse("Problem with the flags given to your Elm program on initialization.\n\n", desc, v);
    if (flags != NULL) FIC_RC_DROP(flags);
    return rc;
  }
  if (flags != NULL) FIC_RC_DROP(flags);                    /* the decoded leaves keep the only counts (D3) */
  return FIC_OK;
}

/* ======== ports (only with the scheduler: a program that has ports) ======== */
#ifdef FIC_SCHED_H

/* the subscribers of an outgoing port (Elm's `subs` array): subscribe pushes onto the array (a delivery in progress sees the new
   callback), unsubscribe replaces it by a copy without the callback (a delivery in progress keeps the old one); refs = the table's
   count plus one per delivery that reads it */
typedef struct { fic_port_fn fn; void *env; } fic_port_sub;
typedef struct { size_t refs, n, cap; fic_port_sub *items; } fic_port_subs;
static fic_port_subs *fic_port_out_subs[FIC_MAX_MGR];
static const char *fic_port_descs[FIC_MAX_MGR];
typedef int (*fic_port_decode)(fic_ref json, fic_word *out);
static fic_port_decode fic_port_decoders[FIC_MAX_MGR];
static int fic_ports_stopped;

static void fic_port_subs_unref(fic_port_subs *s) {
  if (s != NULL && --s->refs == 0) { free(s->items); free(s); }
}

static int fic_port_find(const char *name, int kind) {
  int i;
  if (name == NULL) return -1;
  for (i = 0; i < fic_nmgr; i++) if (fic_mgrs[i].kind == kind && strcmp(fic_mgrs[i].name, name) == 0) return i;
  return -1;
}

/* outgoing: onEffects router cmds state = for each value, every subscriber of this moment; then init (sleep 0) again */
static fic_word fic_port_out_effects(fic_ref self, fic_word router, fic_word cmds, fic_word state) {
  uint32_t gi = ((fic_router *)router.p)->mgr;
  fic_ref l;
  (void)self; (void)state;
  for (l = cmds.p; l->tag == 1u; l = ((fic_sched_cell *)l)->tail) {
    fic_ref v = ((fic_sched_cell *)l)->head;
    fic_port_subs *cur = fic_port_out_subs[gi];             /* "grab a separate reference to subs in case unsubscribe is called" */
    size_t k;
    if (cur == NULL) continue;
    cur->refs++;
    for (k = 0; k < cur->n; k++) { fic_port_sub s = cur->items[k]; s.fn(s.env, v); }
    fic_port_subs_unref(cur);
  }
  FIC_RC_DROP(router.p); FIC_RC_DROP(cmds.p);
  FIC_RC_DUP(fic_mgrs[gi].init);
  return fic_w_p(fic_mgrs[gi].init);
}
static const fic_code fic_port_out_code = { (void (*)(void))fic_port_out_effects, 3u FIC_CODE_OWN0 };
static fic_clo fic_port_out_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &fic_port_out_code };

static FIC_UNUSED void fic_port_out_def(const char *name) {
  fic_mgr *m = fic_port_def(name, FIC_MGR_PORT_OUT);
  m->init = fic_task_sleep(0); m->on_effects = &fic_port_out_clo.h; m->has_cmd = 1; m->has_sub = 0; m->state_ref = 0;
}

/* incoming: onEffects router subs state = keep the subscriptions */
static fic_word fic_port_in_effects(fic_ref self, fic_word router, fic_word subs, fic_word state) {
  fic_mgr *g = &fic_mgrs[((fic_router *)router.p)->mgr];
  fic_ref old = g->port_subs;
  (void)self; (void)state;
  g->port_subs = subs.p;
  FIC_RC_DROP(old); FIC_RC_DROP(router.p);
  return fic_w_p(fic_task_succeed(FIC_W_UNIT, 0));
}
static const fic_code fic_port_in_code = { (void (*)(void))fic_port_in_effects, 3u FIC_CODE_OWN0 };
static fic_clo fic_port_in_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &fic_port_in_code };

/* desc: the description of the payload type (the slow path of a refused value) */
static FIC_UNUSED void fic_port_in_def(const char *name, fic_port_decode dec, int payload_ref, const char *desc) {
  fic_mgr *m = fic_port_def(name, FIC_MGR_PORT_IN);
  m->init = fic_task_succeed(FIC_W_UNIT, 0); m->on_effects = &fic_port_in_clo.h; m->has_cmd = 0; m->has_sub = 1; m->state_ref = 0;
  m->port_ref = payload_ref;
  fic_port_decoders[fic_nmgr - 1] = dec;
  fic_port_descs[fic_nmgr - 1] = desc;
}

int fic_port_subscribe(const char *port, fic_port_fn fn, void *env) {
  int i;
  fic_port_subs *s;
  if (fic_ports_stopped) return fic_port_fail(FIC_E_STOPPED, "fic_port_subscribe: the program has ended%s", NULL);
  if (fn == NULL) return fic_port_fail(FIC_E_INVALID, "fic_port_subscribe: no function%s", NULL);
  i = fic_port_find(port, FIC_MGR_PORT_OUT);
  if (i < 0) return fic_port_fail(FIC_E_NO_PORT, "there is no outgoing port `%s`", port);
  s = fic_port_out_subs[i];
  if (s == NULL) {
    s = (fic_port_subs *)calloc(1, sizeof(fic_port_subs));
    if (s == NULL) abort();
    s->refs = 1;
    fic_port_out_subs[i] = s;
  }
  if (s->n == s->cap) {
    size_t cap = s->cap == 0 ? 4 : s->cap * 2;
    fic_port_sub *it = (fic_port_sub *)realloc(s->items, cap * sizeof(fic_port_sub));
    if (it == NULL) abort();
    s->items = it; s->cap = cap;
  }
  s->items[s->n].fn = fn; s->items[s->n].env = env; s->n++;
  return FIC_OK;
}

int fic_port_unsubscribe(const char *port, fic_port_fn fn, void *env) {
  int i;
  size_t k, j = 0;
  fic_port_subs *s, *c;
  if (fic_ports_stopped) return fic_port_fail(FIC_E_STOPPED, "fic_port_unsubscribe: the program has ended%s", NULL);
  i = fic_port_find(port, FIC_MGR_PORT_OUT);
  if (i < 0) return fic_port_fail(FIC_E_NO_PORT, "there is no outgoing port `%s`", port);
  s = fic_port_out_subs[i];
  if (s == NULL) return FIC_OK;
  c = (fic_port_subs *)calloc(1, sizeof(fic_port_subs));    /* "copy subs into a new array in case unsubscribe is called within a callback" */
  if (c == NULL) abort();
  c->refs = 1; c->cap = s->n == 0 ? 1 : s->n;
  c->items = (fic_port_sub *)malloc(c->cap * sizeof(fic_port_sub));
  if (c->items == NULL) abort();
  for (k = 0; k < s->n; k++) {
    if (j == k && s->items[k].fn == fn && s->items[k].env == env) continue;   /* the first equal one only (indexOf, splice) */
    c->items[j++] = s->items[k];
  }
  c->n = j;
  fic_port_out_subs[i] = c;
  fic_port_subs_unref(s);
  return FIC_OK;
}

/* app.ports.<name>.send(value): v consumed. The value is decoded, the host's tree released (so the decoded leaves keep the only counts:
   a received string that update writes is unique, D3), and sendToApp runs for each subscription of this moment, at once. */
int fic_port_send(const char *port, fic_hv v) {
  int i;
  fic_mgr *g;
  fic_word w;
  fic_ref subs, l;
  if (v == NULL) return fic_port_fail(FIC_E_INVALID, "fic_port_send: no value%s", NULL);
  if (fic_ports_stopped) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_STOPPED, "fic_port_send: the program has ended%s", NULL); }
  if (!fic_hv_sealed(v)) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_INVALID, "fic_port_send: the value is an unsealed array, object or string%s", NULL); }
  i = fic_port_find(port, FIC_MGR_PORT_IN);
  if (i < 0) { FIC_RC_DROP(v); return fic_port_fail(FIC_E_NO_PORT, "there is no incoming port `%s`", port); }
  g = &fic_mgrs[i];
  if (!fic_port_decoders[i](v, &w)) {
    int rc = fic_pd_refuse("", fic_port_descs[i], v);
    FIC_RC_DROP(v);
    return rc;
  }
  FIC_RC_DROP(v);
  subs = g->port_subs;
  FIC_RC_DUP(subs);                                         /* the list of this moment, as Elm's loop over `subs` */
  for (l = subs; l->tag == 1u; l = ((fic_sched_cell *)l)->tail) {
    if (g->port_ref) FIC_RC_DUP(w.p);
    fic_app_send_fn(fic_ap1(((fic_sched_cell *)l)->head, g->port_ref ? 1u : 0u, w));
  }
  FIC_RC_DROP(subs);
  if (g->port_ref) FIC_RC_DROP(w.p);
  return FIC_OK;
}

int fic_port_send_json(const char *port, const char *text, size_t n) {
  fic_hv v;
  if (fic_ports_stopped) return fic_port_fail(FIC_E_STOPPED, "fic_port_send_json: the program has ended%s", NULL);
  if (fic_port_find(port, FIC_MGR_PORT_IN) < 0) return fic_port_fail(FIC_E_NO_PORT, "there is no incoming port `%s`", port);
  if (text == NULL || !fic_utf8_valid(text, n)) return fic_port_fail(FIC_E_INVALID, "fic_port_send_json: the text is not valid UTF-8%s", NULL);
  v = fic_hv_from_json(text, n);
  if (v == NULL) {                                          /* Json.Decode.decodeString's error (L27) */
    fic_ref s = fic_str_new(n > 0 ? text : "", (int64_t)n), e = fic_jd_failure(fic_str_new("This is not valid JSON! Syntax error", 36), s);
    fic_sb b;
    fic_sb_init(&b);
    fic_ets(&b, e);
    fic_port_fail_n(FIC_E_DECODE, b.p, (size_t)b.n);
    free(b.p);
    FIC_RC_DROP(e); FIC_RC_DROP(s);
    return FIC_E_DECODE;
  }
  return fic_port_send(port, v);
}

/* the end of the program (after fic_platform_teardown): every later call returns FIC_E_STOPPED */
static FIC_UNUSED void fic_ports_stop(void) {
  int i;
  fic_ports_stopped = 1;
  for (i = 0; i < FIC_MAX_MGR; i++) { fic_port_subs_unref(fic_port_out_subs[i]); fic_port_out_subs[i] = NULL; }
  free(fic_port_err_text); fic_port_err_text = NULL;
}

/* ---- the test runner (workertests' harness; D-fx-4): one subscriber per outgoing port prints `<port>: <JSON>` on stdout (a String
        on a port named `output` as its text), and the lines `<port> <JSON>` of the file FIC_PORTS_IN are sent after init. A value
        that does not fit is Elm's crash 4 (the second line is errorToString where Elm's debug mode prints [object Object]: a recorded
        deviation) and exit 1, as node exits on the uncaught exception. ---- */

static void fic_runner_print(void *env, fic_hv v) {
  const char *name = (const char *)env;
  if (v->tag == FIC_TAG_STRING && strcmp(name, "output") == 0) {
    fwrite(FIC_STR(v)->data, 1, (size_t)FIC_STR(v)->len, stdout); fputc('\n', stdout);
  } else {
    size_t n;
    char *j = fic_hv_to_json(v, &n);
    fputs(name, stdout); fputs(": ", stdout);
    fwrite(j, 1, n, stdout); fputc('\n', stdout);
    free(j);
  }
}

static FIC_UNUSED void fic_runner_start(void) {
  const char *path = getenv("FIC_PORTS_IN");
  FILE *f;
  char *line = NULL;
  size_t cap = 0;
  ssize_t got;
  int i;
  for (i = 0; i < fic_nmgr; i++) if (fic_mgrs[i].kind == FIC_MGR_PORT_OUT) fic_port_subscribe(fic_mgrs[i].name, fic_runner_print, (void *)fic_mgrs[i].name);
  if (path == NULL || *path == 0) return;
  f = fopen(path, "r");
  if (f == NULL) { fprintf(stderr, "FIC_PORTS_IN: cannot open %s\n", path); exit(1); }
  while ((got = getline(&line, &cap, f)) > 0) {
    size_t n = (size_t)got;
    char *sp;
    fic_hv v;
    int rc;
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
    if (n == 0) continue;
    sp = strchr(line, ' ');
    if (sp == NULL) { fprintf(stderr, "FIC_PORTS_IN: no JSON on the line: %s\n", line); exit(1); }
    *sp = 0;
    v = fic_hv_from_json(sp + 1, strlen(sp + 1));
    if (v == NULL) { fprintf(stderr, "FIC_PORTS_IN: not JSON: %s\n", sp + 1); exit(1); }
    rc = fic_port_send(line, v);
    if (rc == FIC_E_DECODE) {
      fflush(stdout);
      fprintf(stderr, "Trying to send an unexpected type of value through port `%s`:\n%s\n", line, fic_port_error());
      exit(1);
    }
    if (rc != FIC_OK) { fflush(stdout); fprintf(stderr, "%s\n", fic_port_error()); exit(1); }
  }
  free(line);
  fclose(f);
}

#else /* a program without ports (flags only): the same interface, every port is absent */

int fic_port_subscribe(const char *port, fic_port_fn fn, void *env) { (void)fn; (void)env; return fic_port_fail(FIC_E_NO_PORT, "there is no outgoing port `%s`", port); }
int fic_port_unsubscribe(const char *port, fic_port_fn fn, void *env) { (void)fn; (void)env; return fic_port_fail(FIC_E_NO_PORT, "there is no outgoing port `%s`", port); }
int fic_port_send(const char *port, fic_hv v) { if (v != NULL) FIC_RC_DROP(v); return fic_port_fail(FIC_E_NO_PORT, "there is no incoming port `%s`", port); }
int fic_port_send_json(const char *port, const char *text, size_t n) { (void)text; (void)n; return fic_port_fail(FIC_E_NO_PORT, "there is no incoming port `%s`", port); }

#endif /* FIC_SCHED_H */
