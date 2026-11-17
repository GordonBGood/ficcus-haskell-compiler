/* String functions on UTF-8 text with code point semantics (decisions L8, L11, L13): length, slice, cons, join, words,
   toUpper, toLower, map, foldl, foldr. Strings are always valid UTF-8 (the heap object of fic_base.h). Needs the
   closure runtime (fic_word) and fic_case.h, emitted only into programs that use one of the fic_us_ functions. */

typedef struct fic_us_cell { fic_hdr h; fic_ref f0; fic_ref f1; } fic_us_cell;   /* a cons cell of a List String */

static uint32_t fic_us_get(const unsigned char **p) {
  const unsigned char *s = *p;
  uint32_t c = *s++;
  if (c < 0x80u) { }
  else if (c < 0xE0u) { c = ((c & 0x1Fu) << 6) | (s[0] & 0x3Fu); s += 1; }
  else if (c < 0xF0u) { c = ((c & 0x0Fu) << 12) | ((uint32_t)(s[0] & 0x3Fu) << 6) | (s[1] & 0x3Fu); s += 2; }
  else { c = ((c & 0x07u) << 18) | ((uint32_t)(s[0] & 0x3Fu) << 12) | ((uint32_t)(s[1] & 0x3Fu) << 6) | (s[2] & 0x3Fu); s += 3; }
  *p = s;
  return c;
}

/* the code point that ends just before *p (p moves back to its first byte) */
static uint32_t fic_us_prev(const unsigned char *start, const unsigned char **p) {
  const unsigned char *s = *p;
  const unsigned char *q;
  uint32_t c;
  do { s--; } while (s > start && (*s & 0xC0u) == 0x80u);
  q = s;
  c = fic_us_get(&q);
  *p = s;
  return c;
}

static int fic_us_put(char *o, uint32_t c) {
  if (c < 0x80u) { o[0] = (char)c; return 1; }
  if (c < 0x800u) { o[0] = (char)(0xC0u | (c >> 6)); o[1] = (char)(0x80u | (c & 0x3Fu)); return 2; }
  if (c < 0x10000u) { o[0] = (char)(0xE0u | (c >> 12)); o[1] = (char)(0x80u | ((c >> 6) & 0x3Fu)); o[2] = (char)(0x80u | (c & 0x3Fu)); return 3; }
  o[0] = (char)(0xF0u | (c >> 18)); o[1] = (char)(0x80u | ((c >> 12) & 0x3Fu)); o[2] = (char)(0x80u | ((c >> 6) & 0x3Fu)); o[3] = (char)(0x80u | (c & 0x3Fu));
  return 4;
}

static int64_t fic_us_length(fic_ref s) { return FIC_STR(s)->cps; }   /* L11: cached in the header */

/* ---- code point index to byte offset (FIX2 step 3) ----
   An ASCII string (byte length == code point length, known from its header: both are computed once, when the string is made) has
   offset == index. For another string a one entry cache (the last string with a code point index and its byte offset) lets a left to
   right scan stay linear, and a seek starts at the nearest of the start, the cached position and the end (a scan backwards over
   the continuation bytes), so a restart from zero costs no more than the plain scan and usually much less. Semantics are those of
   decision L11 (code point indices); strings are valid UTF-8, so an index never falls inside a character.
   In a counted program the cache holds a count on its string (a string freed and another allocated at the same address must not be
   mistaken for the cached one); fic_us_release gives it back at the end of the program (test builds). */
static fic_ref fic_us_cs;                 /* the string of the cache */
static int64_t fic_us_ci, fic_us_cb;      /* a code point index of it and its byte offset */

static void fic_us_use(fic_ref s) {
  if (s != fic_us_cs) {
#ifdef FIC_RC
    fic_dup(s);
    if (fic_us_cs != NULL) fic_drop(fic_us_cs);
#endif
    fic_us_cs = s; fic_us_ci = 0; fic_us_cb = 0;
  }
}
static void fic_us_release(void) {
#ifdef FIC_RC
  if (fic_us_cs != NULL) { fic_drop(fic_us_cs); fic_us_cs = NULL; }
#endif
}

/* the byte offset of the code point index cp of s, 0 <= cp <= its length (the byte length for cp == length); clamped outside */
static int64_t fic_us_off(fic_ref s, int64_t cp) {
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data;
  int64_t n = FIC_STR(s)->cps, len = FIC_STR(s)->len, i, b, dc;
  if (cp <= 0) return 0;
  if (cp >= n) return len;
  if (n == len) return cp;                          /* ASCII */
  fic_us_use(s);
  dc = cp > fic_us_ci ? cp - fic_us_ci : fic_us_ci - cp;
  if (cp <= dc && cp <= n - cp) { i = 0; b = 0; }                         /* the start is the nearest */
  else if (n - cp < dc) { i = n; b = len; }                              /* the end is the nearest */
  else { i = fic_us_ci; b = fic_us_cb; }
  while (i < cp) { b++; while (b < len && (d[b] & 0xC0u) == 0x80u) b++; i++; }
  while (i > cp) { b--; while (b > 0 && (d[b] & 0xC0u) == 0x80u) b--; i--; }
  fic_us_ci = cp; fic_us_cb = b;
  return b;
}

/* JavaScript's slice rule on code point indices: negative indices count from the end, both are clamped */
static fic_ref fic_us_slice(int64_t from, int64_t to, fic_ref s) {
  int64_t n = fic_us_length(s), bf, bt;
  if (from < 0) { from += n; if (from < 0) from = 0; } else if (from > n) from = n;
  if (to < 0) { to += n; if (to < 0) to = 0; } else if (to > n) to = n;
  if (from >= to) return fic_str_new("", 0);
  bf = fic_us_off(s, from);
  bt = fic_us_off(s, to);
  if (n == FIC_STR(s)->len) return fic_str_new_cps(FIC_STR(s)->data + bf, bt - bf, bt - bf);     /* ASCII: the result is too */
  return fic_str_new(FIC_STR(s)->data + bf, bt - bf);
}

static fic_ref fic_us_cons(uint32_t c, fic_ref s) {
  char buf[4];
  int k = fic_us_put(buf, c);
  int64_t len = FIC_STR(s)->len;
  fic_string *r = (fic_string *)fic_alloc(sizeof(fic_string) + (size_t)(len + k) + 1, FIC_TAG_STRING, 0);
  r->len = len + k;
  r->cps = FIC_STR(s)->cps + 1;
  memcpy(r->data, buf, (size_t)k);
  memcpy(r->data + k, FIC_STR(s)->data, (size_t)len);
  r->data[len + k] = 0;
  return &r->h;
}

static fic_ref fic_us_join(fic_ref sep, fic_ref list) {
  int64_t total = 0, count = 0, sl = FIC_STR(sep)->len;
  fic_ref p;
  fic_string *r;
  char *o;
  for (p = list; p->tag != 0u; p = ((fic_us_cell *)p)->f1) { total += FIC_STR(((fic_us_cell *)p)->f0)->len; count++; }
  if (count > 1) total += sl * (count - 1);
  r = (fic_string *)fic_alloc(sizeof(fic_string) + (size_t)total + 1, FIC_TAG_STRING, 0);
  r->len = total;
  r->cps = 0;
  o = r->data;
  for (p = list; p->tag != 0u; p = ((fic_us_cell *)p)->f1) {
    fic_ref x = ((fic_us_cell *)p)->f0;
    memcpy(o, FIC_STR(x)->data, (size_t)FIC_STR(x)->len); o += FIC_STR(x)->len;
    if (((fic_us_cell *)p)->f1->tag != 0u) { memcpy(o, FIC_STR(sep)->data, (size_t)sl); o += sl; }
  }
  *o = 0;
  r->cps = fic_str_cps_of(r->data, total);
  return &r->h;
}

/* JavaScript's \s (and the white space that trim removes): the 25 code points of decision L13 */
static int fic_us_ws(uint32_t c) {
  return c == 9u || c == 10u || c == 11u || c == 12u || c == 13u || c == 32u || c == 0xA0u || c == 0x1680u
      || (c >= 0x2000u && c <= 0x200Au) || c == 0x2028u || c == 0x2029u || c == 0x202Fu || c == 0x205Fu || c == 0x3000u || c == 0xFEFFu;
}

static fic_ref fic_us_cons_cell(fic_ref head, fic_ref tail) {
  fic_us_cell *c = (fic_us_cell *)fic_alloc(sizeof(fic_us_cell), 1u, 2);
  c->f0 = head; c->f1 = tail;
  return &c->h;
}

/* Elm's `words`: str.trim().split(/\s+/g), so words "" and words "  " are [""] (decision L13) */
static fic_ref fic_us_words(fic_ref s) {
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data, *end = d + FIC_STR(s)->len, *p = d, *q, *a, *b;
  fic_ref list = fic_nil();
  int64_t n = 0, i = 0;
  const unsigned char **starts, **ends;
  uint32_t c;
  /* trim */
  for (;;) { q = p; if (p >= end) break; c = fic_us_get(&q); if (!fic_us_ws(c)) break; p = q; }
  a = p;
  b = end;
  for (;;) { q = b; if (b <= a) break; c = fic_us_prev(a, &q); if (!fic_us_ws(c)) break; b = q; }
  if (b <= a) return fic_us_cons_cell(fic_str_new("", 0), list);
  /* count the words, then collect them */
  for (p = a; p < b; ) {
    q = p; c = fic_us_get(&q);
    if (fic_us_ws(c)) { p = q; continue; }
    n++;
    while (p < b) { q = p; c = fic_us_get(&q); if (fic_us_ws(c)) break; p = q; }
  }
  starts = (const unsigned char **)malloc((size_t)n * sizeof(*starts));
  ends = (const unsigned char **)malloc((size_t)n * sizeof(*ends));
  if (starts == NULL || ends == NULL) abort();
  for (p = a; p < b; ) {
    q = p; c = fic_us_get(&q);
    if (fic_us_ws(c)) { p = q; continue; }
    starts[i] = p;
    while (p < b) { q = p; c = fic_us_get(&q); if (fic_us_ws(c)) break; p = q; }
    ends[i] = p; i++;
  }
  for (i = n - 1; i >= 0; i--) list = fic_us_cons_cell(fic_str_new((const char *)starts[i], (int64_t)(ends[i] - starts[i])), list);
  free(starts); free(ends);
  return list;
}

static const fic_case_map *fic_us_find(const fic_case_map *tab, int64_t n, uint32_t c) {
  int64_t lo = 0, hi = n - 1;
  while (lo <= hi) {
    int64_t mid = (lo + hi) / 2;
    if (tab[mid].cp == c) return &tab[mid];
    if (tab[mid].cp < c) lo = mid + 1; else hi = mid - 1;
  }
  return NULL;
}

static int fic_us_in(const fic_case_range *tab, int64_t n, uint32_t c) {
  int64_t lo = 0, hi = n - 1;
  while (lo <= hi) {
    int64_t mid = (lo + hi) / 2;
    if (c < tab[mid].lo) hi = mid - 1; else if (c > tab[mid].hi) lo = mid + 1; else return 1;
  }
  return 0;
}

/* Final_Sigma: the sigma at q (just before the code point after it) follows a cased letter (case ignorable code
   points skipped) and no cased letter follows it (same skipping) */
static int fic_us_final_sigma(const unsigned char *start, const unsigned char *at, const unsigned char *after, const unsigned char *end) {
  const unsigned char *p = at;
  int before = 0, later = 0;
  while (p > start) {
    uint32_t c = fic_us_prev(start, &p);
    if (fic_us_in(fic_ignorable_tab, FIC_IGNORABLE_TAB_N, c)) continue;
    before = fic_us_in(fic_cased_tab, FIC_CASED_TAB_N, c);
    break;
  }
  p = after;
  while (p < end) {
    uint32_t c = fic_us_get(&p);
    if (fic_us_in(fic_ignorable_tab, FIC_IGNORABLE_TAB_N, c)) continue;
    later = fic_us_in(fic_cased_tab, FIC_CASED_TAB_N, c);
    break;
  }
  return before && !later;
}

static fic_ref fic_us_case(fic_ref s, int upper) {
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data, *end = d + FIC_STR(s)->len, *p = d;
  char *buf = (char *)malloc((size_t)FIC_STR(s)->len * 3u + 4u), *o = buf;
  fic_ref r;
  if (buf == NULL) abort();
  while (p < end) {
    const unsigned char *at = p;
    uint32_t c = fic_us_get(&p);
    const fic_case_map *m;
    if (c < 0x80u) {
      if (upper) o[0] = (char)((c >= 'a' && c <= 'z') ? c - 32u : c); else o[0] = (char)((c >= 'A' && c <= 'Z') ? c + 32u : c);
      o++;
      continue;
    }
    if (!upper && c == 0x3A3u) {
      o += fic_us_put(o, fic_us_final_sigma(d, at, p, end) ? 0x3C2u : 0x3C3u);
      continue;
    }
    m = upper ? fic_us_find(fic_upper_tab, FIC_UPPER_TAB_N, c) : fic_us_find(fic_lower_tab, FIC_LOWER_TAB_N, c);
    if (m == NULL) o += fic_us_put(o, c);
    else { int k; for (k = 0; k < m->n; k++) o += fic_us_put(o, m->to[k]); }
  }
  r = fic_str_new(buf, (int64_t)(o - buf));
  free(buf);
  return r;
}
static fic_ref fic_us_upper(fic_ref s) { return fic_us_case(s, 1); }
static fic_ref fic_us_lower(fic_ref s) { return fic_us_case(s, 0); }

/* map: f is Char -> Char */
static fic_ref fic_us_map(fic_ref f, fic_ref s) {
  const unsigned char *p = (const unsigned char *)FIC_STR(s)->data, *end = p + FIC_STR(s)->len;
  char *buf = (char *)malloc((size_t)FIC_STR(s)->len * 4u + 4u), *o = buf;
  fic_ref r;
  if (buf == NULL) abort();
  while (p < end) { uint32_t c = fic_us_get(&p); o += fic_us_put(o, fic_ap1(f, 0u, fic_w_c(c)).c); }
  r = fic_str_new(buf, (int64_t)(o - buf));
  free(buf);
  return r;
}

/* foldl and foldr: f is Char -> b -> b, fmask has bit 1 set when b is a reference */
static fic_word fic_us_foldl(fic_ref f, unsigned fmask, fic_word acc, fic_ref s) {
  const unsigned char *p = (const unsigned char *)FIC_STR(s)->data, *end = p + FIC_STR(s)->len;
  while (p < end) { uint32_t c = fic_us_get(&p); acc = fic_ap2(f, fmask, fic_w_c(c), acc); }
  return acc;
}

static fic_word fic_us_foldr(fic_ref f, unsigned fmask, fic_word acc, fic_ref s) {
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data, *p = d + FIC_STR(s)->len;
  while (p > d) { uint32_t c = fic_us_prev(d, &p); acc = fic_ap2(f, fmask, fic_w_c(c), acc); }
  return acc;
}

/* Char.toUpper and Char.toLower: the simple one code point mapping (decision L8; Elm's kernel uses the full mapping
   and answers "SS" for the Char ß, which is not a Char) */
static uint32_t fic_us_cupper(uint32_t c) {
  const fic_case_map *m;
  if (c < 0x80u) return (c >= 'a' && c <= 'z') ? c - 32u : c;
  m = fic_us_find(fic_supper_tab, FIC_SUPPER_TAB_N, c);
  return m == NULL ? c : m->to[0];
}
static uint32_t fic_us_clower(uint32_t c) {
  const fic_case_map *m;
  if (c < 0x80u) return (c >= 'A' && c <= 'Z') ? c + 32u : c;
  m = fic_us_find(fic_slower_tab, FIC_SLOWER_TAB_N, c);
  return m == NULL ? c : m->to[0];
}

/* String.fromList: the cells of a List Char hold the code point (uint32_t) and the tail */
typedef struct fic_us_ccell { fic_hdr h; fic_ref f1; uint32_t f0; } fic_us_ccell;   /* a cons cell of a List Char: the reference first */
static fic_ref fic_us_from_list(fic_ref list) {
  int64_t total = 0;
  fic_ref p;
  char *buf, *o;
  fic_ref r;
  for (p = list; p->tag != 0u; p = ((fic_us_ccell *)p)->f1) total += 4;
  buf = (char *)malloc((size_t)total + 1u);
  if (buf == NULL) abort();
  o = buf;
  for (p = list; p->tag != 0u; p = ((fic_us_ccell *)p)->f1) o += fic_us_put(o, ((fic_us_ccell *)p)->f0);
  r = fic_str_new(buf, (int64_t)(o - buf));
  free(buf);
  return r;
}

/* ---- searching and splitting (UTF-8 byte comparison is the code point comparison; indexes count code points, L11/L22) ---- */

typedef struct fic_us_icell { fic_hdr h; fic_ref f1; int64_t f0; } fic_us_icell;   /* a cons cell of a List Int */

static const char *fic_us_memmem(const char *h, int64_t hl, const char *n, int64_t nl, int64_t from) {
  int64_t i;
  if (nl == 0) return from <= hl ? h + from : NULL;
  for (i = from; i + nl <= hl; i++) if (h[i] == n[0] && memcmp(h + i, n, (size_t)nl) == 0) return h + i;
  return NULL;
}

static uint8_t fic_us_contains(fic_ref sub, fic_ref s) {
  return fic_us_memmem(FIC_STR(s)->data, FIC_STR(s)->len, FIC_STR(sub)->data, FIC_STR(sub)->len, 0) != NULL;
}
static uint8_t fic_us_starts_with(fic_ref sub, fic_ref s) {
  return FIC_STR(sub)->len <= FIC_STR(s)->len && memcmp(FIC_STR(s)->data, FIC_STR(sub)->data, (size_t)FIC_STR(sub)->len) == 0;
}
static uint8_t fic_us_ends_with(fic_ref sub, fic_ref s) {
  int64_t d = FIC_STR(s)->len - FIC_STR(sub)->len;
  return d >= 0 && memcmp(FIC_STR(s)->data + d, FIC_STR(sub)->data, (size_t)FIC_STR(sub)->len) == 0;
}

/* the code point index of the byte offset b */
static int64_t fic_us_cp_index(const char *d, int64_t b) {
  int64_t i, n = 0;
  for (i = 0; i < b; i++) if (((unsigned char)d[i] & 0xC0u) != 0x80u) n++;
  return n;
}

/* Elm's indexes: the non overlapping matches from the left; no index for an empty pattern. One pass: the code point index of a match
   continues from the previous one, and an ASCII string needs no conversion (O(length + matches), not O(matches * offset)) */
static fic_ref fic_us_indexes(fic_ref sub, fic_ref s) {
  int64_t sl = FIC_STR(sub)->len, hl = FIC_STR(s)->len, n = 0, i = 0, k, prev_b = 0, prev_i = 0;
  int ascii = FIC_STR(s)->cps == hl;
  int64_t *at;
  fic_ref list = fic_nil();
  const char *p;
  if (sl < 1) return list;
  at = (int64_t *)malloc((size_t)(hl / sl + 1) * 2 * sizeof(int64_t));      /* at most hl / sl matches: byte offset and code point index */
  if (at == NULL) abort();
  while ((p = fic_us_memmem(FIC_STR(s)->data, hl, FIC_STR(sub)->data, sl, i)) != NULL) {
    int64_t b = (int64_t)(p - FIC_STR(s)->data);
    prev_i = ascii ? b : prev_i + fic_us_cp_index(FIC_STR(s)->data + prev_b, b - prev_b); prev_b = b;
    at[2 * n] = b; at[2 * n + 1] = prev_i; n++;
    i = b + sl;
  }
  for (k = n - 1; k >= 0; k--) {
    fic_us_icell *c = (fic_us_icell *)fic_alloc(sizeof(fic_us_icell), 1u, 1);
    c->f0 = at[2 * k + 1]; c->f1 = list; list = &c->h;
  }
  free(at);
  return list;
}

/* a list of the pieces (start, length) of s in order */
static fic_ref fic_us_pieces(fic_ref s, const int64_t *st, const int64_t *ln, int64_t n) {
  fic_ref list = fic_nil();
  int64_t i;
  for (i = n - 1; i >= 0; i--) list = fic_us_cons_cell(fic_str_new(FIC_STR(s)->data + st[i], ln[i]), list);
  return list;
}

/* String.split: JavaScript's split; an empty separator gives the code points (the empty string gives []) */
static fic_ref fic_us_split(fic_ref sep, fic_ref s) {
  int64_t sl = FIC_STR(sep)->len, hl = FIC_STR(s)->len, n = 0, i = 0, cap = hl + 2;
  int64_t *st = (int64_t *)malloc((size_t)cap * sizeof(int64_t)), *ln = (int64_t *)malloc((size_t)cap * sizeof(int64_t));
  fic_ref r;
  if (st == NULL || ln == NULL) abort();
  if (sl == 0) {
    while (i < hl) { int64_t b = i + 1; while (b < hl && ((unsigned char)FIC_STR(s)->data[b] & 0xC0u) == 0x80u) b++; st[n] = i; ln[n] = b - i; n++; i = b; }
  } else {
    int64_t from = 0;
    const char *p;
    while ((p = fic_us_memmem(FIC_STR(s)->data, hl, FIC_STR(sep)->data, sl, from)) != NULL) {
      int64_t at = (int64_t)(p - FIC_STR(s)->data);
      st[n] = from; ln[n] = at - from; n++; from = at + sl;
    }
    st[n] = from; ln[n] = hl - from; n++;
  }
  r = fic_us_pieces(s, st, ln, n);
  free(st); free(ln);
  return r;
}

/* String.lines: split at \r\n, \r or \n */
static fic_ref fic_us_lines(fic_ref s) {
  int64_t hl = FIC_STR(s)->len, n = 0, i, from = 0;
  int64_t *st = (int64_t *)malloc((size_t)(hl + 2) * sizeof(int64_t)), *ln = (int64_t *)malloc((size_t)(hl + 2) * sizeof(int64_t));
  const char *d = FIC_STR(s)->data;
  fic_ref r;
  if (st == NULL || ln == NULL) abort();
  for (i = 0; i < hl; i++) {
    if (d[i] == '\n' || d[i] == '\r') {
      st[n] = from; ln[n] = i - from; n++;
      if (d[i] == '\r' && i + 1 < hl && d[i + 1] == '\n') i++;
      from = i + 1;
    }
  }
  st[n] = from; ln[n] = hl - from; n++;
  r = fic_us_pieces(s, st, ln, n);
  free(st); free(ln);
  return r;
}

static fic_ref fic_us_reverse(fic_ref s) {
  int64_t hl = FIC_STR(s)->len, i = hl, o = 0;
  fic_string *r = (fic_string *)fic_alloc(sizeof(fic_string) + (size_t)hl + 1, FIC_TAG_STRING, 0);
  while (i > 0) {
    int64_t b = i - 1, k;
    while (b > 0 && ((unsigned char)FIC_STR(s)->data[b] & 0xC0u) == 0x80u) b--;
    for (k = b; k < i; k++) r->data[o++] = FIC_STR(s)->data[k];
    i = b;
  }
  r->len = hl; r->cps = FIC_STR(s)->cps; r->data[hl] = 0;
  return &r->h;
}

/* trim (both, left, right): JavaScript's white space */
static fic_ref fic_us_trim_gen(fic_ref s, int left, int right) {
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data, *end = d + FIC_STR(s)->len, *a = d, *b = end, *q;
  uint32_t c;
  if (left) for (;;) { q = a; if (a >= end) break; c = fic_us_get(&q); if (!fic_us_ws(c)) break; a = q; }
  if (right) for (;;) { q = b; if (b <= a) break; c = fic_us_prev(a, &q); if (!fic_us_ws(c)) break; b = q; }
  return fic_str_new((const char *)a, (int64_t)(b - a));
}
static fic_ref fic_us_trim(fic_ref s) { return fic_us_trim_gen(s, 1, 1); }
static fic_ref fic_us_trim_left(fic_ref s) { return fic_us_trim_gen(s, 1, 0); }
static fic_ref fic_us_trim_right(fic_ref s) { return fic_us_trim_gen(s, 0, 1); }

/* uncons: 0 for the empty string, else the first code point and the rest */
static int fic_us_uncons(fic_ref s, uint32_t *c, fic_ref *rest) {
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data, *p = d;
  if (FIC_STR(s)->len == 0) return 0;
  *c = fic_us_get(&p);
  *rest = fic_str_new((const char *)p, FIC_STR(s)->len - (int64_t)(p - d));
  return 1;
}

/* filter, any, all: f is Char -> Bool */
static fic_ref fic_us_filter(fic_ref f, fic_ref s) {
  const unsigned char *p = (const unsigned char *)FIC_STR(s)->data, *end = p + FIC_STR(s)->len;
  char *buf = (char *)malloc((size_t)FIC_STR(s)->len + 1u), *o = buf;
  fic_ref r;
  if (buf == NULL) abort();
  while (p < end) { uint32_t c = fic_us_get(&p); if (fic_ap1(f, 0u, fic_w_c(c)).b) o += fic_us_put(o, c); }
  r = fic_str_new(buf, (int64_t)(o - buf));
  free(buf);
  return r;
}
static uint8_t fic_us_any(fic_ref f, fic_ref s) {
  const unsigned char *p = (const unsigned char *)FIC_STR(s)->data, *end = p + FIC_STR(s)->len;
  while (p < end) { uint32_t c = fic_us_get(&p); if (fic_ap1(f, 0u, fic_w_c(c)).b) return 1; }
  return 0;
}
static uint8_t fic_us_all(fic_ref f, fic_ref s) {
  const unsigned char *p = (const unsigned char *)FIC_STR(s)->data, *end = p + FIC_STR(s)->len;
  while (p < end) { uint32_t c = fic_us_get(&p); if (!fic_ap1(f, 0u, fic_w_c(c)).b) return 0; }
  return 1;
}

/* toInt: Elm's grammar (an optional + or -, then digits only; nothing else, no digits is Nothing) read in 64 bits:
   a value that does not fit gives Nothing (decision L14; Elm's JavaScript loses precision beyond 2^53) */
static int fic_us_to_int(fic_ref s, int64_t *out) {
  const char *d = FIC_STR(s)->data;
  int64_t n = FIC_STR(s)->len, i = 0;
  int neg = 0;
  uint64_t total = 0, limit;
  if (n > 0 && (d[0] == '+' || d[0] == '-')) { neg = d[0] == '-'; i = 1; }
  if (i == n) return 0;
  limit = neg ? (uint64_t)INT64_MAX + 1u : (uint64_t)INT64_MAX;
  for (; i < n; i++) {
    unsigned dig;
    if (d[i] < '0' || d[i] > '9') return 0;
    dig = (unsigned)(d[i] - '0');
    if (total > (limit - dig) / 10u) return 0;
    total = total * 10u + dig;
  }
  *out = neg ? (int64_t)(0u - total) : (int64_t)total;
  return 1;
}

/* toFloat: Elm accepts what JavaScript's +s reads as a decimal number, except the empty string and anything with white
   space or an x, b or o in it: [+-] (Infinity | digits [. [digits]] [e [+-] digits] | . digits [e [+-] digits]) */
static int fic_us_to_float(fic_ref s, double *out) {
  const char *d = FIC_STR(s)->data;
  int64_t n = FIC_STR(s)->len, i = 0, k;
  int digits = 0, neg = 0;
  char *tmp, *endp;
  for (k = 0; k < n; k++) { unsigned char c = (unsigned char)d[k]; if (c == 'x' || c == 'b' || c == 'o' || fic_us_ws(c) || c >= 0x80u) return 0; }
  if (n == 0) return 0;
  if (d[i] == '+' || d[i] == '-') { neg = d[i] == '-'; i++; }
  if (n - i == 8 && memcmp(d + i, "Infinity", 8) == 0) { *out = neg ? -INFINITY : INFINITY; return 1; }
  while (i < n && d[i] >= '0' && d[i] <= '9') { i++; digits++; }
  if (i < n && d[i] == '.') { i++; while (i < n && d[i] >= '0' && d[i] <= '9') { i++; digits++; } }
  if (digits == 0) return 0;
  if (i < n && (d[i] == 'e' || d[i] == 'E')) {
    int64_t j = i + 1;
    int ed = 0;
    if (j < n && (d[j] == '+' || d[j] == '-')) j++;
    while (j < n && d[j] >= '0' && d[j] <= '9') { j++; ed++; }
    if (ed == 0) return 0;
    i = j;
  }
  if (i != n) return 0;
  tmp = (char *)malloc((size_t)n + 1u);
  if (tmp == NULL) abort();
  memcpy(tmp, d, (size_t)n); tmp[n] = 0;
  *out = strtod(tmp, &endp);
  free(tmp);
  return 1;
}

/* Char.fromCode: a surrogate, a negative number or a value above 0x10FFFF gives U+FFFD (decision L9) */
static uint32_t fic_us_from_code(int64_t n) {
  if (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) return 0xFFFDu;
  return (uint32_t)n;
}
