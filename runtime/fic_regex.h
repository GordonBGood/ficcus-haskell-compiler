/* The kernel of elm/regex (decision L24; STAGE4-PLAN section 8; detail in docs/REGEX-KERNEL.md). Emitted only into programs that use a
   fic_re_ function (after fic_ustring.h, which gives the UTF-8 readers and the case tables).

   An ECMAScript 262 subset (the dialect of Elm's `RegExp` without flags `u` `s` `y` `d`): classes, `.`, anchors, `\b \B`, groups,
   non capturing groups, backreferences, lookahead and lookbehind, greedy and lazy quantifiers, `\d \w \s` with the JavaScript
   meanings, the flags `i` and `m`. Not supported (the pattern is invalid, `fromString` gives Nothing): named groups, `\k`, `\p`, `\P`,
   inline flags `(?i)`. The subject is valid UTF-8 and the engine works on code points (L22): `.` and a class match one code point.

   A pattern is compiled to a program of int32 words (the Regex value is a raw vector holding it). The matcher is a backtracking
   machine with an EXPLICIT stack (no C recursion on the subject): the stack holds choice points and undo records of captures and loop
   registers, so a failure restores the state exactly. The number of steps of one search is limited (FIC_RE_BUDGET), as is the stack
   (FIC_RE_MAX_STACK): exceeding either is resource exhaustion, which ends the program like a stack overflow does (message and abort;
   `fic_re_exhausted_hook` is for the tests). Scratch memory (parser tables, matcher stack) is plain malloc, released before a
   function returns; counted objects are the Regex (vector), the capture vector and the strings, all results are owned.

   Ownership: every argument is BORROWED (STAGE4-PLAN section 8.1 letters `b`; the Int arguments are scalars). */

#ifndef FIC_RE_BUDGET
#define FIC_RE_BUDGET 400000000ull       /* steps of one search (one call of fic_re_exec) */
#endif
#ifndef FIC_RE_MAX_STACK
#define FIC_RE_MAX_STACK ((size_t)1 << 25)   /* entries of the backtracking stack (24 bytes each) */
#endif
#define FIC_RE_MAX_DEPTH 200             /* nesting of groups, lookarounds and quantified groups in a pattern */
#define FIC_RE_MAGIC 0x46524531          /* a valid program; 0 in the first word: the pattern was invalid */

static void (*fic_re_exhausted_hook)(const char *) = NULL;
static void fic_re_exhausted(const char *what) {
  if (fic_re_exhausted_hook != NULL) { fic_re_exhausted_hook(what); return; }
  fprintf(stderr, "Ficcus: a regular expression exceeded its %s\n", what);
  abort();
}

/* ---------------------------------------------------------------- program layout ----
   word 0 magic, 1 groups (without group 0), 2 registers, 3 flags (1 i, 2 m), 4 number of code words,
   5 first byte of a match that must start with a fixed literal (-1: none), 6 1 if the match must start at 0 (^ without m) */
#define FIC_RE_HDR 7
enum {
  FIC_RE_MATCH = 1, FIC_RE_CHAR, FIC_RE_ANY, FIC_RE_CLASS,           /* | 0x100: backward (lookbehind) */
  FIC_RE_JMP, FIC_RE_SPLIT, FIC_RE_SAVE, FIC_RE_BOL, FIC_RE_EOL, FIC_RE_WORDB, FIC_RE_NWORDB,
  FIC_RE_BACKREF, FIC_RE_RESETCAPS, FIC_RE_SETREG, FIC_RE_MARK, FIC_RE_LOOP, FIC_RE_ENDITER,
  FIC_RE_LOOKSTART, FIC_RE_LOOKEND, FIC_RE_REPEAT1
};
#define FIC_RE_BACK 0x100

/* ---------------------------------------------------------------- case folding ----
   ES Canonicalize without the u flag: the full upper case of the code point if it is one code point, and an ASCII result only from
   an ASCII code point. */
static uint32_t fic_re_canon(uint32_t c) {
  const fic_case_map *m;
  if (c < 0x80u) return (c >= 'a' && c <= 'z') ? c - 32u : c;
  m = fic_us_find(fic_upper_tab, FIC_UPPER_TAB_N, c);
  if (m == NULL || m->n != 1 || m->to[0] < 0x80u) return c;
  return m->to[0];
}

/* ---------------------------------------------------------------- the compiler ---- */
typedef struct fic_re_node {
  int32_t type, a, b, c, glo, ghi, child, next, last;
} fic_re_node;
enum { N_EMPTY, N_CHAR, N_ANY, N_CLASS, N_SEQ, N_ALT, N_GROUP, N_REP, N_BOL, N_EOL, N_WORDB, N_NWORDB, N_LOOK, N_BACKREF };

typedef struct fic_re_cc {
  const unsigned char *p, *end;
  int ci, ml, err, depth;
  int total_groups, groups;                       /* in the whole pattern (prescan), allocated so far */
  fic_re_node *nodes; size_t nn, ncap;
  uint32_t *pool; size_t np, pcap;                /* ranges of the classes: pairs lo, hi */
  uint32_t *tmp; size_t nt, tcap;                 /* the class being built */
  int32_t *code; size_t nc, ccap;
  int nregs;
} fic_re_cc;

static void *fic_re_grow(void *p, size_t *cap, size_t need, size_t esz) {
  if (need > *cap) {
    size_t nc = *cap ? *cap * 2 : 64;
    void *q;
    while (nc < need) nc *= 2;
    q = realloc(p, nc * esz);
    if (q == NULL) abort();
    *cap = nc; return q;
  }
  return p;
}

static int fic_re_new(fic_re_cc *cc, int type) {
  fic_re_node *n;
  cc->nodes = (fic_re_node *)fic_re_grow(cc->nodes, &cc->ncap, cc->nn + 1, sizeof(fic_re_node));
  n = &cc->nodes[cc->nn];
  memset(n, 0, sizeof *n);
  n->type = type; n->child = n->next = n->last = -1;
  return (int)cc->nn++;
}
#define FN(i) (cc->nodes[i])

static void fic_re_append(fic_re_cc *cc, int list, int node) {
  if (FN(list).child < 0) FN(list).child = node; else FN(FN(list).last).next = node;
  FN(list).last = node;
}

static void fic_re_tadd(fic_re_cc *cc, uint32_t lo, uint32_t hi) {
  cc->tmp = (uint32_t *)fic_re_grow(cc->tmp, &cc->tcap, cc->nt + 2, sizeof(uint32_t));
  cc->tmp[cc->nt++] = lo; cc->tmp[cc->nt++] = hi;
}

static int fic_re_cmp_range(const void *a, const void *b) {
  const uint32_t *x = (const uint32_t *)a, *y = (const uint32_t *)b;
  return x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : x[1] < y[1] ? -1 : x[1] > y[1] ? 1 : 0;
}

/* sort and merge the ranges of tmp from index `from` */
static void fic_re_tnorm(fic_re_cc *cc, size_t from) {
  size_t i, o = from, n = (cc->nt - from) / 2;
  if (n < 2) return;
  qsort(cc->tmp + from, n, 2 * sizeof(uint32_t), fic_re_cmp_range);
  for (i = from + 2; i < cc->nt; i += 2) {
    if ((uint64_t)cc->tmp[i] <= (uint64_t)cc->tmp[o + 1] + 1u) { if (cc->tmp[i + 1] > cc->tmp[o + 1]) cc->tmp[o + 1] = cc->tmp[i + 1]; }
    else { o += 2; cc->tmp[o] = cc->tmp[i]; cc->tmp[o + 1] = cc->tmp[i + 1]; }
  }
  cc->nt = o + 2;
}

/* the ranges of \d \w \s (positive) appended to tmp */
static void fic_re_tescape(fic_re_cc *cc, int e) {
  size_t from = cc->nt;
  int neg = (e == 'D' || e == 'W' || e == 'S');
  switch (e) {
  case 'd': case 'D': fic_re_tadd(cc, '0', '9'); break;
  case 'w': case 'W': fic_re_tadd(cc, '0', '9'); fic_re_tadd(cc, 'A', 'Z'); fic_re_tadd(cc, '_', '_'); fic_re_tadd(cc, 'a', 'z'); break;
  default:
    fic_re_tadd(cc, 9, 13); fic_re_tadd(cc, 32, 32); fic_re_tadd(cc, 0xA0, 0xA0); fic_re_tadd(cc, 0x1680, 0x1680);
    fic_re_tadd(cc, 0x2000, 0x200A); fic_re_tadd(cc, 0x2028, 0x2029); fic_re_tadd(cc, 0x202F, 0x202F); fic_re_tadd(cc, 0x205F, 0x205F);
    fic_re_tadd(cc, 0x3000, 0x3000); fic_re_tadd(cc, 0xFEFF, 0xFEFF); break;
  }
  fic_re_tnorm(cc, from);
  if (neg) {                                       /* complement within 0..10FFFF */
    size_t i, n = cc->nt - from;
    uint32_t *old = (uint32_t *)malloc(n * sizeof(uint32_t)), next = 0;
    if (old == NULL) abort();
    memcpy(old, cc->tmp + from, n * sizeof(uint32_t));
    cc->nt = from;
    for (i = 0; i < n; i += 2) { if (old[i] > next) fic_re_tadd(cc, next, old[i] - 1u); next = old[i + 1] + 1u; }
    if (next <= 0x10FFFFu) fic_re_tadd(cc, next, 0x10FFFFu);
    free(old);
  }
}

static int fic_re_is_escape_class(int e) { return e == 'd' || e == 'D' || e == 'w' || e == 'W' || e == 's' || e == 'S'; }
static int fic_re_hexv(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
static int fic_re_isdigit(int c) { return c >= '0' && c <= '9'; }

static uint32_t fic_re_getcp(fic_re_cc *cc) { const unsigned char *q = cc->p; uint32_t c = fic_us_get(&q); cc->p = q; return c; }

/* the hex digits at p: n of them, or -1 */
static int64_t fic_re_hex(const unsigned char *p, const unsigned char *end, int n) {
  int64_t v = 0; int i;
  if (end - p < n) return -1;
  for (i = 0; i < n; i++) { int h = fic_re_hexv(p[i]); if (h < 0) return -1; v = v * 16 + h; }
  return v;
}

/* A character escape after the backslash (cc->p is at the character after it): the code point, or -1 for an error. in_class: inside [...]. */
static int64_t fic_re_char_escape(fic_re_cc *cc, int in_class) {
  uint32_t e;
  int64_t v;
  if (cc->p >= cc->end) return -1;
  e = fic_re_getcp(cc);
  switch (e) {
  case 'f': return 12; case 'n': return 10; case 'r': return 13; case 't': return 9; case 'v': return 11;
  case 'c':
    if (cc->p < cc->end) {
      int l = *cc->p;
      if ((l >= 'a' && l <= 'z') || (l >= 'A' && l <= 'Z') || (in_class && (fic_re_isdigit(l) || l == '_'))) { cc->p++; return l % 32; }
    }
    cc->p--;                                       /* Annex B: the backslash is a literal and the c follows */
    return '\\';
  case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': {
    /* legacy octal escape: up to three digits, value at most 0377 */
    int64_t o = (int64_t)(e - '0');
    int n = 1;
    while (cc->p < cc->end && *cc->p >= '0' && *cc->p <= '7' && n < 3 && o * 8 + (*cc->p - '0') <= 0377) { o = o * 8 + (*cc->p - '0'); cc->p++; n++; }
    return o; }
  case 'x': v = fic_re_hex(cc->p, cc->end, 2); if (v < 0) return 'x'; cc->p += 2; return v;
  case 'u':
    v = fic_re_hex(cc->p, cc->end, 4);
    if (v < 0) return 'u';
    cc->p += 4;
    if (v >= 0xD800 && v <= 0xDBFF && cc->end - cc->p >= 6 && cc->p[0] == '\\' && cc->p[1] == 'u') {
      int64_t lo = fic_re_hex(cc->p + 2, cc->end, 4);
      if (lo >= 0xDC00 && lo <= 0xDFFF) { cc->p += 6; return 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00); }
    }
    return v;
  case 'k': case 'p': case 'P': return -1;         /* named groups and Unicode properties: not supported (L24) */
  case 'b': if (in_class) return 8; return -1;
  case '8': case '9': return e;
  default: return e;                               /* identity escape */
  }
}

/* one class atom: a code point (*cp >= 0) or an escape class appended to tmp (returns 2); 0 on error */
static int fic_re_class_atom(fic_re_cc *cc, int64_t *cp) {
  uint32_t c = fic_re_getcp(cc);
  if (c != '\\') { *cp = c; return 1; }
  if (cc->p >= cc->end) return 0;
  if (fic_re_is_escape_class(*cc->p)) { fic_re_tescape(cc, *cc->p); cc->p++; return 2; }
  *cp = fic_re_char_escape(cc, 1);
  return *cp < 0 ? 0 : 1;
}

static int fic_re_class_node(fic_re_cc *cc, size_t from, int neg) {
  int n = fic_re_new(cc, N_CLASS);
  size_t k = cc->nt - from;
  fic_re_tnorm(cc, from);
  k = cc->nt - from;
  cc->pool = (uint32_t *)fic_re_grow(cc->pool, &cc->pcap, cc->np + k, sizeof(uint32_t));
  if (k > 0) memcpy(cc->pool + cc->np, cc->tmp + from, k * sizeof(uint32_t));
  FN(n).a = (int32_t)cc->np; FN(n).b = (int32_t)(k / 2); FN(n).c = neg;
  cc->np += k; cc->nt = from;
  return n;
}

static int fic_re_parse_class(fic_re_cc *cc) {            /* after '[' */
  size_t from = cc->nt;
  int neg = 0;
  if (cc->p < cc->end && *cc->p == '^') { neg = 1; cc->p++; }
  for (;;) {
    int64_t lo, hi; int ka, kb;
    if (cc->p >= cc->end) { cc->err = 1; return -1; }
    if (*cc->p == ']') { cc->p++; break; }
    ka = fic_re_class_atom(cc, &lo);
    if (ka == 0) { cc->err = 1; return -1; }
    if (ka == 1 && cc->p + 1 < cc->end && *cc->p == '-' && cc->p[1] != ']') {
      const unsigned char *save = cc->p;
      cc->p++;
      kb = fic_re_class_atom(cc, &hi);
      if (kb == 0) { cc->err = 1; return -1; }
      if (kb == 1) {
        if (lo > hi) { cc->err = 1; return -1; }
        fic_re_tadd(cc, (uint32_t)lo, (uint32_t)hi);
        continue;
      }
      /* Annex B: a class escape as the end of a range makes the `-` a literal */
      fic_re_tadd(cc, (uint32_t)lo, (uint32_t)lo); fic_re_tadd(cc, '-', '-');
      (void)save;
      continue;
    }
    if (ka == 1) fic_re_tadd(cc, (uint32_t)lo, (uint32_t)lo);
  }
  return fic_re_class_node(cc, from, neg);
}

/* a quantifier at p: 1 and the bounds (max -1: unbounded) if there is one (consumed), else 0 */
static int fic_re_quant(fic_re_cc *cc, int64_t *mn, int64_t *mx) {
  const unsigned char *p = cc->p;
  if (p >= cc->end) return 0;
  if (*p == '*') { *mn = 0; *mx = -1; cc->p++; return 1; }
  if (*p == '+') { *mn = 1; *mx = -1; cc->p++; return 1; }
  if (*p == '?') { *mn = 0; *mx = 1; cc->p++; return 1; }
  if (*p == '{') {
    int64_t a = 0, b;
    int digits = 0;
    p++;
    while (p < cc->end && fic_re_isdigit(*p)) { a = a * 10 + (*p - '0'); if (a > 2147483647) a = 2147483647; p++; digits++; }
    if (digits == 0) return 0;
    if (p < cc->end && *p == '}') { *mn = *mx = a; cc->p = p + 1; return 1; }
    if (p < cc->end && *p == ',') {
      p++;
      if (p < cc->end && *p == '}') { *mn = a; *mx = -1; cc->p = p + 1; return 1; }
      b = 0; digits = 0;
      while (p < cc->end && fic_re_isdigit(*p)) { b = b * 10 + (*p - '0'); if (b > 2147483647) b = 2147483647; p++; digits++; }
      if (digits == 0 || p >= cc->end || *p != '}') return 0;
      *mn = a; *mx = b; cc->p = p + 1;
      if (a > b) cc->err = 1;
      return 1;
    }
  }
  return 0;
}

static int fic_re_parse_disj(fic_re_cc *cc);

static int fic_re_parse_term(fic_re_cc *cc) {
  uint32_t c;
  int atom = -1, quantifiable = 1, g0 = cc->groups;
  int64_t mn, mx;
  c = fic_re_getcp(cc);
  switch (c) {
  case '^': return fic_re_new(cc, N_BOL);
  case '$': return fic_re_new(cc, N_EOL);
  case '.': atom = fic_re_new(cc, N_ANY); break;
  case '*': case '+': case '?': cc->err = 1; return -1;
  case '{': cc->p--; if (fic_re_quant(cc, &mn, &mx)) { cc->err = 1; return -1; } cc->p++; atom = fic_re_new(cc, N_CHAR); FN(atom).a = '{'; break;
  case '[': atom = fic_re_parse_class(cc); break;
  case '(': {
    int kind = 0, behind = 0, neg = 0, idx = 0, body;
    if (cc->p < cc->end && *cc->p == '?') {
      cc->p++;
      if (cc->p >= cc->end) { cc->err = 1; return -1; }
      if (*cc->p == ':') { cc->p++; kind = 1; }
      else if (*cc->p == '=' || *cc->p == '!') { neg = *cc->p == '!'; cc->p++; kind = 2; }
      else if (*cc->p == '<' && cc->p + 1 < cc->end && (cc->p[1] == '=' || cc->p[1] == '!')) { neg = cc->p[1] == '!'; behind = 1; cc->p += 2; kind = 2; }
      else { cc->err = 1; return -1; }              /* (?<name>..), (?i) and the like: not supported */
    } else idx = ++cc->groups;
    body = fic_re_parse_disj(cc);
    if (cc->err) return -1;
    if (cc->p >= cc->end || *cc->p != ')') { cc->err = 1; return -1; }
    cc->p++;
    if (kind == 2) { atom = fic_re_new(cc, N_LOOK); FN(atom).a = behind; FN(atom).b = neg; FN(atom).child = body; quantifiable = !behind; }
    else if (kind == 1) atom = body;
    else { atom = fic_re_new(cc, N_GROUP); FN(atom).a = idx; FN(atom).child = body; }
    break; }
  case '\\': {
    uint32_t e;
    if (cc->p >= cc->end) { cc->err = 1; return -1; }
    e = *cc->p;
    if (e == 'b') { cc->p++; return fic_re_new(cc, N_WORDB); }
    if (e == 'B') { cc->p++; return fic_re_new(cc, N_NWORDB); }
    if (fic_re_is_escape_class((int)e)) { size_t from = cc->nt; cc->p++; fic_re_tescape(cc, (int)e); atom = fic_re_class_node(cc, from, 0); break; }
    if (e >= '1' && e <= '9') {                      /* backreference, or a legacy escape when the number is too large */
      const unsigned char *q = cc->p;
      int64_t v = 0;
      while (q < cc->end && fic_re_isdigit(*q) && v < 100000) { v = v * 10 + (*q - '0'); q++; }
      if (v <= cc->total_groups) { cc->p = q; atom = fic_re_new(cc, N_BACKREF); FN(atom).a = (int32_t)v; break; }
    }
    {
      int64_t v = fic_re_char_escape(cc, 0);
      if (v < 0) { cc->err = 1; return -1; }
      atom = fic_re_new(cc, N_CHAR); FN(atom).a = (int32_t)v;
    }
    break; }
  default: atom = fic_re_new(cc, N_CHAR); FN(atom).a = (int32_t)c; break;
  }
  if (cc->err || atom < 0) { cc->err = 1; return -1; }
  if (!quantifiable) return atom;
  if (fic_re_quant(cc, &mn, &mx)) {
    int rep;
    if (cc->err) return -1;
    rep = fic_re_new(cc, N_REP);
    FN(rep).a = (int32_t)mn; FN(rep).b = (int32_t)mx; FN(rep).child = atom; FN(rep).glo = g0 + 1; FN(rep).ghi = cc->groups; FN(rep).c = 1;
    if (cc->p < cc->end && *cc->p == '?') { cc->p++; FN(rep).c = 0; }
    return rep;
  }
  return atom;
}

static int fic_re_parse_alt(fic_re_cc *cc) {
  int seq = fic_re_new(cc, N_SEQ);
  while (cc->p < cc->end && *cc->p != '|' && *cc->p != ')') {
    int t = fic_re_parse_term(cc);
    if (cc->err) return -1;
    fic_re_append(cc, seq, t);
  }
  return seq;
}

static int fic_re_parse_disj(fic_re_cc *cc) {
  int alt, first;
  if (++cc->depth > FIC_RE_MAX_DEPTH) { cc->err = 1; return -1; }
  alt = fic_re_new(cc, N_ALT);
  for (;;) {
    int s = fic_re_parse_alt(cc);
    if (cc->err) return -1;
    fic_re_append(cc, alt, s);
    if (cc->p < cc->end && *cc->p == '|') { cc->p++; continue; }
    break;
  }
  cc->depth--;
  first = FN(alt).child;
  return FN(first).next < 0 ? first : alt;
}

/* the number of capture groups of the pattern: a `(` that is not escaped, not in a class and not followed by `?` */
static int fic_re_count_groups(const unsigned char *p, const unsigned char *end) {
  int n = 0, in_class = 0;
  while (p < end) {
    unsigned char c = *p++;
    if (c == '\\') { if (p < end) p++; }
    else if (in_class) { if (c == ']') in_class = 0; }
    else if (c == '[') in_class = 1;
    else if (c == '(' && !(p < end && *p == '?')) n++;
  }
  return n;
}

/* can the node match the empty string (so that an iteration of a loop can make no progress) */
static int fic_re_can_empty(fic_re_cc *cc, int n) {
  int k;
  switch (FN(n).type) {
  case N_CHAR: case N_ANY: case N_CLASS: return 0;
  case N_SEQ: for (k = FN(n).child; k >= 0; k = FN(k).next) if (!fic_re_can_empty(cc, k)) return 0; return 1;
  case N_ALT: for (k = FN(n).child; k >= 0; k = FN(k).next) if (fic_re_can_empty(cc, k)) return 1; return 0;
  case N_GROUP: return fic_re_can_empty(cc, FN(n).child);
  case N_REP: return FN(n).a == 0 || fic_re_can_empty(cc, FN(n).child);
  default: return 1;
  }
}

static void fic_re_emit(fic_re_cc *cc, int32_t w) {
  cc->code = (int32_t *)fic_re_grow(cc->code, &cc->ccap, cc->nc + 1, sizeof(int32_t));
  cc->code[cc->nc++] = w;
}

static int fic_re_is_atom(fic_re_cc *cc, int n) {
  if (FN(n).type == N_SEQ && FN(n).child >= 0 && FN(FN(n).child).next < 0) return fic_re_is_atom(cc, FN(n).child);
  return FN(n).type == N_CHAR || FN(n).type == N_ANY || FN(n).type == N_CLASS;
}

static void fic_re_gen(fic_re_cc *cc, int n, int back);

static void fic_re_gen_atom(fic_re_cc *cc, int n, int back) {
  int32_t bk = back ? FIC_RE_BACK : 0;
  while (FN(n).type == N_SEQ) n = FN(n).child;
  switch (FN(n).type) {
  case N_CHAR: fic_re_emit(cc, FIC_RE_CHAR | bk); fic_re_emit(cc, (int32_t)(cc->ci ? fic_re_canon((uint32_t)FN(n).a) : (uint32_t)FN(n).a)); break;
  case N_ANY: fic_re_emit(cc, FIC_RE_ANY | bk); break;
  default: {
    int32_t k;
    fic_re_emit(cc, FIC_RE_CLASS | bk); fic_re_emit(cc, FN(n).c); fic_re_emit(cc, FN(n).b);
    for (k = 0; k < FN(n).b * 2; k++) fic_re_emit(cc, (int32_t)cc->pool[FN(n).a + k]);
    break; }
  }
}

static void fic_re_gen_rep(fic_re_cc *cc, int n, int back) {
  int child = FN(n).child, greedy = FN(n).c, glo = FN(n).glo, ghi = FN(n).ghi;
  int64_t mn = FN(n).a, mx = FN(n).b;
  int empty, resets = ghi >= glo;
  size_t head, body, patch, patch2;
  if (mx == 0) return;
  if (!back && fic_re_is_atom(cc, child)) {          /* one character per iteration: no counters, one backtrack record */
    fic_re_emit(cc, FIC_RE_REPEAT1); fic_re_emit(cc, (int32_t)mn); fic_re_emit(cc, (int32_t)mx); fic_re_emit(cc, greedy);
    fic_re_gen_atom(cc, child, 0);
    return;
  }
  empty = fic_re_can_empty(cc, child);
  if (!empty && mx < 0 && mn <= 1) {                 /* x* and x+ without counters */
    head = cc->nc;
    if (mn == 0) {
      fic_re_emit(cc, FIC_RE_SPLIT); fic_re_emit(cc, 0); fic_re_emit(cc, 0); patch = head + 1;     /* first, second */
      body = cc->nc;
      if (resets) { fic_re_emit(cc, FIC_RE_RESETCAPS); fic_re_emit(cc, glo); fic_re_emit(cc, ghi); }
      fic_re_gen(cc, child, back);
      fic_re_emit(cc, FIC_RE_JMP); fic_re_emit(cc, (int32_t)head);
      if (greedy) { cc->code[patch] = (int32_t)body; cc->code[patch + 1] = (int32_t)cc->nc; }
      else { cc->code[patch] = (int32_t)cc->nc; cc->code[patch + 1] = (int32_t)body; }
    } else {
      body = cc->nc;
      if (resets) { fic_re_emit(cc, FIC_RE_RESETCAPS); fic_re_emit(cc, glo); fic_re_emit(cc, ghi); }
      fic_re_gen(cc, child, back);
      fic_re_emit(cc, FIC_RE_SPLIT); patch = cc->nc; fic_re_emit(cc, 0); fic_re_emit(cc, 0);
      if (greedy) { cc->code[patch] = (int32_t)body; cc->code[patch + 1] = (int32_t)cc->nc; }
      else { cc->code[patch] = (int32_t)cc->nc; cc->code[patch + 1] = (int32_t)body; }
    }
    return;
  }
  if (!empty && mn == 0 && mx == 1) {                /* x? */
    fic_re_emit(cc, FIC_RE_SPLIT); patch = cc->nc; fic_re_emit(cc, 0); fic_re_emit(cc, 0);
    body = cc->nc;
    fic_re_gen(cc, child, back);
    if (greedy) { cc->code[patch] = (int32_t)body; cc->code[patch + 1] = (int32_t)cc->nc; }
    else { cc->code[patch] = (int32_t)cc->nc; cc->code[patch + 1] = (int32_t)body; }
    return;
  }
  {                                                  /* the general loop with a counter (and a mark when an iteration can be empty) */
    int32_t creg = cc->nregs++, mreg = empty ? cc->nregs++ : -1;
    fic_re_emit(cc, FIC_RE_SETREG); fic_re_emit(cc, creg); fic_re_emit(cc, 0);
    head = cc->nc;
    fic_re_emit(cc, FIC_RE_LOOP); fic_re_emit(cc, creg); fic_re_emit(cc, (int32_t)mn); fic_re_emit(cc, (int32_t)mx); fic_re_emit(cc, greedy);
    patch2 = cc->nc; fic_re_emit(cc, 0);
    if (empty) { fic_re_emit(cc, FIC_RE_MARK); fic_re_emit(cc, mreg); }
    if (resets) { fic_re_emit(cc, FIC_RE_RESETCAPS); fic_re_emit(cc, glo); fic_re_emit(cc, ghi); }
    fic_re_gen(cc, child, back);
    fic_re_emit(cc, FIC_RE_ENDITER); fic_re_emit(cc, creg); fic_re_emit(cc, mreg); fic_re_emit(cc, (int32_t)mn); fic_re_emit(cc, (int32_t)head);
    cc->code[patch2] = (int32_t)cc->nc;
  }
}

static void fic_re_gen(fic_re_cc *cc, int n, int back) {
  int k;
  switch (FN(n).type) {
  case N_EMPTY: break;
  case N_CHAR: case N_ANY: case N_CLASS: fic_re_gen_atom(cc, n, back); break;
  case N_SEQ:
    if (!back) { for (k = FN(n).child; k >= 0; k = FN(k).next) fic_re_gen(cc, k, back); }
    else {
      int cnt = 0, i;
      int *kids;
      for (k = FN(n).child; k >= 0; k = FN(k).next) cnt++;
      kids = (int *)malloc((size_t)(cnt + 1) * sizeof(int));
      if (kids == NULL) abort();
      i = 0;
      for (k = FN(n).child; k >= 0; k = FN(k).next) kids[i++] = k;
      while (i > 0) fic_re_gen(cc, kids[--i], back);
      free(kids);
    }
    break;
  case N_ALT: {
    size_t *js, njs = 0, i, nalt = 0;
    for (k = FN(n).child; k >= 0; k = FN(k).next) nalt++;
    js = (size_t *)malloc(nalt * sizeof(size_t));
    if (js == NULL) abort();
    for (k = FN(n).child; k >= 0; k = FN(k).next) {
      if (FN(k).next >= 0) {
        size_t sp;
        fic_re_emit(cc, FIC_RE_SPLIT); sp = cc->nc; fic_re_emit(cc, (int32_t)(cc->nc + 2)); fic_re_emit(cc, 0);
        fic_re_gen(cc, k, back);
        fic_re_emit(cc, FIC_RE_JMP);
        js[njs++] = cc->nc; fic_re_emit(cc, 0);
        cc->code[sp + 1] = (int32_t)cc->nc;
      } else fic_re_gen(cc, k, back);
    }
    for (i = 0; i < njs; i++) cc->code[js[i]] = (int32_t)cc->nc;
    free(js);
    break; }
  case N_GROUP:
    fic_re_emit(cc, FIC_RE_SAVE); fic_re_emit(cc, back ? 2 * FN(n).a + 1 : 2 * FN(n).a);
    fic_re_gen(cc, FN(n).child, back);
    fic_re_emit(cc, FIC_RE_SAVE); fic_re_emit(cc, back ? 2 * FN(n).a : 2 * FN(n).a + 1);
    break;
  case N_REP: fic_re_gen_rep(cc, n, back); break;
  case N_BOL: fic_re_emit(cc, FIC_RE_BOL); break;
  case N_EOL: fic_re_emit(cc, FIC_RE_EOL); break;
  case N_WORDB: fic_re_emit(cc, FIC_RE_WORDB); break;
  case N_NWORDB: fic_re_emit(cc, FIC_RE_NWORDB); break;
  case N_BACKREF: fic_re_emit(cc, FIC_RE_BACKREF | (back ? FIC_RE_BACK : 0)); fic_re_emit(cc, FN(n).a); break;
  case N_LOOK: {
    size_t patch;
    fic_re_emit(cc, FIC_RE_LOOKSTART); fic_re_emit(cc, FN(n).b); patch = cc->nc; fic_re_emit(cc, 0);
    fic_re_gen(cc, FN(n).child, FN(n).a);
    fic_re_emit(cc, FIC_RE_LOOKEND); fic_re_emit(cc, FN(n).b);
    cc->code[patch] = (int32_t)cc->nc;
    break; }
  default: break;
  }
}

/* Compile: flags 1 = case insensitive, 2 = multiline. The result is a raw vector of the program; an invalid pattern gives a vector
   whose magic word is 0. */
static fic_ref fic_re_compile(int64_t flags, fic_ref pat) {
  fic_re_cc cc;
  fic_ref r;
  int root = -1;
  int32_t hdr[FIC_RE_HDR];
  size_t bytes;
  memset(&cc, 0, sizeof cc);
  cc.p = (const unsigned char *)FIC_STR(pat)->data; cc.end = cc.p + FIC_STR(pat)->len;
  cc.ci = (flags & 1) != 0; cc.ml = (flags & 2) != 0;
  cc.total_groups = fic_re_count_groups(cc.p, cc.end);
  root = fic_re_parse_disj(&cc);
  if (!cc.err && cc.p != cc.end) cc.err = 1;                       /* a `)` without its `(` */
  memset(hdr, 0, sizeof hdr);
  if (!cc.err) {
    int32_t i = 0;
    fic_re_gen(&cc, root, 0);
    fic_re_emit(&cc, FIC_RE_MATCH);
    hdr[0] = FIC_RE_MAGIC; hdr[1] = cc.groups; hdr[2] = cc.nregs; hdr[3] = (int32_t)flags; hdr[4] = (int32_t)cc.nc; hdr[5] = -1; hdr[6] = 0;
    while (cc.code[i] == FIC_RE_SAVE) i += 2;                      /* a literal first character, or a ^ at the start */
    if (cc.code[i] == FIC_RE_CHAR && !cc.ci) {
      char b[4]; fic_us_put(b, (uint32_t)cc.code[i + 1]); hdr[5] = (unsigned char)b[0];
    } else if (cc.code[i] == FIC_RE_BOL && !cc.ml) hdr[6] = 1;
  }
  bytes = sizeof hdr + (cc.err ? 0 : cc.nc * sizeof(int32_t));
  r = fic_vec_new((int64_t)bytes, 1, FIC_TAG_VEC_RAW);
  FIC_VEC(r)->len = (int64_t)bytes;
  memcpy(FIC_VEC(r)->data, hdr, sizeof hdr);
  if (!cc.err) memcpy(FIC_VEC(r)->data + sizeof hdr, cc.code, cc.nc * sizeof(int32_t));
  free(cc.nodes); free(cc.pool); free(cc.tmp); free(cc.code);
  return r;
}

static uint8_t fic_re_valid(fic_ref re) { return ((const int32_t *)FIC_VEC(re)->data)[0] == FIC_RE_MAGIC; }
static int64_t fic_re_groups(fic_ref re) { return ((const int32_t *)FIC_VEC(re)->data)[1]; }
static uint8_t fic_re_eq(fic_ref a, fic_ref b) {
  return FIC_VEC(a)->len == FIC_VEC(b)->len && memcmp(FIC_VEC(a)->data, FIC_VEC(b)->data, (size_t)FIC_VEC(a)->len) == 0;
}

/* ---------------------------------------------------------------- the matcher ---- */
enum { FIC_RE_E_CHOICE, FIC_RE_E_CAP, FIC_RE_E_REG, FIC_RE_E_RANGEG, FIC_RE_E_RANGEL, FIC_RE_E_LOOKP, FIC_RE_E_LOOKN };
typedef struct fic_re_ent { int64_t pos, aux; int32_t pc, kind; } fic_re_ent;
typedef struct fic_re_vm {
  const int32_t *code; int ci, ml;
  const unsigned char *s; int64_t len;
  fic_re_ent *st; size_t sp, cap;
  int64_t *regs, *caps;
  int ncaps, nregs;
  uint64_t steps;
  int status;                                      /* 0 ok, 1 budget exhausted, 2 stack exhausted */
} fic_re_vm;

static int fic_re_push(fic_re_vm *vm, int kind, int32_t pc, int64_t pos, int64_t aux) {
  fic_re_ent *e;
  if (vm->sp == vm->cap) {
    size_t nc = vm->cap ? vm->cap * 2 : 1024;
    fic_re_ent *q;
    if (nc > FIC_RE_MAX_STACK) nc = FIC_RE_MAX_STACK;
    if (nc == vm->cap) { vm->status = 2; return 0; }
    q = (fic_re_ent *)realloc(vm->st, nc * sizeof(fic_re_ent));
    if (q == NULL) { vm->status = 2; return 0; }
    vm->st = q; vm->cap = nc;
  }
  e = &vm->st[vm->sp++];
  e->kind = kind; e->pc = pc; e->pos = pos; e->aux = aux;
  return 1;
}

static int fic_re_is_lt(uint32_t c) { return c == 10 || c == 13 || c == 0x2028u || c == 0x2029u; }

static int fic_re_in_ranges(const int32_t *r, int32_t n, uint32_t c) {
  int32_t lo = 0, hi = n - 1;
  while (lo <= hi) {
    int32_t mid = (lo + hi) / 2;
    if (c < (uint32_t)r[2 * mid]) hi = mid - 1; else if (c > (uint32_t)r[2 * mid + 1]) lo = mid + 1; else return 1;
  }
  return 0;
}

/* a code point against a class: with the i flag any code point of the same canonical form counts */
static int fic_re_class_test(const fic_re_vm *vm, const int32_t *a, uint32_t ch) {
  int r = fic_re_in_ranges(a + 3, a[2], ch);
  if (!r && vm->ci) {
    uint32_t cn = fic_re_canon(ch), l;
    if (cn != ch) r = fic_re_in_ranges(a + 3, a[2], cn);
    if (!r) { l = fic_us_clower(cn); if (l != cn && l != ch && fic_re_canon(l) == cn) r = fic_re_in_ranges(a + 3, a[2], l); }
    if (!r) { l = fic_us_clower(ch); if (l != ch && l != cn && fic_re_canon(l) == cn) r = fic_re_in_ranges(a + 3, a[2], l); }
  }
  return r != a[1];
}

/* the length in words of a character instruction */
static int fic_re_atom_len(const int32_t *a) {
  switch (a[0] & 0xFF) { case FIC_RE_CHAR: return 2; case FIC_RE_ANY: return 1; default: return 3 + 2 * a[2]; }
}

/* one character: forward reads the code point at *pos, backward the one before it */
static int fic_re_step(const fic_re_vm *vm, const int32_t *a, int64_t *pos) {
  uint32_t ch;
  const unsigned char *q;
  if (a[0] & FIC_RE_BACK) {
    if (*pos <= 0) return 0;
    q = vm->s + *pos; ch = fic_us_prev(vm->s, &q); *pos = q - vm->s;
  } else {
    if (*pos >= vm->len) return 0;
    q = vm->s + *pos; ch = fic_us_get(&q); *pos = q - vm->s;
  }
  switch (a[0] & 0xFF) {
  case FIC_RE_CHAR: return vm->ci ? fic_re_canon(ch) == (uint32_t)a[1] : ch == (uint32_t)a[1];
  case FIC_RE_ANY: return !fic_re_is_lt(ch);
  default: return fic_re_class_test(vm, a, ch);
  }
}

static int fic_re_wordch(const fic_re_vm *vm, int64_t at) {      /* ASCII word character at byte at (outside: no) */
  unsigned char c;
  if (at < 0 || at >= vm->len) return 0;
  c = vm->s[at];
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}
static int fic_re_lt_before(const fic_re_vm *vm, int64_t pos) {
  const unsigned char *q;
  if (pos <= 0) return 0;
  q = vm->s + pos;
  return fic_re_is_lt(fic_us_prev(vm->s, &q));
}
static int fic_re_lt_after(const fic_re_vm *vm, int64_t pos) {
  const unsigned char *q;
  if (pos >= vm->len) return 0;
  q = vm->s + pos;
  return fic_re_is_lt(fic_us_get(&q));
}

static int fic_re_undo(fic_re_vm *vm, const fic_re_ent *e) {
  if (e->kind == FIC_RE_E_CAP) { vm->caps[e->pc] = e->pos; return 1; }
  if (e->kind == FIC_RE_E_REG) { vm->regs[e->pc] = e->pos; return 1; }
  return 0;
}

/* The search at one start position. Returns 1 (match; vm->caps filled), 0, or -1 (resource exhaustion; vm->status says which). */
static int fic_re_run(fic_re_vm *vm, int64_t start) {
  const int32_t *code = vm->code;
  int64_t pos = start;
  int32_t pc = 0;
  int i;
  vm->sp = 0;
  for (i = 0; i < vm->ncaps; i++) vm->caps[i] = -1;
  for (i = 0; i < vm->nregs; i++) vm->regs[i] = 0;
  vm->caps[0] = start;
#define FIC_RE_PUSH(kind, pc_, pos_, aux_) do { if (!fic_re_push(vm, (kind), (pc_), (pos_), (aux_))) return -1; } while (0)
  for (;;) {
    if (++vm->steps > FIC_RE_BUDGET) { vm->status = 1; return -1; }
    switch (code[pc] & 0xFF) {
    case FIC_RE_MATCH: vm->caps[1] = pos; return 1;
    case FIC_RE_CHAR: case FIC_RE_ANY: case FIC_RE_CLASS:
      if (!fic_re_step(vm, code + pc, &pos)) goto fail;
      pc += fic_re_atom_len(code + pc);
      continue;
    case FIC_RE_JMP: pc = code[pc + 1]; continue;
    case FIC_RE_SPLIT: FIC_RE_PUSH(FIC_RE_E_CHOICE, code[pc + 2], pos, 0); pc = code[pc + 1]; continue;
    case FIC_RE_SAVE:
      FIC_RE_PUSH(FIC_RE_E_CAP, code[pc + 1], vm->caps[code[pc + 1]], 0);
      vm->caps[code[pc + 1]] = pos; pc += 2; continue;
    case FIC_RE_BOL: if (pos == 0 || (vm->ml && fic_re_lt_before(vm, pos))) { pc++; continue; } goto fail;
    case FIC_RE_EOL: if (pos == vm->len || (vm->ml && fic_re_lt_after(vm, pos))) { pc++; continue; } goto fail;
    case FIC_RE_WORDB: if (fic_re_wordch(vm, pos - 1) != fic_re_wordch(vm, pos)) { pc++; continue; } goto fail;
    case FIC_RE_NWORDB: if (fic_re_wordch(vm, pos - 1) == fic_re_wordch(vm, pos)) { pc++; continue; } goto fail;
    case FIC_RE_BACKREF: {
      int64_t a = vm->caps[2 * code[pc + 1]], b = vm->caps[2 * code[pc + 1] + 1];
      if (a < 0 || b < 0) { pc += 2; continue; }       /* a group that has not taken part matches the empty string */
      if (!vm->ci) {
        int64_t n = b - a;
        if (code[pc] & FIC_RE_BACK) { if (pos < n || memcmp(vm->s + pos - n, vm->s + a, (size_t)n) != 0) goto fail; pos -= n; }
        else { if (vm->len - pos < n || memcmp(vm->s + pos, vm->s + a, (size_t)n) != 0) goto fail; pos += n; }
      } else if (code[pc] & FIC_RE_BACK) {
        const unsigned char *p1 = vm->s + b, *p2 = vm->s + pos;
        while (p1 > vm->s + a) {
          uint32_t c1, c2;
          if (p2 <= vm->s) goto fail;
          c1 = fic_us_prev(vm->s, &p1); c2 = fic_us_prev(vm->s, &p2);
          if (c1 != c2 && fic_re_canon(c1) != fic_re_canon(c2)) goto fail;
        }
        pos = p2 - vm->s;
      } else {
        const unsigned char *p1 = vm->s + a, *p2 = vm->s + pos, *e1 = vm->s + b;
        while (p1 < e1) {
          uint32_t c1, c2;
          if (p2 >= vm->s + vm->len) goto fail;
          c1 = fic_us_get(&p1); c2 = fic_us_get(&p2);
          if (c1 != c2 && fic_re_canon(c1) != fic_re_canon(c2)) goto fail;
        }
        pos = p2 - vm->s;
      }
      pc += 2; continue; }
    case FIC_RE_RESETCAPS: {
      int32_t g;
      for (g = code[pc + 1]; g <= code[pc + 2]; g++) {
        if (vm->caps[2 * g] != -1) { FIC_RE_PUSH(FIC_RE_E_CAP, 2 * g, vm->caps[2 * g], 0); vm->caps[2 * g] = -1; }
        if (vm->caps[2 * g + 1] != -1) { FIC_RE_PUSH(FIC_RE_E_CAP, 2 * g + 1, vm->caps[2 * g + 1], 0); vm->caps[2 * g + 1] = -1; }
      }
      pc += 3; continue; }
    case FIC_RE_SETREG: FIC_RE_PUSH(FIC_RE_E_REG, code[pc + 1], vm->regs[code[pc + 1]], 0); vm->regs[code[pc + 1]] = code[pc + 2]; pc += 3; continue;
    case FIC_RE_MARK: FIC_RE_PUSH(FIC_RE_E_REG, code[pc + 1], vm->regs[code[pc + 1]], 0); vm->regs[code[pc + 1]] = pos; pc += 2; continue;
    case FIC_RE_LOOP: {                                /* c min max greedy exit */
      int64_t n = vm->regs[code[pc + 1]], mn = code[pc + 2], mx = code[pc + 3];
      if (n < mn) { pc += 6; continue; }
      if (mx >= 0 && n >= mx) { pc = code[pc + 5]; continue; }
      if (code[pc + 4]) { FIC_RE_PUSH(FIC_RE_E_CHOICE, code[pc + 5], pos, 0); pc += 6; }
      else { FIC_RE_PUSH(FIC_RE_E_CHOICE, pc + 6, pos, 0); pc = code[pc + 5]; }
      continue; }
    case FIC_RE_ENDITER: {                             /* c mark min head */
      int64_t n = vm->regs[code[pc + 1]];
      if (code[pc + 2] >= 0 && n >= code[pc + 3] && vm->regs[code[pc + 2]] == pos) goto fail;   /* an empty iteration beyond the minimum */
      FIC_RE_PUSH(FIC_RE_E_REG, code[pc + 1], n, 0);
      vm->regs[code[pc + 1]] = n + 1;
      pc = code[pc + 4]; continue; }
    case FIC_RE_LOOKSTART: FIC_RE_PUSH(code[pc + 1] ? FIC_RE_E_LOOKN : FIC_RE_E_LOOKP, code[pc + 2], pos, 0); pc += 3; continue;
    case FIC_RE_LOOKEND: {
      size_t k = vm->sp, j;
      while (k > 0 && vm->st[k - 1].kind != FIC_RE_E_LOOKP && vm->st[k - 1].kind != FIC_RE_E_LOOKN) k--;
      k--;                                             /* the marker */
      if (code[pc + 1] == 0) {                         /* positive: keep the undo records, drop the choices, go back to the start */
        pos = vm->st[k].pos;
        for (j = k + 1; j < vm->sp; j++) if (vm->st[j].kind == FIC_RE_E_CAP || vm->st[j].kind == FIC_RE_E_REG) vm->st[k++] = vm->st[j];
        vm->sp = k; pc += 2; continue;
      }
      while (vm->sp > k + 1) { vm->sp--; fic_re_undo(vm, &vm->st[vm->sp]); }   /* negative: the lookahead matched, so this fails */
      vm->sp = k;
      goto fail; }
    case FIC_RE_REPEAT1: {                             /* min max greedy atom */
      int64_t mn = code[pc + 1], mx = code[pc + 2], p = pos, cnt = 0, plo = pos;
      const int32_t *atom = code + pc + 4;
      int32_t next = pc + 4 + fic_re_atom_len(atom);
      if (code[pc + 3]) {
        while (mx < 0 || cnt < mx) {
          int64_t q = p;
          if (++vm->steps > FIC_RE_BUDGET) { vm->status = 1; return -1; }
          if (!fic_re_step(vm, atom, &q)) break;
          p = q; cnt++;
          if (cnt == mn) plo = p;
        }
        if (cnt < mn) goto fail;
        if (p > plo) FIC_RE_PUSH(FIC_RE_E_RANGEG, pc, plo, p);
      } else {
        while (cnt < mn) {
          if (++vm->steps > FIC_RE_BUDGET) { vm->status = 1; return -1; }
          if (!fic_re_step(vm, atom, &p)) goto fail;
          cnt++;
        }
        if (mx < 0 || cnt < mx) FIC_RE_PUSH(FIC_RE_E_RANGEL, pc, p, cnt);
      }
      pos = p; pc = next; continue; }
    default: return 0;
    }
  fail:
    for (;;) {
      fic_re_ent *e;
      if (vm->sp == 0) return 0;
      if (++vm->steps > FIC_RE_BUDGET) { vm->status = 1; return -1; }
      e = &vm->st[vm->sp - 1];
      switch (e->kind) {
      case FIC_RE_E_CHOICE: pc = e->pc; pos = e->pos; vm->sp--; goto resume;
      case FIC_RE_E_CAP: case FIC_RE_E_REG: fic_re_undo(vm, e); vm->sp--; continue;
      case FIC_RE_E_LOOKP: vm->sp--; continue;
      case FIC_RE_E_LOOKN: pc = e->pc; pos = e->pos; vm->sp--; goto resume;
      case FIC_RE_E_RANGEG: {                          /* a shorter run of the same atom: one code point less */
        int64_t cur = e->aux;
        const unsigned char *q = vm->s + cur;
        const int32_t *atom = code + e->pc + 4;
        fic_us_prev(vm->s, &q);
        cur = q - vm->s;
        pc = e->pc + 4 + fic_re_atom_len(atom); pos = cur;
        if (cur > e->pos) e->aux = cur; else vm->sp--;
        goto resume; }
      case FIC_RE_E_RANGEL: {                          /* one more iteration */
        int64_t cur = e->pos, cnt = e->aux + 1, mx = code[e->pc + 2];
        const int32_t *atom = code + e->pc + 4;
        int32_t save_pc = e->pc;
        vm->sp--;
        if (!fic_re_step(vm, atom, &cur)) continue;
        if (mx < 0 || cnt < mx) { if (!fic_re_push(vm, FIC_RE_E_RANGEL, save_pc, cur, cnt)) return -1; }
        pc = save_pc + 4 + fic_re_atom_len(atom); pos = cur;
        goto resume; }
      default: vm->sp--; continue;
      }
    }
  resume: ;
  }
#undef FIC_RE_PUSH
}

/* Regex.find and friends: the match with the leftmost start at or after the byte offset `from` (a character boundary; `fromcp` is the
   code point index of `from`). The result is a raw vector of int64: 0 entries for no match, else
   [start byte, end byte, start code point index, end code point index, then start and end byte of each group (-1: did not take part)]. */
static fic_ref fic_re_exec(fic_ref re, fic_ref str, int64_t from, int64_t fromcp) {
  const int32_t *prog = (const int32_t *)FIC_VEC(re)->data;
  int64_t len = FIC_STR(str)->len, s, groups = prog[1], n = 4 + 2 * groups, i;
  fic_re_vm vm;
  fic_ref out;
  int found = 0, r = 0;
  if (prog[0] != FIC_RE_MAGIC || from < 0 || from > len) { out = fic_vec_new(1, 8, FIC_TAG_VEC_RAW); FIC_VEC(out)->len = 0; return out; }
  memset(&vm, 0, sizeof vm);
  vm.code = prog + FIC_RE_HDR; vm.ci = prog[3] & 1; vm.ml = (prog[3] & 2) != 0;
  vm.s = (const unsigned char *)FIC_STR(str)->data; vm.len = len;
  vm.ncaps = (int)(2 * (groups + 1)); vm.nregs = prog[2];
  vm.caps = (int64_t *)malloc((size_t)vm.ncaps * sizeof(int64_t));
  vm.regs = (int64_t *)malloc((size_t)(vm.nregs > 0 ? vm.nregs : 1) * sizeof(int64_t));
  if (vm.caps == NULL || vm.regs == NULL) abort();
  s = from;
  while (s <= len) {
    if (prog[5] >= 0) {                                /* the match must start with this byte */
      const unsigned char *q = (const unsigned char *)memchr(vm.s + s, prog[5], (size_t)(len - s));
      if (q == NULL) break;
      s = q - vm.s;
    }
    if (prog[6] && s > 0) break;                       /* ^ without the m flag: only the start of the text */
    r = fic_re_run(&vm, s);
    if (r != 0) { found = r > 0; break; }
    if (s == len) break;
    { const unsigned char *q = vm.s + s; fic_us_get(&q); s = q - vm.s; }
  }
  if (r < 0) {
    free(vm.caps); free(vm.regs); free(vm.st);
    fic_re_exhausted(vm.status == 2 ? "backtracking stack" : "step budget");
    out = fic_vec_new(1, 8, FIC_TAG_VEC_RAW); FIC_VEC(out)->len = 0; return out;
  }
  if (!found) { out = fic_vec_new(1, 8, FIC_TAG_VEC_RAW); FIC_VEC(out)->len = 0; }
  else {
    int64_t *d;
    out = fic_vec_new(n, 8, FIC_TAG_VEC_RAW); FIC_VEC(out)->len = n;
    d = (int64_t *)FIC_VEC(out)->data;
    d[0] = vm.caps[0]; d[1] = vm.caps[1];
    d[2] = fromcp + fic_str_cps_of(FIC_STR(str)->data + from, vm.caps[0] - from);
    d[3] = d[2] + fic_str_cps_of(FIC_STR(str)->data + vm.caps[0], vm.caps[1] - vm.caps[0]);
    for (i = 1; i <= groups; i++) {
      int64_t a = vm.caps[2 * i], b = vm.caps[2 * i + 1];
      if (a < 0 || b < 0) a = b = -1;
      d[2 + 2 * i] = a; d[3 + 2 * i] = b;
    }
  }
  free(vm.caps); free(vm.regs); free(vm.st);
  return out;
}

static uint8_t fic_re_found(fic_ref caps) { return FIC_VEC(caps)->len > 0; }
static int64_t fic_re_cap(fic_ref caps, int64_t i) { return ((const int64_t *)FIC_VEC(caps)->data)[i]; }

/* the text between two byte offsets (a negative `to`: up to the end; both are clamped) */
static fic_ref fic_re_slice(fic_ref str, int64_t from, int64_t to) {
  int64_t len = FIC_STR(str)->len;
  if (to < 0 || to > len) to = len;
  if (from < 0) from = 0;
  if (from > to) from = to;
  return fic_str_new(FIC_STR(str)->data + from, to - from);
}

static int64_t fic_re_size(fic_ref str) { return FIC_STR(str)->len; }

/* the offset after the code point at byte `at` (one more than the size if `at` is the end) */
static int64_t fic_re_advance(fic_ref str, int64_t at) {
  const unsigned char *q;
  if (at >= FIC_STR(str)->len) return FIC_STR(str)->len + 1;
  q = (const unsigned char *)FIC_STR(str)->data + at;
  fic_us_get(&q);
  return q - (const unsigned char *)FIC_STR(str)->data;
}
