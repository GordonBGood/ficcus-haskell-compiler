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

static int64_t fic_us_length(fic_ref s) {
  int64_t i, n = 0, len = FIC_STR(s)->len;
  for (i = 0; i < len; i++) if (((unsigned char)FIC_STR(s)->data[i] & 0xC0u) != 0x80u) n++;
  return n;
}

/* JavaScript's slice rule on code point indices: negative indices count from the end, both are clamped */
static fic_ref fic_us_slice(int64_t from, int64_t to, fic_ref s) {
  int64_t n = fic_us_length(s), i = 0, bf = 0, bt = 0, len = FIC_STR(s)->len;
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data;
  if (from < 0) { from += n; if (from < 0) from = 0; } else if (from > n) from = n;
  if (to < 0) { to += n; if (to < 0) to = 0; } else if (to > n) to = n;
  if (from >= to) return fic_str_new("", 0);
  { int64_t b = 0;
    while (b < len && i < to) {
      if (i == from) bf = b;
      b++; while (b < len && (d[b] & 0xC0u) == 0x80u) b++;
      i++;
    }
    bt = b;
    if (from == 0) bf = 0;
  }
  return fic_str_new(FIC_STR(s)->data + bf, bt - bf);
}

static fic_ref fic_us_cons(uint32_t c, fic_ref s) {
  char buf[4];
  int k = fic_us_put(buf, c);
  int64_t len = FIC_STR(s)->len;
  fic_string *r = (fic_string *)fic_alloc(sizeof(fic_string) + (size_t)(len + k) + 1, FIC_TAG_STRING, 0);
  r->len = len + k;
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
  o = r->data;
  for (p = list; p->tag != 0u; p = ((fic_us_cell *)p)->f1) {
    fic_ref x = ((fic_us_cell *)p)->f0;
    memcpy(o, FIC_STR(x)->data, (size_t)FIC_STR(x)->len); o += FIC_STR(x)->len;
    if (((fic_us_cell *)p)->f1->tag != 0u) { memcpy(o, FIC_STR(sep)->data, (size_t)sl); o += sl; }
  }
  *o = 0;
  return &r->h;
}

/* JavaScript's \s (and the white space that trim removes): the 25 code points of decision L13 */
static int fic_us_ws(uint32_t c) {
  return c == 9u || c == 10u || c == 11u || c == 12u || c == 13u || c == 32u || c == 0xA0u || c == 0x1680u
      || (c >= 0x2000u && c <= 0x200Au) || c == 0x2028u || c == 0x2029u || c == 0x202Fu || c == 0x205Fu || c == 0x3000u || c == 0xFEFFu;
}

static fic_ref fic_us_cons_cell(fic_ref head, fic_ref tail) {
  fic_us_cell *c = (fic_us_cell *)fic_alloc(sizeof(fic_us_cell), 1u, 0);
  c->f0 = head; c->f1 = tail;
  return &c->h;
}

/* Elm's `words`: str.trim().split(/\s+/g), so words "" and words "  " are [""] (decision L13) */
static fic_ref fic_us_words(fic_ref s) {
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data, *end = d + FIC_STR(s)->len, *p = d, *q, *a, *b;
  fic_ref list = (fic_ref)fic_alloc(sizeof(fic_hdr), 0u, 0);
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
typedef struct fic_us_ccell { fic_hdr h; uint32_t f0; fic_ref f1; } fic_us_ccell;
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
